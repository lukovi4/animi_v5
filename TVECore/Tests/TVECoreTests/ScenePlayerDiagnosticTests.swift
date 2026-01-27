// swiftlint:disable file_length function_body_length
import XCTest
@testable import TVECore

/// Diagnostic tests for ScenePlayer - NO FIXES, ONLY DATA COLLECTION
/// Per review.md: structured dump to localize issues
final class ScenePlayerDiagnosticTests: XCTestCase {

    // MARK: - Test Resources

    private var testPackageURL: URL {
        Bundle.module.url(
            forResource: "scene",
            withExtension: "json",
            subdirectory: "Resources/example_4blocks"
        )!.deletingLastPathComponent()
    }

    private func loadTestPackage() throws -> (ScenePackage, LoadedAnimations) {
        let loader = ScenePackageLoader()
        let package = try loader.load(from: testPackageURL)

        let animLoader = AnimLoader()
        let animations = try animLoader.loadAnimations(from: package)

        return (package, animations)
    }

    // MARK: - 1. Scene-Level Diagnostic (section 1.1 of review.md)

    func testDiagnostic_sceneLevel() throws {
        let (package, animations) = try loadTestPackage()
        let player = ScenePlayer()
        let compiled = try player.compile(package: package, loadedAnimations: animations)
        let runtime = compiled.runtime

        print("\n" + String(repeating: "=", count: 80))
        print("SCENE-LEVEL DIAGNOSTIC (Passport)")
        print(String(repeating: "=", count: 80))

        // Canvas
        print("\n[CANVAS]")
        print("  width: \(runtime.canvas.width)")
        print("  height: \(runtime.canvas.height)")
        print("  fps: \(runtime.canvas.fps)")
        print("  durationFrames: \(runtime.canvas.durationFrames)")

        // Blocks by zIndex
        print("\n[BLOCKS] (sorted by zIndex)")
        for block in runtime.blocks {
            print("\n  Block: \(block.blockId) (zIndex=\(block.zIndex))")
            print("    rectCanvas: (x=\(block.rectCanvas.x), y=\(block.rectCanvas.y), " +
                  "w=\(block.rectCanvas.width), h=\(block.rectCanvas.height))")
            print("    inputRect: (x=\(block.inputRect.x), y=\(block.inputRect.y), " +
                  "w=\(block.inputRect.width), h=\(block.inputRect.height))")
            print("    containerClip: \(block.containerClip)")
            print("    timing: start=\(block.timing.startFrame), end=\(block.timing.endFrame)")

            // Variant / AnimIR info
            if let variant = block.selectedVariant {
                print("    animRef: \(variant.animRef)")
                print("    AnimIR.meta.size: (w=\(variant.animIR.meta.width), h=\(variant.animIR.meta.height))")
                print("    AnimIR.meta.fps: \(variant.animIR.meta.fps)")
                print("    AnimIR.meta.op: \(variant.animIR.meta.outPoint)")

                // Check: rectCanvas != inputRect = RED FLAG
                if block.rectCanvas != block.inputRect {
                    print("    ⚠️ RED FLAG: rectCanvas != inputRect")
                }

                // Check: animSize vs canvasSize
                let animSize = variant.animIR.meta.size
                let canvasSize = runtime.canvasSize
                if animSize.width != canvasSize.width || animSize.height != canvasSize.height {
                    print("    ⚠️ animSize != canvasSize → blockTransform will use contain policy")
                } else {
                    print("    ✓ animSize == canvasSize → blockTransform = identity")
                }

                // First 3 assets
                let assetIds = Array(variant.animIR.assets.byId.keys.prefix(3))
                if !assetIds.isEmpty {
                    print("    assets (first 3): \(assetIds.joined(separator: ", "))")
                }
            }
        }

        print("\n" + String(repeating: "=", count: 80))
    }

    // MARK: - 2. Per-Frame Summary (section 1.2 of review.md)

