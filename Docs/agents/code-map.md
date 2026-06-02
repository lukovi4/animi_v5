# Animi Code Map

This file is a routing map for AI agents. It is not source of truth and not a substitute for reading current code.

Use it to decide where to start investigation, then verify actual files before planning, implementation, or review.

## Editor Timeline / Playhead / Scene Focus

Start here when behavior involves selecting scenes, focus, playhead movement, timeline taps, or playback control:

- `AnimiApp/Sources/Editor/Timeline/TimelineView.swift`: timeline UI events.
- `AnimiApp/Sources/Editor/Controllers/EditorTimelineController.swift`: dispatch path from timeline events to editor actions.
- `AnimiApp/Sources/Editor/Store/EditorAction.swift`: reducer action surface.
- `AnimiApp/Sources/Editor/Store/EditorReducer.swift`: editor state transitions.
- `AnimiApp/Sources/Editor/Store/EditorState.swift`: selection, timeline mode, playhead helpers.
- `AnimiApp/Tests/EditorReducerPlayheadSelectionTests.swift`: reducer tests for playhead and scene selection.
- `AnimiApp/Tests/EditorTimelineControllerFocusPlaybackTests.swift`: controller-level focus/playback behavior when present.

Regression checks to consider: timeline selection, playhead movement, follow-playhead mode, scene-edit mode, playback start/stop behavior, undo/snapshot behavior.

## User Media / Video Trim / Playback Window

Start here when behavior involves user media, video windows, poster/still extraction, trim, preview/export parity, or playback windows:

- `AnimiApp/Sources/UserMedia/UserMediaService.swift`: user-media state and service behavior.
- `AnimiApp/Sources/UserMedia/VideoFrameProvider.swift`: video frame extraction/playback window behavior.
- `AnimiApp/Sources/UserMedia/UserMediaTextureFactory.swift`: texture creation path.
- `AnimiApp/Sources/Editor/SceneEdit/InlineVideoTrimCoordinator.swift`: inline trim interactions.
- `AnimiApp/Tests/UserMediaServiceTrimPreviewTests.swift`: trim preview behavior.
- `AnimiApp/Tests/VideoFrameProviderPlaybackWindowTests.swift`: playback-window behavior.

Regression checks to consider: preview/export parity, committed vs draft trim, still extraction latest-wins behavior, playback clamp/hold behavior, persistence/roundtrip.

## TVECore Runtime Boundary

Start here when behavior involves runtime playback/rendering, templates, compiler boundaries, or source-scene loading:

- `TVECore/Sources/`: runtime/compiler package sources.
- `TVECore/Tests/`: package-level tests.
- `Scripts/verify_module_boundary.sh`: boundary verification.
- `Scripts/verify_singleton_bans.sh`: singleton/dependency direction verification.

Regression checks to consider: runtime independence from compiler/source parsing, release app path dependencies, JSON/source tooling leakage.

## Project / Build Files

Start here only when the approved task contract explicitly allows project/build changes:

- `AnimiApp/AnimiApp.xcodeproj/project.pbxproj`: Xcode target membership and build settings.
- `Scripts/`: local and CI verification gates.
- `Makefile`: local build entry points.

Project/build-file changes are sensitive. They require explicit plan approval and must stay inside the approved task.
