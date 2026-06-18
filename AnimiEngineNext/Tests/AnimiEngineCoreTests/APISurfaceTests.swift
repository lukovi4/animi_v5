import XCTest
import Foundation
@testable import AnimiEngineCore

/// Verifies the **public API surface** of `AnimiEngineCore` via symbol-graph inspection
/// (corrective plan C-4, Revision 3).
///
/// IMPORTANT: this test does **not** run `swift build` (no recursive build from XCTest). The symbol
/// graph must be produced by a separate verification command:
///
///     swift build --target AnimiEngineCore \
///       -Xswiftc -emit-symbol-graph -Xswiftc -emit-symbol-graph-dir -Xswiftc .symbolgraph
///
/// If `.symbolgraph/AnimiEngineCore.symbols.json` is not present, the test is skipped (the separate
/// command is the authoritative gate; this test is a convenience that reads its output).
final class APISurfaceTests: XCTestCase {

    /// The eight window/requirement family types that must expose no public initializer.
    private let family: Set<String> = [
        "EvaluationWindow", "WindowScene", "WindowTransition", "WindowOverlay",
        "EvaluationWindowRequirement", "RequiredSceneSpan", "RequiredBoundary", "RequiredOverlayEntry"
    ]

    /// `<repo>/AnimiEngineNext/.symbolgraph/AnimiEngineCore.symbols.json`.
    private func symbolGraphURL() -> URL {
        var url = URL(fileURLWithPath: #file)
        for _ in 0..<3 { url.deleteLastPathComponent() }   // → AnimiEngineNext/
        return url.appendingPathComponent(".symbolgraph/AnimiEngineCore.symbols.json")
    }

    func testNoPublicInitializersOnWindowFamilyAndSearchDiagnosticsIsInternal() throws {
        let url = symbolGraphURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("symbol graph not generated; run the separate emit-symbol-graph command first")
        }
        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let symbols = try XCTUnwrap(json["symbols"] as? [[String: Any]])

        var publicInits: [String] = []
        var searchDiagnostics: [String] = []
        for symbol in symbols {
            let components = (symbol["pathComponents"] as? [String]) ?? []
            let kind = ((symbol["kind"] as? [String: Any])?["identifier"] as? String) ?? ""
            if kind == "swift.init", components.count >= 2, family.contains(components[components.count - 2]) {
                publicInits.append(components.joined(separator: "."))
            }
            if components.contains("SearchDiagnostics") {
                searchDiagnostics.append(components.joined(separator: "."))
            }
        }
        XCTAssertTrue(publicInits.isEmpty, "window/requirement family must expose no public init: \(publicInits)")
        XCTAssertTrue(searchDiagnostics.isEmpty, "SearchDiagnostics must be internal, not public: \(searchDiagnostics)")
    }
}
