# Slice 004 — Device Evidence Gate

**Verdict: PARTIAL — build/install/run on a physical iPhone PASS; the Slice-004
realtime-audio behaviours (A/V sync, silent scrub, route pause-only, D-213 audible
quality, 6-video-with-music) are NOT YET OBSERVABLE on device and remain BLOCKED.**

The Slice-004 device gate is **NOT closed**. No production code was changed; no
commit/stage/push was performed.

---

## Device / toolchain info

| Field | Value |
|------|-------|
| Xcode | 26.0.1 (build 17A400) |
| Physical device | **iPhone Evgeny**, iOS **26.5**, id `00008110-000C59C20A20401E`, arch arm64 |
| (note) | No iPhone 13 Pro available; the spec permits "доступный физический iPhone". Simulator runs are NOT counted as device evidence. |
| Git commit under test (HEAD) | `a9ea433afe7a8f5b16ea5f78285417349a0e70f9` — "Complete realtime audio preview unit closure" |
| DerivedData (temp, not in repo) | `/tmp/animi-slice004-device-dd` |

---

## Exact commands run

```bash
# Index / HEAD precondition
git diff --cached --name-only            # → empty
git rev-parse HEAD                        # → a9ea433afe7a8f5b16ea5f78285417349a0e70f9

# Destination discovery
xcodebuild -showdestinations -project AnimiApp/AnimiApp.xcodeproj -scheme AnimiApp
#   → { platform:iOS, arch:arm64, id:00008110-000C59C20A20401E, name:iPhone Evgeny }

# Build for the physical device
xcodebuild build \
  -project AnimiApp/AnimiApp.xcodeproj \
  -scheme AnimiApp \
  -destination 'platform=iOS,arch=arm64,id=00008110-000C59C20A20401E' \
  -derivedDataPath /tmp/animi-slice004-device-dd \
  -allowProvisioningUpdates
#   → ** BUILD SUCCEEDED ** (signed: Apple Development: Evgeny Lukovich (6C9K9KT3HC))

# Install + launch on device
xcrun devicectl device install app   --device 00008110-000C59C20A20401E \
  /tmp/animi-slice004-device-dd/Build/Products/Debug-iphoneos/AnimiApp.app
#   → App installed: bundleID com.animi.app
xcrun devicectl device process launch --device 00008110-000C59C20A20401E com.animi.app
#   → Launched application with com.animi.app
xcrun devicectl device info processes --device 00008110-000C59C20A20401E | grep AnimiApp
#   → 17906  .../AnimiApp.app/AnimiApp   (process alive)
```

---

## Results by matrix

| Item | Result | Evidence |
|------|--------|----------|
| **build / install / run** | ✅ **PASS** | `** BUILD SUCCEEDED **`; `App installed` (com.animi.app); `Launched`; process PID 17906 alive on device. Signed with a real Apple Development identity + provisioning profile. |
| **A/V sync (audio-master clock)** | ⛔ **BLOCKED — not observable** | The Slice-004 realtime layer is not wired into the running app (see Critical Finding). The audio path executing on device is the **legacy** app-side preview-audio controller, not `AudioMasterPreviewSession`/`AudioSampleMasterClock`. Observing it would validate the legacy path, not Slice 004. Also requires an interactive human operator (press Play, listen). |
| **silent scrub** | ⛔ **BLOCKED — not observable** | Same: `scrubSettlePreview`/`PreviewAudioGraph` are not on the app's scrub path on device. Proven only at unit/offline level (`SilentScrubAudioTests`, 7/0). Device confirmation needs a human scrubbing the timeline and listening. |
| **route / new-device pause-only** | ⛔ **BLOCKED — not observable** | `RealtimeAudioSessionEvent`/`handleSessionEvent` are not invoked by the app target. Requires physically plugging/unplugging headphones/BT and observing pause-only behaviour against the Slice-004 session, which is not running. |
| **D-213 audible quality** | ⛔ **BLOCKED — not observable** | `OutputOverloadStage` (Candidate A hard saturation) is not in the app's audible mix path on device. Cannot be assessed by ear without it running. NOT switched to Candidate B (no STOP triggered — A is simply unobserved, not rejected). |
| **6-video-with-music** | ⛔ **BLOCKED — STOP condition hit** | The `6_frames_template` fixture is **untracked (`??`)**, i.e. **NOT reproducible from a clean checkout** — this is an explicit device-gate STOP condition. Even if loaded, it would exercise the legacy preview path, not Slice 004. |

