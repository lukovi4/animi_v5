# Animi Regression Map

This file maps recurring risk areas to focused checks. It is a routing aid, not source of truth.

Codex chooses checks based on changed files, approved behavior, and review risk. Claude reports exact commands and results in `claude-summary.md`.

## Timeline / Scene Focus / Playhead

Risk signals:

- `TimelineView.swift`, `EditorTimelineController.swift`, `EditorAction.swift`, `EditorReducer.swift`, or `EditorState.swift` changes.
- User-visible scene selection, playhead movement, focus, playback start/stop, follow-playhead, or timeline tap behavior.

Focused seams:

- `AnimiApp/Tests/EditorReducerPlayheadSelectionTests.swift`
- `AnimiApp/Tests/EditorTimelineControllerFocusPlaybackTests.swift` when controller/playback dispatch is involved.

Broader gate:

- `ANIMIAPP_DERIVED_DATA_PATH=/tmp/<task> bash Scripts/run_animiapp_tests.sh`

Manual QA is usually required when gesture timing, playback start/stop, or visible playhead behavior is part of the expected outcome.

## User Media / Trim / VideoFrameProvider

Risk signals:

- `UserMediaService.swift`, `VideoFrameProvider.swift`, `UserMediaTextureFactory.swift`, or `InlineVideoTrimCoordinator.swift` changes.
- Preview/export parity, committed vs draft trim, still extraction, playback window, or media timing behavior.

Focused seams:

- `AnimiApp/Tests/UserMediaServiceTrimPreviewTests.swift`
- `AnimiApp/Tests/VideoFrameProviderPlaybackWindowTests.swift`

Broader gate:

- `ANIMIAPP_DERIVED_DATA_PATH=/tmp/<task> bash Scripts/run_animiapp_tests.sh`

Manual QA is often required when the issue is visual, interactive, or export-output related.

## TVECore Runtime / Compiler Boundary

Risk signals:

- `TVECore/Sources/**` changes.
- Runtime playback/rendering changes.
- Compiler/source-scene/JSON loading changes.

Focused seams:

- Targeted `swift test` in `TVECore` when a package test exists.
- `Scripts/verify_module_boundary.sh`
- `Scripts/verify_singleton_bans.sh`

Broader gate:

- `make build` when app integration risk is present and explicitly allowed.

## Project / Build System

Risk signals:

- `project.pbxproj`, schemes, build scripts, package/dependency files, signing/release resources.

Checks:

- Show focused project-file diff and target membership reasoning.
- Run the narrowest relevant build/test command approved by the plan and marker.
- Treat unverified project-file edits as high risk.