    func testDiagnostic_perFrameSummary() throws {
        let (package, animations) = try loadTestPackage()
        let player = ScenePlayer()
        let compiled = try player.compile(package: package, loadedAnimations: animations)
        let runtime = compiled.runtime

        let testFrames = [0, 30, 60, 90, 150]

        print("\n" + String(repeating: "=", count: 80))
        print("PER-FRAME SUMMARY")
        print(String(repeating: "=", count: 80))

        for frame in testFrames {
            let commands = runtime.renderCommands(sceneFrameIndex: frame)
            let counts = commands.commandCounts()

            print("\n[Frame \(frame)]")
            print("  commands.count: \(commands.count)")
            print("  drawImage: \(counts["drawImage"] ?? 0)")
            print("  drawShape: \(counts["drawShape"] ?? 0)")
            print("  beginMaskAdd/endMask: \(counts["beginMaskAdd"] ?? 0)/\(counts["endMask"] ?? 0)")
            print("  beginMatte/endMatte: \(counts["beginMatte"] ?? 0)/\(counts["endMatte"] ?? 0)")
            print("  pushTransform/popTransform: \(counts["pushTransform"] ?? 0)/\(counts["popTransform"] ?? 0)")
            print("  pushClipRect/popClipRect: \(counts["pushClipRect"] ?? 0)/\(counts["popClipRect"] ?? 0)")
            print("  beginGroup/endGroup: \(counts["beginGroup"] ?? 0)/\(counts["endGroup"] ?? 0)")
            print("  balanced: \(commands.isBalanced())")
        }

        print("\n" + String(repeating: "=", count: 80))
    }

    // MARK: - 3. Block-Level Scope Dump (section 1.3 of review.md)

    func testDiagnostic_blockLevelScope() throws {
        let (package, animations) = try loadTestPackage()
        let player = ScenePlayer()
        let compiled = try player.compile(package: package, loadedAnimations: animations)
        let runtime = compiled.runtime

        let frame = 150
        let commands = runtime.renderCommands(sceneFrameIndex: frame)

        print("\n" + String(repeating: "=", count: 80))
        print("BLOCK-LEVEL SCOPE DUMP (Frame \(frame))")
        print(String(repeating: "=", count: 80))

        // Parse commands into block scopes
        var currentBlock: String?
        var blockCommands: [String: [RenderCommand]] = [:]

        for cmd in commands {
            if case .beginGroup(let name) = cmd, name.hasPrefix("Block:") {
                currentBlock = name.replacingOccurrences(of: "Block:", with: "")
                blockCommands[currentBlock!] = []
            } else if case .endGroup = cmd, currentBlock != nil {
                // Check if this ends the block group
                // We'll mark end by looking at next beginGroup or by counting
            }

            if let block = currentBlock {
                blockCommands[block, default: []].append(cmd)
            }
        }

        // For each block, extract key info
        for block in compiled.runtime.blocks {
            let blockId = block.blockId
            guard let cmds = blockCommands[blockId] else {
                print("\n[Block: \(blockId)] - NO COMMANDS FOUND")
                continue
            }

            print("\n[Block: \(blockId)]")
            print("  Expected rect: (x=\(block.rectCanvas.x), y=\(block.rectCanvas.y), " +
                  "w=\(block.rectCanvas.width), h=\(block.rectCanvas.height))")

            // Find first pushClipRect
            if let clipCmd = cmds.first(where: { if case .pushClipRect = $0 { return true }; return false }),
               case .pushClipRect(let rect) = clipCmd {
                print("  First pushClipRect: (x=\(rect.x), y=\(rect.y), w=\(rect.width), h=\(rect.height))")

                // Compare with expected
                if rect.x != block.rectCanvas.x || rect.y != block.rectCanvas.y ||
                   rect.width != block.rectCanvas.width || rect.height != block.rectCanvas.height {
                    print("  ⚠️ clipRect MISMATCH with rectCanvas!")
                }
            } else {
                print("  ⚠️ NO pushClipRect found!")
            }

            // Find first pushTransform after clip
            if let transformCmd = cmds.first(where: { if case .pushTransform = $0 { return true }; return false }),
               case .pushTransform(let matrix) = transformCmd {
                if matrix == .identity {
                    print("  First pushTransform: identity")
                } else {
                    print("  First pushTransform: a=\(matrix.a), d=\(matrix.d), tx=\(matrix.tx), ty=\(matrix.ty)")
                }
            }

            // Count drawImage inside block
            let drawImageCount = cmds.filter { if case .drawImage = $0 { return true }; return false }.count
            print("  drawImage count: \(drawImageCount)")

            // Check beginMask/beginMatte
            let hasMask = cmds.contains { if case .beginMaskAdd = $0 { return true }; return false }
            let hasMatte = cmds.contains { if case .beginMatte = $0 { return true }; return false }
            print("  hasMask: \(hasMask), hasMatte: \(hasMatte)")

            // List drawImage assetIds
            var assetIds: [String] = []
            for cmd in cmds {
                if case .drawImage(let assetId, _) = cmd {
                    if !assetIds.contains(assetId) {
                        assetIds.append(assetId)
                    }
                }
            }
            if !assetIds.isEmpty {
                print("  drawImage assetIds: \(assetIds.joined(separator: ", "))")
            }

            // For matte blocks, check matteSource/matteConsumer groups
            if hasMatte {
                let hasMatteSource = cmds.contains {
                    if case .beginGroup(let name) = $0, name == "matteSource" { return true }
                    return false
                }
                let hasMatteConsumer = cmds.contains {
                    if case .beginGroup(let name) = $0, name == "matteConsumer" { return true }
                    return false
                }
                print("  matteSource group: \(hasMatteSource), matteConsumer group: \(hasMatteConsumer)")
            }
        }

        print("\n" + String(repeating: "=", count: 80))
    }

