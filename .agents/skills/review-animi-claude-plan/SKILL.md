---
name: review-animi-claude-plan
description: Review Claude's claude-plan.md before implementation. Use after Claude completes the Animi Planning Pass, or when the user asks Codex to approve, reject, or verify Claude's implementation plan before code changes.
---

# Review Animi Claude Plan

Use this skill before any Claude implementation pass.

## Ground Rules

- Review `claude-plan.md` against `task-contract.md`, not chat memory.
- Do not approve scope expansion, new product decisions, files outside contracted scope, or weaker verification.
- If the plan is approved, create the implementation marker. Do not ask the user for a second approval unless a new decision is required.
- Findings come first when blocking.

## Required Inputs

- `.codex-local/tasks/<task-id>/task-contract.md`
- `.codex-local/tasks/<task-id>/claude-plan.md`
- `../../../Docs/agents/codex-plan-review-template.md`
- `../../../Docs/agents/marker-schema.md`

If any required input is missing, write `codex-plan-review.md` with `Status: BLOCKED`.

## Workflow

1. Read `task-contract.md`.
2. Read `claude-plan.md`.
3. Check planned files against contracted scope.
4. Check that Claude's plan accounts for the contracted code trace, state/data flow, dependency scan, and edge cases.
5. Check that `task-contract.md` has `Status: Approved`.
6. Check planned tests and verification against risk.
7. Check manual QA expectations from `task-contract.md`.
8. Check that Claude introduced no product behavior, architecture, dependency, CI, git, hook, or project-file decision.
9. Write `codex-plan-review.md` using `../../../Docs/agents/codex-plan-review-template.md`.
10. If Status is `APPROVED`, create `.codex-local/active-implementation.json` using `../../../Docs/agents/marker-schema.md`, then give the user the implementation slash command.

## Status Rules

- `APPROVED`: plan is inside contracted scope and ready for marker creation.
- `CHANGES_REQUESTED`: plan is close but needs Claude revision.
- `BLOCKED`: missing inputs, product decision needed, scope conflict, or unsafe implementation path.

Use `CHANGES_REQUESTED`, not a new task, when Claude can fix the plan inside the same approved scope.

If the review is `APPROVED`, do not tell Claude to implement with a prose prompt. After marker creation, give the user this exact slash command:

```text
/animi-implement-task .codex-local/tasks/<task-id>
```
