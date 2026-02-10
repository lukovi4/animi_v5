import Foundation
import TVECompilerCore

// MARK: - TVE Template Compiler CLI

/// Compiles a ScenePackage (scene.json + anim-*.json) into compiled.tve
@main
struct TVETemplateCompiler {
    static func main() {
        do {
            try run()
        } catch {
            printError("Error: \(error)")
            exit(1)
        }
    }

    static func run() throws {
        let args = CommandLine.arguments

        guard args.count >= 3 else {
            printUsage()
            exit(1)
        }

        var inputURL: URL?
        var outputURL: URL?

        var i = 1
        while i < args.count {
            switch args[i] {
            case "--input", "-i":
                i += 1
                guard i < args.count else {
                    printError("Missing value for --input")
                    exit(1)
                }
                inputURL = URL(fileURLWithPath: args[i])
            case "--output", "-o":
                i += 1
                guard i < args.count else {
                    printError("Missing value for --output")
                    exit(1)
                }
                outputURL = URL(fileURLWithPath: args[i])
            case "--help", "-h":
                printUsage()
                exit(0)
            default:
                if args[i].hasPrefix("-") {
                    printError("Unknown option: \(args[i])")
                    exit(1)
                }
            }
            i += 1
        }

        guard let input = inputURL else {
            printError("Missing required --input parameter")
            printUsage()
            exit(1)
        }

        guard let output = outputURL else {
            printError("Missing required --output parameter")
            printUsage()
            exit(1)
        }

        try compile(from: input, to: output)
    }

    static func printUsage() {
        print("""
        TVE Template Compiler v\(TVECore.version)

        Usage: tve-template-compiler --input <ScenePackageFolder> --output <OutputFolder>

        Options:
          -i, --input   Path to ScenePackage folder containing scene.json and anim-*.json
          -o, --output  Path to output folder where compiled.tve will be written
          -h, --help    Show this help message

        Example:
          tve-template-compiler --input ./templates/my_template --output ./compiled
        """)
    }

    static func printError(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    static func compile(from inputURL: URL, to outputURL: URL) throws {
        print("TVE Template Compiler v\(TVECore.version)")
        print("Input:  \(inputURL.path)")
        print("Output: \(outputURL.path)")
        print("")

        // 1. Load package
        print("[1/6] Loading package...")
        let packageLoader = ScenePackageLoader()
        let package = try packageLoader.load(from: inputURL)
        print("       Loaded scene with \(package.scene.mediaBlocks.count) block(s)")

        // 2. Load animations
        print("[2/6] Loading animations...")
        let animLoader = AnimLoader()
        let loadedAnimations = try animLoader.loadAnimations(from: package)
        let totalVariants = package.scene.mediaBlocks.flatMap { $0.variants }.count
        let animCount = loadedAnimations.lottieByAnimRef.count
        print("       Loaded \(animCount) animation(s) for \(totalVariants) variant(s)")

        // 3. Validate scene
        print("[3/6] Validating scene...")
        let sceneValidator = SceneValidator()
        let sceneReport = sceneValidator.validate(scene: package.scene)
        let sceneErrors = sceneReport.errors
        let sceneWarnings = sceneReport.warnings

        if !sceneWarnings.isEmpty {
            for warning in sceneWarnings {
                print("       WARNING: [\(warning.code)] \(warning.path): \(warning.message)")
            }
        }

        if !sceneErrors.isEmpty {
            for error in sceneErrors {
                printError("       ERROR: [\(error.code)] \(error.path): \(error.message)")
            }
            throw CompilerError.sceneValidationFailed(errors: sceneErrors.count)
        }
        print("       Scene validation passed (\(sceneWarnings.count) warning(s))")

        // 4. Validate animations
        print("[4/6] Validating animations...")
        let localAssets = try LocalAssetsIndex(imagesRootURL: inputURL.appendingPathComponent("images"))
        let sharedURL = inputURL.appendingPathComponent("shared")
        let sharedAssets: SharedAssetsIndex
        if FileManager.default.fileExists(atPath: sharedURL.path) {
            sharedAssets = try SharedAssetsIndex(rootURL: sharedURL)
        } else {
            sharedAssets = .empty
        }
        let resolver = CompositeAssetResolver(localIndex: localAssets, sharedIndex: sharedAssets)

        let animValidator = AnimValidator()
        let animReport = animValidator.validate(
            scene: package.scene,
            package: package,
            loaded: loadedAnimations,
            resolver: resolver
        )
        let animErrors = animReport.errors
        let animWarnings = animReport.warnings

        if !animWarnings.isEmpty {
            for warning in animWarnings {
                print("       WARNING: [\(warning.code)] \(warning.path): \(warning.message)")
            }
        }

        if !animErrors.isEmpty {
            for error in animErrors {
                printError("       ERROR: [\(error.code)] \(error.path): \(error.message)")
            }
            throw CompilerError.animValidationFailed(errors: animErrors.count)
        }
        print("       Animation validation passed (\(animWarnings.count) warning(s))")

        // 5. Compile using SceneCompiler (from TVECompilerCore)
        print("[5/6] Compiling...")
        let sceneCompiler = SceneCompiler()
        let compiled = try sceneCompiler.compile(package: package, loadedAnimations: loadedAnimations)
        print("       Compiled \(compiled.runtime.blocks.count) block(s)")
        print("       PathRegistry: \(compiled.pathRegistry.count) path(s)")
        print("       MergedAssets: \(compiled.mergedAssetIndex.byId.count) asset(s)")

        // 6. Write compiled.tve
        print("[6/6] Writing compiled.tve...")

        // Ensure output directory exists
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        let templateId = package.scene.sceneId ?? inputURL.lastPathComponent
        let payload = CompiledScenePayload(
            compiled: compiled,
            templateId: templateId,
            templateRevision: 1,
            engineVersion: TVECore.version
        )

        let outputFileURL = outputURL.appendingPathComponent("compiled.tve")
        try CompiledScenePackageWriter.write(
            payload: payload,
            to: outputFileURL,
            engineVersion: TVECore.version
        )

        let fileSize = try FileManager.default.attributesOfItem(atPath: outputFileURL.path)[.size] as? Int ?? 0
        let fileSizeKB = Double(fileSize) / 1024.0

        print("")
        print("Success!")
        print("  Output: \(outputFileURL.path)")
        print("  Size:   \(String(format: "%.1f", fileSizeKB)) KB")
    }
}

// MARK: - Compiler Errors

enum CompilerError: Error, CustomStringConvertible {
    case sceneValidationFailed(errors: Int)
    case animValidationFailed(errors: Int)

    var description: String {
        switch self {
        case .sceneValidationFailed(let count):
            return "Scene validation failed with \(count) error(s)"
        case .animValidationFailed(let count):
            return "Animation validation failed with \(count) error(s)"
        }
    }
}
