---
name: review-animi-implementation
description: Review Claude implementation against an approved Animi plan. Use after Claude writes code or fills claude-summary.md, or when the user asks Codex to review, verify, approve, or request fixes for Claude's work.
---

# Review Animi Implementation

Use this skill to perform Codex technical-lead review after Claude work.

## Ground Rules

- Findings first.
- Review against `plan.approved.md`, not chat memory.
- Tests and verification evidence are reviewed before code style.
- Do not approve plausibility; require evidence or accepted risk.
- Do not rerun heavy checks unless risk, missing evidence, or findings justify it.

## Required Inputs

- `.codex-local/tasks/<task-id>/plan.approved.md`
- `.codex-local/tasks/<task-id>/claude-plan.md`
- `.codex-local/tasks/<task-id>/codex-plan-review.md`
- `.codex-local/tasks/<task-id>/claude-summary.md`
- `.codex-local/active-implementation.json` if still present, or the marker snapshot recorded in `claude-summary.md`
- relevant diff/stat/focused hunks

If required files are missing, review is blocked.

## Required References

Read only the sections needed:

- `../../../Docs/agents/workflow.md`
- `../../../Docs/agents/review-template.md`
- `../../../Docs/agents/claude-summary-template.md`
- `review-checklist.md`

## Workflow

1. Identify changed files with stats/names first.
2. Read `plan.approved.md`.
3. Read `claude-plan.md`, `codex-plan-review.md`, and `claude-summary.md`.
4. Confirm `codex-plan-review.md` approved the plan before implementation.
5. Compare implementation to approved scope and marker-approved paths using the live marker or summary marker snapshot.
6. Review tests first.
7. Review correctness and edge cases.
8. Review architecture invariants.
9. Review verification evidence.
10. Decide whether heavy checks need rerun.
11. Write `codex-review.md`.

## Verdicts

Use one:

- `Approved`
- `Changes Requested`
- `Blocked`
- `Needs User Decision`

Do not close while P0/P1 findings remain open.
