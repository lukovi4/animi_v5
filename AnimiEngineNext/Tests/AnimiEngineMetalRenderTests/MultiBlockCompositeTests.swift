import XCTest
import Foundation
import AnimiEngineCore
import AnimiEngineRenderModel
import AnimiEngineNext
@testable import AnimiEngineMetalRender
@testable import AnimiEngineTemplateAdapter
@testable import AnimiEngineRenderGraph
@testable import AnimiEngineRenderTestSupport

/// CP4 — full multi-block composite gate. Drives the REAL `example_4blocks` (4 media blocks, 2×2
/// grid) end-to-end with four DISTINCT solid-colour user-media fixtures and asserts the final frame
/// shows all four colours in their four block quadrants — i.e. all four scene layers actually render.
///
/// This is the engine-level reproduction of the device finding "only 1 of 4 blocks visible". It uses
/// NO AnimiApp bridge — pure CompiledTemplateConverter → TimelineEvaluator → RenderInputResolver →
/// RenderGraphCompiler → MetalRenderSession.execute.
final class MultiBlockCompositeTests: XCTestCase {

    private func scenesRoot() -> URL {
        var url = URL(fileURLWithPath: #file)
        for _ in 0..<4 { url.deleteLastPathComponent() }   // Tests/.../<file> → repo root
        return url.appendingPathComponent("AnimiApp/Resources/Scenes")
    }
    private func config() throws -> RenderConfiguration {
        try RenderConfiguration(
            output: OutputContext(canvas: try CanvasSize(width: 1080, height: 1920), frameRate: try FrameRate(numerator: 30, denominator: 1)),
            colorContract: .task003, intermediateProfile: .rgba16FloatLinear)
    }

    /// A 64×64 solid-colour BGRA8 fixture (premultiplied, opaque).
    private func solid(_ id: String, b: UInt8, g: UInt8, r: UInt8) throws -> ResolvedPixelInput {
        let w = 64, h = 64
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) { bytes[i*4] = b; bytes[i*4+1] = g; bytes[i*4+2] = r; bytes[i*4+3] = 255 }
        return try ResolvedPixelInput(
            id: try PixelInputID(id),
            dimensions: try PixelDimensions(width: w, height: h, bytesPerRow: w * 4, format: .bgra8, orientation: .up),
            bytes: Data(bytes))
    }

    func testExampleFourBlocksRendersAllFourColours() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let session = try MetalRenderSession(device: device)
        let cfg = try config()

        // Convert example_4blocks with ALL blocks' selected variants + 4 explicit image bindings.
        let out = try RealTemplateMatrix.convert(
            scenesRootURL: scenesRoot(), catalogID: "example_4blocks", selectAll: nil)

        // (a) FramePlan has 4 active scene layers at frame 0.
        let plan = try RealTemplateMatrix.evaluate(out.document, atTick: 0)
        guard case let .single(subplan) = plan.body else { return XCTFail("expected single body") }
        let imageLayers = subplan.layers.filter { if case .image = $0.content { return true }; return false }
        XCTAssertEqual(imageLayers.count, 4, "(a) 4 active image scene layers")

        // 4 distinct solid colours, bound by each layer's ACTUAL content reference.
        let palette: [(b: UInt8, g: UInt8, r: UInt8)] = [(0,0,255), (0,255,0), (255,0,0), (0,255,255)] // R,G,B,Yellow
        var fixtures: [RenderInputResolver.FixtureKey: ResolvedPixelInput] = [:]
        var refByOrder: [String] = []
        for (i, layer) in imageLayers.sorted(by: { $0.layerID.raw < $1.layerID.raw }).enumerated() {
            guard case let .image(ref) = layer.content else { continue }
            let c = palette[i % palette.count]
            // PixelInputID == the content reference, so the graph's drawImage resourceID matches it.
            fixtures[.image(reference: ref.raw)] = try solid(ref.raw, b: c.b, g: c.g, r: c.r)
            refByOrder.append(ref.raw)
        }
        XCTAssertEqual(Set(refByOrder).count, 4, "4 DISTINCT content references")

