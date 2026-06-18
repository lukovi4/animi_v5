import XCTest
import Foundation
import AnimiEngineCore
import AnimiEngineRenderModel
import AnimiEngineRenderGraph

/// Task-003 plan §9 (error model), §4.1 (material/pixel/frame values), §6, §8, §13 rows "Typed
/// errors" / "Input completeness" — render-model value invariants and typed failures.
///
/// Stage-3 scope: the immutable value models and their typed failures. The RenderGraph *compiler* and
/// full *validator* are §17 step 9; this file proves the model-level invariants only.
final class Task003ErrorModelTests: XCTestCase {

    // Module-identity backstop retained from Stage 2.
    func testRenderGraphModuleLinksWithAllowedDependenciesOnly() {
        XCTAssertTrue([RenderGraphError]().isEmpty)
        XCTAssertTrue([RenderModelError]().isEmpty)
    }

    // MARK: - PixelDimensions / ResolvedPixelInput (§6, §8, §9)

    private func bgra8(_ w: Int, _ h: Int) throws -> PixelDimensions {
        try PixelDimensions(width: w, height: h, bytesPerRow: w * 4, format: .bgra8)
    }

    func testMalformedDimensionsRejected() {
        XCTAssertThrowsError(try PixelDimensions(width: 0, height: 4, bytesPerRow: 0, format: .bgra8))
        XCTAssertThrowsError(try PixelDimensions(width: 4, height: -1, bytesPerRow: 16, format: .bgra8))
        // Stride smaller than width * bytesPerPixel.
        XCTAssertThrowsError(try PixelDimensions(width: 4, height: 4, bytesPerRow: 8, format: .bgra8))
    }

    func testPixelByteCountMismatchRejected() throws {
        let dims = try bgra8(2, 2)                     // requires 2*2*4 = 16 bytes
        XCTAssertThrowsError(
            try ResolvedPixelInput(id: try PixelInputID("a"), dimensions: dims, bytes: Data(count: 15))
        ) { error in
            guard case let RenderModelError.pixelByteCountMismatch(expected, actual)? =
                    error as? RenderModelError else { return XCTFail("got \(error)") }
            XCTAssertEqual(expected, 16); XCTAssertEqual(actual, 15)
        }
    }

    func testResolvedPixelInputHashesOverContentDeterministically() throws {
        let dims = try bgra8(2, 2)
        let bytes = Data((0..<16).map { UInt8($0) })
        let a = try ResolvedPixelInput(id: try PixelInputID("x"), dimensions: dims, bytes: bytes)
        let b = try ResolvedPixelInput(id: try PixelInputID("y"), dimensions: dims, bytes: bytes)
        // Same dimensions + bytes → same content hash regardless of id (content identity).
        XCTAssertEqual(a.contentHash, b.contentHash)
        // Different bytes → different hash.
        let c = try ResolvedPixelInput(
            id: try PixelInputID("z"), dimensions: dims, bytes: Data(repeating: 9, count: 16))
        XCTAssertNotEqual(a.contentHash, c.contentHash)
    }

    func testEmptyIdentifierRejected() {
        XCTAssertThrowsError(try PixelInputID("")) { error in
            guard case RenderModelError.emptyIdentifier? = error as? RenderModelError else {
                return XCTFail("got \(error)")
            }
        }
    }

    // MARK: - RenderMaterialTable order independence + duplicate rejection (D3-11, §9)

    func testMaterialTableRejectsDuplicateIDs() throws {
        let dims = try bgra8(1, 1)
        let p1 = try ResolvedPixelInput(id: try PixelInputID("dup"), dimensions: dims, bytes: Data(count: 4))
        let p2 = try ResolvedPixelInput(id: try PixelInputID("dup"), dimensions: dims, bytes: Data(count: 4))
        XCTAssertThrowsError(try RenderMaterialTable(pixelInputs: [p1, p2])) { error in
            guard case RenderModelError.duplicateIdentity? = error as? RenderModelError else {
                return XCTFail("got \(error)")
            }
        }
    }

