# Task 003 — Step 10 iPhone Device-Verification Gate (PLAN ONLY)

**Revision:** 2 — APPROVED (R1 approved; R2 `DEVELOPMENT_TEAM=KRX7JQ8GTF`); extraction commands updated for Xcode 26
**Status:** IMPLEMENTATION ATTEMPTED → **BLOCKED on device execution by a SwiftPM limitation (see §-1).**
No engine code, no `Package.swift`, no `*.xcodeproj`/`*.pbxproj`, no `.xcscheme`, and no forbidden path was changed.
**Predecessor:** Step 10 + corrective passes — accepted on the **Apple M2 Pro (macOS)** host; `swift build`
green; full `swift test` 693 / 1 skip / 0 fail; Metal suite 58 / 0 / 0.
**Gate goal:** first **physical iPhone** verification of the Step-10 Metal path — specifically the **iOS-only
`.private` storage + staging upload-blit** that the macOS `.shared` host never exercises. Target device:
**iPhone 13 Pro** (model `iPhone14,2`).

---

## -1. Factual outcome of the implementation attempt (variant A) — BLOCKED

Variant A (the single approved edit: gate `dumpPackage()` to `#if os(macOS)`) was applied and **succeeded at
build/sign**, but **on-device test execution is blocked by a fundamental SwiftPM limitation**:

| Phase | Result |
|---|---|
| Variant-A edit (`Task003DependencyBoundaryTests.swift` `dumpPackage()` → `#if os(macOS)` / `#else XCTSkip`) | DONE; macOS boundary tests stay fully active |
| macOS `swift test` (regression) | **697 executed, 5 skipped, 0 failures** (unchanged); `Task003DependencyBoundaryTests` runs 4/4 active on macOS |
| `xcodebuild build-for-testing -scheme AnimiEngineNext-Package -destination 'platform=iOS,id=00008110-…'` (signed, `DEVELOPMENT_TEAM=KRX7JQ8GTF`) | **`TEST BUILD SUCCEEDED`** — all test bundles built **and signed** for the device, incl. a real `AnimiEngineMetalRenderTests.xctest` (the variant-A fix removed the `Process()` iOS-compile failure) |
| `xcodebuild test-without-building -scheme AnimiEngineNext-Package -destination 'platform=iOS,id=…' -only-testing:AnimiEngineMetalRenderTests` | **FAILED** with the exact error below |

```
xcodebuild: error: Failed to build workspace AnimiEngineNext with scheme AnimiEngineNext-Package.:
Cannot test target "AnimiEngineMetalRenderTests" on "iPhone Evgeny": Tool-hosted testing is unavailable
on device destinations. Select a host application for the test target, or use a simulator destination instead.
```

**Root cause:** SwiftPM XCTest targets are **tool-hosted** (they have no host-app bundle). Apple permits
tool-hosted testing only on **macOS and the iOS Simulator**, **never on a physical iOS device** — a device
test bundle must be **app-hosted**. This is independent of the variant-A fix (which worked) and independent
of signing (which succeeded). Running this XCTest target on a real iPhone therefore requires a **host
application**, i.e. a committed Xcode host project/target — which is **out of scope** (forbidden
`*.xcodeproj` / the R1-rejected committed-container alternative).

Per the owner's standing instruction ("if the next iOS compile/sign/run error appears, STOP and send the
exact error; do not fix anything further"), implementation is **STOPPED here**. The device-only test file
`IPhoneDeviceGateTests.swift` was authored and compiles for iOS, but cannot be executed on a physical device
under the current (host-app-free) scope. **Owner decision needed** (see §-1.1).

### -1.1 Options for the owner (no action taken)