    // MARK: - 4. Effective Matrix + Scissor per DrawImage (section 2 of review.md)

    func testDiagnostic_effectiveMatrixAndScissor() throws {
        let (package, animations) = try loadTestPackage()
        let player = ScenePlayer()
        let compiled = try player.compile(package: package, loadedAnimations: animations)

        let frame = 150
        let commands = compiled.runtime.renderCommands(sceneFrameIndex: frame)

        print("\n" + String(repeating: "=", count: 80))
        print("EFFECTIVE MATRIX + SCISSOR PER DRAWIMAGE (Frame \(frame))")
        print(String(repeating: "=", count: 80))

        // Simulate transform stack
        var transformStack: [Matrix2D] = [.identity]
        var clipStack: [RectD] = []
        var currentBlock: String = "?"
        var drawCountPerBlock: [String: Int] = [:]

        for cmd in commands {
            switch cmd {
            case .beginGroup(let name):
                if name.hasPrefix("Block:") {
                    currentBlock = name.replacingOccurrences(of: "Block:", with: "")
                    drawCountPerBlock[currentBlock] = 0
                }

            case .pushTransform(let matrix):
                let current = transformStack.last ?? .identity
                let newMatrix = current.concatenating(matrix)
                transformStack.append(newMatrix)

            case .popTransform:
                if transformStack.count > 1 {
                    transformStack.removeLast()
                }

            case .pushClipRect(let rect):
                clipStack.append(rect)

            case .popClipRect:
                if !clipStack.isEmpty {
                    clipStack.removeLast()
                }

            case .drawImage(let assetId, let opacity):
                let drawCount = (drawCountPerBlock[currentBlock] ?? 0) + 1
                drawCountPerBlock[currentBlock] = drawCount

                // Limit to first 5 per block
                if drawCount <= 5 {
                    let effective = transformStack.last ?? .identity
                    let scissor = clipStack.last

                    print("\n[Block: \(currentBlock)] drawImage #\(drawCount)")
                    print("  assetId: \(assetId)")
                    print("  opacity: \(opacity)")
                    print("  effectiveMatrix:")
                    print("    a=\(effective.a), b=\(effective.b)")
                    print("    c=\(effective.c), d=\(effective.d)")
                    print("    tx=\(effective.tx), ty=\(effective.ty)")
                    if let s = scissor {
                        print("  effectiveScissor: (x=\(s.x), y=\(s.y), w=\(s.width), h=\(s.height))")
                    } else {
                        print("  effectiveScissor: NONE (full canvas)")
                    }

                    // Check for issues
                    if effective.a != 1.0 || effective.d != 1.0 {
                        print("  ⚠️ scale != 1 (a=\(effective.a), d=\(effective.d))")
                    }
                }

            default:
                break
            }
        }

        print("\n" + String(repeating: "=", count: 80))
    }

    // MARK: - 5. Full Diagnostic Report (all sections combined)

    func testDiagnostic_fullReport() throws {
        print("\n")
        print(String(repeating: "#", count: 80))
        print("# FULL DIAGNOSTIC REPORT")
        print(String(repeating: "#", count: 80))

        try testDiagnostic_sceneLevel()
        try testDiagnostic_perFrameSummary()
        try testDiagnostic_blockLevelScope()
        try testDiagnostic_effectiveMatrixAndScissor()

        print("\n")
        print(String(repeating: "#", count: 80))
        print("# END OF DIAGNOSTIC REPORT")
        print(String(repeating: "#", count: 80))
        print("\n")
    }
}
// swiftlint:enable file_length function_body_length
