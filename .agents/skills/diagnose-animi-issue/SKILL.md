---
name: diagnose-animi-issue
description: Diagnose Animi bugs, failing tests, flaky behavior, or regressions before proposing fixes. Use when the user reports something broken, tests fail, behavior diverges, or media/export/trim/persistence issues need root-cause investigation.
---

# Diagnose Animi Issue

Use this skill before fix planning when the failure mode is not proven.

## Ground Rules

- No guess-and-fix.
- Do not edit production code.
- Requests like `fix`, `implement`, `исправь`, `почини`, `найди и исправь`, or `сделай` are not permission for Codex production-code edits.
- Build or identify a feedback loop first.
- Reproduce before proposing a fix.
- Find root cause before proposing a fix. Symptom patches are not an acceptable diagnosis.
- State hypotheses before testing them.
- One variable at a time.
- If no correct test seam exists, record that as an architecture finding.

## Required References

Read only the sections needed:

- `../../../Docs/agents/workflow.md`
- `../../../Docs/agents/domain.md`
- `../../../Docs/agents/code-map.md`
- `../../../Docs/agents/regression-map.md`
- `../../../Docs/agents/codex-analysis-template.md`
- `reproduction-template.md`

## Workflow

1. Create or reuse a task folder.
2. Capture the observed symptom.
3. Build the smallest reliable reproduction or explain why it is not yet possible.
4. Identify the affected track: quick fix, feature/behavior, or architecture/media pipeline.
5. Trace backward from symptom to immediate cause, upstream trigger, and root-cause candidate.
6. Trace the relevant code path and adjacent dependencies before proposing a fix.
7. List 3-5 ranked hypotheses when the cause is unclear.
8. Test one hypothesis at a time. Do not stack speculative fixes or bundle unrelated changes.
9. Add targeted instrumentation only when needed and keep it temporary.
10. Convert the reproduction into a failing test when a valid seam exists.
11. Write or update `codex-analysis.md` with architecture trace, root-cause trace, hypotheses, invariants, risk areas, verification seams, and map-update candidates.
12. If the user explicitly asked for analysis only, produce a diagnosis summary or `claude-findings.md` handoff.
13. If the diagnosis points to production-code changes, continue into the `create-animi-plan` workflow and persist the result as `task-contract.md` with `Status: Pending User Approval`; do not leave the implementation scope only in chat.

## Special Animi Surfaces

Be stricter for:

- preview/export parity;
- UserMedia;
- trim/playback window;
- `VideoFrameProvider`;
- persistence/roundtrip;
- timeline vs scene-edit divergence.

## Stop Conditions

Stop and ask when:

- reproducing requires user-only environment access;
- product behavior is unclear;
- three fix attempts have already failed;
- three same-symptom fix or repair attempts have failed; stop treating it as a same-scope patch and raise an architecture/product decision;
- diagnosis requires changing production code before a `task-contract.md` is approved for Claude, or before the user gives a literal Codex production-code override.
