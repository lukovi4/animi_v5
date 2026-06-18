import Foundation
import CryptoKit

/// Identifies and hashes the five mandatory real templates (Task-001 plan, "Real-template fixture
/// index", decision **D-004**). It **only** identifies and hashes — it never loads, parses, or
/// renders a template (acceptance #7, #9).
///
/// Each template is resolved under the **injected** repository root at `SceneSources/<id>/`.
public struct TemplateFixtureIndex {

    /// The five mandatory catalog template ids, in declaration order.
    public static let mandatoryCatalogIDs: [String] = [
        "full_image",
        "polaroid_shared_demo",
        "polaroid_2",
        "example_4blocks",
        "6_frames_template"
    ]

    /// A single indexed template: its canonical catalog id, source directory, optional captured
    /// `sceneId` metadata, and the content hash.
    public struct Entry: Equatable, Sendable {
        /// Canonical key — the **catalog directory id** (e.g. `example_4blocks`), correction #7.
        public let catalogID: String
        /// The source directory: `<root>/SceneSources/<catalogID>`.
        public let directoryURL: URL
        /// Optional opaque internal `sceneId` captured as metadata only (e.g.
        /// `scene_test_2x2_4blocks`); stored without parsing template semantics.
        public let sceneIDMetadata: String?
        /// Lowercase hex SHA-256 content hash (see ``contentHashHex(ofTemplateAt:)``).
        public let contentHashHex: String
    }

    /// Errors raised while indexing/hashing a template.
    public enum IndexError: Error, Equatable, Sendable {
        /// The template source directory was not found under the injected root.
        case templateNotFound(catalogID: String, path: String)
        /// A symlink was encountered inside a template — rejected, never followed (correction #6).
        case symlinkRejected(path: String)
        /// An underlying filesystem operation failed.
        case ioFailure(reason: String)
    }

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Indexes all five mandatory templates under `root`.
    public func indexMandatoryTemplates(root: TemplateRepositoryRoot) throws -> [Entry] {
        try Self.mandatoryCatalogIDs.map { id in
            try indexTemplate(catalogID: id, directoryURL: root.templateDirectoryURL(forCatalogID: id))
        }
    }

    /// Indexes a single template at an explicit directory (used by both the mandatory walk and
    /// the copied-fixture tests).
    public func indexTemplate(catalogID: String, directoryURL: URL) throws -> Entry {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw IndexError.templateNotFound(catalogID: catalogID, path: directoryURL.path)
        }
        let hash = try contentHashHex(ofTemplateAt: directoryURL)
        let sceneID = capturedSceneID(in: directoryURL)
        return Entry(
            catalogID: catalogID,
            directoryURL: directoryURL,
            sceneIDMetadata: sceneID,
            contentHashHex: hash
        )
    }

    // MARK: - Hashing

    /// SHA-256 over, for each included file in **sorted relative-path order**:
    /// the **relative path bytes**, the **file size** (as 8 little-endian bytes), then the
    /// **file bytes** (Task-001 plan, correction #6).
    ///
    /// Rules: ignore hidden/system files (dotfiles); reject symlinks (typed error, no following).
    /// The walk is confined to `templateURL`, so the redundant compiled
    /// `AnimiApp/Resources/Scenes/<id>/compiled.tve` (which lives outside `SceneSources/`) is
    /// naturally excluded.
    public func contentHashHex(ofTemplateAt templateURL: URL) throws -> String {
        let files = try includedFiles(under: templateURL)
        var hasher = SHA256()
        for file in files.sorted(by: { $0.relativePath < $1.relativePath }) {
            hasher.update(data: Data(file.relativePath.utf8))

            let size = try fileSize(at: file.url)
            withUnsafeBytes(of: UInt64(size).littleEndian) { hasher.update(data: Data($0)) }

            do {
                let bytes = try Data(contentsOf: file.url)
                hasher.update(data: bytes)
            } catch {
                throw IndexError.ioFailure(reason: "read \(file.relativePath): \(error)")
            }
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private struct IncludedFile {
        let url: URL
        let relativePath: String
    }

    /// Recursively enumerates the included files under `templateURL`, rejecting symlinks and
    /// ignoring hidden/system files.
    private func includedFiles(under templateURL: URL) throws -> [IncludedFile] {
        var results: [IncludedFile] = []
        let basePath = templateURL.standardizedFileURL.path

        // Shallow, manual recursion so we can detect symlinks before following them.
        func walk(_ directory: URL) throws {
            let entries: [URL]
            do {
                entries = try fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
                    options: []
                )
            } catch {
                throw IndexError.ioFailure(reason: "list \(directory.path): \(error)")
            }

            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = entry.lastPathComponent
                // Ignore hidden/system files (dotfiles such as .DS_Store, OS metadata).
                if name.hasPrefix(".") { continue }

                let values = try resourceValues(for: entry)
                if values.isSymlink {
                    throw IndexError.symlinkRejected(path: entry.path)
                }
                if values.isDirectory {
                    try walk(entry)
                } else {
                    let full = entry.standardizedFileURL.path
                    let relative = String(full.dropFirst(basePath.count).drop(while: { $0 == "/" }))
                    results.append(IncludedFile(url: entry, relativePath: relative))
                }
            }
        }

        try walk(templateURL)
        return results
    }

    private func resourceValues(for url: URL) throws -> (isSymlink: Bool, isDirectory: Bool) {
        do {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            return (values.isSymbolicLink ?? false, values.isDirectory ?? false)
        } catch {
            throw IndexError.ioFailure(reason: "stat \(url.path): \(error)")
        }
    }

    private func fileSize(at url: URL) throws -> Int {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            return values.fileSize ?? 0
        } catch {
            throw IndexError.ioFailure(reason: "size \(url.path): \(error)")
        }
    }

    // MARK: - Optional sceneId metadata

    /// Captures the opaque `sceneId` from `scene.json` as metadata only, without parsing template
    /// semantics. Returns `nil` if absent or unreadable — it is non-authoritative.
    private func capturedSceneID(in templateURL: URL) -> String? {
        let sceneJSON = templateURL.appendingPathComponent("scene.json")
        guard let data = try? Data(contentsOf: sceneJSON),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sceneID = object["sceneId"] as? String else {
            return nil
        }
        return sceneID
    }
}