---

## Critical finding (why items 2–6 are blocked, not merely un-run)

Slice 004 A–H is an **engine-only** layer under
`AnimiEngineNext/Sources/AnimiEngineCore/Realtime/`. It is **not yet integrated into
the AnimiApp target**:

```bash
grep -rn "AudioMasterPreviewSession\|PlaybackStartBarrier\|PreviewAudioGraph\|\
scheduleInitialAudioPreroll\|RealtimeAudioSessionEvent\|OutputOverloadStage\|\
AudioSampleMasterClock" AnimiApp/        # → no matches
```

The app does import `AnimiEngineCore`, but only for the **Next video** preview/export
bridge (Slice 003 / CP7 — `NextVideoTextureResolver`, `NextSingleSceneBridge`, …).
Its **audio** preview is still the legacy app-side path
(`EnginePreviewAudioPlaybackController`, `EditorRuntimePreviewAudioCoordinator`,
`PreviewAudioControlling`, `AVAudioEngine`/PR3 host-time sync).

Therefore the app that builds, installs, and runs on the device **does not execute the
Slice-004 realtime runtime**. There is nothing Slice-004-specific to observe on device
yet. Validating audio behaviour by hand right now would measure the legacy runtime and
would be falsely attributed to Slice 004.

Wiring the realtime layer into the app target is **integration / production work**,
which is explicitly out of scope for this evidence-only pass (separate STOP). It was
**not** performed.

---

## STOP conditions encountered

- **6-video-with-music not reproducible from clean checkout** — fixture is untracked. (STOP)
- **Interactive audible observation requires a physical operator** — pressing Play,
  scrubbing, plugging/unplugging headphones, and judging saturation by ear cannot be
  automated from this harness. (STOP for items 2–5 as written.)
- **Production-code change would be required** to make Slice 004 observable on device
  (app-target integration). Not done. (STOP — separate approval needed.)

No STOP was triggered by a regression: nothing indicates A/V sync broken, scrub leaking
audio, route auto-resume, or D-213 Candidate A being unacceptable — these simply could
not be exercised. D-213 was **not** switched to Candidate B.

---

## Logs / artefacts

- Build/install/launch console output captured in the gate session (above).
- No crash, NaN/Inf, or underrun symptoms observed at launch (app idle-alive, PID 17906).
- No screenshots/video captured — no Slice-004 behaviour was reachable to record.

---

## Open blockers (to close the Slice-004 device gate)

1. **App-target integration** of the `Realtime/` layer (`AudioMasterPreviewSession` +
   `PreviewAudioGraph` driving the app's preview audio) — required before any item 2–6
   can produce *Slice-004* evidence. Needs its own approved task (production change).
2. **Track the 6-video-with-music fixture** (or provide a clean-checkout-reproducible
   stress project) so item 6 is runnable from a fresh clone.
3. **Human operator session** on a physical iPhone for the interactive/audible matrix
   (A/V sync, silent scrub, headphone connect/disconnect pause-only, D-213 by ear,
   6-video memory/thermal/underrun).
4. **D-213 device audible-quality confirmation** of Candidate A (`d213.hardSaturation.v1`)
   once it is on the device mix path — still PENDING.

---

## Is the Slice 004 device gate closed?

**No.** Build/install/run is PASS, but every audible/behavioural Slice-004 invariant is
BLOCKED because the realtime layer is not yet executed by the app and the stress fixture
is not in a clean checkout. Unit/offline closure remains COMPLETE
(`slice-004-implementation-report.md`, 659 tests / 1 skipped / 0 failures); the **device
gate stays OPEN** pending the four blockers above.
