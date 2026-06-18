import Foundation

/// Copies a real fixture into a fresh temporary directory so mutation-based tests
/// (symlink-rejection, dotfile-ignore) can plant artifacts **there** without ever writing to
/// `SceneSources/` (Task-001 plan, correction #4).
///
/// The real `SceneSources/` tree is read-only input to the index; only the temp copy is mutated.
/// Callers own cleanup via ``remove()`` (or by removing ``rootURL``).
public final class CopiedFixture {
    /// The temporary directory that contains the copied template directory.
    public let rootURL: URL
    /// The copied template directory: `<rootURL>/<catalogID>`.
    public let templateURL: URL

    private let fileManager: FileManager

    /// Copies `SceneSources/<catalogID>` from `root` into a unique temp directory.
    public init(
        catalogID: String,
        from root: TemplateRepositoryRoot,
        fileManager: FileManager = .default
    ) throws {
        self.fileManager = fileManager

        let source = root.templateDirectoryURL(forCatalogID: catalogID)
        let temp = fileManager.temporaryDirectory
            .appendingPathComponent("AnimiEngineNextFixture-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temp, withIntermediateDirectories: true)

        let destination = temp.appendingPathComponent(catalogID, isDirectory: true)
        try fileManager.copyItem(at: source, to: destination)

        self.rootURL = temp
        self.templateURL = destination
    }

    /// Plants an empty dotfile (e.g. `.DS_Store`) inside the copied template, to assert it is
    /// ignored by the index.
    @discardableResult
    public func plantDotfile(named name: String = ".DS_Store") throws -> URL {
        precondition(name.hasPrefix("."), "dotfile name must start with a dot")
        let url = templateURL.appendingPathComponent(name)
        try Data().write(to: url)
        return url
    }

    /// Plants a symlink inside the copied template, to assert the index rejects it.
    @discardableResult
    public func plantSymlink(named name: String, pointingTo destination: URL) throws -> URL {
        let url = templateURL.appendingPathComponent(name)
        try fileManager.createSymbolicLink(at: url, withDestinationURL: destination)
        return url
    }

    /// Removes the temporary directory tree.
    public func remove() {
        try? fileManager.removeItem(at: rootURL)
    }
}
