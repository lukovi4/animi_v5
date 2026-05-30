---
name: create-animi-plan
description: Create an Animi task folder and Codex implementation plan without editing production code. Use when the user asks Codex to plan, scope, prepare, or approve work for Claude, especially for app behavior, media/export, architecture, tests, or bugfix tasks.
---

# Create Animi Plan

Use this skill to turn a user request into a Codex-owned task folder and plan for Claude.

## Ground Rules

- Do not edit production code.
- Do not create `plan.approved.md` until the user approves the draft.
- Do not create `claude-task.md` until `plan.approved.md` exists.
- Do not decide product behavior. Recommend and ask for approval.
- Keep bulky logs and notes under task `artifacts/`.

## Required References

Read only the sections needed:

- `../../../Docs/agents/workflow.md`
- `../../../Docs/agents/planning-template.md`
- `../../../Docs/agents/task-folder-template.md`
- `../../../Docs/agents/claude-task-template.md`
- `plan-template.md`
- `readiness-checklist.md`

## Workflow

1. Create or reuse a task folder under `.codex-local/tasks/YYYY-MM-DD-short-slug/`.
2. Classify the task: quick fix, feature/behavior, or architecture/media pipeline.
3. Gather targeted code context only when needed.
4. Write `task.md`.
5. Write `product-decisions.md`.
6. Write `plan.draft.md`.
7. Write `followups.md`.
8. Run the readiness checklist.
9. Ask the user to approve, reject, or revise the draft.

After explicit user approval:

1. Create `plan.approved.md` with `Status: APPROVED`.
2. Create `claude-task.md`.
3. Give the user the exact Claude prompt to run the Planning Pass and write `claude-plan.md`.
4. Do not tell Claude to implement until Codex reviews `claude-plan.md`, writes `codex-plan-review.md` with `Status: APPROVED`, the user explicitly approves implementation, and Codex creates a valid implementation marker.

## Stop Conditions

Stop and ask the user when:

- product behavior is unclear;
- the task needs dependency, CI, hook, Xcode project, signing, or build-script changes;
- existing dirty files conflict with the plan;
- the plan would require production code edits by Codex.
