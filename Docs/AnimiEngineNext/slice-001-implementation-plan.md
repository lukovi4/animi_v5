# Slice 001 — Implementation Plan: Canonical Audio Schema v3 + Exact tick↔sample mapping

- **Status:** PLANNING PASS ONLY — awaiting technical-lead review. No production or test code written.
- **Author role:** planning agent (no code authority until this plan is approved).
- **Date context:** 2026-06-25.
- **Scope:** pure canonical audio project model + exact 48 kHz tick↔sample mapping inside
  `AnimiEngineNext/Sources/AnimiEngineCore`. No play/decode/mix/schedule/export.
- **Governing contracts read in full (in order):** README, architecture-proposal,
  decision-register, validation-contract, canonical-runtime-roadmap, slice-001-canonical-audio-schema,
  ADR-002, ADR-003, ADR-004, ADR-005, ADR-006, ADR-012, ADR-014.
- **Evidence (non-normative):** `audits/audio-scheduler-export-deep-audit.md` §12. Where it agrees with
  the ADRs it is cited as corroboration; it never overrides them. **No contradiction with the
  normative set was found** — §12 matches ADR-012 §1–1.2 and roadmap Slice 1 exactly.

> Authority order applied throughout (architecture-proposal §13): approved product rules +
> decision-register → accepted ADRs → architecture-proposal + validation-contract → roadmap → audits.

---

## 1. Readiness verdict

**Verdict: READY TO IMPLEMENT. BLOCKER-1 is now CLOSED by the recorded tech-lead decision (§4),
fixed in ADR-012 §1.0a and the Slice-001 contract. Implementation (including Stage A) MUST NOT begin
until that decision is version-controlled in ADR-012 + the Slice-001 contract (it now is in the working
tree; Gate-0 requires it in the implementation changeset). No implementation stage — Stage A
included — may start ahead of this fixed mapping, because the migration/round-trip tests assert the
documented meaning of `sourceTrim`/`destination`.**

> **Correction to the prior pass.** The prior verdict said Stage A could start immediately, ahead of
> the §4 decision. That is now superseded: per the tech lead, Stage A must not begin until the
> source-time-mapping decision is fixed in the normative docs. The decision is fixed (§4); the gating
> condition is "decision is in version control with the implementation."

The normative contract is internally consistent and implementable. ADR-012 §1/§1.1/§1.2, the Slice-001
task contract, ADR-006 §4, ADR-003, and the roadmap Slice-1 stages all describe the same model, the same
schema-migration rule, the same validation split, and the same `[ceilDiv5(start), ceilDiv5(end))` mapping.
The existing code already provides every primitive the slice reuses:

- the `StructuralID` ID-wrapper pattern with construction-time emptiness rejection —
  `Project/References.swift:8-23`;
- the existing `MediaReference` reused by `.videoLayerMedia` — `Project/References.swift:75-81`;
- `SceneInstanceID` / `LayerID` reused by `SceneLayerReference` — `Project/References.swift:25-31`,
  `:57-63`;
- the exact-rational `RationalSourceRange` reused by `sourceTrim` — `Time/SourceTimeMapping.swift:2-16`;
- `ProjectTimeRange` reused by `destination` — `Time/ProjectTime.swift:48-67`;
- the strict, dual-path migration idiom already proven for v1→v2 (`timelineSpan`) —
  decode `Codec/RawProjectDTO.swift:43-95`, encode `Codec/CanonicalProjectValueBuilder.swift:88-126`,
  round-trip test `Tests/AnimiEngineCoreTests/CanonicalProjectEncodingTests.swift:186-198`;
- `CheckedInt64` for the overflow-checked mapping — `Time/TimeError.swift:33-51`;
- 240,000-tick clock for the 5-ticks/sample constant — `Time/TickClock.swift:7-10`.

**No Float/Double exists anywhere in `AnimiEngineCore`** (verified by sweep — only `Float`/`Double`
appear in the Metal/RenderModel targets, not Core), so the "no floating gain/time" stop condition is
already structurally satisfied; the only risk is introducing one, which the plan forbids.

**Contradictions / under-definition found:**

1. **BLOCKER-1 (semantic, §4) — CLOSED.** ADR-012 and the task contract store, for a video-layer audio
   clip, BOTH `destination: ProjectTimeRange` and `sourceTrim: RationalSourceRange`, but the **rate**
   relating them was not stored on `AudioClipEntry` (unlike `VideoBinding.sourceMapping`, which carries
   `PlaybackRate` + `SourceTimescale` — `Time/SourceTimeMapping.swift:26-49`). **The tech lead has fixed
   the canonical mapping** (recorded in ADR-012 §1.0a and the Slice-001 contract; see §4): **no** `rate`
   field is added and **no** length-derived rate; **global** audio is strict 1/1 and anchors on
   `destination.start`; **video-layer** audio inherits the video's full mapping (rate/timescale/anchor),
   so it is NOT necessarily 1/1; and
   `sourceTrim` is a window/gate only; audibility = `projectTime ∈ destination ∧ sourceTime ∈
   sourceTrim`; `.once` stops at the first end. This is documentation-only and changes **no** Slice-1
   stored field. **Implementation (Stage A included) must not begin until this decision is in version
   control with the implementation.**

2. **Under-definition (resolved, not a blocker):** ADR-012 §1 calls `audio` a field on
   `CanonicalProjectManifest` ("schema v3 adds one required `audio` field"); the task-contract JSON shows
   `"audio"` nested inside the `manifest` object. These agree: the manifest is the inner `"manifest"`
   object of the document JSON (`Codec/RawProjectDTO.swift:9-25`,
   `Codec/CanonicalProjectValueBuilder.swift:70-100`). `audio` is the manifest's **6th stored field** and
   the manifest object's 6th key — resolved, no owner question.

3. **Under-definition (resolved):** "destination lies inside project duration" — project duration is
   `Σ scene.timelineSpan` (`CanonicalProjectManifest.projectDuration()` —
   `Project/CanonicalProjectManifest.swift:38-44`), the exact same basis already used for overlay
   containment (`Project/ProjectValidator.swift:66-73`). Reuse it verbatim; no new definition.

**No technical questions are posed to the owner.** The only open item is a tech-lead canonical-contract
clarification (§4 BLOCKER-1), which is an engineering decision inside the accepted ADR envelope, not a
product question.

---

## 2. Current code map (every type/file Slice 1 touches)

All paths under `AnimiEngineNext/Sources/AnimiEngineCore/` unless noted. Line ranges are the audited
HEAD (`cp7/next-user-video`).

### 2.1 Existing files to MODIFY

| File / type | Current purpose | Existing invariants | Callers | Tests covering | Evidence |
|---|---|---|---|---|---|
| `Project/CanonicalProjectManifest.swift` — `CanonicalProjectManifest` | Lightweight manifest: output, scenes, boundaryTransitions, overlays; `supportedSchemaVersion`, `acceptedSchemaVersions`, `projectDuration()` | 5 stored fields; v-bump owns schema; `Equatable, Sendable` | every call site below; `RawProjectDecoder.decodeManifest`; `CanonicalProjectValueBuilder.manifest` | `CanonicalProjectEncodingTests`, `ProjectValidationTests`, `DeterminismTests`, `StretchedSceneTwoClockTests` | `:5-45`; version consts `:8,11` |
| `Project/ProjectValidator.swift` — `ProjectValidator` | Two entry points: `validateManifest` (manifest-only) and `validate(document)` (payload-dependent) | manifest checks need no payloads; document checks add payload correspondence + `MaterialAvailabilityValidator` | `CanonicalProjectEncoding.encode/decodeValidated`; `TimelineIndex.init` | `ProjectValidationTests` (17 KB) | `:16-227`; manifest path `:20-77`; doc path `:81-96` |
| `Project/ProjectValidationError.swift` — `ProjectValidationError` | Typed semantic-validation errors (distinct from decoding/time errors); `Equatable` | additive enum; `.wrap` maps `TimeError` | thrown from validator, decoder domain factories | asserted across `ProjectValidationTests`, `CanonicalProjectEncodingTests` | `:6-50` |
| `Project/References.swift` | Structural ID wrappers + opaque references (`MediaReference`, `SceneInstanceID`, `LayerID`, …) on `StructuralID` | non-empty at construction; `Hashable`, `Comparable` (IDs) | everywhere | `OrderingTests`, `ProjectValidationTests` | `:8-121` |
| `Codec/CanonicalProjectValueBuilder.swift` — `CanonicalProjectValueBuilder` / `CanonicalJSONWriter` | Builds the ordering-agnostic `CanonicalValue` tree; writer sorts keys, fixed int format | encoder always writes `supportedSchemaVersion`; payload tables emitted in id order; no Float | `CanonicalProjectEncoding.encode` | `CanonicalProjectEncodingTests` (byte-stable, sorted keys, golden tags) | `:69-100` manifest; `:88-126` |
| `Codec/RawProjectDTO.swift` — `RawProjectDecoder` | Strict decode → domain factories; dual-path v1/v2 uplift via `max(schemaVersion, supported)` | unknown/duplicate keys rejected at every depth; `finish()` strict | `CanonicalProjectEncoding.decodeValidated` | `CanonicalProjectEncodingTests` | `:29-95` manifest + dual-path `:81-89` |
| `Codec/StrictReader.swift` — `StrictObjectReader` | Strict object reader; `optionalObject` treats `null` as absent | `optionalValue` returns nil for absent **AND** for explicit `null` (`:36-40`) | all decoders | `CanonicalProjectEncodingTests` (unknown field, duplicate key) | `:36-40`, `:78-81` |

