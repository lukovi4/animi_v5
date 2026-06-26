#!/usr/bin/env python3
"""
Slice 3.5 — deterministic media corpus generator.

Roadmap §5 requires a legally-safe, deterministic, byte-stable media corpus
committed before any runtime/device gate. This generator is the single source
of truth for that corpus. It uses ONLY the Python standard library, performs no
network access, and embeds no third-party/downloaded media. Every byte it emits
is a pure function of constants in this file, so re-running it reproduces
byte-identical output (verified by the committed SHA256 hashes in
`corpus-manifest.json` and by `MediaCorpusManifestTests`).

What is generated here:
  * Audio tones at 44.1 / 48 / 96 kHz (canonical PCM16 mono WAV) + a silent WAV.
    Audio is byte-deterministic and IS committed.
  * Canonical JSON descriptors for video fixtures (silent video, known-audio
    video, corrupt, missing) and stress/transition-overlap PROJECT descriptors
    (6 / 10 / 20 video layers, transition-overlap).

Why no encoded video bytes are committed:
  Encoded H.264/HEVC output from AVFoundation is NOT byte-deterministic (verified
  empirically: identical pixel input → differing container bytes across runs),
  and `ffmpeg` is not available in this environment. A canonical, committed,
  byte-stable encoded clip is therefore impossible here without an external
  deterministic encoder. Slice 3.5 commits the deterministic AUDIO corpus plus
  deterministic video/project DESCRIPTORS; the encoded clips themselves are a
  device/Slice-4 generated-on-demand artifact (see the manifest + the
  slice-003.5 document for the exact gate ownership). This keeps the committed
  corpus legally safe and byte-stable while still pinning every fixture's
  intended metadata and expected behavior.

Usage:
  python3 generate_corpus.py            # regenerate audio + descriptors in place
  python3 generate_corpus.py --check    # regenerate to a temp dir and diff hashes
                                         # against corpus-manifest.json (no writes)

This file changes NOTHING outside Docs/AnimiEngineNext/media-corpus/.
"""

import argparse
import hashlib
import json
import math
import os
import struct
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))

# ---- Canonical constants (the ONLY inputs; changing them changes the hashes) ----

TONE_FREQ_HZ = 440.0          # A4; an arbitrary fixed, legally-neutral tone.
TONE_DURATION_S = 0.25        # short, repo-friendly.
TONE_AMPLITUDE = 0.5          # -6 dBFS, well below clipping.
SILENT_DURATION_S = 0.25
SILENT_SAMPLE_RATE = 48000

AUDIO_SPECS = [
    # (filename,        sample_rate, freq,        duration,        amplitude)
    ("tone_44100hz.wav", 44100,      TONE_FREQ_HZ, TONE_DURATION_S, TONE_AMPLITUDE),
    ("tone_48000hz.wav", 48000,      TONE_FREQ_HZ, TONE_DURATION_S, TONE_AMPLITUDE),
    ("tone_96000hz.wav", 96000,      TONE_FREQ_HZ, TONE_DURATION_S, TONE_AMPLITUDE),
    ("silent_48000hz.wav", SILENT_SAMPLE_RATE, 0.0, SILENT_DURATION_S, 0.0),
]


def render_pcm16_mono_wav(sample_rate, freq, duration_s, amplitude):
    """Deterministic canonical PCM16 mono WAV. Returns the full file bytes."""
    n = int(round(sample_rate * duration_s))
    samples = bytearray()
    for i in range(n):
        if amplitude == 0.0 or freq == 0.0:
            v = 0
        else:
            v = int(round(amplitude * 32767.0 * math.sin(2.0 * math.pi * freq * i / sample_rate)))
            v = max(-32768, min(32767, v))
        samples += struct.pack("<h", v)
    byte_rate = sample_rate * 2
    block_align = 2
    header = b"RIFF" + struct.pack("<I", 36 + len(samples)) + b"WAVE"
    header += b"fmt " + struct.pack("<IHHIIHH", 16, 1, 1, sample_rate, byte_rate, block_align, 16)
    header += b"data" + struct.pack("<I", len(samples))
    return header + bytes(samples)


