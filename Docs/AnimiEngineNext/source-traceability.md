# AnimiEngineNext Source Traceability

Status: **WORKING CONTROL DOCUMENT**

This matrix prevents a research statement, current-code behavior or engineering
proposal from silently becoming a product decision.

| Requirement or proposal | Source | Classification |
|---|---|---|
| New engine beside the current product | Product owner | Approved requirement |
| No incremental migration | Product owner | Approved requirement |
| No product UI during initial functional development | Product owner | Approved requirement |
| Real templates and animations are mandatory tests | Product owner | Approved requirement |
| Up to 20 animated videos in one scene | Product owner and system specification | Approved capability goal |
| 10 animated text blocks | Product owner and research | Approved capability goal |
| Centered transitions | Product owner and system specification | Approved behavior |
| Outgoing scene continues through slide completion | Product owner | Approved behavior |
| Transition does not change project duration | System specification, confirmed by owner description | Approved behavior |
| Global preview rate reduces together under overload | Product owner | Approved behavior |
| Zero stale, mixed or partial publications | System specification and both research reports | Approved invariant |
| Proxy-first preview | System specification and both research reports | Approved architecture direction |
| Central scheduler | System specification and both research reports | Approved architecture direction |
| Scene flattening/render cache | System specification and both research reports | Approved architecture direction |
| Rational time | System specification and both research reports | Approved architecture direction |
| Deterministic original-media export | System specification and both research reports | Approved invariant |
| Metal-first renderer | System specification and both research reports | Approved architecture direction |
| Independent Swift package | Technical-lead proposal | Pending approval |
| Minimal iOS benchmark host | Required for physical-device evidence; technical-lead proposal | Pending approval |
| Current `.tve` compatibility adapter | Current template format plus technical-lead proposal | Pending approval |
| Immutable `FramePlan` | Research v2 plus technical-lead proposal | Pending approval |
| Separate revision/request/cache identities | Gap found in system specification | Pending approval |
| AVFoundation or VideoToolbox backend | Research v2 | Benchmark decision |
| Proxy codec and levels | Research v2 | Benchmark decision |
| Cache format and chunk size | Research v2 gap | Benchmark decision |
| Decoder count | Research v2 and system specification | Benchmark decision |
| Device tiers | Research v2 and system specification | Benchmark decision |
| YUV/BGRA and high-precision boundaries | Research v2 | Benchmark decision |
| Text texture or glyph atlas strategy | Research v2 | Benchmark decision |
| Audio master clock and sample rate | Research v2 gap | ADR plus benchmark decision |

## Current repository evidence

- Five catalog templates exist.
- Current real-template media-block counts are 1, 1, 2, 4 and 6.
- Existing templates cover static and animated variants, masks, clipping and
  multiple block layouts.
- No test video or audio corpus is stored in the repository.
- No real template currently contains 10 or 20 video blocks.
- The current timeline persists microseconds.
- Current preview uses independent `AVPlayerItemVideoOutput` providers.
- Current active-scene policy has no fixed decoder cap.
- Current preview and export are primarily BGRA8.
- Existing diagnostics are useful but fragmented and not a complete immutable
  benchmark evidence system.

## Required new evidence

Before claiming that the new engine meets the product goal, the project needs:

- an approved and legally usable real media corpus;
- generated 10- and 20-video stress templates;
- a 20-to-20 transition case;
- a 10 animated text-block case;
- physical-device runs across approved device tiers;
- golden preview/export references for every real template;
- stored long-run memory and thermal results.

## Task 003 traceability closure (§17 step 18)

- **Implementation report:** `claude-task-003-implementation-report.md` (steps 1–17, deviations, gate
  G1–G9 mapping, audits).
- **Decisions:** `decision-register.md` §17 steps 1–18 (X*/Y*/Z*/W*/V* entries).
- **ADR:** `AnimiEngineNext/Docs/ADR-014` — "Reference Promotion & Comparison Closure" section is the
  §17-"ADR-010" deliverable (no separate ADR-010 file; the numbering mismatch is recorded in the report).
- **Approved evidence:** approved sealed run `694A5886-…`; approved references
  `AnimiEngineNext/ReferenceData/` (64 PNG + `approval-manifest.json`, tree `be021df5…`); obsolete run
  `2E4AED19-…`.
- **Isolation:** forbidden-tree byte-identical to the Step-15 snapshot (`a23d7cda…`); `Package.swift` +
  pbxproj unchanged; dependency-boundary tests pass.

