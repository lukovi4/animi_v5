# Animi Review Checklist

## Plan Compliance

- [ ] `plan.approved.md` exists and has `Status: APPROVED`.
- [ ] `codex-plan-review.md` exists and has `Status: APPROVED`.
- [ ] Live marker or `claude-summary.md` marker snapshot identifies the implementation scope.
- [ ] Claude stayed inside scope.
- [ ] Claude changed only paths allowed by the implementation marker.
- [ ] Claude did not change product behavior beyond approved decisions.
- [ ] Claude did not edit Codex-owned task artifacts.

## Tests First

- [ ] Tests match the risk of the change.
- [ ] Behavior tests are preferred over implementation-coupled tests.
- [ ] Red/green evidence is present when applicable.
- [ ] Missing tests are called out as findings or accepted risk.

## Correctness

- [ ] The changed behavior matches the approved goal.
- [ ] Edge cases from the plan are covered.
- [ ] Failure paths and validation behavior are preserved.
- [ ] Existing dirty worktree changes were not reverted.

## Architecture

- [ ] `TVECore` runtime boundaries are preserved.
- [ ] Preview/export parity is preserved when relevant.
- [ ] Timeline and scene-edit modes are considered when relevant.
- [ ] Persistence, undo/redo, normalization, and roundtrip risk is checked when touched.
- [ ] UserMedia, trim, and `VideoFrameProvider` changes have focused verification.

## Verification

- [ ] Claude summary lists exact commands.
- [ ] Results are passed/failed/not run, not "should pass".
- [ ] Bulky logs are in `artifacts/`.
- [ ] Heavy rerun decision is justified.

## Output

Write `codex-review.md` using `../../../Docs/agents/review-template.md`.