def sha256_hex(blob: bytes) -> str:
    return hashlib.sha256(blob).hexdigest()


# ---- Real video fixtures: deterministic frame sequence (PPM P6) + committed PCM ----
#
# Owner decision (2026-06-25): the canonical committed video fixture is a deterministic,
# byte-stable IMAGE SEQUENCE (PPM P6 frames) plus, for the audio-bearing fixture, a
# committed 48 kHz PCM16 WAV. These are REAL media fixtures (actual pixels + actual audio
# samples) — not descriptors. A single ENCODED .mov/.mp4 clip is a DERIVED artifact for the
# Slice-4 / device gate, not the canonical committed fixture (encoders are non-deterministic
# and ffmpeg is unavailable; see the slice-003.5 document). PPM P6 is chosen because its
# binary header + raw RGB body are a pure function of the pixels, so the bytes are stable and
# a future adapter can trivially consume them.

VIDEO_FIXTURE_WIDTH = 32
VIDEO_FIXTURE_HEIGHT = 32
VIDEO_FIXTURE_FPS = 6
VIDEO_FIXTURE_FRAMES = 6


def render_ppm_frame(width, height, frame_index):
    """Deterministic PPM P6 (binary) RGB frame. Pure function of (width,height,frame_index)."""
    header = b"P6\n%d %d\n255\n" % (width, height)
    body = bytearray()
    for y in range(height):
        for x in range(width):
            r = (frame_index * 32) & 0xff
            g = (y * 4 + frame_index * 8) & 0xff
            b = (x * 4 + frame_index * 16) & 0xff
            body += bytes((r, g, b))
    return header + bytes(body)


# ---- Video / project DESCRIPTORS (deterministic JSON; canonical sorted bytes) ----

