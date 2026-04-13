import Foundation

/// Creates a `ProjectDraft` for the blank-project flow.
///
/// Uses the canonical `CanonicalTimeline.makeWithSingleScene` factory so the
/// draft arrives at `EditorSession.bootstrap` with a non-empty timeline.
enum BlankProjectFactory {

    /// Default starter scene type id used for blank projects.
    static let defaultStarterSceneTypeId = "blank_starter"

    /// Creates a blank-project draft pre-populated with one starter scene.
    ///
    /// - Parameters:
    ///   - starterSceneTypeId: Scene type id for the starter scene.
    ///   - library: Scene library snapshot to resolve base duration.
    /// - Returns: A ready-to-bootstrap `ProjectDraft`.
    /// - Throws: If the starter scene is not found in the library.
    static func makeDraft(
        starterSceneTypeId: String = defaultStarterSceneTypeId,
        library: SceneLibrarySnapshot
    ) throws -> ProjectDraft {
        guard let scene = library.scene(byId: starterSceneTypeId) else {
            throw BlankProjectError.starterSceneNotFound(starterSceneTypeId)
        }

        let origin = ProjectOrigin.blank(starterSceneTypeId: starterSceneTypeId)
        let timeline = CanonicalTimeline.makeWithSingleScene(
            sceneTypeId: starterSceneTypeId,
            durationUs: scene.baseDurationUs
        )

        return ProjectDraft(
            origin: origin,
            canonicalTimeline: timeline
        )
    }
}

// MARK: - Errors

enum BlankProjectError: Error, LocalizedError {
    case starterSceneNotFound(String)

    var errorDescription: String? {
        switch self {
        case .starterSceneNotFound(let id):
            return "Starter scene '\(id)' not found in scene library"
        }
    }
}