### 2.2 Existing files REUSED unchanged (depended on, not edited)

| File / type | Why Slice 1 needs it | Evidence |
|---|---|---|
| `Time/SourceTimeMapping.swift` — `RationalSourceRange` | `AudioClipEntry.sourceTrim` type; `contains` for trim containment | `:2-16` |
| `Time/ProjectTime.swift` — `ProjectTimeRange`, `ProjectTime` | `AudioClipEntry.destination`; project-duration containment | `:48-67` |
| `Time/TickClock.swift` — `ticksPerSecond = 240_000` | the 5-ticks-per-sample constant derivation | `:7-10` |
| `Time/TimeError.swift` — `CheckedInt64`, `TimeError` | overflow-checked mapping arithmetic; typed overflow | `:33-51` |
| `Project/SceneLayer.swift` — `VideoBinding`, `SceneLayerContent` | document-level asset-match + video-not-image check | `:1-22` |
| `Project/CanonicalProjectManifest.swift` — `projectDuration()` | destination-within-project check | `:38-44` |

### 2.3 The 16 `CanonicalProjectManifest(...)` call sites that must keep compiling

`rg` over the package (Sources + Tests):

- **Sources (3):** `AnimiEngineTestSupport/CanonicalProjectFixtures.swift` (×2: `singleSceneDocument`
  `:229`, `twoSceneDocument` `:260`); `AnimiEngineTemplateAdapter/CompiledTemplateConverter.swift:200`
  (already passes `supportedSchemaVersion`, so it follows the 2→3 bump for free).
- **Tests (13 files):** `CanonicalProjectEncodingTests`, `ProjectValidationTests`,
  `EvaluationWindowBuilderTests`, `TimelineIndexTests`, `DurationInvarianceTests`,
  `TransitionAvailabilityTests`, `StretchedSceneTwoClockTests`, `DeterminismTests`,
  `GlobalOverlayTests`, `TransitionWindowIndexTests`, `StressFixtureTests`.

> The audit said "30 call sites"; the actual audited count on this HEAD is **16
> `CanonicalProjectManifest(` initializer occurrences** (3 in Sources, 13 in Tests). Some test files
> contain several occurrences, which is how the audit reached a higher number. The migration mechanic
> (default initializer parameter `audio: AudioManifest = .empty`) keeps every one of them compiling
> unchanged. **A grep at implementation time must re-confirm the exact count before claiming "all call
> sites compile".**

### 2.4 Real hash/golden state (NOT invented)

- **`AnimiEngineCore` has NO SHA-256 / canonical-document golden-hash test.** The only golden tests in
  Core pin the **FixedTrig CORDIC integer tables** (`Tests/AnimiEngineCoreTests/FixedTrigTests.swift:177`),
  which Slice 1 does not touch.
- The Core encoding tests assert **byte-stability and pinned enum tags by substring/round-trip**, not a
  stored document SHA: `CanonicalProjectEncodingTests.testByteStableRoundTrip` (`:18`),
  `testSortedKeysInOutput` (`:27`), `testEnumTagsPinnedGolden` (`:62`),
  `testIntegerFormattingHasNoTrailingDecimalOrExponent` (`:134`).
- The document/manifest **canonical SHA used as approved evidence lives in the render/promotion layer**,
  not in Core: the pixel reference set + `approval-manifest.json` and `PostPromotionMatrixRegressionTests`
  (decision-register §17 step 17; ADR-014 "Reference Promotion & Comparison Closure"). Stage E's "hash
  re-bake" therefore means: (a) re-pin Core's byte-stable encoding expectations for v3; (b) **prove the
  pixel `ReferenceData` is byte-identical** (no render path touched). There is **no single Core
  document-SHA constant to re-bake** — do not fabricate one.

---

## 3. Exact Swift API proposal

All types are `public`, value-semantic, `Sendable`, in `AnimiEngineCore`. No AVFoundation/TVECore/App.
No `Float`/`Double`. Throwing initializers use the existing typed errors; an `internal`/`private`
unchecked initializer is allowed **only** where the existing code already does so (the `init(unchecked:)`
on `StructuralID` — `References.swift:16-18`) for statically-valid constants such as `.empty` / `.zero`.

### 3.1 Typed IDs — `Project/AudioIdentifiers.swift` (new)

Built on the `StructuralID` pattern (`References.swift:8-23`): non-empty at construction; free
`Hashable`/`Comparable` for deterministic encoder ordering.

```swift
public struct AudioSourceID: Hashable, Comparable, Sendable {
    public let id: StructuralID
    public init(_ raw: String) throws { id = try StructuralID(raw) }
    init(_ id: StructuralID) { self.id = id }
    public var raw: String { id.raw }
    public static func < (lhs: AudioSourceID, rhs: AudioSourceID) -> Bool { lhs.id < rhs.id }
}
public struct AudioTrackID: Hashable, Comparable, Sendable { /* identical shape */ }
public struct AudioClipID:  Hashable, Comparable, Sendable { /* identical shape */ }

/// Opaque provenance id for global music / voiceover / SFX (no URL/path/AVAsset).
public struct GlobalAudioAssetID: Hashable, Comparable, Sendable {
    public let id: StructuralID
    public init(_ raw: String) throws { id = try StructuralID(raw) }
    init(_ id: StructuralID) { self.id = id }
    public var raw: String { id.raw }
    public static func < (lhs: GlobalAudioAssetID, rhs: GlobalAudioAssetID) -> Bool { lhs.id < rhs.id }
}
```

- **Comparable** is required (encoder sort by `AudioSourceID`, `AudioTrackID`, and clip tuple).
- **Throwing init** rejects empty via `ProjectValidationError.emptyIdentifier` (inherited from
  `StructuralID.init`).
- **`internal init(_ id: StructuralID)`** unchecked-bridge matches the existing pattern (`References.swift`).

### 3.2 Closed enums — `Project/AudioManifest.swift` (new)

```swift
public enum AudioSourceRole: String, Hashable, Sendable, CaseIterable {
    case videoLayer, music, voiceover, soundEffect
}

public enum AudioPlaybackPolicy: String, Hashable, Sendable {
    case once          // the ONLY case in v1; no loop/loopToFit/wrap is representable
}

public enum AudioAssetReference: Hashable, Sendable {
    case videoLayerMedia(MediaReference)   // reuses existing MediaReference (References.swift:75)
    case globalAudio(GlobalAudioAssetID)
}
```

- `AudioSourceRole`/`AudioPlaybackPolicy` are `String`-raw enums so the codec maps tags 1:1 and an
  unknown tag is a typed `ProjectDecodingError.unknownEnumTag` (mirrors transition/content decoding,
  `RawProjectDTO.swift:138-140,258-260`).
- `AudioAssetReference` is a closed enum, role-tagged in JSON (`kind`).

### 3.3 Checked gain — `Project/AudioGain.swift` (new)

```swift
public struct AudioGain: Hashable, Comparable, Sendable {
    public static let unityRaw: Int64 = 1_000_000
    public let raw: Int64                    // 0 ... 1_000_000, integer linear scale; 1_000_000 == unity

    public init(raw: Int64) throws {
        guard raw >= 0, raw <= AudioGain.unityRaw else {
            throw ProjectValidationError.invalidAudioGain(value: raw)   // typed; NEVER clamped
        }
        self.raw = raw
    }
    private init(uncheckedRaw raw: Int64) { self.raw = raw }
    public static let unity = AudioGain(uncheckedRaw: unityRaw)
    public static let silent = AudioGain(uncheckedRaw: 0)
    public static func < (l: AudioGain, r: AudioGain) -> Bool { l.raw < r.raw }
}
```

- **No Float/Double.** DSP conversion to `Float32` is explicitly a later-slice processing-boundary
  concern (ADR-012 §1: "DSP adapters convert gain to `Float32` only at the processing boundary").
- Out-of-range throws; the `uncheckedRaw` init is `private` and used only for the statically-valid
  `.unity`/`.silent` constants (mirrors `ProjectTime.zero` / `TickDuration.zero`).

### 3.4 Scene-layer reference + entries — `Project/AudioManifest.swift` (new)

