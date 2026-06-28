import XCTest
@testable import AnimiApp

/// Slice-005 Stage C — the `DebugPreviewAudioWithNextEngine` toggle selects the controller:
/// OFF (default) → legacy `EnginePreviewAudioPlaybackController`; ON → `CanonicalPreviewAudioController`.
@MainActor
final class PreviewAudioToggleSelectionTests: XCTestCase {

    private let key = "DebugPreviewAudioWithNextEngine"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    func testToggleDefaultsOff() {
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(NextPreviewAudioEngineToggles.previewAudioWithNextEngine, "toggle defaults OFF")
    }

    func testToggleOffSelectsLegacyController() {
        let controller = EditorRuntimePreviewAudioCoordinator.makeControllerForTesting(canonicalEnabled: false)
        XCTAssertTrue(controller is EnginePreviewAudioPlaybackController,
            "toggle OFF must use the legacy controller (legacy path unchanged)")
        XCTAssertFalse(controller is CanonicalPreviewAudioController)
    }

    func testToggleOnSelectsCanonicalController() {
        let controller = EditorRuntimePreviewAudioCoordinator.makeControllerForTesting(canonicalEnabled: true)
        XCTAssertTrue(controller is CanonicalPreviewAudioController,
            "toggle ON must use the canonical realtime controller")
        XCTAssertFalse(controller is EnginePreviewAudioPlaybackController)
    }

    /// The toggle's key string is the established `Debug…WithNextEngine` shape and defaults OFF.
    func testToggleKeyAndDefault() {
        XCTAssertEqual(NextPreviewAudioEngineToggles.defaultsKey, "DebugPreviewAudioWithNextEngine")
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(NextPreviewAudioEngineToggles.previewAudioWithNextEngine)
    }
}
