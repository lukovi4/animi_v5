import Foundation

/// Index of image assets by their ID
public struct AssetIndex: Sendable, Equatable {
    /// Mapping from asset ID to relative file path (e.g. "image_0" -> "images/img_1.png")
    public let byId: [String: String]

    public init(byId: [String: String] = [:]) {
        self.byId = byId
    }
}

/// Result of loading all animations from a scene package
public struct LoadedAnimations: Sendable, Equatable {
    /// Loaded Lottie JSON data keyed by animRef (e.g. "anim-1.json" -> LottieJSON)
    public let lottieByAnimRef: [String: LottieJSON]

    /// Asset index for each animation keyed by animRef
    public let assetIndexByAnimRef: [String: AssetIndex]

    public init(
        lottieByAnimRef: [String: LottieJSON] = [:],
        assetIndexByAnimRef: [String: AssetIndex] = [:]
    ) {
        self.lottieByAnimRef = lottieByAnimRef
        self.assetIndexByAnimRef = assetIndexByAnimRef
    }
}

/// Loads and decodes Lottie animation JSON files from a scene package
public final class AnimLoader {
    private let fileManager: FileManager

    /// Creates a new animation loader
    /// - Parameter fileManager: FileManager to use for file operations
    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Loads all animations referenced in the scene package
    /// - Parameter package: The scene package containing animation file references
    /// - Returns: LoadedAnimations containing decoded Lottie data and asset indices
    /// - Throws: AnimLoadError if any animation fails to load or decode
    public func loadAnimations(from package: ScenePackage) throws -> LoadedAnimations {
        var lottieByAnimRef: [String: LottieJSON] = [:]
        var assetIndexByAnimRef: [String: AssetIndex] = [:]

        for (animRef, fileURL) in package.animFilesByRef {
            let lottie = try loadSingleAnimation(animRef: animRef, fileURL: fileURL)
            lottieByAnimRef[animRef] = lottie
            assetIndexByAnimRef[animRef] = buildAssetIndex(from: lottie)
        }

        return LoadedAnimations(
            lottieByAnimRef: lottieByAnimRef,
            assetIndexByAnimRef: assetIndexByAnimRef
        )
    }

    /// Loads a single animation file
    private func loadSingleAnimation(animRef: String, fileURL: URL) throws -> LottieJSON {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw AnimLoadError.animJSONReadFailed(
                animRef: animRef,
                reason: error.localizedDescription
            )
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(LottieJSON.self, from: data)
        } catch {
            throw AnimLoadError.animJSONDecodeFailed(
                animRef: animRef,
                reason: error.localizedDescription
            )
        }
    }

    /// Builds asset index from Lottie JSON
    /// Extracts image assets that have directory (u) and filename (p) fields
    private func buildAssetIndex(from lottie: LottieJSON) -> AssetIndex {
        var byId: [String: String] = [:]

        for asset in lottie.assets where asset.isImage {
            if let relativePath = asset.relativePath {
                byId[asset.id] = relativePath
            }
        }

        return AssetIndex(byId: byId)
    }
}