    func testMaterialTableHashIsInsertionOrderIndependent() throws {
        let dims = try bgra8(1, 1)
        let a = try ResolvedPixelInput(id: try PixelInputID("a"), dimensions: dims, bytes: Data([1, 2, 3, 4]))
        let b = try ResolvedPixelInput(id: try PixelInputID("b"), dimensions: dims, bytes: Data([5, 6, 7, 8]))
        let forward = try RenderMaterialTable(pixelInputs: [a, b])
        let reverse = try RenderMaterialTable(pixelInputs: [b, a])
        XCTAssertEqual(try forward.contentHash(), try reverse.contentHash(),
                       "table hash must be order-independent")
        XCTAssertEqual(forward, reverse)
        // Dictionary storage is hidden: iteration is sorted by id (item 8; no optional lookup).
        XCTAssertEqual(forward.pixelInputs.map { $0.id.rawValue }, ["a", "b"])
    }

    // MARK: - Checked pixel-size arithmetic — Int.max must throw, not trap (item 1)

    func testIntMaxDimensionsThrowOverflowNotTrap() {
        XCTAssertThrowsError(
            try PixelDimensions(width: Int.max, height: 2, bytesPerRow: Int.max, format: .bgra8)
        ) { error in
            guard case RenderModelError.integerOverflow? = error as? RenderModelError else {
                return XCTFail("expected integerOverflow, got \(error)")
            }
        }
        XCTAssertThrowsError(
            try PixelDimensions(width: 4, height: Int.max, bytesPerRow: 16, format: .bgra8)
        ) { error in
            guard case RenderModelError.integerOverflow? = error as? RenderModelError else {
                return XCTFail("expected integerOverflow, got \(error)")
            }
        }
    }

    func testRequiredByteCountIsStoredAndChecked() throws {
        let dims = try PixelDimensions(width: 3, height: 2, bytesPerRow: 12, format: .bgra8)
        XCTAssertEqual(dims.requiredByteCount, 24)   // 2 * 12
    }

    // MARK: - Defensive byte ownership against external backing memory (item 3)

