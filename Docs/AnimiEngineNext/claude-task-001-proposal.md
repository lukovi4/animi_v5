# Claude Code Task 001 - Isolated Engine Skeleton and Evidence Foundation

Status: **PLANNING AUTHORIZED - CODE NOT YET AUTHORIZED**

## Objective

Create the isolated development and test foundation for `AnimiEngineNext`.
Implement no video decoder, renderer, proxy, cache, audio or export behavior.

## Preconditions

- Decisions D-101, D-102, D-103, D-105, D-106, D-107, D-109 and D-110 are approved.
- Decisions still marked pending must not be assumed or implemented.
- The current working-tree changes are preserved.

## Allowed scope

- Add a new isolated `AnimiEngineNext/` package.
- Add a minimal physical-device benchmark host if approved.
- Add typed configuration and validation.
- Add structured benchmark-run manifests and event recording.
- Add test fixtures that identify current real templates.
- Add unit tests for configuration and evidence-file determinism.
- Add documentation for running tests.

## Forbidden scope

- Do not edit current playback, renderer, export, project or UI code.
- Do not replace or refactor `TVECore`.
- Do not implement AVPlayer, VideoToolbox, Metal rendering, proxy or cache code.
- Do not choose default decoder counts, codecs, resolutions or thresholds.
- Do not create hidden constants that bypass configuration.
- Do not alter current template assets.

## Proposed package targets

Pending ADR approval:

- `AnimiEngineNext` - public engine contracts and configuration.
- `AnimiEngineDiagnostics` - structured events and run artifacts.
- `AnimiEngineTestSupport` - fixtures and deterministic test utilities.
- `AnimiEngineNextTests` - pure unit tests.

## Required configuration contract

Configuration must be versioned and include explicit placeholders for:

- project frame rate;
- preview frame-rate ladder;
- decoder backend and pool limits;
- proxy profiles;
- cache profiles;
- render quality profiles;
- memory limits;
- export profiles;
- diagnostics sampling and output.

Unknown fields, invalid ranges and unsupported schema versions must fail with
clear typed errors.

No performance default is declared “optimal.”

## Required evidence contract

One run creates an immutable directory containing at least:

- `run-manifest.json`;
- `engine-config.json`;
- `device.json`;
- `events.ndjson`;
- `summary.json`;
- `failures.json`.

Serialization must be stable enough for deterministic tests. Every event must
carry run ID, monotonic timestamp, subsystem, event type and structured fields.

## Real-template fixture index

The test-support target must discover or explicitly index:

- `full_image`;
- `polaroid_shared_demo`;
- `polaroid_2`;
- `example_4blocks`;
- `6_frames_template`.

The task only proves that fixtures can be identified and hashed. It does not
load or render them.

## Acceptance criteria

1. Existing product source files are unchanged.
2. New package builds independently.
3. Unit tests pass.
4. Identical configuration produces an identical configuration hash.
5. Each test run writes a complete manifest and closes it with success/failure.
6. Events are structured and machine-readable.
7. Real-template fixture IDs and content hashes are recorded.
8. Invalid configuration is rejected by tests.
9. No media-engine implementation is added.
10. Claude Code provides changed-file list, commands, test output and known gaps.

## Required Claude Code response

Before writing code, Claude Code must return:

- its implementation plan;
- exact files it intends to create or modify;
- confirmation that current engine files remain untouched;
- open conflicts with the approved ADRs.

Implementation begins only after that plan is reviewed and explicitly accepted
by the technical lead.
