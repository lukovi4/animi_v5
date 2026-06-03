# Animi Review Checklist

## Plan Compliance

- [ ] `task-contract.md` exists and has `Status: Approved`.
- [ ] `codex-plan-review.md` exists and has `Status: APPROVED`.
- [ ] Live marker or `claude-summary.md` marker snapshot identifies the task authorization context.
- [ ] `codex-review-packet.md` exists for the latest implementation or repair pass.
- [ ] `codex-analysis.md` was read when present.
- [ ] Claude stayed inside scope.
- [ ] Claude changed only files/actions needed for the task contract.
- [ ] Claude did not run deletion, destructive cleanup, git rollback cleanup, or unapproved tracked-file removal.
- [ ] Claude did not change product behavior beyond approved decisions.
- [ ] Claude did not edit Codex-owned task artifacts.

## Tests First

- [ ] Tests match the risk of the change.
- [ ] Behavior tests are preferred over implementation-coupled tests.
- [ ] Red/green evidence is present when applicable.
- [ ] Missing tests are called out as findings or accepted risk.

## Packet-First Review

- [ ] Packet lists every changed file with contract reason.
- [ ] Packet maps contract requirements and edge cases to implementation/test evidence.
- [ ] Packet identifies focused risk hotspots for Codex, not broad full-file review requests.
- [ ] Packet lists exact verification commands, results, and full-log artifact paths.
- [ ] Packet gaps are treated as findings or accepted risk.
- [ ] Review depth is recorded as Low, Medium, or High.

## Correctness

- [ ] The changed behavior matches the contracted goal.
- [ ] Edge cases from the task contract are covered.
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

## Manual QA

- [ ] Manual QA is marked required/not required.
- [ ] If required, exact steps and expected result are written for the user.
- [ ] If skipped, risk is explicitly accepted or not applicable.

## Same-Task Repair

- [ ] Fixable findings inside approved scope stay in this task.
- [ ] New task is used only for new product/architecture/scope decisions, uncontracted infrastructure/dependency/tooling/git-state changes, deletion/cleanup/rollback, or materially different implementation paths.
- [ ] Marker scope is refreshed only when needed for the same task.

## Closure

- [ ] Obsolete files/code introduced by the task are removed or justified.
- [ ] Required docs or knowledge-map updates are completed or explicitly unnecessary.
- [ ] Marker cleanup is handled.
- [ ] Commit-ready files for this task are listed.
- [ ] Unrelated dirty files are listed separately and excluded from commit.
- [ ] User is asked to write `commit` if they want Codex to create the scoped commit.

## Output

Write `codex-review.md` using `../../../Docs/agents/review-template.md`.