| Option | What it requires | Scope impact |
|---|---|---|
| **A′ — committed host app** | A minimal iOS host **app** target (an `.xcodeproj`/SwiftPM app product) that hosts `AnimiEngineMetalRenderTests` so it can install/run on device | Adds a committed `*.xcodeproj` (forbidden today) **or** a SwiftPM executable app product + scheme — explicit scope expansion |
| **B′ — accept macOS + simulator coverage** | Run the device-only class on the **iOS Simulator** (tool-hosted is allowed there) for the upload-blit/order/evidence facts, and keep the real `.private`-on-hardware verification deferred | No new committed artifact; but the Simulator does **not** exercise true `.private` device memory, so it is weaker evidence (the gate's whole point is real hardware) |
| **C′ — defer the device gate** | Keep Step 10 accepted on macOS; revisit the device gate when a host-app harness exists (e.g. alongside a future product app) | No change now |

The rest of this document (the original Revision-2 plan) is retained below for reference; it remains valid
**except** that the chosen run mechanism (auto library scheme / package scheme) cannot host the XCTest target
on a physical device without one of A′/B′/C′.

---

(Original Revision-2 plan follows.)

---

## 0. Why Revision 1 was wrong, and what changed

Revision 1 proposed a committed **shared SwiftPM `.xcscheme`** under `.swiftpm/xcode/xcshareddata/xcschemes/`
to build only the Metal test target on iOS. **That is invalid:** the repo's root `.gitignore:19` ignores
**`.swiftpm/`** entirely, so such a scheme would be untracked/ignored — exactly the "hidden generated state"
the owner forbids. Revision 1 also relied on the auto-generated `AnimiEngineNext-Package` scheme, which
cannot build for iOS at all.

**Revision 2 establishes a reproducible container that needs ZERO committed files** and avoids `.swiftpm`,
proven below (§1). The device run uses the auto-generated **library** scheme `AnimiEngineMetalRender` for
**build-for-testing** (which builds *only* `AnimiEngineMetalRenderTests` — never the macOS-only adapter
target) and the produced **`.xctestrun`** for **test-without-building** on the device. No `.xcscheme`, no
`*.xcodeproj`, no engine change, and `@testable` access to the package-internal seams is preserved.

---

## 1. Reproducible Xcode container — VERIFIED (pt.1)

All four facts below were verified by running the commands against the repository (read-only; temp
DerivedData removed afterward). The container is the package directory itself.

| Requirement (pt.1) | Result | Evidence |
|---|---|---|
| Exact container path | `/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiEngineNext` — the **`Package.swift` directory**, which Xcode treats as an implicit workspace ("Information about workspace AnimiEngineNext"). **No `.xcworkspace`/`.xcodeproj` is created or relied upon.** | `xcodebuild -list` run from this dir succeeds with `.swiftpm` absent |
| `xcodebuild -list` sees the scheme | **YES** — schemes are auto-generated **in-memory** (no committed file). Relevant: `AnimiEngineMetalRender` (the library-target scheme) and `AnimiEngineNext-Package`. Verified **after deleting `.swiftpm/`** — they regenerate without any shared-scheme file | `xcodebuild -list` lists `AnimiEngineMetalRender` from a clean state |
| `-showDestinations` sees a physical iPhone | **YES** — `xcodebuild -showdestinations -scheme AnimiEngineMetalRender` lists `{ platform:iOS, arch:arm64, id:<UDID>, name:<iPhone> }` for the connected device (plus the `Any iOS Device` placeholder) | observed a real `platform:iOS … id:00008110-…` device line |
| Builds **only** `AnimiEngineMetalRenderTests` for iOS | **YES** — `xcodebuild build-for-testing -scheme AnimiEngineMetalRender -destination 'generic/platform=iOS'` ⇒ **`TEST BUILD SUCCEEDED`**, compiling the five Metal test sources and **NOT** `AnimiEngineTemplateAdapterTests` (whose macOS-only `Process()` would otherwise fail the iOS build) | `TEST BUILD SUCCEEDED`; no `AdapterTests` compilation; produces `AnimiEngineMetalRender_AnimiEngineMetalRender_iphoneos*.xctestrun` |

**Two constraints the commands must respect (also verified):**

1. The **`AnimiEngineNext-Package`** scheme **fails** to build for iOS (`cannot find 'Process'` in
   `AnimiEngineTemplateAdapterTests/Task003DependencyBoundaryTests.swift:277`), and `-only-testing:` does
   **not** prevent it from *building* the broken target. So that scheme is unusable for device.
2. The **`AnimiEngineMetalRender`** library scheme **builds** the test target but is **not configured for the
   `test`/`test-without-building` *action*** (`xcodebuild test-without-building -scheme AnimiEngineMetalRender`
   ⇒ "Scheme … is not currently configured for the test-without-building action"). **Therefore the device
   run MUST use the produced `.xctestrun` file**, not `-scheme`, at test time.

**Conclusion (pt.1 satisfied):** a reproducible container exists with **no committed files and no `.swiftpm`
dependency**: `build-for-testing` with the auto-generated library scheme → run the resulting `.xctestrun`
with `test-without-building`. `@testable import AnimiEngineMetalRender` (needed for the seams) is preserved
because the device test lives in the package's own `AnimiEngineMetalRenderTests` target, compiled with
testability in the same module. **No STOP condition is triggered.**

> If, at implementation time, a future Xcode drops in-memory library-scheme generation or stops emitting a
> Metal-only `.xctestrun`, the preflight gate (§6) catches it **before** any test file is written, and the
> plan STOPs and reports (the owner's pt.1 fallback).

---

## 2. Scope and non-scope

### 2.1 In scope (this gate)

On a connected **iPhone 13 Pro**, run the **entire `AnimiEngineMetalRenderTests` suite** (pt.2) plus a small
new device-only class. The whole Metal suite must pass on device (proving the existing 58 tests are valid on
real hardware, including the `.private` paths they exercise indirectly). The **new device-only class**
verifies **only** the four device-specific facts (pt.2):

1. **physical iOS device, not a simulator;**
2. **the iOS `.private` staging path is active;**
3. **presence + order of `uploadBlit → normalize → sceneRender → finalConversion → readbackBlit → commit →
   completion`** (the `uploadBlit` event fires only on iOS);
4. **device/GPU/OS evidence** (`MTLDevice.name`, `registryID`, `utsname` model, iOS version/build).

### 2.2 Explicit non-scope

- The new device-only class does **NOT** reuse the private `runTwoSidedEdge` helper and does **NOT** duplicate
  the existing ownership/failure/repeatability/colour tests (pt.2). Those already run as part of the full
  Metal suite on device; re-asserting them in the device class would be redundant.
- **No Step 11/12**; no CPU renderer; no reference promotion; no performance/timing assertions; no
  realtime/scheduler work.
- **No engine-code change**; **no change to existing test files**; **no `Package.swift` change**; **no
  `.xcscheme`/`*.xcodeproj`/`*.pbxproj`**; no `TVECore/`, `AnimiApp/`, `SceneSources/`, `SharedAssets/`,
  approved-plan, or RenderModel/RenderGraph change.

---

## 3. Exact files

### 3.1 Create — one device-only test file (the ONLY new artifact before the run)

| File | Responsibility |
|---|---|
| `AnimiEngineNext/Tests/AnimiEngineMetalRenderTests/IPhoneDeviceGateTests.swift` | Device-only XCTest class (§5 matrix D0–D4). `@testable import AnimiEngineMetalRender`; gates on a physical iOS device; uses the existing `onExecutionEvent` seam + `MetalTestEnvironment` builders; emits device/GPU/OS evidence via `XCTAttachment`. **Does not** call `runTwoSidedEdge` and **does not** duplicate ownership/failure tests. |

A test file in the existing target is **not engine code** and changes no production behaviour. It compiles
for iOS (the existing Metal test sources already do — §1).

### 3.2 Create — one report (AFTER the device run, not now)

| File | Responsibility |
|---|---|
| `Docs/AnimiEngineNext/claude-task-003-step-10-iphone-device-gate-report.md` | Post-run report: device/GPU/OS, exact commands + `.xcresult` path, full-Metal-suite result on device, device-class results, recorded `rawOutputHash`, repeatability confirmation, forbidden-path comparison. |

### 3.3 NOT created / NOT changed

- **No `.xcscheme`** (the container needs none — §1).
- No `Package.swift`, no production source, no existing test file, no `*.xcodeproj`/`*.pbxproj`, no forbidden
  path.

---

## 4. Launch / run commands (pt.3)

Single fixed `DERIVED` for both phases; `.xctestrun` from build is the test input; `.xcresult` is produced
**only by the test phase**; destination is the exact UDID; explicit signing (pt.4). Replace `<TEAM_ID>` and
`<UDID>` with the real values — **never guessed** (R2).

```bash
cd /Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiEngineNext

# Inputs:
UDID="<iphone-13-pro-udid>"        # from: xcodebuild -showdestinations -scheme AnimiEngineMetalRender
TEAM_ID="KRX7JQ8GTF"               # approved R2 — the developer's Apple Developer team id
DERIVED="$PWD/build/ios-device-gate-derived"   # SAME derivedDataPath for both phases
XCRESULT="$PWD/build/ios-device-gate.xcresult" # xcresult produced ONLY by the test phase

# Phase 1 — build the Metal test bundle for the device (library scheme = Metal-only, never AdapterTests).
xcodebuild build-for-testing \
  -scheme AnimiEngineMetalRender \
  -destination "platform=iOS,id=$UDID" \
  -derivedDataPath "$DERIVED" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates

# Locate the produced .xctestrun (Metal-only; no AdapterTests blueprint).
XCTESTRUN="$(ls "$DERIVED"/Build/Products/AnimiEngineMetalRender_AnimiEngineMetalRender_iphoneos*.xctestrun)"

# Phase 2 — run the ENTIRE AnimiEngineMetalRenderTests suite on the device via the .xctestrun
# (the library scheme is NOT test-action-configured, so we run the xctestrun, not -scheme).
xcodebuild test-without-building \
  -xctestrun "$XCTESTRUN" \
  -destination "platform=iOS,id=$UDID" \
  -derivedDataPath "$DERIVED" \
  -resultBundlePath "$XCRESULT" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates

# Evidence — Xcode 26 xcresulttool (the legacy `get --format json` is deprecated/removed in Xcode 26).
xcrun xcresulttool get test-results summary \
  --path "$XCRESULT" --compact \
  > "$PWD/build/ios-device-gate-summary.json"

xcrun xcresulttool get test-results tests \
  --path "$XCRESULT" \
  > "$PWD/build/ios-device-gate-tests.json"

# The device/GPU/OS XCTAttachment(s) are exported to a directory (Xcode 26 syntax).
xcrun xcresulttool export attachments \
  --path "$XCRESULT" \
  --output-path "$PWD/build/ios-device-gate-attachments"
```

Notes:
- **Whole suite runs**, not just the new class (pt.2): the `.xctestrun` carries all of
  `AnimiEngineMetalRenderTests`; no `-only-testing` narrowing.
- macOS regression remains the existing `swift test` (must stay green; this gate does not replace it).
- The simulator is **not** acceptable; the device class hard-fails on a simulator (§5 D0).

---

## 5. Test matrix

### 5.1 Full Metal suite on device (pt.2)

| # | Requirement | Selection | Assertion |
|---|---|---|---|
| S-ALL | The entire existing `AnimiEngineMetalRenderTests` (58 tests) passes on the iPhone 13 Pro | whole `.xctestrun` | 0 failures; 0 device-absent skips (a real device is present); the `.private` upload-blit path is exercised by every pixel-input test |

### 5.2 New device-only class `IPhoneDeviceGateTests` (pt.2 — only the four device facts)

| # | Requirement | Test | Assertion |
|---|---|---|---|
| D0 | Real iPhone, not simulator | `testRunningOnPhysicalDeviceNotSimulator` | `#if targetEnvironment(simulator)` ⇒ `XCTFail` (hard failure on simulator); `MTLCreateSystemDefaultDevice()` non-nil |
| D1 | iOS `.private` staging path active | `testPrivateStagingPathActive` | `MetalTextureAllocator(device:).pixelInputNeedsStagedUpload == true` (true only on the iOS `.private` build) |
| D2 | Event presence + exact order, incl. `uploadBlit` | `testExecutionEventOrderIncludesUploadBlit` | observe `onExecutionEvent` for a one-pixel-resource graph; assert order **== exactly** `[uploadBlit, normalize(<resourceID>), sceneRender, finalConversion, readbackBlit, commit, completion]` (uploadBlit **present** on iOS) and `normalize` precedes `sceneRender`, `readbackBlit` follows `finalConversion`, `commit` precedes `completion` |
| D3 | Device/GPU/OS evidence captured | `testCaptureDeviceEvidence` | attach via `XCTAttachment` (and log): `{ deviceName=MTLDevice.name, registryID, model=utsname.machine, osVersion=ProcessInfo…operatingSystemVersionString, osBuild=sysctl kern.osversion }`; assert non-empty; **record `model` for review** (must be `iPhone14,2` for a 13 Pro — §5.3) |

The device class **does not** include any colour/edge oracle test, any ownership/failure test, or any
repeatability test — those are covered by S-ALL (pt.2: no `runTwoSidedEdge`, no duplication).

### 5.3 Simulator + model policy (pt.5)

- **Simulator ⇒ hard failure:** D0 fails (not skips) on a simulator destination, so a simulator run cannot be
  mistaken for a device pass.
- **Model in evidence; review enforces 13 Pro:** D3 records `utsname.machine`; **review** confirms it equals
  **`iPhone14,2`** (iPhone 13 Pro). The test does **not** hard-code the model assertion (avoids brittle false
  negatives across iOS naming); the operator must connect a 13 Pro and the evidence proves it.

---

## 6. Mandatory preflight gate (pt.6) — prove the container before writing the test

Before any device test file is created, the implementation MUST run and record these **device-independent**
proofs (they confirm the container/scheme/Metal-only-build; the signing+device proof is in Phase 1):

```bash
cd /Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiEngineNext
rm -rf .swiftpm                                          # prove no hidden committed scheme is relied upon
xcodebuild -list | grep -q 'AnimiEngineMetalRender'      # P1: scheme visible from clean state
xcodebuild -showdestinations -scheme AnimiEngineMetalRender | grep -E 'platform:iOS.*id:[0-9A-F-]+'  # P2: a physical iPhone is visible
xcodebuild build-for-testing -scheme AnimiEngineMetalRender \
  -destination 'generic/platform=iOS' -derivedDataPath /tmp/preflight-dd 2>&1 | grep -q 'TEST BUILD SUCCEEDED'   # P3: Metal-only iOS test build succeeds
test -f /tmp/preflight-dd/Build/Products/AnimiEngineMetalRender_AnimiEngineMetalRender_iphoneos*.xctestrun       # P4: a Metal-only .xctestrun is produced
! ( xcodebuild build-for-testing -scheme AnimiEngineNext-Package -destination 'generic/platform=iOS' 2>&1 | grep -q 'AdapterTests' )  # (informational) confirm the package scheme is the broken path we avoid
rm -rf /tmp/preflight-dd
```

**Preflight pass condition:** P1–P4 succeed. Then, with the device connected + signing configured, Phase 1
(`build-for-testing` to the real `-destination id=<UDID>` with `DEVELOPMENT_TEAM`/`-allowProvisioningUpdates`)
must **link, sign, and produce the installable `.xctest`** — this is the signing+device proof that cannot be
done on the M2 host alone.

**If any preflight proof fails** (e.g. a future toolchain stops emitting a Metal-only `.xctestrun`, or no
physical iPhone is visible, or signing cannot produce a device bundle): **STOP and report** — do not write
the test file, do not hand-craft a scheme/xcodeproj, do not modify the AdapterTests `Process()` line. The
owner then decides (R1).

---

## 7. Evidence captured

The `.xcresult` + report record: the exact `build-for-testing`/`test-without-building` commands + statuses;
the `.xctestrun` path; the full-Metal-suite result on device (S-ALL); D0–D3 results; the device-evidence
attachment (`deviceName`, `registryID`, `model`=`iPhone14,2`, `osVersion`, `osBuild`); the canonical
fixture's `rawOutputHash` (read from a representative S-ALL test or recomputed in D-evidence for the record);
and the forbidden-path `git status --short` comparison (initial vs final).

---

## 8. Acceptance gates

- **AG1 Reproducible container:** preflight P1–P4 pass from a clean `.swiftpm` state; no committed scheme/
  xcodeproj is relied upon (pt.1).
- **AG2 Device + signing:** Phase 1 builds, signs, and installs the Metal test bundle on the **iPhone 13 Pro**
  (`-destination id=<UDID>`, `DEVELOPMENT_TEAM=<TEAM_ID>`, `CODE_SIGN_STYLE=Automatic`,
  `-allowProvisioningUpdates`); D0 confirms a physical device (pt.4/pt.5).
- **AG3 Full Metal suite green on device:** S-ALL — all 58 existing Metal tests pass on hardware, 0 failures,
  0 device-absent skips (pt.2).
- **AG4 Private upload-blit + order:** D1/D2 pass — `.private` staging active and the `uploadBlit→…→completion`
  order is exactly as specified (the macOS-unverified path proven on device).
- **AG5 Evidence:** D3 attaches device/GPU/OS evidence; review confirms `model == iPhone14,2` (pt.5).
- **AG6 No regression / no engine change:** macOS `swift test` stays green (693/1-skip/0-fail);
  forbidden-path `git status` byte-identical; no engine source / existing-test / `Package.swift` /
  `*.xcodeproj` / `*.pbxproj` / `.xcscheme` change.
- **AG7 No simulator pass, no timing claim:** a simulator run hard-fails (D0); no wall-clock assertion anywhere.

The gate is accepted only when AG1–AG7 hold and the owner reviews the recorded device evidence.

---

## 9. Decisions requiring owner input (only two remain)

| ID | Decision | Resolution |
|---|---|---|
| **R1** | Container approach: **auto-generated `AnimiEngineMetalRender` library scheme + `.xctestrun`** (no committed file, no `.swiftpm` reliance) | **APPROVED** — verified reproducible (§1), no committed artifact, `@testable` seams preserved |
| **R2** | `DEVELOPMENT_TEAM` for on-device signing | **APPROVED: `KRX7JQ8GTF`** |

The model-enforcement and simulator-failure decisions are **closed** (pt.5: record `utsname`, review requires
`iPhone14,2`; simulator hard-fails). No `.xcscheme` decision remains (Revision 1's scheme approach is dropped).

---

## 10. Known risks / limitations

- **iPhone 13 Pro must be the connected device.** The phones currently attached are not a 13 Pro; the run
  requires the correct device. D0 enforces "physical device"; D3 records the model so review confirms 13 Pro.
- **Signing.** The device bundle must be signed (R2); without a team id the gate cannot install.
- **`.xctestrun` path naming** depends on the SDK version (`…iphoneos<NN>.xctestrun`); the command globs it
  (`ls …iphoneos*.xctestrun`) rather than hard-coding the SDK number.
- **The macOS-only `Process()`** in `AnimiEngineTemplateAdapterTests` keeps the whole-package iOS bundle
  un-buildable; this is deliberately **not** fixed (it would change an existing test). The library-scheme
  route avoids it entirely.
- Same-device determinism only (cross-device thresholds deferred, per the approved determinism language).

---

## 11. Stop rule

This planning pass modified exactly one file:
`Docs/AnimiEngineNext/claude-task-003-step-10-iphone-device-gate-plan.md`. No engine source, no test, no
`Package.swift`, no `.xcscheme`, no `*.xcodeproj`/`*.pbxproj`, and no forbidden path was modified. The
verification commands in §1/§6 used only read-only `xcodebuild` against the existing package and temporary
`/tmp` DerivedData, which was removed; `.swiftpm` was deleted to prove independence and left absent.

**Claude stops here and waits for explicit owner approval** (and R1–R2 resolution) before implementing the
device gate. If, during the mandatory preflight (§6), the reproducible container cannot be established
without violating scope or losing the package-internal seams, Claude **STOPs and reports** rather than
proceeding. Step 11, Step 12, Task 004, a CPU renderer, reference promotion, and performance optimization
must not be started.