def canonical_json_bytes(obj) -> bytes:
    """Deterministic JSON encoding: sorted keys, compact, trailing newline."""
    return (json.dumps(obj, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def video_descriptors():
    """
    Canonical descriptors for the video fixtures. The silent / known-audio fixtures point at
    REAL committed frame-sequence + PCM data (see `framesDir` / `audioFile`); the descriptor
    only records metadata and expected runtime behavior. The `encodedArtifact` field states
    that a single ENCODED .mov/.mp4 clip is a DERIVED artifact for the Slice-4 / device gate,
    NOT the canonical committed fixture (encoders are non-deterministic; ffmpeg unavailable).
    """
    return {
        "silent_video.json": {
            "kind": "video",
            "role": "silentVideo",
            "width": VIDEO_FIXTURE_WIDTH, "height": VIDEO_FIXTURE_HEIGHT,
            "frameRate": VIDEO_FIXTURE_FPS,
            "frameCount": VIDEO_FIXTURE_FRAMES,
            "hasAudioTrack": False,
            "fixtureForm": "frameSequencePPM",
            "framesDir": "video/silent_video",
            "expectedBehavior": "Authoritatively audioless video: contributes legitimate silence "
                                "(ADR-012 §9). Absence of an audio track is NOT a decode failure. "
                                "Canonical committed fixture is the PPM frame sequence in framesDir.",
            "encodedArtifact": "derivedForSlice4DeviceGate",
        },
        "video_with_audio.json": {
            "kind": "video",
            "role": "videoWithKnownAudio",
            "width": VIDEO_FIXTURE_WIDTH, "height": VIDEO_FIXTURE_HEIGHT,
            "frameRate": VIDEO_FIXTURE_FPS,
            "frameCount": VIDEO_FIXTURE_FRAMES,
            "hasAudioTrack": True,
            "audioSampleRate": 48000, "audioChannels": 1,
            "fixtureForm": "frameSequencePPM+PCM",
            "framesDir": "video/video_with_audio",
            "audioFile": "video/video_with_audio/audio.wav",
            "expectedBehavior": "Video with a known-present audio stream: the project adapter creates a "
                                "default unmuted unity-gain video-layer audio clip (ADR-012 §1.2). "
                                "Missing/undecodable required audio must fail typed, never silently silence. "
                                "Canonical committed fixture is the PPM frame sequence + committed PCM WAV.",
            "encodedArtifact": "derivedForSlice4DeviceGate",
        },
        "corrupt_media.json": {
            "kind": "corrupt",
            "role": "corruptMedia",
            "expectedBehavior": "Required media that is present but undecodable: produces a typed error "
                                "with source identity and stage (ADR-012 §9). Preview pauses/fails per "
                                "ADR-006; export fails atomically. Never silently substituted.",
            # A tiny, deterministic, intentionally-invalid byte blob committed verbatim
            # (see corrupt_media.bin). Not real media; cannot be a copyright concern.
            "encodedArtifact": "committedInvalidBlob",
            "blobFile": "corrupt_media.bin",
        },
        "missing_media.json": {
            "kind": "missing",
            "role": "missingMedia",
            "expectedBehavior": "Required media reference that resolves to no file at all: typed "
                                "unresolved/missing failure (ADR-012 §9, §1.0b). A legitimately silent "
                                "video is the ABSENCE of an audio clip, never a failed resolution.",
            "encodedArtifact": "intentionallyAbsent",
        },
    }


def _video_layer(index):
    return {
        "layerIndex": index,
        "source": "video_with_audio.json",
        "destinationStartTicks": 0,
        "destinationEndTicks": 240000,   # 1.0 s at 240000 ticks/s
        "muted": False,
        "gain": 1000000,                 # unity (AudioGain integer scale, ADR-012 §1)
    }


def project_descriptors():
    """
    Deterministic stress / transition-overlap PROJECT descriptors. These pin the
    canonical structure (layer counts, time ranges, transition window) future
    Slice-4/6 device gates instantiate. Integer/rational time only — no Float.
    """
    def stress(n):
        return {
            "kind": "stressProject",
            "videoLayerCount": n,
            "projectDurationTicks": 240000,
            "frameRateNumerator": 30, "frameRateDenominator": 1,
            "allLayersUnmutedByDefault": True,
            "layers": [_video_layer(i) for i in range(n)],
            "expectedBehavior": (
                "%d simultaneous unmuted video-audio layers all mix (ADR-012 §1, D-019/D-020). "
                "Bounded memory/queues required under this load (ADR-006 §9). The published frame "
                "is ONE synchronized composition or nothing new (ADR-005 §6)." % n
            ),
        }

    overlap = {
        "kind": "transitionOverlapProject",
        "videoLayerCount": 2,
        "projectDurationTicks": 240000,
        "frameRateNumerator": 30, "frameRateDenominator": 1,
        # Centered transition window around boundary B (ADR-012 §1.0a, D-006/D-016).
        "transitionBoundaryTicks": 120000,
        "transitionWindowStartTicks": 96000,
        "transitionWindowEndTicks": 144000,
        "outgoing": {
            "layerIndex": 0, "source": "video_with_audio.json",
            "sceneStartTicks": 0,
            "destinationStartTicks": 0, "destinationEndTicks": 144000,
            "muted": False, "gain": 1000000,
            "note": "Outgoing continues into the post-roll at normal speed (ADR-012 §1.0a item 5b).",
        },
        "incoming": {
            "layerIndex": 1, "source": "video_with_audio.json",
            "sceneStartTicks": 120000,
            # destination.start >= B (incoming pre-boundary hold is silent, §1.0a item 5a).
            "destinationStartTicks": 120000, "destinationEndTicks": 240000,
            "muted": False, "gain": 1000000,
            "note": "Incoming is silent during the pre-boundary hold; destination.start == B.",
        },
        "expectedBehavior": (
            "Both temporally active unmuted sources mix during the overlap with NO implicit "
            "crossfade/duck/ramp (ADR-012 §2). Incoming pre-boundary interval is silent; outgoing "
            "post-roll may continue (ADR-012 §1.0a items 5a/5b)."
        ),
    }

    return {
        "stress_6_video.json": stress(6),
        "stress_10_video.json": stress(10),
        "stress_20_video.json": stress(20),
        "transition_overlap.json": overlap,
    }


def corrupt_blob() -> bytes:
    """
    A deterministic, intentionally-invalid 'media' blob. It is NOT real media:
    a fake/unknown 4-byte magic followed by fixed filler. Cannot decode; cannot
    be a copyright concern. Committed verbatim so the corrupt path is exercisable
    without any encoder.
    """
    return b"\x00CRPT" + bytes(range(0, 60))  # 65 bytes, fixed content


# ---- Build / check ----

def build(out_root, write):
    """Generate every asset; return an ordered manifest list of dicts."""
    assets = []

    audio_dir = os.path.join(out_root, "audio")
    desc_dir = os.path.join(out_root, "descriptors")
    proj_dir = os.path.join(out_root, "projects")
    video_silent_dir = os.path.join(out_root, "video", "silent_video")
    video_audio_dir = os.path.join(out_root, "video", "video_with_audio")
    if write:
        for d in (audio_dir, desc_dir, proj_dir, video_silent_dir, video_audio_dir):
            os.makedirs(d, exist_ok=True)

    # Audio (committed, byte-stable).
    for (name, sr, freq, dur, amp) in AUDIO_SPECS:
        blob = render_pcm16_mono_wav(sr, freq, dur, amp)
        path = os.path.join("audio", name)
        if write:
            with open(os.path.join(out_root, path), "wb") as f:
                f.write(blob)
        n_samples = int(round(sr * dur))
        assets.append({
            "path": path, "category": "audio",
            "sampleRate": sr, "channels": 1, "bitsPerSample": 16,
            "durationSeconds": dur, "sampleCount": n_samples,
            "byteCount": len(blob), "sha256": sha256_hex(blob),
            "committed": True, "generator": "render_pcm16_mono_wav",
        })

    # Real video fixtures — deterministic PPM frame sequences (owner decision 2026-06-25).
    # silent_video: frames only (no audio track → legitimate silence).
    for i in range(VIDEO_FIXTURE_FRAMES):
        blob = render_ppm_frame(VIDEO_FIXTURE_WIDTH, VIDEO_FIXTURE_HEIGHT, i)
        path = os.path.join("video", "silent_video", "frame_%03d.ppm" % i)
        if write:
            with open(os.path.join(out_root, path), "wb") as f:
                f.write(blob)
        assets.append({
            "path": path, "category": "videoFrame", "fixture": "silent_video",
            "frameIndex": i, "width": VIDEO_FIXTURE_WIDTH, "height": VIDEO_FIXTURE_HEIGHT,
            "byteCount": len(blob), "sha256": sha256_hex(blob),
            "committed": True, "generator": "render_ppm_frame",
        })

    # video_with_audio: identical frame sequence + a committed 48 kHz PCM track whose duration
    # matches the frame sequence (frameCount / fps), so the known-present audio is REAL committed data.
    for i in range(VIDEO_FIXTURE_FRAMES):
        blob = render_ppm_frame(VIDEO_FIXTURE_WIDTH, VIDEO_FIXTURE_HEIGHT, i)
        path = os.path.join("video", "video_with_audio", "frame_%03d.ppm" % i)
        if write:
            with open(os.path.join(out_root, path), "wb") as f:
                f.write(blob)
        assets.append({
            "path": path, "category": "videoFrame", "fixture": "video_with_audio",
            "frameIndex": i, "width": VIDEO_FIXTURE_WIDTH, "height": VIDEO_FIXTURE_HEIGHT,
            "byteCount": len(blob), "sha256": sha256_hex(blob),
            "committed": True, "generator": "render_ppm_frame",
        })
    va_sr = 48000
    va_dur = VIDEO_FIXTURE_FRAMES / float(VIDEO_FIXTURE_FPS)   # exact: 6/6 = 1.0 s
    va_blob = render_pcm16_mono_wav(va_sr, TONE_FREQ_HZ, va_dur, TONE_AMPLITUDE)
    va_path = os.path.join("video", "video_with_audio", "audio.wav")
    if write:
        with open(os.path.join(out_root, va_path), "wb") as f:
            f.write(va_blob)
    assets.append({
        "path": va_path, "category": "audio", "fixture": "video_with_audio",
        "sampleRate": va_sr, "channels": 1, "bitsPerSample": 16,
        "durationSeconds": va_dur, "sampleCount": int(round(va_sr * va_dur)),
        "byteCount": len(va_blob), "sha256": sha256_hex(va_blob),
        "committed": True, "generator": "render_pcm16_mono_wav",
    })

    # Corrupt blob (committed verbatim).
    cblob = corrupt_blob()
    cpath = os.path.join("descriptors", "corrupt_media.bin")
    if write:
        with open(os.path.join(out_root, cpath), "wb") as f:
            f.write(cblob)
    assets.append({
        "path": cpath, "category": "corrupt",
        "byteCount": len(cblob), "sha256": sha256_hex(cblob),
        "committed": True, "generator": "corrupt_blob",
    })

    # Video descriptors.
    for name, obj in sorted(video_descriptors().items()):
        blob = canonical_json_bytes(obj)
        path = os.path.join("descriptors", name)
        if write:
            with open(os.path.join(out_root, path), "wb") as f:
                f.write(blob)
        assets.append({
            "path": path, "category": "videoDescriptor",
            "byteCount": len(blob), "sha256": sha256_hex(blob),
            "committed": True, "generator": "video_descriptors",
        })

    # Project descriptors.
    for name, obj in sorted(project_descriptors().items()):
        blob = canonical_json_bytes(obj)
        path = os.path.join("projects", name)
        if write:
            with open(os.path.join(out_root, path), "wb") as f:
                f.write(blob)
        assets.append({
            "path": path, "category": "projectDescriptor",
            "byteCount": len(blob), "sha256": sha256_hex(blob),
            "committed": True, "generator": "project_descriptors",
        })

    return assets


def write_manifest(out_root, assets):
    manifest = {
        "schema": "slice-3.5-media-corpus/v1",
        "generator": "generate_corpus.py",
        "toneFrequencyHz": TONE_FREQ_HZ,
        "note": "Deterministic, locally generated, legally-safe, byte-stable. The canonical committed "
                "video fixtures are PPM frame sequences (silent_video, video_with_audio) plus a committed "
                "48 kHz PCM track for video_with_audio. A single ENCODED .mov/.mp4 clip is a DERIVED "
                "artifact for the Slice-4 / device gate (encoders are not byte-deterministic / ffmpeg "
                "unavailable), not the canonical committed fixture.",
        "assetCount": len(assets),
        "assets": assets,
    }
    blob = canonical_json_bytes(manifest)
    path = os.path.join(out_root, "corpus-manifest.json")
    with open(path, "wb") as f:
        f.write(blob)
    return path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="regenerate to a temp dir and verify hashes against the committed manifest")
    args = ap.parse_args()

    if args.check:
        manifest_path = os.path.join(HERE, "corpus-manifest.json")
        if not os.path.exists(manifest_path):
            print("FAIL: corpus-manifest.json missing", file=sys.stderr)
            return 2
        with open(manifest_path, "rb") as f:
            committed = json.loads(f.read())
        with tempfile.TemporaryDirectory() as tmp:
            regenerated = build(tmp, write=False)
        by_path = {a["path"]: a for a in regenerated}
        ok = True
        for a in committed["assets"]:
            r = by_path.get(a["path"])
            if r is None:
                print("FAIL: missing in regeneration:", a["path"]); ok = False; continue
            if r["sha256"] != a["sha256"]:
                print("FAIL: hash drift:", a["path"], a["sha256"], "->", r["sha256"]); ok = False
        if len(regenerated) != len(committed["assets"]):
            print("FAIL: asset count drift", len(committed["assets"]), "->", len(regenerated)); ok = False
        print("CHECK OK" if ok else "CHECK FAILED")
        return 0 if ok else 1

    assets = build(HERE, write=True)
    mpath = write_manifest(HERE, assets)
    print("Wrote %d assets + %s" % (len(assets), os.path.basename(mpath)))
    for a in assets:
        print("  %-40s %s %d bytes" % (a["path"], a["sha256"][:16], a["byteCount"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
