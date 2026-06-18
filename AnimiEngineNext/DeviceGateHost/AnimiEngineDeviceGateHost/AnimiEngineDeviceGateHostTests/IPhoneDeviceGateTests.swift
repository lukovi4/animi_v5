import XCTest
import Foundation
import Metal
import AnimiEngineCore
import AnimiEngineRenderModel
import AnimiEngineRenderGraph
@testable import AnimiEngineMetalRender

/// Task-003 Step-10 iPhone device-verification gate — APP-HOSTED on the iPhone 13 Pro.
///
/// This lives in the `AnimiEngineDeviceGateHost` app-hosted unit-test target (not the SwiftPM tool-hosted
/// `AnimiEngineMetalRenderTests`), which is what makes on-device execution possible. It verifies ONLY the
/// four device-specific facts the macOS host cannot prove:
///   * D0 — running on a physical iOS device, NOT a simulator (hard failure on simulator);
///   * D1 — the iOS `.private` staging upload path is active;
///   * D2 — the execution-event order **including `uploadBlit`** (which only fires on iOS);
///   * D3 — device/GPU/OS evidence (MTLDevice.name, registryID, utsname model, iOS version/build).
///
/// It uses the existing public API + the package-internal `onExecutionEvent` seam via `@testable import`,
/// plus a small **test-only** helper struct (`DeviceGateEnv`) inlined here (it mirrors the package's
/// `MetalTestEnvironment` builders, which are not importable from a separate target). NO engine production
/// API is extended.
final class IPhoneDeviceGateTests: XCTestCase {

    // MARK: - Test-only helpers (inlined; not engine API)

    enum DeviceGateEnv {
        static func makeDevice() -> MTLDevice? { MTLCreateSystemDefaultDevice() }

        static func requireDevice(file: StaticString = #filePath, line: UInt = #line) throws -> MTLDevice {
            guard let device = makeDevice() else { throw XCTSkip("no Metal device available") }
            return device
        }

        static func canvasRaw(_ points: Int64) -> Int64 { points * CanvasScalar.unitsPerPoint }

        static func configuration(width: Int64, height: Int64, profile: IntermediateProfile) throws -> RenderConfiguration {
            let canvas = try CanvasSize(width: width, height: height)
            let output = OutputContext(canvas: canvas, frameRate: try FrameRate(numerator: 30, denominator: 1))
            return try RenderConfiguration(output: output, intermediateProfile: profile)
        }

        static func linearCanvasDescriptor(width: Int64, height: Int64, profile: IntermediateProfile) -> RenderResourceDescriptor {
            RenderResourceDescriptor(
                offscreenID: RenderSurface.linearCanvas,
                width: canvasRaw(width), height: canvasRaw(height),
                profile: .intermediate(profile), colorContract: .task003)
        }

        static func sRGBSurfaceDescriptor(width: Int64, height: Int64) -> RenderResourceDescriptor {
            RenderResourceDescriptor(
                offscreenID: RenderSurface.sRGBSurface,
                width: canvasRaw(width), height: canvasRaw(height),
                profile: .finalSRGB, colorContract: .task003)
        }

        /// Build a BGRA8 premultiplied pixel input from straight sRGB-byte channels (8-bit rounding).
        static func makePixelInput(
            id: String, width: Int, height: Int,
            straightBGRA: [(b: UInt8, g: UInt8, r: UInt8, a: UInt8)]
        ) throws -> ResolvedPixelInput {
            let bpr = width * 4
            precondition(straightBGRA.count == width * height)
            var data = Data(count: bpr * height)
            data.withUnsafeMutableBytes { raw in
                let p = raw.bindMemory(to: UInt8.self).baseAddress!
                for y in 0..<height {
                    for x in 0..<width {
                        let s = straightBGRA[y * width + x]
                        let a = Int(s.a)
                        func pm(_ c: UInt8) -> UInt8 { UInt8((Int(c) * a + 127) / 255) }
                        let off = y * bpr + x * 4
                        p[off + 0] = pm(s.b)
                        p[off + 1] = pm(s.g)
                        p[off + 2] = pm(s.r)
                        p[off + 3] = s.a
                    }
                }
            }
            let dims = try PixelDimensions(width: width, height: height, bytesPerRow: bpr, format: .bgra8)
            return try ResolvedPixelInput(id: try PixelInputID(id), dimensions: dims, bytes: data)
        }

