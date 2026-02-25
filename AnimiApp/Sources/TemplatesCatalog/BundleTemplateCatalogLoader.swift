import Foundation

// MARK: - Catalog Loader Errors

enum CatalogLoaderError: Error, LocalizedError {
    case manifestNotFound
    case decodingFailed(Error)
    case invalidPath(String)

    var errorDescription: String? {
        switch self {
        case .manifestNotFound:
            return "Catalog manifest.json not found in bundle"
        case .decodingFailed(let error):
            return "Failed to decode manifest: \(error.localizedDescription)"
        case .invalidPath(let path):
            return "Invalid resource path: \(path)"
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

        // Resolve URLs for each template, skip those with missing recipeURL
        // Release v1: Templates reference recipes, not compiled.tve files
        let resolvedTemplates: [TemplateDescriptor] = manifest.templates.compactMap { template in
            var resolved = template
            resolved.recipeURL = resolveURL(for: template.recipePath)
            resolved.previewURL = resolveURL(for: template.previewVideoPath)

            // Skip templates with missing recipe
            guard resolved.recipeURL != nil else {
                #if DEBUG
                print("[Catalog] ⚠️ Skipping template '\(template.id)': missing recipe at \(template.recipePath)")
                #endif
                return nil
            }

            return resolved
        }

        return TemplateCatalogSnapshot(
            categories: manifest.categories,
            templates: resolvedTemplates
        )
    }

    /// Resolves a relative path to a bundle URL.
    /// Release v1: Simple direct file lookup for all files (recipes, previews).
    private func resolveURL(for relativePath: String) -> URL? {
        // Path format: "Templates/Recipes/example_4blocks.json"
        let nsPath = relativePath as NSString
        let directory = nsPath.deletingLastPathComponent
        let filenameWithExt = nsPath.lastPathComponent as NSString
        let filename = filenameWithExt.deletingPathExtension
        let ext = nsPath.pathExtension

        #if DEBUG
        print("[Catalog] Resolving: \(relativePath) -> dir=\(directory), file=\(filename), ext=\(ext)")
        #endif

        // Direct file lookup
        if let directURL = bundle.url(
            forResource: filename,
            withExtension: ext.isEmpty ? nil : ext,
            subdirectory: directory
        ) {
            #if DEBUG
            print("[Catalog] Found: \(directURL.path)")
            #endif
            return directURL
        }

        #if DEBUG
        print("[Catalog] NOT found: \(relativePath)")
        #endif
        return nil
    }
}