        let base = try RenderInputResolver.resolve(framePlan: plan, materials: out.materials, fixtures: fixtures)

        // (b) ResolvedFrameInput has 4 scene-layer entries.
        var sceneEntries: [ResolvedSceneLayerEntry] = []
        for layer in subplan.layers {
            let key = ResolvedLayerKey.sceneLayer(sceneID: subplan.sceneID, role: .sole, layerID: layer.layerID)
            guard let prog = base.program(for: key), let pl = base.mediaPlacement(for: key), let px = base.pixelInput(for: key) else { continue }
            sceneEntries.append(try ResolvedSceneLayerEntry(key: key, program: prog, pixelInput: px, placement: pl))
        }
        XCTAssertEqual(sceneEntries.count, 4, "(b) 4 resolved scene-layer entries")
        let resolved = try ResolvedFrameInput(sceneLayers: sceneEntries, overlays: [], assetPixels: [])

        // (c) RenderGraph has 4 user-media drawImage commands with 4 distinct resourceIDs.
        let graph = try RenderGraphCompiler.compile(plan: plan, input: resolved, configuration: cfg)
        var allDrawImageResourceIDs = [String]()
        var userResourceIDs = Set<String>()
        let boundRefSet = Set(refByOrder)
        for cmd in graph.commands {
            if case let .drawImage(resourceID, _, _, _) = cmd.payload {
                allDrawImageResourceIDs.append(resourceID)
                if boundRefSet.contains(resourceID) { userResourceIDs.insert(resourceID) }
            }
        }
        XCTAssertEqual(userResourceIDs.count, 4,
            "(c) 4 distinct user-media drawImage resourceIDs.\n  boundRefs=\(refByOrder.sorted())\n  ALL drawImage resourceIDs=\(allDrawImageResourceIDs)")