        static func singleImageGraph(
            width: Int64, height: Int64, profile: IntermediateProfile, pixels: ResolvedPixelInput,
            transform: FixedAffineTransform2D = .identity, opacity: OpacityScalar = .opaque
        ) throws -> RenderGraph {
            let config = try configuration(width: width, height: height, profile: profile)
            var cmds: [RenderCommand] = []
            var o = 0
            func add(_ p: RenderCommandPayload) throws { cmds.append(try RenderCommand(ordinal: o, payload: p)); o += 1 }
            try add(.declareResource(RenderResourceDescriptor(pixelInputID: pixels.id.rawValue, pixels: pixels, colorContract: .task003)))
            try add(.offscreenSurface(linearCanvasDescriptor(width: width, height: height, profile: profile)))
            try add(.offscreenSurface(sRGBSurfaceDescriptor(width: width, height: height)))
            try add(.clearBackground(color: .transparentBlack, targetSurfaceID: RenderSurface.linearCanvas))
            try add(.beginScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas))
            try add(.drawImage(resourceID: pixels.id.rawValue, transform: transform, opacity: opacity, targetSurfaceID: RenderSurface.linearCanvas))
            try add(.endScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas))
            try add(.finalLinearToSRGB(sourceSurfaceID: RenderSurface.linearCanvas, targetSurfaceID: RenderSurface.sRGBSurface))
            try add(.finalOutput(sourceSurfaceID: RenderSurface.sRGBSurface))
            return try RenderGraph(configuration: config, commands: cmds)
        }

        static func pixel(_ frame: RenderedFrame, x: Int, y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
            let bpr = frame.dimensions.bytesPerRow
            let off = y * bpr + x * 4
            let bytes = [UInt8](frame.bytes)
            return (bytes[off], bytes[off + 1], bytes[off + 2], bytes[off + 3])
        }

        // Step-13 (D7) device evidence: an INLINE deterministic PNG encoder, identical algorithm to the
        // product `DeterministicPNGEncoder` (stored DEFLATE + filter 0 + hand CRC32/Adler32). It is inlined
        // here because the DeviceGateHost project links only `AnimiEngineMetalRender` and the project
        // structure must not change (hard constraint 3); `AnimiEngineRenderTestSupport` is not importable.
        // The device case only needs to prove a device-rendered frame encodes to a deterministic PNG.
        static func encodeDeterministicPNG(_ frame: RenderedFrame) -> Data {
            let w = frame.dimensions.width, h = frame.dimensions.height, bpr = frame.dimensions.bytesPerRow
            let src = [UInt8](frame.bytes)
            let rowStride = w * 4 + 1
            var raw = [UInt8](); raw.reserveCapacity(rowStride * h)
            for y in 0..<h {
                raw.append(0)
                var x = 0
                while x < w {
                    let p = y * bpr + x * 4
                    raw.append(src[p + 2]); raw.append(src[p + 1]); raw.append(src[p + 0]); raw.append(src[p + 3])  // BGRA→RGBA
                    x += 1
                }
            }
            func be32(_ v: UInt32) -> [UInt8] { [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
            func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
            var table = [UInt32](repeating: 0, count: 256)
            for n in 0..<256 { var c = UInt32(n); for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }; table[n] = c }
            func crc32(_ d: [UInt8]) -> UInt32 { var c: UInt32 = 0xFFFFFFFF; for b in d { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }; return c ^ 0xFFFFFFFF }
            func adler(_ d: [UInt8]) -> UInt32 { let m: UInt32 = 65521; var a: UInt32 = 1, b: UInt32 = 0; for x in d { a = (a + UInt32(x)) % m; b = (b + a) % m }; return (b << 16) | a }
            func chunk(_ png: inout [UInt8], _ type: String, _ data: [UInt8]) {
                let t = Array(type.utf8); png += be32(UInt32(data.count)); png += t; png += data; var ci = t; ci += data; png += be32(crc32(ci))
            }
            var idat: [UInt8] = [0x78, 0x01]; var i = 0
            if raw.isEmpty { idat.append(0x01); idat += le16(0); idat += le16(0xFFFF) }
            else { while i < raw.count { let len = min(65535, raw.count - i); let fin = (i + len) >= raw.count; idat.append(fin ? 0x01 : 0x00); idat += le16(len); idat += le16(len ^ 0xFFFF); idat += raw[i..<(i + len)]; i += len } }
            idat += be32(adler(raw))
            var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
            var ihdr = be32(UInt32(w)) + be32(UInt32(h)); ihdr += [8, 6, 0, 0, 0]
            chunk(&png, "IHDR", ihdr); chunk(&png, "IDAT", idat); chunk(&png, "IEND", [])
            return Data(png)
        }

        static func canvasScalar(_ raw: Int64) -> CanvasScalar { CanvasScalar(rawValue: raw) }

        static func isoSurface(_ id: String, width: Int64, height: Int64) -> RenderCommandPayload {
            .offscreenSurface(RenderResourceDescriptor(
                offscreenID: id, width: canvasRaw(width), height: canvasRaw(height),
                profile: .intermediate(.rgba16FloatLinear), colorContract: .task003))
        }

        /// Step-11 (Rev-4) combined frame: a masked red fill (left-half `add` mask) matted by a left-half
        /// alpha source — exercises drawShape + an ordered mask group + matteLink on device.
        static func step11CombinedGraph(width: Int64, height: Int64) throws -> RenderGraph {
            let pt = CanvasScalar.unitsPerPoint
            func mesh(_ pathID: Int, _ coords: [Int64]) throws -> SampledPathMesh {
                try SampledPathMesh(pathID: pathID, positions: coords.map { canvasScalar($0 * pt) },
                                    indices: [0, 1, 2, 0, 2, 3], closed: true)
            }
            let full = try mesh(1, [0, 0, width, 0, width, height, 0, height])
            let leftHalf = try mesh(2, [0, 0, width / 2, 0, width / 2, height, 0, height])
            let red = try SampledSRGBAColor(components: [.one, .zero, .zero, .one])
            let white = try SampledSRGBAColor(components: [.one, .one, .one, .one])
            let maskedShape = try SampledShape(fillMesh: full, fillColor: red, fillOpacity: .opaque, stroke: nil, groupOpacity: .opaque)
            let srcShape = try SampledShape(fillMesh: leftHalf, fillColor: white, fillOpacity: .opaque, stroke: nil, groupOpacity: .opaque)
            let maskOp = SampledMaskOperation(mode: .add, inverted: false, opacity: .opaque, mesh: leftHalf, pathToTarget: .identity)

            let config = try configuration(width: width, height: height, profile: .rgba16FloatLinear)
            var cmds: [RenderCommand] = []
            var o = 0
            func add(_ p: RenderCommandPayload) throws { cmds.append(try RenderCommand(ordinal: o, payload: p)); o += 1 }
            let content = "iso\u{1F}content", src = "iso\u{1F}src", con = "iso\u{1F}con"
            try add(.offscreenSurface(linearCanvasDescriptor(width: width, height: height, profile: .rgba16FloatLinear)))
            try add(.offscreenSurface(sRGBSurfaceDescriptor(width: width, height: height)))
            try add(isoSurface(content, width: width, height: height))
            try add(isoSurface(src, width: width, height: height))
            try add(isoSurface(con, width: width, height: height))
            try add(.clearBackground(color: .transparentBlack, targetSurfaceID: RenderSurface.linearCanvas))
            try add(.beginScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas))
            // Matte consumer: a masked red fill isolated in `con`, matted by a left-half alpha source.
            try add(.clearBackground(color: .transparentBlack, targetSurfaceID: src))
            try add(.clearBackground(color: .transparentBlack, targetSurfaceID: con))
            try add(.drawShape(shape: srcShape, transform: .identity, opacity: .opaque, targetSurfaceID: src))
            // Consumer content is itself masked: isolate into `content`, mask into `con`.
            try add(.clearBackground(color: .transparentBlack, targetSurfaceID: content))
            try add(.beginMask(operations: [maskOp], contentSurfaceID: content, targetSurfaceID: con))
            try add(.drawShape(shape: maskedShape, transform: .identity, opacity: .opaque, targetSurfaceID: content))
            try add(.endMask(contentSurfaceID: content, targetSurfaceID: con))
            try add(.matteLink(mode: .alpha, sourceLayerID: 2, consumerLayerID: 1, sourceSurfaceID: src, consumerSurfaceID: con, targetSurfaceID: RenderSurface.linearCanvas))
            try add(.endScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas))
            try add(.finalLinearToSRGB(sourceSurfaceID: RenderSurface.linearCanvas, targetSurfaceID: RenderSurface.sRGBSurface))
            try add(.finalOutput(sourceSurfaceID: RenderSurface.sRGBSurface))
            return try RenderGraph(configuration: config, commands: cmds)
        }

        /// Step-12 (Rev-1) device graph: a slide transition (incoming green over stationary outgoing red,
        /// halfway left) with an opaque blue overlay above the body — exercises slideTransition + overlay
        /// (and the fade path is exercised by the separate fade device case below). `effect` selects fade
        /// vs slide.
        static func step12Graph(width: Int64, height: Int64, fade: Bool, withOverlay: Bool) throws -> RenderGraph {
            let pt = CanvasScalar.unitsPerPoint
            func fullShape(_ pathID: Int, _ comps: [NormalizedColorComponent]) throws -> SampledShape {
                let mesh = try SampledPathMesh(pathID: pathID,
                    positions: [CanvasScalar(rawValue: 0), CanvasScalar(rawValue: 0),
                                CanvasScalar(rawValue: width * pt), CanvasScalar(rawValue: 0),
                                CanvasScalar(rawValue: width * pt), CanvasScalar(rawValue: height * pt),
                                CanvasScalar(rawValue: 0), CanvasScalar(rawValue: height * pt)],
                    indices: [0, 1, 2, 0, 2, 3], closed: true)
                return try SampledShape(fillMesh: mesh, fillColor: try SampledSRGBAColor(components: comps),
                                        fillOpacity: .opaque, stroke: nil, groupOpacity: .opaque)
            }
            let red = try fullShape(1, [.one, .zero, .zero, .one])
            let green = try fullShape(3, [.zero, .one, .zero, .one])
            let config = try configuration(width: width, height: height, profile: .rgba16FloatLinear)
            var cmds: [RenderCommand] = []
            var o = 0
            func add(_ p: RenderCommandPayload) throws { cmds.append(try RenderCommand(ordinal: o, payload: p)); o += 1 }
            let outgoing = "iso\u{1F}out", incoming = "iso\u{1F}in"
            if withOverlay {
                let ov = try makePixelInput(id: "ov12", width: Int(width), height: Int(height),
                                            straightBGRA: Array(repeating: (b: 255, g: 0, r: 0, a: 255), count: Int(width * height)))
                try add(.declareResource(RenderResourceDescriptor(pixelInputID: "ov12", pixels: ov, colorContract: .task003)))
            }
            try add(.offscreenSurface(linearCanvasDescriptor(width: width, height: height, profile: .rgba16FloatLinear)))
            try add(.offscreenSurface(sRGBSurfaceDescriptor(width: width, height: height)))
            try add(isoSurface(outgoing, width: width, height: height))
            try add(isoSurface(incoming, width: width, height: height))
            try add(.clearBackground(color: .transparentBlack, targetSurfaceID: RenderSurface.linearCanvas))
            try add(.clearBackground(color: .transparentBlack, targetSurfaceID: outgoing))
            try add(.beginScene(sceneID: "o", role: .outgoing, targetSurfaceID: outgoing))
            try add(.drawShape(shape: red, transform: .identity, opacity: .opaque, targetSurfaceID: outgoing))
            try add(.endScene(sceneID: "o", role: .outgoing, targetSurfaceID: outgoing))
            try add(.clearBackground(color: .transparentBlack, targetSurfaceID: incoming))
            try add(.beginScene(sceneID: "i", role: .incoming, targetSurfaceID: incoming))
            try add(.drawShape(shape: green, transform: .identity, opacity: .opaque, targetSurfaceID: incoming))
            try add(.endScene(sceneID: "i", role: .incoming, targetSurfaceID: incoming))
            if fade {
                try add(.fadeTransition(easedProgress: try UnitInterval(rawValue: 500_000),
                                        outgoingSurfaceID: outgoing, incomingSurfaceID: incoming, targetSurfaceID: RenderSurface.linearCanvas))
            } else {
                try add(.slideTransition(direction: .left, easedProgress: try UnitInterval(rawValue: 500_000),
                                         offsetX: -(width / 2) * pt, offsetY: 0,
                                         outgoingSurfaceID: outgoing, incomingSurfaceID: incoming, targetSurfaceID: RenderSurface.linearCanvas))
            }
            if withOverlay {
                let one = FixedAffineTransform2D.linearUnitsPerOne
                let sizing = FixedAffineTransform2D.scale(scaleX: one, scaleY: one)   // 1px→1pt, canvas-sized overlay
                try add(.overlay(resourceID: "ov12", transform: sizing, opacity: .opaque, compositionOrder: 0, targetSurfaceID: RenderSurface.linearCanvas))
            }
            try add(.finalLinearToSRGB(sourceSurfaceID: RenderSurface.linearCanvas, targetSurfaceID: RenderSurface.sRGBSurface))
            try add(.finalOutput(sourceSurfaceID: RenderSurface.sRGBSurface))
            return try RenderGraph(configuration: config, commands: cmds)
        }

        static func srgbToLinear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        static func linearToSRGB(_ c: Double) -> Double { c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1.0 / 2.4) - 0.055 }
        static func opaqueRoundTripByte(_ srgbByte: UInt8) -> UInt8 {
            let s = Double(srgbByte) / 255.0
            let q = (linearToSRGB(srgbToLinear(s)) * 255.0 + 0.5).rounded(.down)
            return UInt8(min(255.0, max(0.0, q)))
        }
    }

    private func modelIdentifier() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        return Mirror(reflecting: sysinfo.machine).children.reduce(into: "") { acc, el in
            guard let v = el.value as? Int8, v != 0 else { return }
            acc.append(Character(UnicodeScalar(UInt8(v))))
        }
    }

    private func osBuild() -> String {
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("kern.osversion", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    // MARK: - D0 — physical iOS device, not a simulator (HARD failure on simulator)

    func testRunningOnPhysicalDeviceNotSimulator() throws {
        #if targetEnvironment(simulator)
        XCTFail("Device gate must run on a PHYSICAL iPhone 13 Pro, not the iOS Simulator.")
        #elseif !os(iOS)
        XCTFail("Device gate must run on iOS hardware, not \(ProcessInfo.processInfo.operatingSystemVersionString).")
        #else
        guard MTLCreateSystemDefaultDevice() != nil else { return XCTFail("No Metal device on the physical iOS device.") }
        XCTAssertTrue(true)
        #endif
    }

    // MARK: - D1 — iOS `.private` staging path active

    func testPrivateStagingPathActive() throws {
        let device = try DeviceGateEnv.requireDevice()
        let allocator = MetalTextureAllocator(device: device)
        XCTAssertTrue(allocator.pixelInputNeedsStagedUpload,
                      "iOS `.private` staging upload path must be active on the physical device")
    }

    // MARK: - D2 — execution-event order INCLUDING uploadBlit (iOS-only event)

    func testExecutionEventOrderIncludesUploadBlit() throws {
        let device = try DeviceGateEnv.requireDevice()
        let session = try MetalRenderSession(device: device)
        let img = try DeviceGateEnv.makePixelInput(
            id: "device-events", width: 2, height: 2,
            straightBGRA: Array(repeating: (b: 0, g: 0, r: 255, a: 255), count: 4))
        let graph = try DeviceGateEnv.singleImageGraph(width: 2, height: 2, profile: .rgba16FloatLinear, pixels: img)

        let expectedOrder: [ExecutionEvent] = [
            .uploadBlit,
            .normalize(resourceID: img.id.rawValue),
            .sceneRender,
            .finalConversion,
            .readbackBlit,
            .commit,
            .completion,
        ]

        var events: [ExecutionEvent] = []
        session.onExecutionEvent = { events.append($0) }

        // Run 1 — capture its events independently.
        let frame = try session.execute(graph)
        let firstRunEvents = events
        XCTAssertEqual(firstRunEvents, expectedOrder, "run-1 device execution-event order (incl. uploadBlit) mismatch")

        // Reset before run 2 so the second run's events are captured cleanly (not appended to run 1).
        events.removeAll()

        // Run 2 — capture independently; it must EXACTLY equal run 1.
        let frame2 = try session.execute(graph)
        let secondRunEvents = events
        XCTAssertEqual(secondRunEvents, expectedOrder, "run-2 device execution-event order mismatch")
        XCTAssertEqual(secondRunEvents, firstRunEvents, "run-2 execution order must EXACTLY equal run-1")

        // Pixel correctness (opaque round-trip red) on the device-rendered frame.
        let p = DeviceGateEnv.pixel(frame, x: 0, y: 0)
        XCTAssertEqual(p.r, DeviceGateEnv.opaqueRoundTripByte(255), "device upload-blit pixel red")
        XCTAssertEqual(p.a, 255)

        // Same-device repeatability: identical bytes + rawOutputHash across the two runs.
        XCTAssertEqual(frame.bytes, frame2.bytes, "same-device byte repeatability")
        XCTAssertEqual(frame.rawOutputHash, frame2.rawOutputHash, "same-device hash repeatability")

        let order1 = firstRunEvents.map { String(describing: $0) }.joined(separator: " → ")
        let order2 = secondRunEvents.map { String(describing: $0) }.joined(separator: " → ")
        let att = XCTAttachment(string:
            "executionOrderRun1 = \(order1)\n" +
            "executionOrderRun2 = \(order2)\n" +
            "ordersEqual = \(firstRunEvents == secondRunEvents)\n" +
            "rawOutputHash(2x2 red, rgba16FloatLinear) run1 = \(frame.rawOutputHash)\n" +
            "rawOutputHash run2 = \(frame2.rawOutputHash)\n" +
            "hashEqual = \(frame.rawOutputHash == frame2.rawOutputHash)\n" +
            "bytesEqual = \(frame.bytes == frame2.bytes)")
        att.name = "device-execution-order-and-hash"
        att.lifetime = .keepAlways
        add(att)
    }

    // MARK: - D3 — device/GPU/OS evidence captured

    func testCaptureDeviceEvidence() throws {
        let device = try DeviceGateEnv.requireDevice()
        let model = modelIdentifier()
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let build = osBuild()
        let gpu = device.name
        let registry = String(device.registryID)

        let evidence = """
        AnimiEngineNext Step-10 iPhone device gate — evidence
        deviceName(MTLDevice.name) = \(gpu)
        registryID                 = \(registry)
        modelIdentifier(utsname)   = \(model)
        osVersion                  = \(os)
        osBuild(kern.osversion)    = \(build)
        """
        let attachment = XCTAttachment(string: evidence)
        attachment.name = "device-gate-evidence"
        attachment.lifetime = .keepAlways
        add(attachment)
        print(evidence)

        XCTAssertFalse(gpu.isEmpty, "MTLDevice.name must be non-empty")
        XCTAssertFalse(model.isEmpty, "model identifier must be non-empty")
        XCTAssertFalse(build.isEmpty, "OS build must be non-empty")
        if model != "iPhone14,2" {
            print("WARNING: model is \(model), expected iPhone14,2 (iPhone 13 Pro) — confirm at review.")
        }
    }

    // MARK: - D4 (Step 11) — 4x MSAA r16Float coverage capability on device

    func testFourxSampleCountSupportedOnDevice() throws {
        let device = try DeviceGateEnv.requireDevice()
        XCTAssertTrue(device.supportsTextureSampleCount(4),
                      "Step-11 requires 4x texture sample count on the physical device")
        // Constructing the session creates every Step-11 pipeline (incl. 4x r16Float coverage) eagerly;
        // a capability gap would throw at construction.
        XCTAssertNoThrow(try MetalRenderSession(device: device), "Step-11 4x r16Float pipelines must create on device")
        let att = XCTAttachment(string: "supportsTextureSampleCount(4) = \(device.supportsTextureSampleCount(4))\nGPU = \(device.name)")
        att.name = "device-4x-msaa-support"; att.lifetime = .keepAlways; add(att)
    }

    // MARK: - D5 (Step 11) — combined shape + ordered masks + matte frame on device

    func testStep11CombinedShapeMaskMatteFrameOnDevice() throws {
        let device = try DeviceGateEnv.requireDevice()
        let session = try MetalRenderSession(device: device)
        let w: Int64 = 8, h: Int64 = 8

        var events: [ExecutionEvent] = []
        session.onExecutionEvent = { events.append($0) }

        let graph = try DeviceGateEnv.step11CombinedGraph(width: w, height: h)
        let frame = try session.execute(graph)
        let run1Events = events

        // D1 (private upload path) — no pixel input here, so no uploadBlit; but the .private surfaces and
        // 4x coverage textures all execute on the device. Verify the canonical event order present.
        XCTAssertEqual(run1Events.first, .sceneRender, "first event is the device scene render")
        XCTAssertEqual(run1Events.suffix(3), [.readbackBlit, .commit, .completion], "tail event order on device")

        // Pixel correctness: only the LEFT half (inside both the add-mask and the alpha-matte source) is
        // opaque red; the right half is removed by both the mask and the matte.
        let left = DeviceGateEnv.pixel(frame, x: 2, y: 4)
        let right = DeviceGateEnv.pixel(frame, x: 6, y: 4)
        XCTAssertEqual(left.r, 255, "device: masked+matted left half is opaque red")
        XCTAssertEqual(left.a, 255)
        XCTAssertEqual(right.a, 0, "device: right half removed by mask ∩ matte")

        // Same-device repeatability: identical bytes + rawOutputHash on a second run.
        events.removeAll()
        let frame2 = try session.execute(graph)
        XCTAssertEqual(frame.bytes, frame2.bytes, "device: same-device byte repeatability (shape+mask+matte)")
        XCTAssertEqual(frame.rawOutputHash, frame2.rawOutputHash, "device: rawOutputHash repeatability")
        XCTAssertEqual(events, run1Events, "device: run-2 execution order equals run-1")

        let order = run1Events.map { String(describing: $0) }.joined(separator: " → ")
        let att = XCTAttachment(string:
            "step11ExecutionOrder = \(order)\n" +
            "rawOutputHash(8x8 shape+mask+matte) run1 = \(frame.rawOutputHash)\n" +
            "rawOutputHash run2 = \(frame2.rawOutputHash)\n" +
            "hashEqual = \(frame.rawOutputHash == frame2.rawOutputHash)\n" +
            "bytesEqual = \(frame.bytes == frame2.bytes)\n" +
            "leftPixel(2,4) = \(left)  rightPixel(6,4) = \(right)\n" +
            "model = \(modelIdentifier())  GPU = \(device.name)  os = \(ProcessInfo.processInfo.operatingSystemVersionString) build \(osBuild())")
        att.name = "device-step11-combined-frame"; att.lifetime = .keepAlways; add(att)
        print(att.userInfo ?? "")
    }

    // MARK: - D6 (Step 12) — fade transition on device

    func testStep12FadeFrameOnDevice() throws {
        let device = try DeviceGateEnv.requireDevice()
        let session = try MetalRenderSession(device: device)
        let w: Int64 = 8, h: Int64 = 8
        let graph = try DeviceGateEnv.step12Graph(width: w, height: h, fade: true, withOverlay: false)
        let f1 = try session.execute(graph)
        // fade p=0.5 of opaque red → green: both channels ≈ sRGB(0.5); alpha opaque.
        let px = DeviceGateEnv.pixel(f1, x: 4, y: 4)
        let mid = UInt8(DeviceGateEnv.linearToSRGB(0.5) * 255.0 + 0.5)
        XCTAssertEqual(Int(px.r), Int(mid), accuracy: 4, "device fade midpoint red ≈ sRGB(0.5)")
        XCTAssertEqual(Int(px.g), Int(mid), accuracy: 4, "device fade midpoint green ≈ sRGB(0.5)")
        XCTAssertEqual(px.a, 255)
        let f2 = try session.execute(graph)
        XCTAssertEqual(f1.bytes, f2.bytes, "device fade byte repeatability")
        XCTAssertEqual(f1.rawOutputHash, f2.rawOutputHash, "device fade hash repeatability")
        let a = XCTAttachment(string: "step12 fade midpoint=\(px) hash=\(f1.rawOutputHash) hashEqual=\(f1.rawOutputHash == f2.rawOutputHash) model=\(modelIdentifier()) GPU=\(device.name)")
        a.name = "device-step12-fade"; a.lifetime = .keepAlways; add(a)
    }

    // MARK: - D7 (Step 12) — slide transition + overlay on device + private upload + event order

    func testStep12SlideAndOverlayFrameOnDevice() throws {
        let device = try DeviceGateEnv.requireDevice()
        let session = try MetalRenderSession(device: device)
        let w: Int64 = 8, h: Int64 = 8
        var events: [ExecutionEvent] = []
        session.onExecutionEvent = { events.append($0) }
        let graph = try DeviceGateEnv.step12Graph(width: w, height: h, fade: false, withOverlay: true)
        let f1 = try session.execute(graph)
        let run1 = events
        // The opaque blue overlay (b=255) covers the whole canvas above the slide result.
        let px = DeviceGateEnv.pixel(f1, x: 4, y: 4)
        XCTAssertEqual(px.b, 255, "device: opaque blue overlay above the slide result")
        XCTAssertEqual(px.r, 0); XCTAssertEqual(px.g, 0)
        // Private upload path (overlay pixel input) + canonical event order: uploadBlit first, tail ordered.
        XCTAssertEqual(run1.first, .uploadBlit, "overlay pixel input → private upload blit first on device")
        XCTAssertEqual(run1.suffix(3), [.readbackBlit, .commit, .completion], "device tail event order")
        // Repeatability.
        events.removeAll()
        let f2 = try session.execute(graph)
        XCTAssertEqual(f1.bytes, f2.bytes, "device slide+overlay byte repeatability")
        XCTAssertEqual(f1.rawOutputHash, f2.rawOutputHash, "device slide+overlay hash repeatability")
        XCTAssertEqual(events, run1, "device run-2 event order equals run-1")
        let order = run1.map { String(describing: $0) }.joined(separator: " → ")
        let a = XCTAttachment(string:
            "step12 slide+overlay executionOrder=\(order)\n" +
            "centerPixel=\(px) hash=\(f1.rawOutputHash) hashEqual=\(f1.rawOutputHash == f2.rawOutputHash) bytesEqual=\(f1.bytes == f2.bytes)\n" +
            "model=\(modelIdentifier()) GPU=\(device.name) os=\(ProcessInfo.processInfo.operatingSystemVersionString) build \(osBuild())")
        a.name = "device-step12-slide-overlay"; a.lifetime = .keepAlways; add(a)
        print(a.userInfo ?? "")
    }

    // MARK: - D8 (Step 13) — candidate PNG evidence on device (no comparison, no promotion)

    func testStep13CandidatePNGEvidenceOnDevice() throws {
        let device = try DeviceGateEnv.requireDevice()
        let session = try MetalRenderSession(device: device)
        // Render a candidate frame on the physical device (opaque-red single-image scene).
        let px = try DeviceGateEnv.makePixelInput(
            id: "s13cand", width: 4, height: 4, straightBGRA: Array(repeating: (b: 0, g: 0, r: 255, a: 255), count: 16))
        let graph = try DeviceGateEnv.singleImageGraph(width: 4, height: 4, profile: .rgba16FloatLinear, pixels: px)
        let f1 = try session.execute(graph)

        // Encode the device-rendered frame to a deterministic PNG, twice → byte-identical (determinism proof).
        let png1 = DeviceGateEnv.encodeDeterministicPNG(f1)
        let png2 = DeviceGateEnv.encodeDeterministicPNG(f1)
        XCTAssertEqual(png1, png2, "device candidate PNG is deterministic (same frame → identical bytes)")
        XCTAssertEqual(Array(png1.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "valid PNG signature")
        XCTAssertGreaterThan(png1.count, 8, "non-empty PNG")

        // A second device render of the same input must produce the same frame → same candidate PNG.
        let f2 = try session.execute(graph)
        XCTAssertEqual(f1.rawOutputHash, f2.rawOutputHash, "device candidate frame repeatable")
        XCTAssertEqual(DeviceGateEnv.encodeDeterministicPNG(f2), png1, "device candidate PNG repeatable across renders")

        // Record the candidate PNG as device evidence (no comparison, no reference, no promotion).
        let pngAttachment = XCTAttachment(data: png1, uniformTypeIdentifier: "public.png")
        pngAttachment.name = "device-step13-candidate.png"; pngAttachment.lifetime = .keepAlways; add(pngAttachment)
        let meta = XCTAttachment(string:
            "step13 device candidate: rawOutputHash=\(f1.rawOutputHash) pngBytes=\(png1.count) pngDeterministic=\(png1 == png2)\n" +
            "model=\(modelIdentifier()) GPU=\(device.name) os=\(ProcessInfo.processInfo.operatingSystemVersionString) build \(osBuild())")
        meta.name = "device-step13-candidate-meta"; meta.lifetime = .keepAlways; add(meta)
        print(meta.userInfo ?? "")
    }

    // MARK: - D5 (Step 14) — matrix subset on device: one real-content row + one structural fixture

    func testStep14MatrixSubsetCandidateEvidenceOnDevice() throws {
        let device = try DeviceGateEnv.requireDevice()
        let session = try MetalRenderSession(device: device)

        // (a) A real-content row: a single-image scene (the shape a real template "cut" produces). The
        // device host links only AnimiEngineMetalRender (no TemplateAdapter), so a real compiled.tve cannot
        // be decoded here without a project-file change (forbidden); this exercises the same cut render +
        // deterministic PNG candidate evidence on device.
        let px = try DeviceGateEnv.makePixelInput(
            id: "s14real", width: 4, height: 4, straightBGRA: Array(repeating: (b: 0, g: 0, r: 255, a: 255), count: 16))
        let realGraph = try DeviceGateEnv.singleImageGraph(width: 4, height: 4, profile: .rgba16FloatLinear, pixels: px)
        let realFrame = try session.execute(realGraph)
        let realPNG1 = DeviceGateEnv.encodeDeterministicPNG(realFrame)
        let realPNG2 = DeviceGateEnv.encodeDeterministicPNG(try session.execute(realGraph))
        XCTAssertEqual(realPNG1, realPNG2, "device real-row candidate PNG deterministic across renders")
        XCTAssertEqual(Array(realPNG1.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        // (b) A structural fixture: a fade transition (synthetic-faithful), rendered + PNG-encoded on device.
        let fadeGraph = try DeviceGateEnv.step12Graph(width: 8, height: 8, fade: true, withOverlay: false)
        let fadeFrame = try session.execute(fadeGraph)
        let fadePNG1 = DeviceGateEnv.encodeDeterministicPNG(fadeFrame)
        let fadePNG2 = DeviceGateEnv.encodeDeterministicPNG(try session.execute(fadeGraph))
        XCTAssertEqual(fadePNG1, fadePNG2, "device structural fixture candidate PNG deterministic across renders")
        XCTAssertGreaterThan(fadePNG1.count, 8)

        // Record both candidate PNGs as device evidence (no comparison, no reference, no promotion).
        let realAtt = XCTAttachment(data: realPNG1, uniformTypeIdentifier: "public.png")
        realAtt.name = "device-step14-real-row-candidate.png"; realAtt.lifetime = .keepAlways; add(realAtt)
        let fadeAtt = XCTAttachment(data: fadePNG1, uniformTypeIdentifier: "public.png")
        fadeAtt.name = "device-step14-structural-fade-candidate.png"; fadeAtt.lifetime = .keepAlways; add(fadeAtt)
        let meta = XCTAttachment(string:
            "step14 device subset: realRowHash=\(realFrame.rawOutputHash) realPNG=\(realPNG1.count)B det=\(realPNG1 == realPNG2)\n" +
            "structuralFadeHash=\(fadeFrame.rawOutputHash) fadePNG=\(fadePNG1.count)B det=\(fadePNG1 == fadePNG2)\n" +
            "model=\(modelIdentifier()) GPU=\(device.name) os=\(ProcessInfo.processInfo.operatingSystemVersionString) build \(osBuild())")
        meta.name = "device-step14-subset-meta"; meta.lifetime = .keepAlways; add(meta)
        print(meta.userInfo ?? "")
    }
}
