# CP7 — Final Report (for Codex review)

**Task 004 / CP7 — DEBUG-only user-VIDEO media support in AnimiEngineNext (preview + export).**
Status: implementation + corrective passes complete, automated + manual device E2E green. **NOT committed / NOT pushed.**

---

## 1. Scope & contract (owner-approved)

- DEBUG-only, behind existing flags `DebugRenderWithNextEngine` (preview) and `DebugExportWithNextEngine` (export). Default OFF → old TVECore path untouched.
- App/bridge-level **CPU decoder: video → BGRA8 `Data`** (no GPU readback from the existing MTLTexture providers). Old `ExportVideoFrameProvider` / `VideoFrameProvider` (MTLTexture) remain the TVECore default, unchanged.
- **No AnimiEngineNext schema/canonical changes.** `ResolvedPixelInput` already accepts arbitrary BGRA8.
- **Trim-only** user-media video timing (trimStart/trimEnd; no speed/loop/hold — those don't exist for user media). Byte-identical to the production `VideoTimelineTimeMapper`.
- No silent fallback when Next flags are ON — typed fail-closed errors only.

---

## 2. Exact changed files

### New (4)
| File | Lines | Purpose |
|---|---|---|
| `AnimiApp/Sources/Player/NextVideoFrameResolver.swift` | 452 | CPU video decoder → BGRA8: AVAssetReader, hold-last + lookahead, reseek on backward scrub, orientation bake (single CGContext.draw), downsample, `NextVideoTimeMapping`. |
| `AnimiApp/Tests/NextVideoFrameResolverTests.swift` | 459 | Resolver behaviour + orientation (real `preferredTransform` via `AVAssetWriterInput.transform`) + oracle rotation. |
| `AnimiApp/Tests/NextVideoTimeMappingTests.swift` | 133 | Mapping lockstep vs `VideoTimelineTimeMapper`. |
| `AnimiApp/Tests/NextVideoExportIntegrationTests.swift` | 288 | E2E export through `NextVideoExportRunner` (frame count, A=255). |

### Modified (8 src/test + pbxproj)
| File | Δ | What |
|---|---|---|
| `Player/NextSingleSceneBridge.swift` | +183/−… | `NextBridgeBlock.video`; `NextDecodedBlock` photo OR video resolver; `decodeMedia` builds resolver + probe; `NextPreparedContext.videoResolversByReference`; per-frame `mergeVideoPixels`; **stretch guard** (`stretchedSceneUnsupported`, `timelineDurationFrames`, `nominalFrameCount`); `LocalizedError` conformance. |
| `Player/NextTimelineBridge.swift` | +29 | per-scene video resolvers; per-subplan video resolution (outgoing/incoming sample own scene-local time). |
| `Player/NextPreviewController.swift` | +… | `NextPreviewKey.BlockMedia.videoWindow` (re-trim invalidates cache) + `timelineDurationFrames` in the media key so a live stretch change re-enters `decodeMedia` and fails closed before render. |
| `Player/EditorViewController.swift` | +28 | preview accepts video blocks (audio still fail-closed); feeds `timelineDurationFrames`. |
| `Export/NextExportInputsBuilder.swift` | +114 | video blocks from `mediaSnapshot.videoRefs`; `makeSingleScene(snapshot:)` for 1-scene timeline; `timelineDurationFrames` wiring. |
| `EditorRuntime/EditorRuntimeExportController.swift` | +94 | removed video fail-closed guards; 1-scene-timeline → single-scene route; video-audio selections into `exportVideoNext`; stretch span wiring. |
| `Export/NextVideoExportRunner.swift` | (CP6) | unchanged contract; sources video frames via the resolver-backed context. |
| `Tests/NextVideoExportRunnerTests.swift` | +129 | audio fail-closed→audio kind; 1-scene-snapshot video block; stretch fail-closed; `LocalizedError` readable. |
| `Tests/NextPreviewCacheKeyTests.swift` | +… | regression: `timelineDurationFrames` changes break the media key, while frame index still does not. |
| `AnimiApp.xcodeproj/project.pbxproj` | +16 | `xcodegen generate`; only the 4 new files. project.yml unchanged. |

---

## 3. Key design decisions (review focus)

1. **Timing contract = trim-only, proven by code.** `NextVideoTimeMapping.targetVideoTime` ≡ `VideoTimelineTimeMapper` (`tVideo = winStart + max(0, sceneSeconds)`, clamp `[winStart, winEnd − 1/600]`, hold-last). `NextVideoTimeMappingTests` pins epsilon (1/600 == `VideoWindowValidator.epsilon`) and frame/seconds-form equivalence + a parity sweep vs the production mapper.
2. **Scene-local time source = `SceneSubplan.scenePlaybackTime`** (the evaluator's own per-scene time). For transitions, outgoing/incoming subplans carry different scene-local times → each video frame sampled at its own time.
3. **Orientation** baked app-side (the reader yields raw track orientation; the Next bridge consumes `.up` and ignores `VideoPresentationInfo`). Quarter-turn derived from `preferredTransform`; applied in **one** `CGContext.draw` (rotate + downsample). Proven by `test_realTransform_identity_topStaysTop`, `test_realTransform_portrait90_isUprightAndPortraitSized`, `test_realTransform_portrait90_withDownsample_uprightAndScaled` (REAL `preferredTransform` MP4s), plus oracle `rotateBGRA` 0/90/180/270 (kept TEST-ONLY).
4. **Performance corrective**: an earlier per-pixel CPU rotation caused ~10× slowdown — replaced with the single hardware draw. `rotateBGRA` is test-only oracle; `downsampleBGRA` removed (dead).
5. **Single-scene export audio**: `exportVideoNext` now receives `videoSelectionsByBlockId` (from `mediaSnapshot.videoRefs` / snapshot `videoSelections`) — same audio contract as old single-scene export (was dropping video-slot audio).
6. **1-scene routing**: export route is `timeline` whenever the timeline engine is active; the Next timeline bridge needs ≥2 scenes. A 1-scene project now routes to the single-scene Next export (`runNextSingleSceneExportFromTimelineSession`).
7. **`LocalizedError`**: `NextBridgeError` now surfaces `description` through `localizedDescription` (export UI showed `NextBridgeError error <code>` before).

---

## 4. Stretched scenes — explicit fail-closed (canonical limitation)

Audit confirmed the **two-clock** model the old TVECore app uses for a stretched scene (timeline span > native duration):
- VISUAL/template clock = `clamp(frame, 0, nativeDurationFrames−1)` (`ExportFrameClamping.sceneFrame` / `SceneInstanceRuntime.clampedLocalFrame`) — animation holds the last native frame;
- MEDIA/video clock = `max(frame, 0)` unclamped (`ResolvedTimelineFrame.mediaLocalFrame`) — video continues to trim end.

The AnimiEngineNext evaluator exposes only ONE `scenePlaybackTime` and `projectDuration() == sum(nominalDuration)`. Representing two clocks requires a **canonical change** (declared STOP condition). CP7 therefore **fails closed before render**:
- `NextBridgeInputs.timelineDurationFrames` (app `durationUs`→frames) fed from preview + all export paths;
- guard in `decodeMedia` (after probe convert): `if timelineFrames > nominalFrames + 1 → throw stretchedSceneUnsupported(sceneTypeId, nativeFrames, timelineFrames)` (+1 frame µs-rounding tolerance);
- `timelineDurationFrames` is part of `NextPreviewKey.mediaKey`, so a scene stretched after a prepared context is cached invalidates the decode context and cannot leak `evaluate.outsideProject`;
- no `evaluate.outsideProject` leak, no truncated export, no perf cliff.

Canonical follow-up (separate Next task, NOT in CP7): add `timelineSpan`/`effectiveDuration` to `SceneManifestEntry`; `projectDuration` sums span; evaluator emits `visualPlaybackTime` (held) + `mediaPlaybackTime` (continues) on `SceneSubplan`; transitions use span; preview/export parity; golden tests vs old renderer's `localFrame`/`mediaLocalFrame`.

---

## 5. Supported vs unsupported (all fail-closed, typed)

**Supported (Next flags ON):** photo + video media; single-scene + timeline; cut/fade/slide/push/dip transitions; video on outgoing/incoming transition scenes; trim/volume/mute audio in single-scene export; orientation 0/90/180/270.

**Fail-closed (typed `NextBridgeError`, no silent fallback):** stretched scene; audio media kind; hidden block; missing/corrupt media; reduced export size (no downscale); custom background regions; text/sticker overlays; unknown transition; missing video trim window.

---

## 6. Tests & results

Sim: **iPhone 16 Pro, OS 18.4**. Cmd: `xcodebuild test -project AnimiApp/AnimiApp.xcodeproj -scheme AnimiApp -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.4'`

| Suite | Count | Result |
|---|---|---|
| NextVideoFrameResolverTests | 17 | 0 fail |
| NextVideoTimeMappingTests | 10 | 0 fail |
| NextVideoExportRunnerTests | 16 | 0 fail |
| NextVideoExportIntegrationTests | 3 | 0 fail |
| NextPreviewCacheKeyTests | 19 | 0 fail |
| **Full AnimiApp suite** | all | **TEST SUCCEEDED, 0 failures** |

Codex review rerun after the preview cache-key corrective:
`NextPreviewCacheKeyTests + NextVideoFrameResolverTests + NextVideoTimeMappingTests + NextVideoExportRunnerTests + NextVideoExportIntegrationTests`
→ **65 tests, 0 failures**.

Device unit/integration earlier run on iPhone 13 Pro (real H.264): resolver + mapping 18/18.

---

## 7. Device E2E (manual, iPhone 13 Pro "iPhone Evgeny", iOS 26.5, flags ON) — owner-confirmed OK

- Preview video: portrait + landscape orientation correct; scrub/play smooth (no 10× slowdown). ✅
- Single-scene export: image correct, **audio present**, trim/volume/mute intact. ✅
- Timeline export: 2 scenes + transition + video → MP4 visually fine. ✅
- Stretched scene: readable fail-closed error (after `LocalizedError` fix), no `outsideProject`, no truncation. ✅
- (Owner: "все хорошо".)

---

## 8. Boundaries / confirmations

- No templates / resources / SceneSources / SharedAssets / compiled.tve / ReferenceData / Package.swift changes. (`manifest.json` M and `SceneSources/6_frames_template/` ?? are PRE-EXISTING baseline residue from the session-start git snapshot — `manifest.json` mtime Jun 11, my edits Jun 19–20; not touched.)
- No AnimiEngineNext schema/canonical changes.
- All TEMP diagnostics removed: `rg "TEMP DIAG|cp7_video_diag|cp7_export_fail|remove before commit"` → no matches.
- pbxproj diff = +16, only the 4 new files (xcodegen).
- Nothing staged. **NOT committed, NOT pushed.**
- CP8 / text / sticker / background NOT started.

---

## 9. Suggested review focus for Codex

1. `NextVideoFrameResolver.bake` / `configureRotateDraw` — orientation correctness for all 4 quarter-turns + downsample; the single-draw geometry.
2. Resolver thread-confinement + AVAssetReader lifecycle (reseek on backward scrub; forward stream in export).
3. Stretch guard placement (before render, all paths) + µs↔frame rounding tolerance.
4. `mergeVideoPixels` per-subplan timing in transitions (outgoing vs incoming).
5. Memory bounds (no full predecode; one last+pending buffer; autoreleasepool in runner/preview).
6. Single-scene-from-1-scene-timeline routing + audio selection wiring.