```swift
public struct SceneLayerReference: Hashable, Sendable {
    public let sceneID: SceneInstanceID      // existing (References.swift:25)
    public let layerID: LayerID              // existing (References.swift:57); scene-local → needs sceneID
    public init(sceneID: SceneInstanceID, layerID: LayerID) {
        self.sceneID = sceneID; self.layerID = layerID
    }
}

public struct AudioSourceEntry: Hashable, Sendable {
    public let id: AudioSourceID
    public let asset: AudioAssetReference
    public init(id: AudioSourceID, asset: AudioAssetReference) { self.id = id; self.asset = asset }
}

public struct AudioTrackEntry: Hashable, Sendable {
    public let id: AudioTrackID
    public let role: AudioSourceRole
    public init(id: AudioTrackID, role: AudioSourceRole) { self.id = id; self.role = role }
}

public struct AudioClipEntry: Hashable, Sendable {
    public let id: AudioClipID
    public let trackID: AudioTrackID
    public let sourceID: AudioSourceID
    public let videoLayer: SceneLayerReference?    // role .videoLayer ⇒ non-nil; else ⇒ nil
    public let destination: ProjectTimeRange       // existing (Time/ProjectTime.swift:48)
    public let sourceTrim: RationalSourceRange      // existing (Time/SourceTimeMapping.swift:2)
    public let gain: AudioGain
    public let isMuted: Bool
    public let playbackPolicy: AudioPlaybackPolicy  // == .once
    public init(/* memberwise, non-throwing: all members are pre-validated value types */) { … }
}

public struct AudioManifest: Equatable, Sendable {
    public let sources: [AudioSourceEntry]
    public let tracks:  [AudioTrackEntry]
    public let clips:   [AudioClipEntry]
    public init(sources: [AudioSourceEntry], tracks: [AudioTrackEntry], clips: [AudioClipEntry]) { … }
    public static let empty = AudioManifest(sources: [], tracks: [], clips: [])
}
```

- **Equatable/Hashable/Sendable** everywhere (all `let` value members → free synthesis;
  `AudioManifest` is `Equatable` to match the manifest, no need for `Hashable`).
- **No throwing initializer on the entries/manifest:** every constituent is already a validated value
  type, and **semantic** invariants (uniqueness, dangling refs, role/asset agreement, ranges) are the
  **validator's** job, not construction's — consistent with the existing model where
  `CanonicalProjectManifest.init` is non-throwing and `ProjectValidator` enforces cross-object facts.
  The only throwing constructions are the IDs and `AudioGain` (local, value-level invariants), matching
  `ProjectTime`/`TickDuration`/`RationalSourceRange`.
- **`internal unchecked init` allowed** only for `.empty`/`.unity`/`.silent` constants (static validity),
  matching the existing `uncheckedTicks`/`unchecked` pattern.

### 3.5 Manifest field

```swift
// CanonicalProjectManifest gains a 6th stored field + initializer param with a default:
public let audio: AudioManifest
public init(… existing params …, audio: AudioManifest = .empty) { … ; self.audio = audio }
public static let supportedSchemaVersion = 3                 // was 2
public static let acceptedSchemaVersions: Set<Int> = [1, 2, 3]   // was [1, 2]
```

- The **default `= .empty`** keeps the 16 call sites compiling unchanged. It does **not** weaken the
  on-disk schema: v3 JSON still **requires** an explicit `"audio"` object with all three arrays
  (decoder enforces presence; the default only affects the in-memory Swift initializer).

### 3.6 Sample mapping — `Time/AudioSampleRange.swift` (new)

```swift
public enum AudioSampleGrid {
    public static let samplesPerSecond: Int64 = 48_000
    public static let ticksPerSample: Int64 = 5     // 240_000 / 48_000, asserted by a test

    /// ceilDiv5(t) = t/5 + (t % 5 == 0 ? 0 : 1), for t >= 0.
    /// PROOF (no overflow): for t in [0, Int64.max], t/5 <= floor(Int64.max/5) =
    /// 1_844_674_407_370_955_161, and adding at most 1 yields at most
    /// 1_844_674_407_370_955_162 < Int64.max = 9_223_372_036_854_775_807. The `+1` therefore
    /// CANNOT overflow for any non-negative Int64; the result is exact. (A non-negative
    /// precondition is still enforced; negative t is a typed domain error.)
    public static func ceilDiv5(_ tick: Int64) throws -> Int64 {
        guard tick >= 0 else { throw TimeError.negativeValue(domain: "AudioSampleGrid.ceilDiv5", value: tick) }
        let q = tick / 5
        let add: Int64 = (tick % 5 == 0) ? 0 : 1
        return q + add                              // proven not to overflow for tick >= 0
    }
}

/// Half-open 48 kHz sample interval [start, end), the ONLY canonical sample identity (ADR-006 §4).
/// EMPTY ranges are valid: `start == end` means zero samples (the clip rounds to no audio at the
/// 48 kHz grid). Only `end < start` is forbidden.
public struct AudioSampleRange: Hashable, Sendable {
    public let start: Int64                 // >= 0
    public let end: Int64                   // >= start  (empty allowed; only end < start forbidden)
    init(uncheckedStart: Int64, end: Int64) { self.start = uncheckedStart; self.end = end }

    /// Maps a half-open project tick range to its half-open sample range (ADR-006 §4).
    /// May return an EMPTY range (start == end) when both endpoints ceil to the same sample.
    public static func from(projectTicks range: ProjectTimeRange) throws -> AudioSampleRange {
        let s = try AudioSampleGrid.ceilDiv5(range.start.ticks)
        let e = try AudioSampleGrid.ceilDiv5(range.end.ticks)
        guard e >= s else { throw TimeError.invalidRange(field: "AudioSampleRange") }  // end < start only
        return AudioSampleRange(uncheckedStart: s, end: e)
    }
    public var isEmpty: Bool { end == start }
    public var sampleCount: Int64 { end - start }   // >= 0 (end >= start), no overflow
}
```

- **No floating point.** `ceilDiv5` is proven overflow-free for non-negative `Int64` (see proof above),
  so it does **not** wrap `CheckedInt64`. **All other** time/rational arithmetic in the slice still uses
  `CheckedInt64` and still throws typed `TimeError.integerOverflow`.
- Whether a typed `AudioGain` error case lives on `ProjectValidationError` (proposed `invalidAudioGain`)
  vs a new `AudioError` is the only "where does the typed error live" choice; the plan places gain in
  `ProjectValidationError` because gain validity is a manifest-validation concern (§7), and the mapping
  overflow in `TimeError` because it is arithmetic (consistent with §15.1 of Task-002).

---

## 4. Mandatory semantic challenge — RESOLVED (tech-lead decision recorded)

**Claim to prove:** `AudioClipEntry.destination + sourceTrim + playbackPolicy` uniquely determine the
source-time mapping.

**Status: RESOLVED.** The tech lead has fixed the canonical mapping; it is now normative in
**ADR-012 §1.0a** and the **Slice-001 contract** ("Canonical source-time mapping"). The decision:

