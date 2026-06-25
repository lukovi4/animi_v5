# Slice 001 — Implementation Report: Canonical Audio Schema v3 + Exact tick↔sample mapping

- **Status:** Stage A–E COMPLETE. Closure/evidence pass (Stage E).
- **Date context:** 2026-06-25.
- **Scope delivered:** pure canonical audio project model + exact 48 kHz tick↔sample mapping inside
  `AnimiEngineNext/Sources/AnimiEngineCore`. No play/decode/mix/schedule/export/evaluator code.
- **Plan of record:** `Docs/AnimiEngineNext/slice-001-implementation-plan.md`.
- **Normative contract:** `Docs/AnimiEngineNext/slice-001-canonical-audio-schema.md`, ADR-012 §1.0a/§1.0b.
- **Nothing staged or committed by this pass.**

---

## 1. What was built (Stage A–E)

| Stage | Delivered | Net effect |
|---|---|---|
| **A** | schema scaffolding + migration: `schemaVersion 2→3`, `accepted [1,2,3]`, `audio` manifest field (default `.empty`), encoder writes explicit empty `audio`, decoder dual-path (v3 requires `audio`; v1/v2 uplift to `.empty`). Fail-closed: empty-only. | v3 empty round-trip, v1/v2 uplift proven. |
| **B** | value model + sample mapping: `AudioIdentifiers` (4 typed IDs), `AudioGain` (integer 0…1_000_000, no clamp), full `AudioManifest` value types (roles, policy `.once`, asset reference, `SceneLayerReference`, entries), `AudioSampleRange`/`AudioSampleGrid` (48 kHz, `ticksPerSample = 5`, `ceilDiv5`). No `Float`/`Double`. | Pure value model + exact mapping, all tested. |
| **C** | populated codec: encoder emits real `sources`/`tracks`/`clips` with deterministic ordering; decoder reads populated audio (asset/videoLayer/range/gain/policy); `optionalObjectRejectingNull` + `ProjectDecodingError.explicitNull`; populated `AudioManifest` initializer made `public`. | Populated v3 round-trips byte-stable. |
| **D** | semantic validation: `validateAudioManifest` (manifest-level) + `validateAudioDocument` (payload-level) + `mediaActiveDomain` helper; 15 new typed `ProjectValidationError` cases. | Every §7 invariant enforced at the correct boundary. |
| **E** | closure/evidence (this report): old→new encoding expectations recorded; pixel `ReferenceData` proven byte-identical; final gates run; Gate-0 docs confirmed in working tree. | Evidence closure. |

---

## 2. Files (whole Slice 001)

### 2.1 New production files (`AnimiEngineNext/Sources/AnimiEngineCore`)
- `Project/AudioIdentifiers.swift` (41 lines) — `AudioSourceID`, `AudioTrackID`, `AudioClipID`, `GlobalAudioAssetID`.
- `Project/AudioGain.swift` (30) — integer linear gain.
- `Project/AudioManifest.swift` (131) — roles, policy, asset reference, `SceneLayerReference`, entries, `AudioManifest` (+ `public init`, `.empty`, `isEmpty`).
- `Time/AudioSampleRange.swift` (62) — `AudioSampleGrid` + `AudioSampleRange`.

