import Foundation
import TVECore

// MARK: - Resolved Editor Render

/// Result of render command resolution.
struct ResolvedEditorRender {
    /// The template mode used for rendering (kept for debug/tests).
    let mode: TemplateMode
    /// The frame index used for rendering.
    let frameIndex: Int
    /// The render commands to execute.
    let commands: [RenderCommand]
}

// MARK: - Editor Render Command Resolver

/// Resolves render commands based on EditorUIMode.
/// Testable without UIKit/Metal dependencies via closures.
enum EditorRenderCommandResolver {

    /// Resolves render commands for the current editor state.
    ///
    /// Resolution order:
    /// 1. Primary: coordinator commands (state-aware)
    /// 2. Fallback: scenePlayer commands (state-aware)
    /// 3. Returns nil if no valid commands available
    ///
    /// - Parameters:
    ///   - uiMode: Current editor UI mode
    ///   - coordinatorLocalFrame: Local frame from coordinator (if available)
    ///   - currentFrameIndex: Fallback frame index
    ///   - coordinatorCommands: Closure to get commands from coordinator
    ///   - scenePlayerCommands: Closure to get commands from scene player
    /// - Returns: Resolved render result, or nil if no valid commands
    static func resolve(
        uiMode: EditorUIMode,
        coordinatorLocalFrame: Int?,
        currentFrameIndex: Int,
        coordinatorCommands: (TemplateMode) -> [RenderCommand]?,
        scenePlayerCommands: (TemplateMode, Int) -> [RenderCommand]?
    ) -> ResolvedEditorRender? {
        let mode = EditorRenderContract.templateMode(for: uiMode)
        let frameIndex = coordinatorLocalFrame ?? currentFrameIndex

        // Primary: coordinator (state-aware)
        if let commands = coordinatorCommands(mode), !commands.isEmpty {
            return ResolvedEditorRender(mode: mode, frameIndex: frameIndex, commands: commands)
        }

        // Fallback: scenePlayer (state-aware)
        if let commands = scenePlayerCommands(mode, frameIndex), !commands.isEmpty {
            return ResolvedEditorRender(mode: mode, frameIndex: frameIndex, commands: commands)
        }

        // No valid commands
        return nil
    }
}
