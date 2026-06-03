---
name: create-animi-plan
description: Create an Animi task folder and task-contract.md for Claude without editing production code. Use when the user asks Codex to plan, scope, prepare, approve work for Claude, fix, implement, diagnose-and-fix, or handle any bugfix/feature likely to require production-code changes.
---

# Create Animi Plan

Use this skill to turn a user request into a Codex-owned task folder and plan for Claude.

## Ground Rules

- Do not edit production code.
- Requests like `fix`, `implement`, `исправь`, `почини`, `найди и исправь`, or `сделай` are not permission for Codex production-code edits.
- Codex production-code edits require a literal user override naming Codex as the implementer.
- If production-code changes may be needed and no literal Codex override exists, create `task-contract.md` for Claude.
- Follow `Docs/agents/workflow.md` and `Docs/agents/guardrails.md`.
- Keep product decisions as recommendations until the user approves them.
- Keep bulky logs and notes under task `artifacts/`.

## Required References

Read only the sections needed:

- `../../../Docs/agents/workflow.md`
- `../../../Docs/agents/task-folder-template.md`
- `../../../Docs/agents/task-contract-template.md`
- `plan-template.md`
- `readiness-checklist.md`

## Workflow

1. Create or reuse a task folder under `.codex-local/tasks/YYYY-MM-DD-short-slug/`.
2. Classify the task: quick fix, feature/behavior, or architecture/media pipeline.
3. Read only relevant knowledge-map sections from `Docs/agents/domain.md`, `Docs/agents/code-map.md`, and `Docs/agents/regression-map.md` when they help route investigation.
4. Investigate the real code like a planning pass before drafting: entry points, state/data flow, direct dependencies, adjacent behavior, and existing test seams.
5. Identify edge cases, product semantics, consequences of likely fixes, and the task decision tree.
6. Run the grill loop before drafting:
   - Interview the user until shared understanding.
   - Walk each relevant branch of the task decision tree.
   - Resolve dependencies between decisions one by one.
   - Ask one question at a time.
   - Include Codex's recommended answer and impact.
   - Wait for the user's answer before asking the next question.
   - If code or existing docs can answer the question, investigate instead of asking.
   - Ask only questions whose answer can change approved behavior, scope, architecture boundary, regression risk, verification, or manual QA.
   - Do not ask questions already answered by the user request, proven by code, or internal to Claude's implementation inside approved scope.
   - Do not write `task-contract.md` until all relevant decision-tree branches are resolved or explicitly out of scope.
7. Write `task-contract.md` with `Status: Pending User Approval`.
8. Write `followups.md` when useful.
9. Run the readiness checklist.
10. Ask the user to approve, reject, or revise the task contract. Include 3-6 concrete investigation evidence bullets and a summary of approved product decisions in the chat response.

After explicit user approval:

1. Update the same `task-contract.md` to `Status: Approved`.
2. Record the user approval statement in `task-contract.md`.
3. Give the user only the exact Claude slash command to run the Planning Pass:
   ```text
   /animi-planning-pass .codex-local/tasks/<task-id>
   ```
4. Stop until Claude writes `claude-plan.md` and Codex reviews it.

## Stop Conditions

Stop and ask the user when:

- product behavior is unclear;
- active semantics, edge cases, or expected manual behavior cannot be inferred safely;
- dependency, CI, hook, Xcode project, signing, build-script, infrastructure, or git-state changes are needed but are not yet explicitly approved in the task scope;
- deletion, destructive cleanup, git rollback cleanup, or tracked-file removal appears necessary;
- existing dirty files conflict with the plan;
- the plan would require production code edits by Codex.
