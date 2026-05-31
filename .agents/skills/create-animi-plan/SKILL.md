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
3. Read only relevant knowledge-map sections from `Docs/agents/domain.md`, `Docs/agents/code-map.md`, and `Docs/agents/regression-map.md` when they help route investigation.
4. Investigate the real code like a planning pass before drafting: entry points, state/data flow, direct dependencies, adjacent behavior, and existing test seams.
5. Identify edge cases, product semantics, and possible consequences of the likely fix.
6. Ask the user every required product/UX/behavior question. Do not write `plan.draft.md` until required answers are clear.
7. Write `task.md`.
8. Write `product-decisions.md`.
9. Write `plan.draft.md`.
10. Write `followups.md`.
11. Run the readiness checklist.
12. Ask the user to approve, reject, or revise the draft.

After explicit user approval:

1. Create `plan.approved.md` with `Status: APPROVED`.
2. Create `claude-task.md`.
3. Give the user only the exact Claude slash command to run the Planning Pass:
   ```text
   /animi-planning-pass .codex-local/tasks/<task-id>
   ```
   Do not give a prose workflow prompt; Claude cannot invoke this skill through `Skill(...)` because it is manual-only.
4. Do not tell Claude to implement until Codex reviews `claude-plan.md`, writes `codex-plan-review.md` with `Status: APPROVED`, the user explicitly approves implementation, and Codex creates a valid implementation marker.

## Stop Conditions

Stop and ask the user when:

- product behavior is unclear;
- active semantics, edge cases, or expected manual behavior cannot be inferred safely;
- the task needs dependency, CI, hook, Xcode project, signing, or build-script changes;
- existing dirty files conflict with the plan;
- the plan would require production code edits by Codex.
