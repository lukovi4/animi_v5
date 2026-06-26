# Slice 3.5 — Deterministic Media Corpus

- **Status:** COMPLETE. Clean checkout contains every required fixture as **real committed media** (audio WAV, deterministic video **frame sequences**, a committed PCM track for the known-audio video, corrupt/missing fixtures, stress + transition-overlap project descriptors).
- **Date context:** 2026-06-26.
- **Normative requirement:** roadmap §5 — a legally-safe, deterministic generator + compact generated fixtures committed *before any runtime/device gate*; gate: *"clean checkout contains all required fixtures"*. ADR-012 verification gates (44.1/48/96 kHz inputs, silent vs required audio, 6/10/20-video stress, transition-overlap).
- **Unblocks:** Slice 004 preflight blocker **B2** → **CLOSED** (see §6 / §10).
- **Owner decision (2026-06-26):** the canonical committed video fixture is a deterministic **PPM frame sequence** (silent_video, video_with_audio) plus a committed **48 kHz PCM** track for the known-audio fixture. A single ENCODED `.mov`/`.mp4` clip is a **derived artifact** for the Slice-4 / device gate, **not** the canonical committed fixture.
- **Nothing staged or committed by this slice.**

---

## 1. What this corpus is

A single deterministic generator (`media-corpus/generate_corpus.py`, Python standard library only, no network, no third-party/downloaded media) emits the entire corpus as a pure function of constants in that file. Re-running it reproduces **byte-identical** output, verified by:

- the committed SHA-256 hashes in `media-corpus/corpus-manifest.json`;
- `python3 generate_corpus.py --check` (regenerates to a temp dir, diffs hashes, writes nothing);
- `MediaCorpusManifestTests` (device-free, AVFoundation-free; re-hashes every committed file and re-parses its header/metadata).

All assets live under `Docs/AnimiEngineNext/media-corpus/`. This location is **outside the Swift package**, so the corpus needs **no `Package.swift` change**; the test reads files from the working tree via `#filePath` (the same pattern as `RuntimeNoFloatNoAVTests`).

## 2. Layout

```
Docs/AnimiEngineNext/media-corpus/
  generate_corpus.py          # deterministic generator (stdlib only)
  corpus-manifest.json        # asset list + per-file sha256 + metadata (canonical sorted JSON)
  audio/                      # committed, byte-stable PCM16 mono WAV tones + silence
  video/
    silent_video/            # committed deterministic PPM P6 frame sequence (no audio)
    video_with_audio/        # committed PPM P6 frame sequence + audio.wav (48 kHz PCM)
  descriptors/                # committed video-fixture descriptors + the corrupt blob
  projects/                   # committed stress / transition-overlap project descriptors
```

## 3. Asset list (exact, with hashes)

All hashes are SHA-256 of the committed file bytes. 26 committed assets.

### Audio (canonical PCM16 mono LE WAV)

| Path | sr / ch / samples / dur | Bytes | SHA-256 |
|---|---|---|---|
| `audio/tone_44100hz.wav` | 44100 / 1 / 11025 / 0.25 s | 22094 | `30573e3bcf207750ec1d8b41facaab9dbf1750767be2a9f402878335b712ebf3` |
| `audio/tone_48000hz.wav` | 48000 / 1 / 12000 / 0.25 s | 24044 | `82e9cf238339eb163eec461002ce40c4607c72b6882571baaa5a8f958a490265` |
| `audio/tone_96000hz.wav` | 96000 / 1 / 24000 / 0.25 s | 48044 | `506881150c8fa5079794eaa1ea33ecf44bf4259380b2bb0b43ac475d84acc58a` |
| `audio/silent_48000hz.wav` | 48000 / 1 / 12000 / 0.25 s | 24044 | `eca4d388a3695168ebd316e8e2094a2e1ffa5df4c37dbf6d8755dfe8ce5ed9a6` |
| `video/video_with_audio/audio.wav` | 48000 / 1 / 48000 / 1.000 s | 96044 | `2e94edecc1d4d411…` (full hash in manifest) |

### Real video frame sequences (PPM P6, 32×32 RGB, 6 frames each)

| Path | Bytes | SHA-256 |
|---|---|---|
| `video/silent_video/frame_000.ppm` | 3085 | `6926fd66f419c3ca…` |
| `video/silent_video/frame_001.ppm` | 3085 | `8455177631955df5…` |
| `video/silent_video/frame_002.ppm` | 3085 | `dbb786e6cb9e9408…` |
| `video/silent_video/frame_003.ppm` | 3085 | `afe4a6c27333cfc3…` |
| `video/silent_video/frame_004.ppm` | 3085 | `0d60db7bca2326ec…` |
| `video/silent_video/frame_005.ppm` | 3085 | `54c31bc59badae17…` |
| `video/video_with_audio/frame_000..005.ppm` | 3085 ea. | identical pixel sequence to silent_video (same 6 hashes) |