### 2.2 Modified production files
- `Project/CanonicalProjectManifest.swift` — `supportedSchemaVersion 2→3`, `acceptedSchemaVersions [1,2]→[1,2,3]`, `audio: AudioManifest = .empty` (6th field).
- `Codec/CanonicalProjectValueBuilder.swift` — populated audio emission + deterministic ordering.
- `Codec/RawProjectDTO.swift` — populated audio dual-path decoder.
- `Codec/StrictReader.swift` — `optionalObjectRejectingNull`.
- `Codec/ProjectDecodingError.swift` — `explicitNull(path:)` (Stage A's transient `unsupportedAudioContent` was removed in Stage C).
- `Project/ProjectValidationError.swift` — `invalidAudioGain` + 15 Stage-D audio cases.
- `Project/ProjectValidator.swift` — `validateAudioManifest`, `validateAudioDocument`, `mediaActiveDomain`, `requireUniqueAudio`.

### 2.3 New / modified test files (`Tests/AnimiEngineCoreTests`)
- New: `AudioSchemaMigrationTests`, `AudioIdentifierTests`, `AudioGainTests`, `AudioSampleMappingTests`, `AudioValueModelTests`, `AudioCodecTests`, `AudioManifestValidationTests`, `AudioDocumentValidationTests`.
- Modified: `CanonicalProjectEncodingTests` (v2→v3 substrings, unsupported-version 3→4, v1-uplift includes empty audio), `ProjectValidationTests` (unsupported version 3→4).

### 2.4 Stage-E artifact
- `Docs/AnimiEngineNext/slice-001-implementation-report.md` (this file) — the ONLY artifact this pass creates.

---

## 3. Old → new encoding expectations

| Expectation | Old (v2) | New (v3) |
|---|---|---|
| `schemaVersion` written | `2` | `3` |
| accepted versions | `[1,2]` | `[1,2,3]` |
| `audio` object | absent | **always** present and explicit |
| empty audio bytes | n/a | `"audio":{"clips":[],"sources":[],"tracks":[]}` (writer-sorted keys) |
| v1/v2 decode | uplift `timelineSpan` | uplift `timelineSpan` **and** `audio = .empty`; in-memory `schemaVersion` normalized to `3` |
| v1/v2 carrying `audio` | n/a | rejected as `unknownField` (strict `finish()`) |
| v3 missing `audio` / a table | n/a | rejected as `missingField` |
| populated audio | n/a | encodes + round-trips **byte-stable**; ordering: sources by `AudioSourceID`, tracks by `AudioTrackID`, clips by `(trackID, destination.start.ticks, AudioClipID)` |
| `videoLayer` absence | n/a | exactly one canonical form — key omitted; explicit `null` rejected (`explicitNull`) |

**No Core document-SHA golden constant exists.** `AnimiEngineCore` pins encoding by **byte-stable
round-trip + pinned enum-tag substrings** (`CanonicalProjectEncodingTests`), not a stored document
SHA. A sweep for `sha256|sha-256|documentSHA|goldenHash|canonicalHash` across
`Sources/AnimiEngineCore` and `Tests/AnimiEngineCoreTests` returns **nothing**. The only canonical SHA
evidence lives in the render/promotion layer (`ReferenceData` + `approval-manifest.json`), which Slice 1
does not touch — see §5.

---

## 4. Validation split (Stage D)

- **`validateManifest` (no payloads):** `.empty` passes; unique source/track/clip IDs; non-dangling
  `sourceID`/`trackID`; orphan source/track; role↔`videoLayer` presence; role↔asset kind; scene exists;
  destination ⊆ project duration; video-layer destination ⊆ media-active domain
  (`start = sceneStart`, `end = sceneStart + timelineSpan + outgoing animated postHalf`, cut postHalf 0,
  post-roll allowed, pre-boundary → `incomingAudioBeforeBoundary`); gain re-assert. activeRange/opacity
  never gate audio.
- **`validate(document)` (payload-dependent):** `SceneLayerReference` resolves
  `sceneID → payloadID → ResolvedScenePayload`; layer exists; content `.video` (image rejected);
  `.videoLayerMedia` == `VideoBinding.media`; `sourceTrim ⊆ sourceMapping.trimRange`; no two video-audio
  clips per `SceneLayerReference`; same `LayerID` in two scenes resolves distinctly; silent video valid;
  one source → many clips.

15 typed cases: `duplicateAudioID`, `danglingAudioReference`, `orphanAudioSource`, `orphanAudioTrack`,
`audioRoleLayerMismatch`, `audioRoleAssetMismatch`, `unknownAudioScene`, `audioDestinationOutsideProject`,
`audioLayerNotFound`, `audioLayerNotVideo`, `audioMediaMismatch`, `audioTrimNotContained`,
`duplicateVideoAudioClip`, `incomingAudioBeforeBoundary`, `audioDestinationOutsideMediaActiveDomain`.

---

## 5. Pixel `ReferenceData` unchanged — evidence

Slice 1 touches **no** render path (no `Evaluator/`, `AnimiEngineMetalRender`, `AnimiEngineRenderGraph`,
no `ReferenceData/*.png`, no `approval-manifest.json`). Proven by tree hash + the render regression gate.

- **ReferenceData tree (files):** 85 files under `AnimiEngineNext/ReferenceData`.
- **Tree hash BEFORE render test:**
  `a37980f2aa84313436cb433f585855b570bf994470455b7f1bed603cf29213bb`
  (`find AnimiEngineNext/ReferenceData -type f -exec shasum -a 256 {} \; | sort | shasum -a 256`)
- **Tree hash AFTER render test:**
  `a37980f2aa84313436cb433f585855b570bf994470455b7f1bed603cf29213bb`
- **Identical:** YES — `BEFORE == AFTER`; 85 files both before and after; no PNG promoted/changed.
- **git status `ReferenceData` BEFORE:** clean.
- **git status `ReferenceData` AFTER:** clean (`git status` and `git diff --stat` both empty).

---

## 6. Final gates

```
# Core
cd AnimiEngineNext && swift test --build-path /tmp/animi-slice001-stageE-core-7731 \
  --filter AnimiEngineCoreTests
→ Executed 307 tests, with 1 test skipped and 0 failures (0 unexpected)

# Render regression (pixel ReferenceData unchanged)
cd AnimiEngineNext && swift test --build-path /tmp/animi-slice001-stageE-render-7731 \
  --filter PostPromotionMatrixRegressionTests
→ testLiveMatrixIsExactMatchAgainstApprovedReferenceData passed (290.707 s)
→ Executed 1 test, with 0 failures (0 unexpected)
```

The 1 Core skip is a pre-existing skipped test, unrelated to audio.

---

## 7. Gate-0 docs present in working tree

All present (untracked/modified, not committed — Gate-0 requires them in the implementation changeset):

- `AnimiEngineNext/Docs/ADR-005-identity-cancellation-and-publication.md`
- `AnimiEngineNext/Docs/ADR-006-scheduler-and-master-clock.md`
- `AnimiEngineNext/Docs/ADR-012-canonical-audio-architecture.md`
- `Docs/AnimiEngineNext/canonical-runtime-roadmap.md`
- `Docs/AnimiEngineNext/slice-001-canonical-audio-schema.md`
- `Docs/AnimiEngineNext/slice-001-implementation-plan.md`

---

## 8. Scope guarantees

No file changed under any forbidden path:
- `AnimiApp/`, scheduler/export/preview, AVFoundation/TVECore, `AnimiEngineMetalRender`,
  `AnimiEngineRenderGraph`, `Evaluator/`, `Package.swift`, `*.xcodeproj`, `ReferenceData/`.
- The pre-existing `AnimiApp.xcscheme` and `AnimiApp/Resources/Scenes/6_frames_template/` entries were
  modified/untracked **before** this slice began (session-start git snapshot) and were never touched.

All Slice-1 production changes are confined to `Sources/AnimiEngineCore`; all test changes to
`Tests/AnimiEngineCoreTests`; the only doc artifact is this report.