        // (d) The executed frame shows all 4 colours at the 4 block-quadrant centres.
        let frame = try session.execute(graph)
        let dims = frame.dimensions
        let bytes = [UInt8](frame.bytes)
        func colorAt(_ xFrac: Double, _ yFrac: Double) -> (b: Int, g: Int, r: Int) {
            let x = min(dims.width - 1, max(0, Int(Double(dims.width) * xFrac)))
            let y = min(dims.height - 1, max(0, Int(Double(dims.height) * yFrac)))
            let o = y * dims.bytesPerRow + x * 4
            return (Int(bytes[o]), Int(bytes[o+1]), Int(bytes[o+2]))
        }
        // Quadrant centres (2×2): TL, TR, BL, BR.
        let tl = colorAt(0.25, 0.25), tr = colorAt(0.75, 0.25)
        let bl = colorAt(0.25, 0.75), br = colorAt(0.75, 0.75)
        func isColoured(_ c: (b: Int, g: Int, r: Int)) -> Bool { c.b + c.g + c.r > 60 }
        // Scan each quadrant for ANY content (mattes may shape a block away from its exact centre).
        func quadrantLit(_ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int) -> Bool {
            var s = y0
            while s < y1 {
                var c = x0
                while c < x1 {
                    let o = s * dims.bytesPerRow + c * 4
                    if Int(bytes[o]) + Int(bytes[o+1]) + Int(bytes[o+2]) > 60 { return true }
                    c += 24
                }
                s += 24
            }
            return false
        }
        let hw = dims.width / 2, hh = dims.height / 2
        let quads = [quadrantLit(0, hw, 0, hh), quadrantLit(hw, dims.width, 0, hh),
                     quadrantLit(0, hw, hh, dims.height), quadrantLit(hw, dims.width, hh, dims.height)]
        let lit = quads.filter { $0 }.count
        XCTAssertEqual(lit, 4,
            "(d) all 4 block quadrants must render SOMETHING; lit=\(lit) quads=\(quads) centres TL=\(tl) TR=\(tr) BL=\(bl) BR=\(br)")
    }

    /// 6_frames_template has six plain image blocks and no mask/matte isolation. It proves the
    /// multi-block geometry contract independently from the matte path.
    func testSixFramesGraphAndRender() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let session = try MetalRenderSession(device: device)
        let out = try RealTemplateMatrix.convert(scenesRootURL: scenesRoot(), catalogID: "6_frames_template", selectAll: nil)
        let plan = try RealTemplateMatrix.evaluate(out.document, atTick: 0)
        guard case let .single(subplan) = plan.body else { return XCTFail("single") }
        let imageLayers = subplan.layers.filter { if case .image = $0.content { return true }; return false }
        XCTAssertEqual(imageLayers.count, 6, "6 image scene layers")

        // 6_frames_template uses NO mask/matte — plain drawImage per block — so it isolates the
        // multi-block transform bug from the mask/matte path.
        let palette: [(b: UInt8, g: UInt8, r: UInt8)] = [(0,0,255),(0,255,0),(255,0,0),(0,255,255),(255,0,255),(255,255,0)]
        var fixtures: [RenderInputResolver.FixtureKey: ResolvedPixelInput] = [:]
        for (i, layer) in imageLayers.sorted(by: { $0.layerID.raw < $1.layerID.raw }).enumerated() {
            if case let .image(ref) = layer.content { let c = palette[i % palette.count]; fixtures[.image(reference: ref.raw)] = try solid(ref.raw, b: c.b, g: c.g, r: c.r) }
        }
        let base = try RenderInputResolver.resolve(framePlan: plan, materials: out.materials, fixtures: fixtures)
        var entries: [ResolvedSceneLayerEntry] = []
        for layer in subplan.layers {
            let key = ResolvedLayerKey.sceneLayer(sceneID: subplan.sceneID, role: .sole, layerID: layer.layerID)
            guard let p = base.program(for: key), let pl = base.mediaPlacement(for: key), let px = base.pixelInput(for: key) else { continue }
            entries.append(try ResolvedSceneLayerEntry(key: key, program: p, pixelInput: px, placement: pl))
        }
        let graph = try RenderGraphCompiler.compile(plan: plan, input: try ResolvedFrameInput(sceneLayers: entries, overlays: [], assetPixels: []), configuration: try config())
        let frame = try session.execute(graph)
        // 6 frames are a 2-col × 3-row grid — scan the 6 grid-cell centres.
        let bytes = [UInt8](frame.bytes); let d = frame.dimensions
        var litCells = 0
        for ry in 0..<3 { for rx in 0..<2 {
            let x = d.width * (2*rx+1)/4, y = d.height * (2*ry+1)/6
            let o = y*d.bytesPerRow + x*4
            if Int(bytes[o])+Int(bytes[o+1])+Int(bytes[o+2]) > 60 { litCells += 1 }
        }}
        XCTAssertEqual(litCells, 6, "all 6 frame blocks must render; lit=\(litCells)")
    }

    /// CP4 Rev-4 canonical cleanup: the whole-animation size (`animIR.meta.size`) is carried ONCE by
    /// `program.meta.width/height` — NOT duplicated in `mediaGeometry`. The compiler reads it from
    /// `program.meta` to choose TVECore's block transform (full-canvas anim → identity, else
    /// animToInputContain). This pins that `program.meta.width/height` equals the selected AnimIR meta.size.
    func testProgramMetaCarriesAnimMetaSize() throws {
        let cs = Double(CanvasScalar.unitsPerPoint)
        for catalog in ["full_image", "polaroid_shared_demo", "polaroid_2", "example_4blocks", "6_frames_template"] {
            let url = scenesRoot().appendingPathComponent(catalog).appendingPathComponent("compiled.tve")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(catalog) compiled.tve exists")
            let data = try Data(contentsOf: url)
            let decoded = try CompiledTemplateDecoder.decode(data)
            var metaByBlock: [String: (Double, Double)] = [:]
            for block in decoded.payload.compiled.runtime.blocks {
                guard let v = block.variants.first(where: { $0.variantID == block.selectedVariantID }) ?? block.variants.first else { continue }
                metaByBlock[block.blockID] = (v.animIR.meta.width, v.animIR.meta.height)
            }
            let out = try RealTemplateMatrix.convert(scenesRootURL: scenesRoot(), catalogID: catalog, selectAll: nil)
            let plan = try RealTemplateMatrix.evaluate(out.document, atTick: 0)
            guard case let .single(subplan) = plan.body else { continue }
            for layer in subplan.layers.sorted(by: { $0.layerID.raw < $1.layerID.raw }) {
                let key = SceneMaterialBindingKey(sceneID: subplan.sceneID, layerID: layer.layerID)
                guard let prog = out.materials.program(for: key) else { continue }
                let blockID = prog.blockID
                let meta = try XCTUnwrap(metaByBlock[blockID], "\(catalog)/\(blockID) selected AnimIR meta")
                let aw = Double(prog.meta.width.rawValue)/cs
                let ah = Double(prog.meta.height.rawValue)/cs
                XCTAssertEqual(aw, meta.0, accuracy: 0.5, "\(catalog)/\(blockID) program.meta width == AnimIR meta.size")
                XCTAssertEqual(ah, meta.1, accuracy: 0.5, "\(catalog)/\(blockID) program.meta height == AnimIR meta.size")
            }
        }
    }

    /// `mediaGeometry.contentSize` remains the binding baseline, DISTINCT from the whole animation size
    /// (now `program.meta.width/height`). This pins that the two coordinate facts genuinely differ for the
    /// real templates — i.e. anim size is not redundant with contentSize, it is a separate role carried by
    /// `program.meta`.
    func testContentSizeRemainsDistinctFromProgramMetaWhereAuthored() throws {
        let cs = Double(CanvasScalar.unitsPerPoint)
        var mismatches = 0
        var checked = 0
        for catalog in ["full_image", "polaroid_shared_demo", "polaroid_2", "example_4blocks", "6_frames_template"] {
            let out = try RealTemplateMatrix.convert(scenesRootURL: scenesRoot(), catalogID: catalog, selectAll: nil)
            let plan = try RealTemplateMatrix.evaluate(out.document, atTick: 0)
            guard case let .single(subplan) = plan.body else { continue }
            for layer in subplan.layers.sorted(by: { $0.layerID.raw < $1.layerID.raw }) {
                let key = SceneMaterialBindingKey(sceneID: subplan.sceneID, layerID: layer.layerID)
                guard let prog = out.materials.program(for: key) else { continue }
                checked += 1
                let cw = Double(prog.mediaGeometry.contentSizeWidth.rawValue)/cs
                let ch = Double(prog.mediaGeometry.contentSizeHeight.rawValue)/cs
                let aw = Double(prog.meta.width.rawValue)/cs
                let ah = Double(prog.meta.height.rawValue)/cs
                if abs(cw - aw) >= 0.5 || abs(ch - ah) >= 0.5 { mismatches += 1 }
            }
        }
        XCTAssertEqual(checked, 14, "real media-bound block count")
        XCTAssertEqual(mismatches, 13, "all real blocks except full_image have binding contentSize distinct from program.meta anim size")
    }

    /// Minimal synthetic isolation: TWO mask groups in ONE scene, each writing a full
    /// red fill into the canvas. Both must survive. If only the FIRST survives, the bug is purely in
    /// repeated mask/matte isolation within a single scene (no template involved).
    func testTwoMaskGroupsBothReachCanvas() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let session = try MetalRenderSession(device: device)
        let w: Int64 = 8, h: Int64 = 8
        let cfg = try StructuralFixtures.config(w, h, frameRate: try StructuralFixtures.fr30())
        // Mask op A covers the LEFT half; op B covers... use full mesh so both cover everything,
        // but draw distinct colours so we can tell which survived.
        let redFull = try StructuralFixtures.fill(try StructuralFixtures.fullMesh(w, h, pathID: 1), try StructuralFixtures.color(.one, .zero, .zero, .one))
        let blueFull = try StructuralFixtures.fill(try StructuralFixtures.fullMesh(w, h, pathID: 3), try StructuralFixtures.color(.zero, .zero, .one, .one))
        let opA = SampledMaskOperation(mode: .add, inverted: false, opacity: .opaque, mesh: try StructuralFixtures.leftMesh(w, h, pathID: 2), pathToTarget: .identity)
        let opB = SampledMaskOperation(mode: .add, inverted: false, opacity: .opaque, mesh: try StructuralFixtures.fullMesh(w, h, pathID: 4), pathToTarget: .identity)
        let payloads: [RenderCommandPayload] = [
            .offscreenSurface(StructuralFixtures.lin(w, h)), .offscreenSurface(StructuralFixtures.srgb(w, h)),
            StructuralFixtures.iso("contentA", w, h), StructuralFixtures.iso("contentB", w, h),
            .clearBackground(color: .transparentBlack, targetSurfaceID: RenderSurface.linearCanvas),
            .beginScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas),
            // Group A (left mask): draw RED into contentA, apply to canvas.
            .clearBackground(color: .transparentBlack, targetSurfaceID: "contentA"),
            .beginMask(operations: [opA], contentSurfaceID: "contentA", targetSurfaceID: RenderSurface.linearCanvas),
            .drawShape(shape: redFull, transform: .identity, opacity: .opaque, targetSurfaceID: "contentA"),
            .endMask(contentSurfaceID: "contentA", targetSurfaceID: RenderSurface.linearCanvas),
            // Group B (full mask): draw BLUE into contentB, apply to canvas (RIGHT-ish via full cover).
            .clearBackground(color: .transparentBlack, targetSurfaceID: "contentB"),
            .beginMask(operations: [opB], contentSurfaceID: "contentB", targetSurfaceID: RenderSurface.linearCanvas),
            .drawShape(shape: blueFull, transform: .identity, opacity: .opaque, targetSurfaceID: "contentB"),
            .endMask(contentSurfaceID: "contentB", targetSurfaceID: RenderSurface.linearCanvas),
            .endScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas),
            .finalLinearToSRGB(sourceSurfaceID: RenderSurface.linearCanvas, targetSurfaceID: RenderSurface.sRGBSurface),
            .finalOutput(sourceSurfaceID: RenderSurface.sRGBSurface)]
        let graph = try RenderGraph(configuration: cfg, commands: try payloads.enumerated().map { try RenderCommand(ordinal: $0.offset, payload: $0.element) })
        let frame = try session.execute(graph)
        let bytes = [UInt8](frame.bytes)
        // Group B (blue, full cover) was applied LAST over group A → centre should show BLUE if both
        // groups composited. If only group A survived (the bug), centre shows RED.
        let o = (Int(h)/2) * frame.dimensions.bytesPerRow + (Int(w)/2) * 4
        let (b, g, r) = (Int(bytes[o]), Int(bytes[o+1]), Int(bytes[o+2]))
        // Left edge sampled from group A (red), should still be visible under blue's full cover only
        // if blue didn't fully overwrite; the key assertion is that group B (the SECOND group) painted.
        XCTAssertGreaterThan(b, 60, "(2nd mask group must reach canvas) centre blue=\(b) r=\(r) g=\(g)")
    }

    /// Synthetic isolation: TWO matte groups in ONE scene (matching example_4blocks block_02/03,
    /// which use matteLink and fail on device). Both matte results must reach the canvas.
    func testTwoMatteGroupsBothReachCanvas() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let session = try MetalRenderSession(device: device)
        let w: Int64 = 8, h: Int64 = 8
        let cfg = try StructuralFixtures.config(w, h, frameRate: try StructuralFixtures.fr30())
        let whiteFull = try StructuralFixtures.fill(try StructuralFixtures.fullMesh(w, h, pathID: 1), try StructuralFixtures.color(.one, .one, .one, .one))
        let red = try StructuralFixtures.fill(try StructuralFixtures.fullMesh(w, h, pathID: 2), try StructuralFixtures.color(.one, .zero, .zero, .one))
        let blue = try StructuralFixtures.fill(try StructuralFixtures.fullMesh(w, h, pathID: 5), try StructuralFixtures.color(.zero, .zero, .one, .one))
        let payloads: [RenderCommandPayload] = [
            .offscreenSurface(StructuralFixtures.lin(w, h)), .offscreenSurface(StructuralFixtures.srgb(w, h)),
            StructuralFixtures.iso("srcA", w, h), StructuralFixtures.iso("conA", w, h),
            StructuralFixtures.iso("srcB", w, h), StructuralFixtures.iso("conB", w, h),
            .clearBackground(color: .transparentBlack, targetSurfaceID: RenderSurface.linearCanvas),
            .beginScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas),
            // Matte A → red into canvas.
            .clearBackground(color: .transparentBlack, targetSurfaceID: "srcA"),
            .clearBackground(color: .transparentBlack, targetSurfaceID: "conA"),
            .drawShape(shape: whiteFull, transform: .identity, opacity: .opaque, targetSurfaceID: "srcA"),
            .drawShape(shape: red, transform: .identity, opacity: .opaque, targetSurfaceID: "conA"),
            .matteLink(mode: .alpha, sourceLayerID: 2, consumerLayerID: 1, sourceSurfaceID: "srcA", consumerSurfaceID: "conA", targetSurfaceID: RenderSurface.linearCanvas),
            // Matte B → blue into canvas (the SECOND matte group).
            .clearBackground(color: .transparentBlack, targetSurfaceID: "srcB"),
            .clearBackground(color: .transparentBlack, targetSurfaceID: "conB"),
            .drawShape(shape: whiteFull, transform: .identity, opacity: .opaque, targetSurfaceID: "srcB"),
            .drawShape(shape: blue, transform: .identity, opacity: .opaque, targetSurfaceID: "conB"),
            .matteLink(mode: .alpha, sourceLayerID: 4, consumerLayerID: 3, sourceSurfaceID: "srcB", consumerSurfaceID: "conB", targetSurfaceID: RenderSurface.linearCanvas),
            .endScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas),
            .finalLinearToSRGB(sourceSurfaceID: RenderSurface.linearCanvas, targetSurfaceID: RenderSurface.sRGBSurface),
            .finalOutput(sourceSurfaceID: RenderSurface.sRGBSurface)]
        let graph = try RenderGraph(configuration: cfg, commands: try payloads.enumerated().map { try RenderCommand(ordinal: $0.offset, payload: $0.element) })
        let frame = try session.execute(graph)
        let bytes = [UInt8](frame.bytes)
        let o = (Int(h)/2) * frame.dimensions.bytesPerRow + (Int(w)/2) * 4
        let b = Int(bytes[o])
        // Blue (2nd matte group) over red → if both composited, blue shows. If only 1st survived, red.
        XCTAssertGreaterThan(b, 60, "(2nd matte group must reach canvas) centre blue=\(b)")
    }

    // MARK: - block_02 pixel-level matte capture (diagnostic)

    /// Per-surface alpha statistics measured from a captured rgba16Float surface.
    private struct SurfaceStats {
        let id: String
        let nonZeroAlpha: Int          // pixels with alpha > ~0
        let total: Int
        var aMin: Float, aMax: Float, aMean: Double
        var rgbaMax: Float             // max of any colour channel (premultiplied) → is anything drawn?
        var boundsMinX, boundsMinY, boundsMaxX, boundsMaxY: Int  // bbox of non-zero alpha
        var sampleCentre: (r: Float, g: Float, b: Float, a: Float)
    }

    /// Capture an rgba16Float surface into a shared staging buffer (8 bytes/pixel, half-float) inside the
    /// SAME command buffer at the current encode point, returning a reader closure to run AFTER completion.
    private func captureFloatSurface(_ id: String, owner: MetalResourceOwner, into cb: MTLCommandBuffer,
                                     device: MTLDevice) -> (() -> SurfaceStats)? {
        guard let tex = owner.surfaces[id] else { return nil }
        let w = tex.width, h = tex.height
        let bpp = 8                                   // rgba16Float
        let align = 256
        let alignedRow = ((w * bpp) + align - 1) / align * align
        guard let staging = device.makeBuffer(length: alignedRow * h, options: .storageModeShared),
              let blit = cb.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: staging, destinationOffset: 0,
                  destinationBytesPerRow: alignedRow, destinationBytesPerImage: alignedRow * h)
        blit.endEncoding()
        return { [self] in
            func f16(_ raw: UInt16) -> Float { self.halfToFloat(raw) }
            let ptr = staging.contents().bindMemory(to: UInt16.self, capacity: alignedRow / 2 * h)
            var nonZero = 0, aMinR = Float.greatestFiniteMagnitude, aMaxR = -Float.greatestFiniteMagnitude
            var aSum = 0.0, rgbaMax = Float(0)
            var minX = w, minY = h, maxX = -1, maxY = -1
            let rowStride16 = alignedRow / 2
            for y in 0..<h {
                for x in 0..<w {
                    let o = y * rowStride16 + x * 4
                    let r = f16(ptr[o]), g = f16(ptr[o+1]), bb = f16(ptr[o+2]), a = f16(ptr[o+3])
                    aSum += Double(a); aMinR = min(aMinR, a); aMaxR = max(aMaxR, a)
                    rgbaMax = max(rgbaMax, max(max(r, g), max(bb, a)))
                    if a > 0.0039 {     // > 1/255
                        nonZero += 1
                        minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                    }
                }
            }
            let cx = w/2, cy = h/2, co = cy * rowStride16 + cx * 4
            return SurfaceStats(id: id, nonZeroAlpha: nonZero, total: w*h,
                aMin: nonZero == 0 ? 0 : aMinR, aMax: aMaxR, aMean: aSum / Double(w*h), rgbaMax: rgbaMax,
                boundsMinX: minX, boundsMinY: minY, boundsMaxX: maxX, boundsMaxY: maxY,
                sampleCentre: (f16(ptr[co]), f16(ptr[co+1]), f16(ptr[co+2]), f16(ptr[co+3])))
        }
    }

    /// IEEE-754 half → float (no `Float16` dependency; works on all CI runners).
    private func halfToFloat(_ h: UInt16) -> Float {
        let sign = UInt32(h & 0x8000) << 16
        let exp = UInt32(h & 0x7C00) >> 10
        let mant = UInt32(h & 0x03FF)
        var bits: UInt32
        if exp == 0 {
            if mant == 0 { bits = sign }
            else {
                var e: Int32 = -1; var m = mant
                repeat { e += 1; m <<= 1 } while (m & 0x0400) == 0
                bits = sign | UInt32(Int32(127 - 15 - e) << 23) | ((m & 0x03FF) << 13)
            }
        } else if exp == 0x1F {
            bits = sign | 0x7F800000 | (mant << 13)
        } else {
            bits = sign | ((exp + (127 - 15)) << 23) | (mant << 13)
        }
        return Float(bitPattern: bits)
    }

    /// PIXEL-LEVEL CAPTURE: for the real example_4blocks graph, blit-read every matte group's SOURCE,
    /// CONSUMER and TARGET (linearCanvas) surface at the matteLink point, and report alpha statistics.
    /// block_02 (alpha matte) renders empty on device while block_03 (alphaInverted) works — this proves
    /// at which surface block_02's coverage vanishes, with no TVECore UI and no speculative fix.
    func testCaptureMatteSurfacesForBlock02() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let session = try MetalRenderSession(device: device)
        let cfg = try config()

        // Build the REAL example_4blocks graph (identical setup to the 4-colour gate).
        let out = try RealTemplateMatrix.convert(scenesRootURL: scenesRoot(), catalogID: "example_4blocks", selectAll: nil)
        let plan = try RealTemplateMatrix.evaluate(out.document, atTick: 0)
        guard case let .single(subplan) = plan.body else { return XCTFail("single body") }
        let imageLayers = subplan.layers.filter { if case .image = $0.content { return true }; return false }
        let palette: [(b: UInt8, g: UInt8, r: UInt8)] = [(0,0,255),(0,255,0),(255,0,0),(0,255,255)]
        var fixtures: [RenderInputResolver.FixtureKey: ResolvedPixelInput] = [:]
        for (i, layer) in imageLayers.sorted(by: { $0.layerID.raw < $1.layerID.raw }).enumerated() {
            if case let .image(ref) = layer.content { let c = palette[i % palette.count]; fixtures[.image(reference: ref.raw)] = try solid(ref.raw, b: c.b, g: c.g, r: c.r) }
        }
        let base = try RenderInputResolver.resolve(framePlan: plan, materials: out.materials, fixtures: fixtures)
        var entries: [ResolvedSceneLayerEntry] = []
        for layer in subplan.layers {
            let key = ResolvedLayerKey.sceneLayer(sceneID: subplan.sceneID, role: .sole, layerID: layer.layerID)
            guard let p = base.program(for: key), let pl = base.mediaPlacement(for: key), let px = base.pixelInput(for: key) else { continue }
            entries.append(try ResolvedSceneLayerEntry(key: key, program: p, pixelInput: px, placement: pl))
        }
        let graph = try RenderGraphCompiler.compile(
            plan: plan, input: try ResolvedFrameInput(sceneLayers: entries, overlays: [], assetPixels: []),
            configuration: cfg)

        // Enumerate matteLink commands → which surfaces each block's matte reads/writes.
        struct MatteCmd { let index: Int; let mode: RenderMatteMode; let src: String; let con: String; let tgt: String }
        var mattes: [MatteCmd] = []
        for (i, cmd) in graph.commands.enumerated() {
            if case let .matteLink(mode, _, _, src, con, tgt) = cmd.payload {
                mattes.append(MatteCmd(index: i, mode: mode, src: src, con: con, tgt: tgt))
            }
        }
        XCTAssertEqual(mattes.count, 2, "example_4blocks emits two matte groups: block_02 (alpha) + block_03 (alphaInverted)")
        let alphaMatte = mattes.first { $0.mode == .alpha }       // block_02 — the one that rendered empty
        XCTAssertNotNil(alphaMatte, "block_02 must emit an .alpha matteLink")

        // Capture SRC + CON for EACH matte at its matteLink point (final source/consumer draws complete,
        // before/equal to the apply — the matte only READS them). Readers run after GPU completion.
        var captured: [String: SurfaceStats] = [:]   // "matteIndex.role" → stats
        session.onCommandEncoded = { [self] index, _, owner, cb in
            guard let m = mattes.first(where: { $0.index == index }) else { return }
            for (role, sid) in [("SRC", m.src), ("CON", m.con)] {
                if let r = self.captureFloatSurface(sid, owner: owner, into: cb, device: device) {
                    let key = "\(index).\(role)"
                    self.pendingReaders.append((key, r))
                }
            }
        }
        pendingReaders.removeAll()

        _ = try session.execute(graph)
        for (key, reader) in pendingReaders { captured[key] = reader() }
        pendingReaders.removeAll()

        // REGRESSION (block_02 alpha-matte residual): the alpha-matte SOURCE and CONSUMER surfaces must be
        // NON-EMPTY. They went fully transparent (nonZeroAlpha=0) because block_02's source+consumer were
        // parented to a 0%-opacity null layer (`img_1.2_parent`) and the compiler wrongly inherited that 0
        // through the parenting chain. Fix: layer parenting scales transform only, never opacity (AE/Lottie/
        // TVECore oracle). If this regresses, both surfaces blank again and the assertions below fail.
        guard let am = alphaMatte else { return XCTFail("no alpha matte") }
        let src = try XCTUnwrap(captured["\(am.index).SRC"], "alpha-matte SOURCE must have been captured")
        let con = try XCTUnwrap(captured["\(am.index).CON"], "alpha-matte CONSUMER must have been captured")
        XCTAssertGreaterThan(src.nonZeroAlpha, 0,
            "block_02 alpha-matte SOURCE must be non-empty (was 0 — null-parent opacity zeroed it). aMax=\(src.aMax)")
        XCTAssertGreaterThan(con.nonZeroAlpha, 0,
            "block_02 alpha-matte CONSUMER (photo) must be non-empty (was 0 — null-parent opacity zeroed it). aMax=\(con.aMax)")
        XCTAssertGreaterThan(src.aMax, 0.5, "block_02 source coverage must reach full alpha")
        XCTAssertGreaterThan(con.aMax, 0.5, "block_02 consumer photo must reach full alpha")
    }

    /// Reader closures registered by the capture seam during `execute` (drained after GPU completion).
    private var pendingReaders: [(String, () -> SurfaceStats)] = []
}
