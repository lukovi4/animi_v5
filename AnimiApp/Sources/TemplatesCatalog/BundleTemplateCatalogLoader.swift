import Foundation

// MARK: - Catalog Loader Errors

enum CatalogLoaderError: Error, LocalizedError {
    case manifestNotFound
    case decodingFailed(Error)

    var errorDescription: String? {
        switch self {
        case .manifestNotFound:
            return "Catalog manifest.json not found in bundle"
        case .decodingFailed(let error):
            return "Failed to decode manifest: \(error.localizedDescription)"
        }
    }
}

// MARK: - Bundle Template Catalog Loader

/// Loads template catalog from app bundle.
final class BundleTemplateCatalogLoader {

    private let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    /// Loads manifest.json and resolves all resource URLs.
    func loadManifest() throws -> TemplateCatalogSnapshot {
        // Find manifest.json in Templates/Catalog/
        guard let manifestURL = bundle.url(
            forResource: "manifest",
            withExtension: "json",
            subdirectory: "Templates/Catalog"
        ) else {
            #if DEBUG
            print("[Catalog] ERROR: manifest.json not found in Templates/Catalog")
            #endif
            throw CatalogLoaderError.manifestNotFound
        }
        #if DEBUG
        print("[Catalog] Found manifest at: \(manifestURL.path)")
        #endif

        // Decode manifest
        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        let manifest: CatalogManifest
        do {
            manifest = try decoder.decode(CatalogManifest.self, from: data)
        } catch {
            throw CatalogLoaderError.decodingFailed(error)
        }

        // Validate templates: skip those with empty sceneTypeIds
        let resolvedTemplates: [TemplateDescriptor] = manifest.templates.compactMap { template in
            guard !template.sceneTypeIds.isEmpty else {
                #if DEBUG
                print("[Catalog] Skipping template '\(template.id)': empty sceneTypeIds")
                #endif
                return nil
            }

            var resolved = template

            // Resolve preview URL if previewAsset is specified
            if let previewAsset = template.previewAsset {
                resolved.previewURL = bundle.url(
                    forResource: (previewAsset as NSString).deletingPathExtension,
                    withExtension: (previewAsset as NSString).pathExtension,
                    subdirectory: "Templates/Previews"
                )
            }

            return resolved
        }

        return TemplateCatalogSnapshot(
            categories: manifest.categories,
            templates: resolvedTemplates
        )
    }
}
