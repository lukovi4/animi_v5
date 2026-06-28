# Slice 005 Device Gate — Canonical Preview Audio (toggle ON)

**Verdict: PARTIAL — build/install/run on a physical iPhone PASS; every canonical-audio
behaviour (toggle selection, non-empty AudioPlan, decoder invocation, sink scheduling,
audible playback, scrub silence, pause/play, route pause-only) is BLOCKED.**

Two hard blockers: (a) the canonical realtime path has **no instrumentation** (no
`os_log`/`MemoryDiagnostics`/`print` anywhere under `Realtime/`), so there is no machine
evidence that the path was reached — confirming it would require **adding logging =
editing production code = STOP**; (b) the audible/interactive checks need a physical
operator (import a music track, press Play, listen, scrub, plug/unplug headphones).

No code was edited by this gate. Index empty; no commit/stage/push.

---

## Device / toolchain / commit

| Field | Value |
|------|-------|
| Xcode | 26.0.1 (build 17A400) |
| Physical device | **iPhone Evgeny**, iOS **26.5**, id `00008110-000C59C20A20401E`, arm64 |
| Configuration | **Debug** (the canonical path + toggle are `#if DEBUG`) |
| HEAD | `13ec15abf83dad5d8ac5b2566e9448eea39241e6` — "Record Slice 004 device gate evidence" |
| Working tree under test | Stage 005 C/C.5 is **uncommitted** (the 13 `Realtime/*.swift` files + the 3 modified app files are in the working tree, not in HEAD). The build therefore reflects the working tree, as required. |
| DerivedData (temp, not in repo) | `/tmp/animi-s005-devicegate` |

---

## Exact commands

```bash
# Preconditions
git diff --cached --name-only            # → empty
git rev-parse HEAD                        # → 13ec15ab…

# Build (Debug, physical device)
xcodebuild build \
  -project AnimiApp/AnimiApp.xcodeproj -scheme AnimiApp -configuration Debug \
  -destination 'platform=iOS,arch=arm64,id=00008110-000C59C20A20401E' \
  -derivedDataPath /tmp/animi-s005-devicegate -allowProvisioningUpdates
#   → ** BUILD SUCCEEDED **  (signed: Apple Development: Evgeny Lukovich (6C9K9KT3HC))

# Install + launch with the canonical toggle ON (app args after `--`)
xcrun devicectl device install app   --device 00008110-…  .../Debug-iphoneos/AnimiApp.app
#   → App installed: com.animi.app
xcrun devicectl device process launch --device 00008110-… com.animi.app \
  -- -DebugPreviewAudioWithNextEngine YES
#   → Launched application with com.animi.app bundle identifier
```

(First launch attempt `… --console com.animi.app -DebugPreviewAudioWithNextEngine YES`
failed: `devicectl` parsed `YES` as its own `-t` flag — app args must follow `--`.)

---

## Pass / fail table

| # | Check | Result | Evidence |
|---|-------|--------|----------|
| 1 | app builds / installs / launches on physical device | ✅ **PASS** | `** BUILD SUCCEEDED **` (Debug, signed); `App installed: com.animi.app`; `Launched … com.animi.app`. |
| 2 | toggle ON selects `CanonicalPreviewAudioController` | ⛔ **BLOCKED** | The launch arg was delivered, but `makeDefaultController()` runs **lazily** only when the coordinator first builds the controller (on entering timeline preview with a loaded project). That requires operator UI, and there is **no log** to confirm which controller was installed. Proven only at unit level (`PreviewAudioToggleSelectionTests`, toggle ON → `CanonicalPreviewAudioController`). |
| 3 | imported audio → non-empty `AudioPlan` | ⛔ **BLOCKED** | Requires an imported music track in the on-device project (operator import; `.bundled` SFX is fail-closed) AND a log of the plan. Neither available. Proven only at unit level (`AppAudioEvaluationBridgeTests`, `CanonicalPreviewAudioChainTests`). |
| 4 | `AVAssetReaderPCMDecoder` invoked | ⛔ **BLOCKED** | No instrumentation in the decoder; can't be observed from syslog. Proven only via the fixture-decoder chain test. |
| 5 | `PreviewAudioGraph` receives a scheduled mixed buffer | ⛔ **BLOCKED** | No instrumentation in graph/sink; not observable. Proven only via `RecordingSink` in `CanonicalPreviewAudioChainTests`. |
| 6 | audible playback on explicit Play | ⛔ **BLOCKED** | Needs an operator to press Play and **listen**. |
| 7 | scrub is silent | ⛔ **BLOCKED** | Needs an operator to scrub and confirm silence by ear. Proven only at unit level. |
| 8 | pause / play works | ⛔ **BLOCKED** | Needs operator interaction. |
| 9 | newDeviceAvailable / route change is pause-only, no auto-resume | ⛔ **BLOCKED** | Needs an operator to plug/unplug headphones/BT and observe. Proven only at unit level (`RealtimeAudioSessionEventMappingTests`, `CanonicalPreviewAudioControllerTests`). |
| 10 | no export path touched | ✅ **PASS** | `git diff -- AnimiApp/Sources/Export AnimiApp/Sources/EditorRuntime/AudioCompositionBuilder.swift` empty; the canonical path imports no export type. |
| 11 | capture logs / evidence | ⚠️ **PARTIAL** | Build/install/launch captured. Device console after launch held only the `devicectl` tunnel boilerplate (3 lines) — **the canonical path emits nothing** (no `os_log`/`MemoryDiagnostics`/`print` under `Realtime/`). |

