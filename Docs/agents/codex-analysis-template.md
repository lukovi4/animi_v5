# Codex Analysis Template

Use this for `codex-analysis.md`.

`codex-analysis.md` is Codex-owned. It captures reusable investigation facts from the first deep audit so later gates can avoid repeating broad exploration. It is a routing and reasoning artifact, not source of truth; current code remains source of truth.

```markdown
# Codex Analysis: <title>

## Investigation Scope

- Task folder: `.codex-local/tasks/<task-id>`
- Analysis depth: Quick fix | Feature / behavior | Architecture / media pipeline
- Relevant knowledge maps checked: <domain/code-map/regression-map sections or "none">

## Architecture Trace

<short trace from user/system entry point through state/data flow to the likely implementation surface>

## Root Cause Trace

- Symptom: <observable failure or requested behavior gap>
- Immediate cause: <where the symptom manifests>
- Upstream trigger: <what sends the bad state/data/timing into that point>
- Root cause candidate: <current best evidence-backed cause, or "not proven yet">
- Evidence:
  - `<path>`: <symbol/line-range-level observation>

## Hypotheses

1. <hypothesis> - evidence for/against; status: open/rejected/likely
2. <hypothesis> - evidence for/against; status: open/rejected/likely

Use one hypothesis at a time when validating. Do not stack speculative fixes.

## Invariants

- <architecture/product invariant that must remain true>
- <preview/export, timeline/scene-edit, UserMedia, persistence, TVECore boundary, etc. when relevant>

## Risk Areas

- <risk>: <why it matters and how to check it>

## Files / Symbols Worth Future Review

- `<path>`: <symbol or focused range and why future Codex review should inspect it>

## Verification Seams

- `<command or test file>`: <what it can prove>
- Manual QA need: yes/no and why

## Open Decisions Or Stop Conditions

- <product/architecture/scope question, or "None">

## Reusable Map Updates

- Stable facts to add/update in `Docs/agents/code-map.md` or `Docs/agents/regression-map.md`: <list or "None">
```
