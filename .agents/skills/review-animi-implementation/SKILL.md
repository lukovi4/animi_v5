---
name: review-animi-implementation
description: Review Claude implementation against an approved Animi plan. Use after Claude writes code, claude-summary.md, and codex-review-packet.md, or when the user asks Codex to review, verify, approve, or request fixes for Claude's work.
---

# Review Animi Implementation

Use this skill to perform Codex technical-lead review after Claude work.

## Ground Rules

- Findings first.
- Review against `task-contract.md`, not chat memory.
- Start from `codex-review-packet.md` and then perform risk-based targeted checks.
- Tests and verification evidence are reviewed before code style.
- Do not approve plausibility; require evidence or accepted risk.
- Do not rerun heavy checks unless risk, missing evidence, or findings justify it.

## Required Inputs

- `.codex-local/tasks/<task-id>/task-contract.md`
- `.codex-local/tasks/<task-id>/claude-plan.md`
- `.codex-local/tasks/<task-id>/codex-plan-review.md`
- `.codex-local/tasks/<task-id>/claude-summary.md`
- `.codex-local/tasks/<task-id>/codex-review-packet.md` for revised-workflow tasks; for legacy tasks, a missing packet must be treated as a review finding, accepted risk, or reason to ask Claude for a packet before deep review
- `.codex-local/tasks/<task-id>/codex-analysis.md` when present
- `.codex-local/active-implementation.json` if still present, or the marker snapshot recorded in `claude-summary.md`
- changed-file stats/names and relevant focused hunks selected from packet risk

If required gate files are missing, review is blocked. For legacy tasks without `codex-review-packet.md`, either document the missing packet as accepted risk or ask Claude for a packet before deep review.

## Required References

Read only the sections needed:

- `../../../Docs/agents/workflow.md`
- `../../../Docs/agents/review-template.md`
- `../../../Docs/agents/claude-summary-template.md`
- `../../../Docs/agents/codex-review-packet-template.md`
- `review-checklist.md`

## Workflow

1. Identify changed files with stats/names first.
2. Read `task-contract.md`.
3. Read `claude-plan.md`, `codex-plan-review.md`, `claude-summary.md`, and `codex-review-packet.md` when present.
4. Read `codex-analysis.md` when present and use it to focus review on recorded invariants, root-cause assumptions, and future-review targets.
5. Confirm `codex-plan-review.md` approved the plan before implementation.
6. Compare implementation to contracted scope using the live marker or summary marker snapshot for task authorization context.
7. Assess packet completeness. Missing changed files, missing verification evidence, vague risk hotspots, or broad full-file spot checks are review findings unless explicitly accepted risk.
8. Select review depth:
   - Low: packet, summary, stats/names, and focused spot checks.
   - Medium: packet, summary, focused hunks, relevant tests, and affected invariants.
   - High: targeted deep review of changed behavior, dependencies, and verification evidence.
9. Review tests first.
10. Review correctness and edge cases.
11. Review architecture invariants.
12. Review verification evidence.
13. Decide whether heavy checks need rerun.
14. Decide whether manual QA is required. If yes, provide exact steps and expected results.
15. Check code cleanliness: no obsolete files, no unused legacy paths introduced by the task, no unrelated churn.
16. Decide whether docs or knowledge maps need updates.
17. Determine commit readiness:
    - list commit-ready files for this task;
    - list unrelated dirty files that must not be committed;
    - if approved and manual QA is complete/not required, tell the user to write `commit` to create a scoped commit.
18. Write `codex-review.md`.

## Verdicts

Use one:

- `Approved`
- `Changes Requested`
- `Blocked`
- `Needs User Decision`
- `Manual QA Pending`

Do not close while P0/P1 findings remain open.

If fixes are required and they stay inside the same approved product scope, keep the same task open. Do not create a new task for same-scope repairs. Update the review with `Repair Instructions For Claude`, refresh the marker when needed, then send Claude back through `/animi-implement-task <task-folder>`.

If three same-symptom implementation or repair attempts fail, stop the repair loop and require a new Codex/user architecture or product decision instead of sending Claude through another same-scope patch.

Do not auto-commit after approval. Commit only after the user explicitly writes `commit`, and stage only the commit-ready files listed in the review.
