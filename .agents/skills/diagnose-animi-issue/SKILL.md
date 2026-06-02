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
- State hypotheses before testing them.
- One variable at a time.
- If no correct test seam exists, record that as an architecture finding.

## Required References

Read only the sections needed:

- `../../../Docs/agents/workflow.md`
- `../../../Docs/agents/domain.md`
- `../../../Docs/agents/code-map.md`
- `../../../Docs/agents/regression-map.md`
- `reproduction-template.md`

## Workflow

1. Create or reuse a task folder.
2. Capture the observed symptom.
3. Build the smallest reliable reproduction or explain why it is not yet possible.
4. Identify the affected track: quick fix, feature/behavior, or architecture/media pipeline.
5. Trace the relevant code path and adjacent dependencies before proposing a fix.
6. List 3-5 ranked hypotheses when the cause is unclear.
7. Add targeted instrumentation only when needed and keep it temporary.
8. Convert the reproduction into a failing test when a valid seam exists.
9. If the user explicitly asked for analysis only, produce a diagnosis summary or `claude-findings.md` handoff.
10. If the diagnosis points to production-code changes, continue into the `create-animi-plan` workflow and persist the result as `task-contract.md` with `Status: Pending User Approval`; do not leave the implementation scope only in chat.

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
- diagnosis requires changing production code before a `task-contract.md` is approved for Claude, or before the user gives a literal Codex production-code override.