(The two fixtures intentionally share the identical frame sequence; they differ only by the presence of the committed audio track — that is exactly the "silent video" vs "video with known audio" contrast.)

### Descriptors + projects

| Path | Bytes | SHA-256 |
|---|---|---|
| `descriptors/corrupt_media.bin` | 65 | `ee7eef203981d37215c297993e0bdcff6a601a270238a852114c9ebc65e0c11a` |
| `descriptors/corrupt_media.json` | 342 | `e1050558d1175486b4cc92c6fb3a21a88bb6c5a8df243f31722ac26d3bfec2f3` |
| `descriptors/missing_media.json` | 312 | `36a8fe33b4dcce61e813b10cc2f3a7039c540525f5f66ef68305270bdc1d9173` |
| `descriptors/silent_video.json` | 448 | `29f443851a4e8928…` |
| `descriptors/video_with_audio.json` | 643 | `44f42728881791bb…` |
| `projects/stress_6_video.json` | 1227 | `b9e4bb74c7030decf06add27eba4f9aac838e4fab6c794e4dd290cde384340a8` |
| `projects/stress_10_video.json` | 1765 | `fff6240dfc0f4b3ebd6b15efd4ae0397ce33455172849cb4d352cbc7d4d29173` |
| `projects/stress_20_video.json` | 3115 | `db0687fdcdafec4dbc260deb83b34b636c1a2f5eb65a59b480842351f133b355` |
| `projects/transition_overlap.json` | 999 | `ba3d86cfc591056b46100a053285675e6cddb89013bceccf69428a0579eef430` |

`corpus-manifest.json` carries the authoritative full hashes for every asset (this table truncates a few for readability). If they ever disagree, the manifest wins and the test fails.

## 4. Required-shape coverage (roadmap §5)

| Required fixture | Realized as | Committed real media? |
|---|---|---|
| 44.1 kHz tone | `audio/tone_44100hz.wav` | yes (PCM16) |
| 48 kHz tone | `audio/tone_48000hz.wav` | yes (PCM16) |
| 96 kHz tone | `audio/tone_96000hz.wav` | yes (PCM16) |
| **silent video** | `video/silent_video/frame_000..005.ppm` | **yes — real deterministic frame sequence** |
| **video with known-present audio** | `video/video_with_audio/frame_000..005.ppm` + `video/video_with_audio/audio.wav` | **yes — real frames + real committed 48 kHz PCM** |
| corrupt media | `descriptors/corrupt_media.json` + `corrupt_media.bin` | yes (committed invalid blob) |
| missing media | `descriptors/missing_media.json` | yes (intentionally-absent file) |
| 6-video stress | `projects/stress_6_video.json` | descriptor (project shape) |
| 10-video stress | `projects/stress_10_video.json` | descriptor |
| 20-video stress | `projects/stress_20_video.json` | descriptor |
| transition-overlap | `projects/transition_overlap.json` | descriptor (centered window) |

The silent-audio WAV (`silent_48000hz.wav`) additionally backs the "no-audio epoch → monotonic host master" path (ADR-006 §3). The stress/transition cases are project **descriptors** by nature — they describe a multi-layer project shape, not a single clip — and each references the real `video_with_audio` fixture as its per-layer source.

## 5. How it is regenerated / verified

```bash
# regenerate audio + frames + descriptors + manifest in place (idempotent, byte-stable):
python3 Docs/AnimiEngineNext/media-corpus/generate_corpus.py

# verify the committed corpus is byte-identical to a fresh regeneration (writes nothing):
python3 Docs/AnimiEngineNext/media-corpus/generate_corpus.py --check     # → CHECK OK

# device-free / AVFoundation-free contract test:
cd AnimiEngineNext && swift test --filter MediaCorpusManifestTests
```

Determinism was confirmed empirically: two independent full regenerations and one `--check` all produced identical hashes; the Swift test's hand-rolled SHA-256 matches system `shasum -a 256` and Python `hashlib` exactly.

## 6. Why the video fixture is a frame sequence, not a single encoded clip (resolved)

This was investigated empirically before settling the fixture form:

- **AVFoundation H.264/HEVC output is not byte-deterministic** — encoding identical pixel input twice via `AVAssetWriter` produced differing container bytes (different SHA-256). Such bytes cannot be a committed hash-gated fixture.
- **`ffmpeg` is unavailable** (`command -v ffmpeg` → not found) — no external deterministic encoder.
- **A hand-rolled uncompressed container could not be made a *consumable* single clip from stdlib** — AVFoundation rejected an uncompressed RIFF AVI ("requires QuickTimeUserData"), and a hand-built uncompressed QuickTime `.mov` opened (`isReadable=true`, correct duration) but did not reliably expose its tracks; making a full deterministic QuickTime muxer is out of scope for a fixture corpus.

**Resolution (owner decision, 2026-06-26):** commit the canonical fixture as a deterministic **PPM P6 frame sequence** (real pixels) plus a committed **48 kHz PCM** track for the known-audio fixture (real audio samples). These are real media, byte-stable, stdlib-generated, and a future adapter can consume them directly. A single encoded `.mov`/`.mp4` clip is recorded as a **derived artifact** produced at the Slice-4 / device gate from these canonical inputs — it is **not** claimed to exist as a committed fixture, and the descriptors mark it `encodedArtifact: derivedForSlice4DeviceGate`.

This satisfies the roadmap §5 gate ("clean checkout contains all required fixtures") with **real committed media** for silent video and video-with-known-audio.

## 7. Which future gates consume this corpus

| Gate | Consumes |
|---|---|
| Slice 004 Stage B/C (sample-time mapping, chunk prep) | the 44.1/48/96 kHz tones + silent WAV (exact rate/sample-count metadata) |
| Slice 004 device A/V-sync / underrun gate | `video_with_audio` (frames + committed PCM; encoded on device as a derived artifact), `silent_video`, the tones |
| Slice 004 / Slice 6 stress gate | `stress_6/10/20_video` project descriptors (each references the real `video_with_audio` fixture) |
| Slice 004 transition-audio gate | `transition_overlap` (mix both, no implicit ramp; incoming hold silent; outgoing post-roll) |
| Required-audio failure gate (ADR-012 §9) | `corrupt_media` (typed decode failure), `missing_media` (typed unresolved failure) |
| Slice 5 export parity (later) | the same frames + tones, re-rendered offline for PCM probes |

## 8. Tests (device-free)

`AnimiEngineNext/Tests/AnimiEngineCoreTests/MediaCorpusManifestTests.swift` (6 cases, no AVFoundation, no device):

1. `testManifestAndGeneratorExist` — manifest + generator present.
2. `testEveryAssetExistsWithExpectedBytesAndHash` — every committed asset exists; byte count + SHA-256 match the manifest (byte-stability gate, all 26 assets).
3. `testAudioWavMetadataMatchesManifest` — every WAV header parses; sample-rate / channels / PCM16 / sample-count match the manifest (5 audio assets).
4. `testRealVideoFrameSequenceFixtures` — both video fixtures have 6 contiguous PPM frames at the manifest dimensions with raw-RGB body size; the known-audio `audio.wav` is real 48 kHz PCM of exactly 1.0 s; descriptors reference the real frame dirs and mark the encoded clip as derived.
5. `testRequiredCorpusShapeIsPresent` — all roadmap-§5 required fixtures present (including the real frame/audio paths).
6. `testStressProjectDescriptorLayerCounts` — 6/10/20 stress descriptors carry the exact layer counts.

The SHA-256 and PPM/WAV header parsers are small test-local implementations (SHA validated against system `shasum`), so the test depends on nothing beyond `Foundation`/`XCTest`.

## 9. Scope guarantees

- **No `AnimiApp/` change.** No `Package.swift` / `*.xcodeproj` / `.xcscheme` change. No existing `ReferenceData/` change.
- **No Slice-004 code.** No AVFoundation/realtime/app-integration code. No production engine code touched.
- **No external/downloaded media.** Every byte is generated locally from constants or is a committed invalid stub.
- New/changed files only: the `media-corpus/` directory (generator + manifest + assets), this document, and one test file. Nothing staged or committed.

## 10. B2 verdict

**B2 (deterministic media corpus) is CLOSED.** A clean checkout contains all roadmap-§5 required fixtures as real committed, byte-stable, deterministically-regenerable media: audio tones + silence, real silent-video and known-audio-video frame sequences with a committed PCM track, corrupt + missing fixtures, and stress + transition-overlap project descriptors — all hash-verified by a device-free test. The only non-committed item is the *encoded single-file clip*, which is explicitly a derived Slice-4/device artifact, not a required committed fixture.
