import Foundation
import XCTest

/// Test-only loader for the real compiled `.tve` fixtures (Task-003 plan §2 D3-01).
///
/// The decoder itself is pure `Data -> DecodedCompiledTemplate` and never touches the filesystem;
/// only the tests read bytes. The five mandatory packages live at
/// `AnimiApp/Resources/Scenes/<id>/compiled.tve`, **outside** `SceneSources/`, so this helper
/// resolves them from the repository root derived from `#file` (the same test-only `#file`
/// convention used by `TemplateFixtureIndexTests`).
///
/// These files are read-only inputs and are never written.
enum CompiledTemplateFixtureBytes {

    /// The five mandatory catalog ids, in declaration order.
    static let mandatoryIDs: [String] = [
        "full_image",
        "polaroid_shared_demo",
        "polaroid_2",
        "example_4blocks",
        "6_frames_template"
    ]

    /// Reads the raw `compiled.tve` bytes for `catalogID`.
    static func bytes(_ catalogID: String) throws -> Data {
        let url = repositoryRootURL()
            .appendingPathComponent("AnimiApp/Resources/Scenes/\(catalogID)/compiled.tve")
        return try Data(contentsOf: url)
    }

    /// `#file` = `<repo>/AnimiEngineNext/Tests/AnimiEngineTemplateAdapterTests/CompiledTemplateFixtureBytes.swift`
    /// → four `deletingLastPathComponent` calls reach `<repo>`.
    private static func repositoryRootURL() -> URL {
        var url = URL(fileURLWithPath: #file)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url
    }
}