---

## Logs proving the canonical path reached decoder/sink

**None available.** A repo-wide scan of the canonical realtime layer found **no logging
of any kind**:

```bash
rg "MemoryDiagnostics|os_log|Logger|print\(|\.event\(" AnimiApp/Sources/EditorRuntime/Realtime/*.swift
#   → (no matches)
```

The device console captured immediately after launch contained only:

```
07:22:26  Acquired tunnel connection to device.
07:22:26  Enabling developer disk image services.
07:22:26  Acquired usage assertion.
```

There is therefore **no syslog evidence** that `currentAudioPlan()` produced a non-empty
plan, that `AVAssetReaderPCMDecoder.decodeMonoFloat32` ran, or that
`PreviewAudioGraph.scheduleMix` reached the sink. Producing such evidence would require
adding instrumentation to `Realtime/*` — a production-code change, which this gate is
forbidden to make (**STOP**).

---

## What was heard / observed

Nothing audible or interactive was observed — there was **no operator** to import a track,
press Play, scrub, or connect/disconnect headphones, and no automated path can do so or
hear the result. The objectively-observed facts are limited to: the app built (Debug,
signed), installed (`com.animi.app`), and launched on the physical device.

---

## Blockers

1. **No instrumentation on the canonical path** — without `os_log`/`MemoryDiagnostics`
   markers at the plan / decoder / sink, there is no headless evidence the path executed.
   Adding them is a production change (STOP). *Recommendation:* a follow-up adds
   DEBUG-only `MemoryDiagnostics.event` markers
   (`preview.audio.canonical.{planBuilt,decode,scheduledMixed,start}`) so the gate can be
   run headlessly; that change must be separately approved.
2. **Operator required** — toggle-selection-in-situ, importing a music track on device,
   pressing Play, judging audibility, scrubbing, and headphone connect/disconnect all need
   a human on the physical iPhone.
3. **On-device imported audio fixture** — there is no committed/clean-checkout way to load
   an imported music track on the device; `.bundled` SFX is fail-closed for the canonical
   preview, so a real imported asset must be added by the operator.

---

## Exact changed files

**None.** This gate edited no source. The working-tree `M`/`??` entries
(`project.pbxproj`, `EngineBridgeDiagnostics.swift`, `EditorRuntime.swift`,
`EditorRuntimePreviewAudioCoordinator.swift`, `Sources/EditorRuntime/Realtime/`) are the
**pre-existing uncommitted Stage 005 C/C.5 work**, unchanged by this gate.

## Index status

`git diff --cached --name-only` → **empty**. No stage / commit / push.

---

## Is the Slice 005 device gate closed?

**No.** Build/install/run is PASS, but every canonical-audio behaviour is BLOCKED on (a)
missing path instrumentation (resolving it = a separate, approved production change) and
(b) a physical operator with an imported music track. Unit/offline closure for Slice 005
A–C.5 remains green (89 app tests + 61 legacy, 0 failures); the **device gate stays
OPEN**.