1. `AudioClipEntry.rate` is **not** added.
2. The rate is **never** `sourceTrim.duration / destination.duration`.
3. **Global audio** (`music`/`voiceover`/`soundEffect`): strict 1/1 —
   `sourceTime = sourceTrim.start + (projectTime − destination.start)`. (Video-layer audio is NOT
   necessarily 1/1; it runs at the video's `PlaybackRate` — item 4. "No per-clip rate" ≠ "always 1/1".)
4. **Video-layer audio** uses **exactly** the referenced `VideoBinding.sourceMapping` — same `rate`,
   `nativeTimescale`, and anchor as the video — through the **same scene-media time
   `TimelineEvaluator` computes for the video** (`mediaPlaybackTime`):
   `sceneMediaTime(sceneID, T)` = `T − sceneStart` (sole) / `T − outgoingSceneStart` (outgoing) /
   `0` if `T < B` else `T − B` (incoming); `sourceTime =
   VideoBinding.sourceMapping.target(for: sceneMediaTime(sceneID, T))`. `AudioEvaluator` reuses this and
   **never** builds a separate project→scene mapping.
5. `sourceTrim` for video-layer audio is **only** an audible window/gate; it does not re-anchor or
   re-scale the video mapping.
5a. **Incoming audio is silent during the pre-boundary hold** (incoming media clock held at 0 while
   `T < B`): an incoming-side clip's `destination.start >= B`; repeating/stretching one sample to fill
   the hold is forbidden.
5b. **Outgoing audio may continue into the post-roll** iff `destination`, `sourceTrim`, and material
   availability allow it (gate + `.once` still apply; no special automation).
6. A clip is audible iff `projectTime ∈ destination` **and** the computed `sourceTime ∈ sourceTrim`
   (both half-open).
7. `.once` stops at the first end reached; loop/stretch/implicit-extension are forbidden.

The analysis below shows why this reading is the only one consistent with every case, and why it
required no change to the Slice-1 stored shape.

### 4.1 What Slice 1 actually has to guarantee

Slice 1 stores and round-trips data; it does not evaluate. The provable Slice-1 property is:
**for `.once`, the stored triple plus the source content is sufficient to define a single, total,
order-preserving map from the audible project interval to a source interval, with a deterministic stop
rule.** It is sufficient **iff** the rate that relates the two intervals is fixed by the contract.

### 4.2 `.once` stop rule (unambiguous, proven from the ADRs)

ADR-012 §1: "All clips use playback policy `.once`. Playback stops at the **earlier of the authored clip
end and available trimmed source content**. There is no wrap, repetition, implicit extension, or
`loopToFit`." So given a start anchor and a forward rate, the audible span is
`[destination.start, min(destination.end, destination.start + (|sourceTrim| / rate)))` — a single
deterministic interval. **`.once` is unambiguous.** `playbackPolicy` contributes exactly the "no wrap,
stop at earliest end" rule and nothing else.

### 4.3 The rate is the ONLY underdetermined quantity (BLOCKER-1)

`AudioClipEntry` stores `destination` (a `ProjectTimeRange`, in ticks) and `sourceTrim` (a
`RationalSourceRange`, in seconds) but **no rate field of its own**. Two readings both satisfy the
stored shape:

- **Reading R1 — derived rate:** `rate = |sourceTrim| seconds / |destination| seconds`. The destination
  fully determines duration; `sourceTrim` picks the in/out points; rate is whatever stretches one onto
  the other. Under R1, `|sourceTrim|` and `|destination|` are **independent** and never conflict.
- **Reading R2 — unit rate (1:1 real-time, the audit's implicit model):** audio plays at the source's
  natural rate; `destination.end` is just where it is cut off; `min(destination.end, …)` does the
  trimming. Under R2, if `|destination| > |sourceTrim|` the clip simply ends early; if
  `|destination| < |sourceTrim|` the tail of the trim is unused. R2 needs **no** separate rate field for
  v1 (rate is implicitly 1/1).

These diverge the moment Slice 2 evaluates: R1 time-stretches audio (and would desync from the video,
which has its **own** `VideoBinding.sourceMapping.rate`); R2 keeps real-time audio and lets destination
clip it.

### 4.4 Per-case analysis (proves where ambiguity bites)

| Case | Resolved by current contract? | Note |
|---|---|---|
| global music / voiceover / SFX | **R2 only is sensible** (music must not time-stretch to fit a destination) | strong evidence the contract intends R2 / global-1:1; D-021 "music plays once and stops at its source end" |
| video-layer audio | **must equal the video's mapping, via the evaluator's `mediaPlaybackTime`** | `sourceTime = VideoBinding.sourceMapping.target(for: sceneMediaTime(sceneID, T))`; same `rate`+`nativeTimescale`+anchor (`SourceTimeMapping.swift:26-49`); ADR-012 §1.2 trim containment. Audio reuses the evaluator clock — no separate mapping. |
| stretched scene (CP7.5) | video media clock continues across `timelineSpan`; visual holds at nominal (ADR-004 §10; `MaterialAvailabilityValidator.swift:108-145`) | audio uses the **same `sceneMediaTime`** (which already continues across the stretched span via `T − sceneStart`), so it follows the media clock automatically — never an independent derived stretch |
| transition post-roll (outgoing) | both scenes' audio mixed, no implicit ramp (ADR-012 §2; D-019) | outgoing `sceneMediaTime = T − outgoingSceneStart` continues past nominal (`TransitionMath.outgoingSceneTime`); outgoing audio may continue iff gate+material allow; rate unchanged |
| transition pre-boundary hold (incoming) | incoming `sceneMediaTime = 0` while `T < B` (`TransitionMath.incomingSceneTime`) | incoming audio is **silent** during the hold; an incoming clip's `destination.start >= B`; no repeat/stretch of a sample during the hold |
| `VideoBinding.sourceMapping` | carries `rate`, `nativeTimescale`, `trimRange` (`SourceTimeMapping.swift:31-35`) | the audio clip has **none of these**; only `sourceTrim` overlaps |
| scene `timelineSpan` | project duration basis for destination containment (`CanonicalProjectManifest.swift:38-44`) | unaffected by the rate reading |
| playback rate | video: explicit `PlaybackRate` (1/1 in v1); audio: **absent** | the gap |
| video audio cannot desync from its video | **only guaranteed under "audio rate == video rate"** | under R1 (derived), a `destination` longer/shorter than the natural source span would time-stretch audio away from the unstretched video → desync. ADR-012 §8 demands preview/export A/V parity; ADR-006 §3 makes audio the master clock. |

### 4.5 Resolution (the recorded decision, and why it is the only consistent reading)

The fixed reading is **video-locked (video audio inherits the video rate) + global 1/1**:

- **Video-layer audio:** the source-time mapping is **inherited from the referenced
  `VideoBinding.sourceMapping`** (its `rate`, `nativeTimescale`, and anchor), applied to the **same
  per-scene media clock the evaluator already computes for the video**:
  `sourceTime = VideoBinding.sourceMapping.target(for: sceneMediaTime(sceneID, T))`, where
  `sceneMediaTime` is the evaluator's `mediaPlaybackTime` — `T − sceneStart` (sole),
  `T − outgoingSceneStart` (outgoing post-roll, `TransitionMath.outgoingSceneTime`),
  `0` while `T < B` else `T − B` (incoming hold-first, `TransitionMath.incomingSceneTime`).
  `AudioEvaluator` (Slice 2) calls the **same** `sceneMediaTime` + `target(for:)`; it builds **no**
  separate project→scene mapping for audio. `AudioClipEntry.sourceTrim` is a window/gate **contained in**
  `VideoBinding.sourceMapping.trimRange` (ADR-012 §1.2 / §1.0a item 5) and never re-anchors the mapping.
  Audio plays at the **same rate as the video** and on the **same scene clock**, so it cannot desync —
  proven by construction. `destination` is the audible window; `.once` stops at the first end.
  **Incoming audio is silent during the pre-boundary hold** (clip `destination.start >= B`; no
  repeat/stretch of a sample during the hold). **Outgoing audio may continue into the post-roll** when
  `destination`/`sourceTrim`/material availability permit.
- **Global roles:** strict 1/1 (no `VideoBinding`); `sourceTime = sourceTrim.start +
  (projectTime − destination.start)`; `destination` places + clips it.

This is the only reading consistent with every row of §4.4: music must not time-stretch (rules out
R1/derived), and video audio must lock to the video's own mapping (rules out an independent per-clip
rate). The fix is **documentation-only** — ADR-012 §1.0a + the Slice-001 contract — and changes **no**
Slice-1 stored field. The discarded alternatives (R1 derived-stretch, or adding a per-clip
`rate`/`nativeTimescale` field) are **explicitly rejected** by the tech-lead decision; if a future need
arises it is a new canonical-shape change beyond ADR-012 → STOP and re-issue, never improvised.

**Gating:** because the migration/round-trip tests assert the documented meaning of
`sourceTrim`/`destination`, **no implementation stage (Stage A included) begins until this decision is
in version control with the implementation** (Gate-0). The decision is now fixed in the normative docs.

### 4.6 Evaluator boundary contracts (ADR-012 §1.0b; Slice-2 surface, documented here)

These constrain how the pure evaluator consumes the Slice-1 schema. They add **no** Slice-1 stored
field; they are recorded now so Slice 1 ships the schema with its evaluation contract pinned.

- **Input is `AudioEvaluationWindow`, not a manifest.** A pure `AudioEvaluator` consumes an immutable
  `AudioEvaluationWindow`; an `AudioEvaluationWindowBuilder` builds it (no I/O, no AVFoundation) from the
  canonical document, an `EvaluationWindowRequirement`, already-loaded `ResolvedScenePayload`s, and
  already-resolved `ResolvedAudioSourceDescriptor`s. The evaluator does no payload lookup and no source
  resolution — exactly mirroring `EvaluationWindowBuilder → EvaluationWindow → TimelineEvaluator` for
  video (`Timeline/EvaluationWindowBuilder.swift`, `Evaluator/TimelineEvaluator.swift`).
- **`ResolvedAudioSourceDescriptor`** resolves each `AudioAssetReference` to **exactly one** logical
  stream (≥ `AudioSourceID`, stable stream/provenance identity, exact source duration, source sample
  rate, channel layout). Zero/multiple matches for an existing clip → typed failure; silent video =
  absent clip; stream choice is identity-deterministic, never `AVAsset` track-order dependent.
- **Media-active domain (shared helper).** A video-layer clip's entire `destination` must lie in the
  scene's media-active domain (where `sceneMediaTime(sceneID, T)` is defined): visual
  `activeRange`/opacity never gate audio; incoming pre-boundary forbidden; outgoing post-roll allowed;
  any part outside → typed validation error. `TimelineEvaluator` and `AudioEvaluator` share **one**
  helper for `sceneMediaTime` + the media-active domain (no duplicated math). The shared helper is a
  small refactor introduced when Slice 2 lands; Slice 1 only records the contract.

---

## 5. Schema v3 migration

### 5.1 Exact rules (ADR-012 §1.1; task contract; mirror of the proven v1→v2 idiom)

| Rule | Implementation | Mirror of |
|---|---|---|
| `supportedSchemaVersion` 2 → 3 | `CanonicalProjectManifest.swift:8` | the CP7.5 1→2 bump |
| `acceptedSchemaVersions` `[1,2]` → `[1,2,3]` | `:11` | same |
| encoder always writes v3 | builder already emits `supportedSchemaVersion` (`CanonicalProjectValueBuilder.swift:94`) | timelineSpan v2 emit |
| v1/v2 must NOT contain `audio` | decoder dual-path: `if schemaVersion >= 3 { read audio } else { audio = .empty; reject a present "audio" key }` | timelineSpan dual-path `RawProjectDTO.swift:84-89` |
| v1/v2 uplift → `audio = .empty` (three empty arrays) | `max(schemaVersion, supported)` normalization already returns 3 (`RawProjectDTO.swift:47`) + inject `.empty` | timelineSpan uplift `:43-46` |
| v3 REQUIRES `audio` with all three arrays | `schemaVersion >= 3` branch reads `reader.object("audio")` then requires `sources`,`tracks`,`clips` arrays (missing any → typed decode error) | required-key reads |
| re-encoding v1/v2 → normalized v3 | in-memory `schemaVersion` normalized to 3; builder emits v3 + explicit empty `"audio"` | v1→v2 re-encode test `CanonicalProjectEncodingTests.swift:186-198` |
| unknown/duplicate fields rejected | `StrictObjectReader.finish()` already rejects unknown; parser rejects duplicate keys | `:92-96` |

### 5.2 Strict dual-path detail (the v1/v2-absent vs v3-required gate)

The decoder reads `schemaVersion` first (already does — `RawProjectDTO.swift:31`), then:

- `schemaVersion <= 2`: do **not** read an `"audio"` key. Because `reader.finish()` rejects unknown
  keys, a v1/v2 document that **does** carry `"audio"` is automatically rejected as an unknown field.
  Set in-memory `audio = .empty`.
- `schemaVersion == 3`: `let audioReader = try reader.object("audio")` (missing ⇒ typed
  `missingField`), then read the three required arrays; `audioReader.finish()` rejects unknown audio
  keys. This is the exact pattern of the v2 `timelineSpan` required-vs-absent read.

### 5.3 Exact canonical JSON shapes

The manifest object gains the `"audio"` key (the canonical writer key-sorts, so it lands between
`acceptedSchemaVersions`-era keys deterministically — actual position is writer-decided, never authored).

**Empty audio (v3, and the uplift target for v1/v2):**
```json
"audio":{"clips":[],"sources":[],"tracks":[]}
```

**Video-layer audio:**
```json
"audio":{
  "sources":[{"asset":{"kind":"videoLayerMedia","media":"media-ref"},"id":"source-id"}],
  "tracks":[{"id":"track-id","role":"videoLayer"}],
  "clips":[{
    "destination":{"end":240000,"start":0},
    "gain":1000000,
    "id":"clip-id",
    "isMuted":false,
    "playbackPolicy":"once",
    "sourceID":"source-id",
    "sourceTrim":{"end":{"denominator":1,"numerator":1},"start":{"denominator":1,"numerator":0}},
    "trackID":"track-id",
    "videoLayer":{"layerID":"layer-id","sceneID":"scene-id"}
  }]
}
```

**Global music (omitted `videoLayer`):**
```json
"sources":[{"asset":{"id":"global-asset-id","kind":"globalAudio"},"id":"s1"}],
"tracks":[{"id":"t1","role":"music"}],
"clips":[{"destination":{"end":240000,"start":0},"gain":1000000,"id":"c1","isMuted":false,
          "playbackPolicy":"once","sourceID":"s1","sourceTrim":{…},"trackID":"t1"}]
```
(no `"videoLayer"` key at all — **absent**, never `"videoLayer":null`).

> Key order shown alphabetical because the canonical writer sorts keys
> (`CanonicalJSONWriter.write` `:14-25`). The plan does not hand-order keys.

---

## 6. Strict optional-field handling

### 6.1 Current behavior (the exact problem)

`StrictObjectReader.optionalValue` (`StrictReader.swift:36-40`) returns `nil` for **both** an absent key
**and** an explicit JSON `null`:
```swift
guard let value = raw(key), value != .null else { return nil }
```
`optionalObject` (`:78-81`) is built on it. Task-contract requirement: `videoLayer` absence has exactly
one canonical representation; an explicit `"videoLayer":null` must be **rejected**, not treated as
absent.

### 6.2 Minimal change (additive, does not alter existing optional semantics)

Add a **new** strict reader method dedicated to "absent-allowed, explicit-null-forbidden", leaving
`optionalValue`/`optionalObject` byte-for-byte unchanged so every existing optional field (the only one
today is `animation` — `RawProjectDTO.swift:196,337`) keeps its current "null == absent" tolerance:

```swift
/// Distinguishes ABSENT (returns nil) from explicit JSON null (throws). For fields whose absence is
/// the ONLY canonical representation (ADR-012: audio clip `videoLayer`).
mutating func optionalObjectRejectingNull(_ key: String) throws -> StrictObjectReader? {
    consumed.insert(key)
    guard let value = raw(key) else { return nil }          // absent → nil
    if value == .null { throw ProjectDecodingError.explicitNull(path: childPath(key)) }   // null → reject
    return try StrictObjectReader(value, path: childPath(key))
}
```
- New `ProjectDecodingError.explicitNull(path:)` case (additive).
- `videoLayer` is decoded through this method **only**; everything else keeps `optionalObject`.
- **Why not change `optionalObject` globally:** the existing `animation` field and any future optional
  field rely on the lenient semantics; flipping it globally would silently tighten unrelated fields
  without proof. The new method is opt-in per field.

### 6.3 Tests (separate from existing optional-field tests)

- `"videoLayer":null` in a v3 clip → `ProjectDecodingError.explicitNull` (rejected).
- absent `videoLayer` on a global-role clip → decodes to `videoLayer == nil` (accepted).
- existing `animation` field with `"animation":null` → still treated as absent (unchanged), proving no
  regression to the lenient path.

---

## 7. Validation split

`validateManifest` runs without payloads; `validate(document)` runs after, with `ResolvedScenePayload`s.
Construction/decoder owns only local value invariants (emptiness, gain range, range start<end). Validator
must **accept shuffled table order** — ordering belongs to the encoder, never validation (ADR-012 §1.1).

| Invariant | validateManifest | validate(document) | Construction / decoder | Evidence / reuse |
|---|:--:|:--:|:--:|---|
| ID non-empty (source/track/clip/globalAsset) | | | ✅ throwing ID init | `References.swift:11` |
| `AudioGain` in `0…1_000_000`, integer, never clamped | | | ✅ `AudioGain.init` typed throw | §3.3 |
| `sourceTrim` start < end (non-empty trim) | ✅ | | ✅ `RationalSourceRange.init` (double-guards) | `SourceTimeMapping.swift:6-10` |
| `destination` start < end | | | ✅ `ProjectTimeRange.init` | `ProjectTime.swift:52-56` |
| `playbackPolicy == .once` (only token) | | | ✅ decoder enum tag; validator re-asserts | `RawProjectDTO` enum-tag idiom |
| unique `AudioSourceID` / `AudioTrackID` / `AudioClipID` | ✅ | | | reuse `requireUnique` `ProjectValidator.swift:214` |
| no dangling clip→source / clip→track | ✅ | | | new manifest check |
| every source referenced by ≥1 clip (no orphan source) | ✅ | | | new |
| every track referenced by ≥1 clip (no orphan track) | ✅ | | | new |
| empty-manifest consistency (all-empty or all-resolving) | ✅ | | | new (`.empty` passes) |
| role ↔ `videoLayer` presence (`.videoLayer`⇒present; else⇒nil) | ✅ | | | new |
| role ↔ asset kind (`.videoLayer`⇒`.videoLayerMedia`; global⇒`.globalAudio`) | ✅ | | | new |
| `videoLayer.sceneID` exists in manifest scenes | ✅ | | | manifest half of resolution |
| `destination` within project duration | ✅ | | | reuse `projectDuration()`/`projectEnd` `:66-67` |
| incoming video-audio clip: `destination.start >= boundary B` (no pre-boundary-hold audio) | ✅ | | | manifest-only: B + the clip's scene role at that boundary are derivable from `scenes` + `boundaryTransitions` (ADR-012 §1.0a 5a) |
| video-audio clip: entire `destination` within the scene's media-active domain (outgoing post-roll allowed; visual activeRange/opacity ignored) | ✅ | | | manifest-only: media-active domain derived from `scenes`+`boundaryTransitions` via the shared helper (ADR-012 §1.0b); outside → typed error |
| `gain` valid (re-assert) / `.once` (re-assert) | ✅ | | | defense-in-depth |
| `SceneLayerReference` resolves `sceneID→payloadID→ResolvedScenePayload` | | ✅ | | reuse correspondence map `ProjectValidator.swift:167-176` |
| referenced layer exists in that scene's payload | | ✅ | | new (payload layer lookup) |
| referenced layer content is `.video` (image rejected) | | ✅ | | `SceneLayer.swift:19-22` |
| `.videoLayerMedia(MediaReference)` == layer's `VideoBinding.media` | | ✅ | | plain value compare, no I/O |
| `sourceTrim ⊆ VideoBinding.sourceMapping.trimRange` (containment) | | ✅ | | reuse `RationalSourceRange.contains` / start≥trim.start ∧ end≤trim.end |
| no two video-audio clips for one `SceneLayerReference` | | ✅ | | new (dedup by ref) |
| legitimate silent video (video layer, no clip) accepted | ✅+✅ | | | absence ⇒ no check (proven) |
| required-but-invalid audio fails (dangling/mismatch/missing) | ✅ | ✅ | | the negation of the above checks |
| shuffled table order accepted (NOT rejected) | ✅ | | | validator iterates sets, not positions |

Notes:
- **Trim containment** for video audio: `sourceTrim.start ≥ binding.trimRange.start` AND
  `sourceTrim.end ≤ binding.trimRange.end` (both half-open, exact rational compare via
  `RationalSourceTime.<`). The existing `RationalSourceRange.contains` is point-containment; the range
  containment is two endpoint comparisons (no new arithmetic).
- New `ProjectValidationError` cases (all additive): `invalidAudioGain(value:)`,
  `duplicateAudioID(scope:id:)` (or reuse `duplicateStructuralID`), `danglingAudioReference(kind:id:)`,
  `orphanAudioSource(id:)`, `orphanAudioTrack(id:)`, `audioRoleLayerMismatch(clip:)`,
  `audioRoleAssetMismatch(clip:)`, `unknownAudioScene(clip:)`, `audioDestinationOutsideProject(clip:)`,
  `audioLayerNotFound(clip:)`, `audioLayerNotVideo(clip:)`, `audioMediaMismatch(clip:)`,
  `audioTrimNotContained(clip:)`, `duplicateVideoAudioClip(layer:)`,
  `incomingAudioBeforeBoundary(clip:)` (incoming-side clip `destination.start < B` — ADR-012 §1.0a 5a),
  `audioDestinationOutsideMediaActiveDomain(clip:)` (part of a video clip's destination outside the
  scene's media-active domain — ADR-012 §1.0b). The exact final set is an implementation detail; each
  test in §9 names the case it asserts.

---

## 8. Exact tick↔sample mapping

- **Constant:** `ticksPerSample = 240_000 / 48_000 = 5` — pinned by a test asserting
  `TickClock.ticksPerSecond / AudioSampleGrid.samplesPerSecond == 5`.
- **Type:** `AudioSampleRange { start: Int64; end: Int64 }`, sample index is `Int64`
  (project ticks are `Int64`; `ceilDiv5` cannot exceed the tick magnitude).
- **Half-open invariant:** `[ceilDiv5(startTick), ceilDiv5(endTick))`; `from(projectTicks:)` requires
  only `end >= start` (empty allowed — see zero-length policy). A `ProjectTimeRange` guarantees
  `end.ticks > start.ticks`, but two distinct ticks can collapse to the same sample, so `start == end`
  is a legitimate empty result.
- **`ceilDiv5` is NOT wrapped in `CheckedInt64`:** `t/5 + (t%5==0 ? 0 : 1)`, with `t ≥ 0` enforced
  (project time is non-negative). **Overflow correction:** for any non-negative `Int64`, `t/5 <=
  floor(Int64.max/5) = 1_844_674_407_370_955_161`, and `+1` gives at most
  `1_844_674_407_370_955_162 < Int64.max`. The `+1` therefore **cannot** overflow — the prior plan's
  `CheckedInt64.add` + "overflow at Int64.max throws" requirement was **false** and is removed. The
  result is exact at `Int64.max`. (Negative `t` is still a typed `negativeValue` domain error.)
- **Zero-length policy (CONFIRMED: empty allowed):** a `ProjectTimeRange` with
  `end.ticks - start.ticks < 5` that maps to `ceilDiv5(start) == ceilDiv5(end)` (e.g. `[1,2)` →
  `[1,1)`) produces a **valid empty** sample range. `AudioSampleRange` permits `start == end`; an empty
  range means **zero samples** and contributes **zero `AudioPlan` segments** in Slice 2 — it is **not**
  an error. **Only `end < start` is rejected** (`TimeError.invalidRange`). `sampleCount` is `end - start`
  (`>= 0`).
- **All OTHER arithmetic stays checked:** every remaining time/rational operation in the slice still
  uses `CheckedInt64`/the rational layer and still throws typed `TimeError.integerOverflow`. Only the
  proven-safe `ceilDiv5` `+1` is exempt.
- **No floating point:** the entire mapping is integer; `AudioGain` and all time stay integer/rational.
- **Mapping tests:** see §9 (exact boundaries at multiples of 5 and non-multiples, the `[ceil,ceil)`
  property, the empty-range (`start == end`) accepted case, the `end < start` rejection, the
  overflow-free `Int64.max` result, and the `5` constant).

---

## 9. Test-first matrix

`Existing` = update an existing test; `New` = new test (new file unless noted). All run under
`AnimiEngineCoreTests`. No golden/hash test is invented; the rows that touch bytes update the existing
byte-stability assertions (§2.4) or pin new substrings, never a fabricated SHA.

| Test class / name | Contract | Setup | Expected | Status |
|---|---|---|---|---|
| `AudioSchemaMigrationTests.testV3EmptyRoundTrip` | v3 round trip | empty `audio` | encode→decode→encode byte-identical; `"audio":{"clips":[],"sources":[],"tracks":[]}` present | New |
| `…testV3PopulatedRoundTrip` | populated round trip | source+track+clip (video) | survive + deterministic bytes | New |
| `…testV1UpliftToEmptyV3` | v1 uplift | synth v1 (drop audio+timelineSpan, schemaVersion:1) | decoded `audio == .empty`; in-memory schemaVersion 3; re-encode v3 | New (mirrors `CanonicalProjectEncodingTests.swift:186`) |
| `…testV2UpliftToEmptyV3` | v2 uplift | synth v2 (no audio) | decoded `audio == .empty`; re-encode v3 | New |
| `…testEncoderAlwaysWritesV3` | encoder header | any input version | `"schemaVersion":3` | New |
| `…testV3MissingAudioRejected` | required audio | v3 bytes minus `"audio"` | typed `missingField` (decoding) | New |
| `…testV3MissingOneTableRejected` | required arrays | v3 audio minus `"tracks"` | typed `missingField` | New |
| `…testV1V2WithAudioRejected` | v1/v2 forbid audio | v1 bytes WITH `"audio"` | typed `unknownField` | New |
| `…testUnknownAudioFieldRejected` | strict finish | extra key in source/clip | typed `unknownField` | New |
| `…testExplicitNullVideoLayerRejected` | absent vs null | clip `"videoLayer":null` | typed `explicitNull` | New (§6.3) |
| `…testAbsentVideoLayerAccepted` | global-role absence | global clip, no `videoLayer` | `videoLayer == nil` | New |
| `…testAnimationNullStillAbsent` | no regression | existing layer `"animation":null` | treated as absent (unchanged) | New |
| `…testMalformedAssetKindRejected` | asset enum tag | `"kind":"bogus"` | typed `unknownEnumTag` | New |
| `…testMalformedSceneLayerRefRejected` | ref shape | `videoLayer` missing `layerID` | typed `missingField` | New |
| `…testMalformedIDsRejected` | id emptiness | `"id":""` | typed `emptyIdentifier` | New |
| `AudioGainTests.testBoundariesAccepted` | gain edges | 0 and 1_000_000 | valid | New |
| `…testOutOfRangeRejectedNoClamp` | gain range | -1, 1_000_001 | typed `invalidAudioGain`; value never coerced | New |
| `…testNonIntegerGainRejected` | gain integer | `"gain":1.5` | typed `malformedInteger` (decoder) | New |
| `AudioManifestValidationTests.testDuplicateIDsRejected` | unique IDs | dup source/track/clip id | typed manifest error | New |
| `…testDanglingClipRefRejected` | dangling | clip→missing track / source | typed manifest error | New |
| `…testOrphanSourceRejected` / `…testOrphanTrackRejected` | orphan | unreferenced source/track | typed manifest error | New |
| `…testAllEmptyManifestConsistent` | empty consistency | `.empty` | passes | New |
| `…testRoleLayerPresenceRules` | role↔videoLayer | `.videoLayer`+nil; global+ref | each → typed error | New |
| `…testRoleAssetKindRules` | role↔asset | `.videoLayer`+`.globalAudio`; global+`.videoLayerMedia` | each → typed error | New |
| `…testUnknownSceneRejected` | scene existence (manifest) | `videoLayer.sceneID` not in scenes | typed error | New |
| `…testDestinationOutsideProjectRejected` | destination range | dest end > projectDuration | typed error | New |
| `…testTrimNonEmptyRejected` | trim | start≥end (constructed pre-check) | typed error at construction | New |
| `…testShuffledTablesAcceptedByValidator` | order non-semantic | shuffled arrays | validation passes | New |
| `AudioDocumentValidationTests.testLayerResolves` | scene-layer resolution | valid video ref | passes | New |
| `…testUnknownLayerInSceneRejected` | layer existence | layerID absent in that payload | typed error | New |
| `…testImageLayerRejected` | video-not-image | ref points to `.image` layer | typed error | New |
| `…testMediaMismatchRejected` | asset match | clip media ≠ `VideoBinding.media` | typed error | New |
| `…testSameLayerIDInTwoScenesResolves` | scene-local disambiguation | same `LayerID` in 2 scenes | both resolve distinctly | New |
| `…testTrimContainmentEnforced` | trim ⊆ video trim | sourceTrim outside binding trim | typed error; inside → passes | New |
| `…testDuplicateVideoAudioClipRejected` | one clip per ref | 2 video clips → same `SceneLayerReference` | typed error | New |
| `…testIncomingAudioBeforeBoundaryRejected` | no pre-hold audio | incoming-side clip `destination.start < B` | typed `incomingAudioBeforeBoundary` | New |
| `…testDestinationOutsideMediaActiveDomainRejected` | media-active domain | video clip destination past the scene's media-active end | typed `audioDestinationOutsideMediaActiveDomain` | New |
| `…testOutgoingPostRollAudioAccepted` | post-roll allowed | outgoing clip destination into post-roll, trim+material OK | passes | New |
| `…testOneSourceManyClipsAccepted` | source reuse | 2 clips, same `sourceID` | passes | New |
| `…testLegitimateSilentVideoAccepted` | silence | video layer, no clip | passes | New |
| `…testRequiredVideoAudioMissingFails` | required audio | video clip, dangling/mismatch | typed error | New |
| `AudioSampleMappingTests.testFiveTicksPerSample` | constant | — | `240000/48000 == 5` | New |
| `…testExactBoundariesMultiplesOfFive` | `[ceil,ceil)` | `[0,240000)`→`[0,48000)` | exact | New |
| `…testNonMultipleOfFiveCeil` | ceil rounding | `[1,7)`→`[1,2)`; `[3,5)`→`[1,1)` (empty, accepted) | exact; empty range valid (zero samples) | New |
| `…testEmptySampleRangeAccepted` | empty allowed | `[1,2)`→`[1,1)` and `[5,6)`→`[1,2)`? no — `[1,4)`→`[1,1)` | `isEmpty==true`, `sampleCount==0`, no throw | New |
| `…testEndBeforeStartRejected` | only inverted rejected | construct `end < start` | typed `invalidRange` | New |
| `…testInt64MaxExactSafeResult` | overflow-free proof | `ceilDiv5(Int64.max)` | exact `1_844_674_407_370_955_162`, **no throw** | New (replaces the removed `testOverflowThrows`) |
| `…testNegativeTickRejected` | domain | negative (constructed) | typed `negativeValue` | New |
| `CanonicalProjectEncodingTests.*` (existing) | bytes change deterministically | existing fixtures now emit v3 + empty `"audio"` | update `schemaVersion:2`→`3` substrings; v1-uplift test updated to inject empty audio; byte-stable round trip still holds | **Existing — UPDATE** |
| `ProjectValidationTests.*` (existing) | unaffected semantics | manifests now carry `.empty` audio by default | should pass unchanged via default param; verify | **Existing — VERIFY** |
| full `AnimiEngineCoreTests` | regression | — | all green (231→231+new, 0 fail) | **Existing — GATE** |
| no-audio evaluator semantics | unchanged FramePlan | v1/v2 fixtures through evaluator | identical output (no render/eval path touched) | **Existing — VERIFY** |

**Real existing test sites that MUST be updated (not invented):**
`CanonicalProjectEncodingTests.swift` — `testByteStableRoundTrip` (`:18`), `testSortedKeysInOutput`
(`:27`), `testMalformedIntegerRejected` (`:123` already keys on `"schemaVersion":2` → becomes `:3`),
`testUnsupportedSchemaVersionRejectedOnEncodeAndDecode` (`:161`, now version 4 is the unsupported one),
`testV1DocumentDecodesWithTimelineSpanEqualNominal` (`:186`, must also account for the empty audio
uplift). No other file pins document bytes.

---

## 10. Ordered green stages (A–E, one gate)

Each stage builds and keeps `AnimiEngineCoreTests` green; **no red commit is ever proposed** (roadmap
rule: "every reviewable implementation stage must build and keep its scoped test suite green").

### Stage A — schema scaffolding + migration tests
- **Precondition (gating, applies to the whole slice):** the §4 source-time-mapping decision is fixed in
  ADR-012 §1.0a + the Slice-001 contract and is part of the implementation changeset (Gate-0). Stage A
  must not begin before this.
- **Files (modify):** `CanonicalProjectManifest.swift` (version consts; add `audio` field with
  `= .empty` default — paired with a minimal `AudioManifest.empty` stub so it compiles), and the
  decoder/encoder dual-path for the **empty** audio object only.
- **New (minimal):** `Project/AudioManifest.swift` containing at least `AudioManifest` + `.empty`
  (full entry types may land here or in Stage B; A only needs `.empty`).
- **Tests:** `AudioSchemaMigrationTests` (v3 empty round trip, v1/v2 uplift, encoder-writes-v3, v3
  missing-audio / missing-table rejected, v1/v2-with-audio rejected); update the existing
  `CanonicalProjectEncodingTests` version substrings.
- **Expected diff:** version consts; 1 new field + default; ~30 lines encoder/decoder dual-path; the new
  migration test file; ~5 existing-test substring edits.
- **Exit gate:** all `AnimiEngineCoreTests` green; v1/v2/v3 round trips proven; no populated audio yet.
- **Rollback boundary:** Stage A is not independently revertible from the slice (see §10 note); within
  the slice it is the first commit.

### Stage B — value model + sample mapping
- **New files:** `Project/AudioIdentifiers.swift` (4 IDs), `Project/AudioGain.swift`,
  `Project/AudioManifest.swift` completed (enums, `AudioAssetReference`, `SceneLayerReference`, entries),
  `Time/AudioSampleRange.swift` (`AudioSampleGrid` + `AudioSampleRange`).
- **Modify:** `ProjectValidationError.swift` (add `invalidAudioGain`); `TimeError` unused beyond
  existing cases.
- **Tests:** `AudioGainTests`, `AudioSampleMappingTests`.
- **Precondition:** the §4 decision is already fixed (gates the whole slice, including Stage A); the §8
  zero-length policy is confirmed before Stage B value semantics are finalized.
- **Exit gate:** value types + mapping fully tested; green. No codec/validator wiring yet.

### Stage C — manifest/codec integration
- **Modify:** `CanonicalProjectValueBuilder.swift` (add `audio(_:)` emitter for the three tables +
  `AudioAssetReference`/`SceneLayerReference`/gain/policy; wire into `manifest(_:)`);
  `RawProjectDTO.swift` (add `decodeAudio`/`decodeSource`/`decodeTrack`/`decodeClip`; v3 required-arrays
  path; `videoLayer` via `optionalObjectRejectingNull`); `StrictReader.swift`
  (`optionalObjectRejectingNull` + `ProjectDecodingError.explicitNull`).
- **Tests:** populated round trip; unknown/malformed asset/ref; explicit-null reject; absent accepted;
  animation-null no-regression.
- **Exit gate:** populated v3 round-trips byte-stable; all 16 call sites still compile (re-grep);
  green.

### Stage D — validation
- **Modify:** `ProjectValidator.swift` (manifest-only audio block in `validateManifest`; payload-
  dependent audio block in `validate(document)`); `ProjectValidationError.swift` (the additive cases).
- **Tests:** `AudioManifestValidationTests`, `AudioDocumentValidationTests` (every §7 row).
- **Exit gate:** every validation invariant proven at the correct boundary; shuffled order accepted;
  green.

### Stage E — golden/evidence closure
- **Action:** record old→new **encoding** expectations (the v3 + `"audio"` byte changes are pinned by
  the updated `CanonicalProjectEncodingTests`); document that **no Core document-SHA constant exists**
  and that the relevant pixel evidence is the render-layer `ReferenceData`.
- **Prove pixel `ReferenceData` byte-identical** for no-audio projects: Slice 1 touches no render path,
  so `PostPromotionMatrixRegressionTests` (render-layer) must remain 84/84 exactMatch and the
  `ReferenceData/references/*.png` tree byte-identical. *(This test lives in the Metal/render test
  target, not `AnimiEngineCoreTests`; running it is part of the full-package gate, recorded in the
  implementation report — see §12.)*
- **Exit gate:** the single Slice-1 gate (below).

**Single Slice-1 gate (all must hold):** full `AnimiEngineCoreTests` green incl. every §9 test; all
ADR-012 schema-v3 tests green; no forbidden imports; canonical encoding deterministic under shuffled
construction; old/new encoding expectations recorded; no no-audio pixel-reference change; no
production-app file changed; v1/v2→empty-v3 uplift proven; malformed/incomplete v3 rejected.

**Rollback boundary (whole slice):** Slice 1 = schema + manifest + codec + validator + tests + evidence.
Rollback is a **single atomic revert of A–E together**; it is **not** valid to revert the new audio
files while leaving `schemaVersion=3` (half-migrated, unbuildable on-disk contract). Revert as one unit.

---

## 11. Exact file list

### 11.1 Existing production files to MODIFY (7)
- `Sources/AnimiEngineCore/Project/CanonicalProjectManifest.swift`
- `Sources/AnimiEngineCore/Project/ProjectValidator.swift`
- `Sources/AnimiEngineCore/Project/ProjectValidationError.swift`
- `Sources/AnimiEngineCore/Project/References.swift` *(only if IDs are co-located here instead of a new
  file; the plan puts IDs in a new file, so References.swift may stay untouched — confirm at impl time)*
- `Sources/AnimiEngineCore/Codec/CanonicalProjectValueBuilder.swift`
- `Sources/AnimiEngineCore/Codec/RawProjectDTO.swift`
- `Sources/AnimiEngineCore/Codec/StrictReader.swift`

### 11.2 New production files (4–5)
- `Sources/AnimiEngineCore/Project/AudioIdentifiers.swift`
- `Sources/AnimiEngineCore/Project/AudioGain.swift`
- `Sources/AnimiEngineCore/Project/AudioManifest.swift`
- `Sources/AnimiEngineCore/Time/AudioSampleRange.swift`
- *(optional)* equivalent file decomposition is permitted **only** if ownership stays in
  `AnimiEngineCore` (task contract). E.g. `Project/AudioErrors.swift` if the audio error cases are
  separated. No new target, no `Package.swift` change.

### 11.3 New test files (4)
- `Tests/AnimiEngineCoreTests/AudioSchemaMigrationTests.swift`
- `Tests/AnimiEngineCoreTests/AudioGainTests.swift`
- `Tests/AnimiEngineCoreTests/AudioSampleMappingTests.swift`
- `Tests/AnimiEngineCoreTests/AudioManifestValidationTests.swift` (+ `AudioDocumentValidationTests.swift`
  may be folded in or split — 4–5 files)

### 11.4 Test files to UPDATE
- `Tests/AnimiEngineCoreTests/CanonicalProjectEncodingTests.swift` (version substrings + v1-uplift +
  unsupported-version-now-4).
- `Sources/AnimiEngineTestSupport/CanonicalProjectFixtures.swift` *(only if a populated-audio fixture
  helper is added; the default `= .empty` means existing helpers need no change — add helpers, do not
  alter existing signatures).*
- `Tests/AnimiEngineCoreTests/ProjectValidationTests.swift` *(verify-only; should pass via default).* 

### 11.5 Documentation / evidence file
- This plan: `Docs/AnimiEngineNext/slice-001-implementation-plan.md`.
- Implementation report (at implementation time): `Docs/AnimiEngineNext/slice-001-implementation-report.md`
  (commands, results, old→new encoding expectations, pixel-reference-unchanged proof).
- **Gate 0 (roadmap):** ADR-005/006/012, the roadmap, and the Slice-001 task contract must enter version
  control **with** the implementation. They are currently untracked/modified (see §12 git status). The
  planning pass stages/commits **nothing**; the implementer must add them in the implementation
  changeset.

### 11.6 Explicitly FORBIDDEN files (must NOT be touched in Slice 1)
- Anything under `AnimiApp/` (shipping app), TVECore, `*.xcodeproj`, `Package.swift`.
- Any AVFoundation/Metal/render source; any `ReferenceData/` PNG; any `approval-manifest.json`.
- The evaluator/render path (`Evaluator/`, `AnimiEngineMetalRender`, `AnimiEngineRenderGraph`).
- No new dependency; no stage/commit/push during planning.

---

## 12. Baseline verification

**Command (exact, run during this planning pass):**
```sh
cd /Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiEngineNext
swift test --build-path /tmp/animi-slice001-plan-99829 --filter AnimiEngineCoreTests
```
(The task contract's minimum is `swift test --filter AnimiEngineCoreTests`; the out-of-repo
`--build-path` is the required external build path.)

**Toolchain / environment:**
- Apple Swift 6.2 (swiftlang-6.2.0.19.9, clang-1700.3.19.1); target `arm64-apple-macosx26.0`.
- Xcode 26.0.1 (17A400); `/Applications/Xcode.app/Contents/Developer`.
- macOS Darwin 25.5.0; host arm64.

**Result:** `Executed 231 tests, with 1 test skipped and 0 failures (0 unexpected)` — the
`AnimiEngineNextPackageTests.xctest` suite filtered to `AnimiEngineCoreTests`, plus a clean Swift-Testing
sub-run (0 tests). **BASELINE GREEN.** (The 1 skip is a pre-existing skipped test, unrelated to audio.)

**Cleanup:** the temporary build path `/tmp/animi-slice001-plan-99829` is outside the repo and may be
removed (`rm -rf /tmp/animi-slice001-plan-99829`); it was never staged. No repo file was produced by the
test run.

**git status before/after:** identical except for this plan file (the only artifact this pass creates).
Before/after the test run: no change to tracked files; the modified/untracked normative docs
(ADR-002/003/004 modified; ADR-005/006/012, roadmap, slice-001 contract, audits untracked) were present
before and are unchanged by this pass. **No production or test code was modified or staged.**

**App tests:** NOT run (Slice 1 does not change the app), per the task contract.

---

## 13. Stop conditions (repeated verbatim from the contract — any of these → STOP, do not improvise)

- No AVFoundation / TVECore / `AnimiApp` in the core.
- No schema shape different from ADR-012 (if §4 forces a new `AudioClipEntry` field → STOP, re-issue
  contract).
- No `Float`/`Double` canonical gain/time.
- No clamp / loop / crossfade / ducking behavior (gain out-of-range throws; only `.once`).
- No permissive unknown-field handling (strict `finish()`; explicit-null rejected for `videoLayer`).
- No pixel `ReferenceData` change (no render path touched; prove byte-identical).
- No legacy deletion; no product cutover; no shipping-app/project-file change.

---

## 14. Final implementation handoff

- **First allowed implementation stage:** **Stage A — schema scaffolding + migration tests**, allowed
  **only after** the §4 source-time-mapping decision (ADR-012 §1.0a + Slice-001 contract) is in version
  control with the implementation changeset.
- **Exact files (Stage A):**
  - modify `Sources/AnimiEngineCore/Project/CanonicalProjectManifest.swift`
    (`supportedSchemaVersion 2→3`, `acceptedSchemaVersions [1,2]→[1,2,3]`, add
    `audio: AudioManifest = .empty`);
  - new `Sources/AnimiEngineCore/Project/AudioManifest.swift` (at minimum `AudioManifest` + `.empty`);
  - modify `Sources/AnimiEngineCore/Codec/CanonicalProjectValueBuilder.swift` (emit empty `"audio"`),
    `Sources/AnimiEngineCore/Codec/RawProjectDTO.swift` (v3-required / v1-v2-absent dual path);
  - new `Tests/AnimiEngineCoreTests/AudioSchemaMigrationTests.swift`;
  - update `Tests/AnimiEngineCoreTests/CanonicalProjectEncodingTests.swift` version substrings.
- **Exact tests (Stage A):** `AudioSchemaMigrationTests` (v3 empty round trip; v1 + v2 uplift to empty;
  encoder-writes-v3; v3 missing-audio rejected; v3 missing-one-table rejected; v1/v2-with-audio
  rejected) + the updated `CanonicalProjectEncodingTests`.
- **Verification command:**
  `cd AnimiEngineNext && swift test --build-path /tmp/animi-slice001-A-<unique> --filter AnimiEngineCoreTests`
- **What Claude MUST show the tech lead before moving to Stage B:**
  1. the §4 source-time-mapping decision present in the changeset (ADR-012 §1.0a + Slice-001 contract,
     verbatim) and the §8 zero-length policy confirmed;
  2. Stage-A green test output (full `AnimiEngineCoreTests`, 0 failures, count ≥ baseline + new);
  3. proof v1/v2 documents uplift to `audio == .empty` and re-encode as v3, and that a v1/v2 document
     carrying `"audio"` is rejected;
  4. confirmation that Gate-0 normative docs are part of the implementation changeset (added, not yet
     committed unless the lead authorizes);
  5. confirmation no app/project/Package/ReferenceData file changed (git status diff scoped to
     `AnimiEngineNext/Sources/AnimiEngineCore` + `Tests/AnimiEngineCoreTests` + the docs).