    /// Allocate raw heap memory, wrap it with `Data(bytesNoCopy:)` (so the `Data` is a *view* over
    /// memory we still control), build the model, then mutate the backing memory directly. The
    /// model's stored bytes and hashes must be unaffected — proving an independent owned copy.
    private func withNoCopyBuffer(count: Int, fill: UInt8, _ body: (Data, UnsafeMutableRawPointer) throws -> Void) rethrows {
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 1)
        defer { ptr.deallocate() }
        ptr.initializeMemory(as: UInt8.self, repeating: fill, count: count)
        // `Data` does NOT free the buffer (deallocator: .none); we own it.
        let view = Data(bytesNoCopy: ptr, count: count, deallocator: .none)
        try body(view, ptr)
    }

    func testResolvedPixelInputIsolatedFromExternalBackingMemory() throws {
        // Large buffer: 256x256 BGRA8 = 262144 bytes.
        let w = 256, h = 256, count = w * h * 4
        let dims = try PixelDimensions(width: w, height: h, bytesPerRow: w * 4, format: .bgra8)
        try withNoCopyBuffer(count: count, fill: 0xAB) { view, ptr in
            let input = try ResolvedPixelInput(id: try PixelInputID("big"), dimensions: dims, bytes: view)
            let hashBefore = input.contentHash
            let bytesBefore = input.bytes

            // Mutate the external backing memory directly, behind the Data view's back.
            ptr.assumingMemoryBound(to: UInt8.self)[0] = 0x00
            ptr.assumingMemoryBound(to: UInt8.self)[count - 1] = 0x00

            XCTAssertEqual(input.bytes, bytesBefore, "stored bytes must not track external mutation")
            XCTAssertEqual(input.bytes.first, 0xAB, "first byte must remain the originally-copied value")
            XCTAssertEqual(input.bytes.last, 0xAB, "last byte must remain the originally-copied value")
            XCTAssertEqual(input.contentHash, hashBefore, "content hash must remain unchanged")
        }
    }

    func testRenderedFrameIsolatedFromExternalBackingMemory() throws {
        let w = 256, h = 256, count = w * h * 4
        let dims = try PixelDimensions(width: w, height: h, bytesPerRow: w * 4, format: .bgra8)
        try withNoCopyBuffer(count: count, fill: 0xCD) { view, ptr in
            let frame = try RenderedFrame(dimensions: dims, colorContract: .task003, bytes: view)
            let hashBefore = frame.rawOutputHash
            let bytesBefore = frame.bytes

            ptr.assumingMemoryBound(to: UInt8.self)[0] = 0x11
            ptr.assumingMemoryBound(to: UInt8.self)[count / 2] = 0x22

            XCTAssertEqual(frame.bytes, bytesBefore, "frame bytes must not track external mutation")
            XCTAssertEqual(frame.bytes.first, 0xCD)
            XCTAssertEqual(frame.rawOutputHash, hashBefore, "raw-output hash must remain unchanged")
        }
    }

    // MARK: - RenderedFrame (§8)

    func testRenderedFrameRequiresCompleteBytesAndBGRA8() throws {
        let dims = try bgra8(2, 1)                     // 8 bytes
        XCTAssertThrowsError(
            try RenderedFrame(dimensions: dims, colorContract: .task003, bytes: Data(count: 7)))
        let frame = try RenderedFrame(dimensions: dims, colorContract: .task003, bytes: Data(count: 8))
        XCTAssertFalse(frame.rawOutputHash.isEmpty)
        // §8: raw-output hash includes the colour contract — distinct from the pixel-only hash by both
        // the domain tag and the colour-contract fields.
        let pixelOnly = try RenderCanonicalEncoding.pixelContentHash(dimensions: dims, bytes: Data(count: 8))
        XCTAssertNotEqual(frame.rawOutputHash, pixelOnly)
    }

    // MARK: - Canonical encoding: duplicate keys fail closed + hash domains (item 7)

    func testCanonicalObjectRejectsDuplicateKeys() {
        XCTAssertThrowsError(
            try RenderCanonicalEncoding.object([("k", .int(1)), ("k", .int(2))])
        ) { error in
            guard case let RenderModelError.duplicateIdentity(field, value)? = error as? RenderModelError else {
                return XCTFail("got \(error)")
            }
            XCTAssertEqual(field, "canonicalObjectKey"); XCTAssertEqual(value, "k")
        }
    }

    func testHashDomainsSeparateOtherwiseIdenticalValues() throws {
        // The same inner value hashed under two domains must differ (domain/schema identifiers).
        let value = try RenderCanonicalEncoding.object([("x", .int(1))])
        let a = try RenderCanonicalEncoding.sha256Hex(of: value, domain: .renderConfiguration)
        let b = try RenderCanonicalEncoding.sha256Hex(of: value, domain: .renderGraph)
        XCTAssertNotEqual(a, b, "distinct hash domains must not collide")
    }

    /// `write(_:into:)` is transactional: a validation failure leaves the caller's `output` exactly
    /// unchanged. Uses a pre-populated buffer and a deeply nested duplicate-key object.
    func testWriteIsTransactionalOnDuplicateKey() {
        let sentinel = "PRE-EXISTING-CONTENT{}[]\"\n"
        var output = sentinel
        // Duplicate key buried several levels deep, inside arrays and objects.
        let deeplyNested = RenderCanonicalEncoding.Value.object([
            ("a", .array([
                .int(1),
                .object([
                    ("b", .object([
                        ("c", .array([
                            .object([("dup", .int(1)), ("keep", .int(0)), ("dup", .int(2))])
                        ]))
                    ]))
                ])
            ]))
        ])
        XCTAssertThrowsError(try RenderCanonicalEncoding.write(deeplyNested, into: &output)) { error in
            guard case let RenderModelError.duplicateIdentity(field, value)? =
                    error as? RenderModelError else {
                return XCTFail("expected duplicateIdentity, got \(error)")
            }
            XCTAssertEqual(field, "canonicalObjectKey"); XCTAssertEqual(value, "dup")
        }
        // The caller's buffer must be byte-for-byte unchanged after the failed write.
        XCTAssertEqual(output, sentinel, "output must remain exactly unchanged on a failed write")
    }

    /// Item 1: a directly-constructed `.object` with a NESTED duplicate key must fail closed with a
    /// typed error through **every public encoding entry point** — never a precondition/fatalError.
    func testNestedDuplicateKeyFailsClosedThroughEveryEntryPoint() throws {
        // Bypass the checked `object(_:)` factory: build a raw nested object with a duplicate key.
        let nestedDuplicate = RenderCanonicalEncoding.Value.object([
            ("outer", .object([("dup", .int(1)), ("dup", .int(2))]))
        ])

        func assertDuplicate(_ body: () throws -> Void, _ entry: String) {
            XCTAssertThrowsError(try body(), "expected fail-closed at \(entry)") { error in
                guard case let RenderModelError.duplicateIdentity(field, value)? =
                        error as? RenderModelError else {
                    return XCTFail("\(entry): expected duplicateIdentity, got \(error)")
                }
                XCTAssertEqual(field, "canonicalObjectKey"); XCTAssertEqual(value, "dup")
            }
        }

        // 1) write(_:into:)
        assertDuplicate({ var s = ""; try RenderCanonicalEncoding.write(nestedDuplicate, into: &s) }, "write")
        // 2) canonicalBytes(_:)
        assertDuplicate({ _ = try RenderCanonicalEncoding.canonicalBytes(nestedDuplicate) }, "canonicalBytes")
        // 3) domainBytes(_:domain:)
        assertDuplicate({ _ = try RenderCanonicalEncoding.domainBytes(nestedDuplicate, domain: .renderGraph) }, "domainBytes")
        // 4) sha256Hex(of:domain:)
        assertDuplicate({ _ = try RenderCanonicalEncoding.sha256Hex(of: nestedDuplicate, domain: .renderGraph) }, "sha256Hex")
    }

    // MARK: - AnimationProgram invariant (§4.1, D3-06, item 4)

    func testAnimationProgramRequiresPositiveTickDuration() throws {
        XCTAssertThrowsError(
            try AnimationProgram(id: try AnimationProgramID("p"), authoredDuration: .zero))
        let program = try AnimationProgram(
            id: try AnimationProgramID("p"), authoredDuration: try TickDuration(ticks: 240_000))
        XCTAssertEqual(program.authoredDuration.ticks, 240_000)
        XCTAssertFalse(try program.programHash().isEmpty)
    }

    // MARK: - RenderPathResource fail-closed invariants (Stage-6 item 3)

    /// A valid 4-vertex single-keyframe path resource (vertexCount*2 == 8 position values, 6 indices,
    /// 0 easing == keyframeCount-1). Mirrors the real fixtures' shape.
    private func validPathArgs() -> (
        pathID: Int, vertexCount: Int, indices: [Int],
        keyframeTimes: [RationalSourceTime], keyframePositions: [[CanvasScalar]], keyframeEasing: [RenderPathEasing?]
    ) {
        let cs: (Int64) -> CanvasScalar = { CanvasScalar(rawValue: $0) }
        return (0, 4, [0, 1, 2, 0, 2, 3],
                [RationalSourceTime.zero],
                [[cs(0), cs(0), cs(1), cs(0), cs(1), cs(1), cs(0), cs(1)]],
                [])
    }

    func testValidPathResourceConstructs() throws {
        let a = validPathArgs()
        XCTAssertNoThrow(try RenderPathResource(
            pathID: a.pathID, vertexCount: a.vertexCount, indices: a.indices,
            keyframeTimes: a.keyframeTimes, keyframePositions: a.keyframePositions, keyframeEasing: a.keyframeEasing))
    }

    func testPathResourceRejectsNegativePathID() {
        let a = validPathArgs()
        XCTAssertThrowsError(try RenderPathResource(
            pathID: -1, vertexCount: a.vertexCount, indices: a.indices,
            keyframeTimes: a.keyframeTimes, keyframePositions: a.keyframePositions, keyframeEasing: a.keyframeEasing))
    }

    func testPathResourceRejectsVertexCountBelowThree() {
        let cs: (Int64) -> CanvasScalar = { CanvasScalar(rawValue: $0) }
        XCTAssertThrowsError(try RenderPathResource(
            pathID: 0, vertexCount: 2, indices: [0, 1, 0],
            keyframeTimes: [.zero], keyframePositions: [[cs(0), cs(0), cs(1), cs(0)]], keyframeEasing: []))
    }

    func testPathResourceRejectsEmptyKeyframes() {
        XCTAssertThrowsError(try RenderPathResource(
            pathID: 0, vertexCount: 4, indices: [0, 1, 2], keyframeTimes: [], keyframePositions: [], keyframeEasing: []))
    }

    func testPathResourceRejectsTimesPositionsCountMismatch() {
        let a = validPathArgs()
        XCTAssertThrowsError(try RenderPathResource(
            pathID: 0, vertexCount: 4, indices: a.indices,
            keyframeTimes: [.zero, .zero], keyframePositions: a.keyframePositions, keyframeEasing: [nil]))
    }

    func testPathResourceRejectsWrongPositionRowLength() {
        let cs: (Int64) -> CanvasScalar = { CanvasScalar(rawValue: $0) }
        let a = validPathArgs()
        XCTAssertThrowsError(try RenderPathResource(
            pathID: 0, vertexCount: 4, indices: a.indices,
            keyframeTimes: [.zero], keyframePositions: [[cs(0), cs(0)]], keyframeEasing: []))  // row 2 != 8
    }

    func testPathResourceRejectsWrongEasingCount() {
        let a = validPathArgs()
        // keyframeCount 1 → easing must be 0; supply 1.
        let easing = RenderPathEasing(outX: EasingScalar(rawValue: 0), outY: EasingScalar(rawValue: 0),
                                      inX: EasingScalar(rawValue: 0), inY: EasingScalar(rawValue: 0), hold: false)
        XCTAssertThrowsError(try RenderPathResource(
            pathID: 0, vertexCount: 4, indices: a.indices,
            keyframeTimes: a.keyframeTimes, keyframePositions: a.keyframePositions, keyframeEasing: [easing]))
    }

    func testPathResourceRejectsEmptyOrNonMultipleOfThreeIndices() {
        let a = validPathArgs()
        XCTAssertThrowsError(try RenderPathResource(
            pathID: 0, vertexCount: 4, indices: [],
            keyframeTimes: a.keyframeTimes, keyframePositions: a.keyframePositions, keyframeEasing: a.keyframeEasing))
        XCTAssertThrowsError(try RenderPathResource(
            pathID: 0, vertexCount: 4, indices: [0, 1],
            keyframeTimes: a.keyframeTimes, keyframePositions: a.keyframePositions, keyframeEasing: a.keyframeEasing))
    }

    func testPathResourceRejectsIndexOutOfVertexRange() {
        let a = validPathArgs()
        XCTAssertThrowsError(try RenderPathResource(
            pathID: 0, vertexCount: 4, indices: [0, 1, 4],  // 4 not < vertexCount 4
            keyframeTimes: a.keyframeTimes, keyframePositions: a.keyframePositions, keyframeEasing: a.keyframeEasing))
    }
}
