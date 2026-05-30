---
name: review-animi-claude-plan
description: Review Claude's claude-plan.md before implementation. Use after Claude completes the Animi Planning Pass, or when the user asks Codex to approve, reject, or verify Claude's implementation plan before code changes.
---

# Review Animi Claude Plan

Use this skill before any Claude implementation pass.

## Ground Rules

- Review `claude-plan.md` against `plan.approved.md`, not chat memory.
- Do not approve scope expansion, new product decisions, new files, or weaker verification.
- Do not create an implementation marker from this skill. Marker creation happens only after user implementation approval.
- Findings come first when blocking.

## Required Inputs

- `.codex-local/tasks/<task-id>/plan.approved.md`
- `.codex-local/tasks/<task-id>/claude-task.md`
- `.codex-local/tasks/<task-id>/claude-plan.md`
- `../../../Docs/agents/codex-plan-review-template.md`

If any required input is missing, write `codex-plan-review.md` with `Status: BLOCKED`.

## Workflow

1. Read `plan.approved.md`.
2. Read `claude-task.md`.
3. Read `claude-plan.md`.
4. Check planned files against approved scope.
5. Check planned tests and verification against risk.
6. Check that Claude introduced no product behavior, architecture, dependency, CI, git, hook, or project-file decision.
7. Write `codex-plan-review.md` using `../../../Docs/agents/codex-plan-review-template.md`.

## Status Rules

- `APPROVED`: plan is inside approved scope and ready for user implementation approval.
- `CHANGES_REQUESTED`: plan is close but needs Claude revision.
- `BLOCKED`: missing inputs, product decision needed, scope conflict, or unsafe implementation path.

If the review is `APPROVED`, do not tell Claude to implement with a prose prompt. After explicit user implementation approval and marker creation, give the user this exact slash command:

```text
/animi-implement-approved-plan .codex-local/tasks/<task-id>
```
