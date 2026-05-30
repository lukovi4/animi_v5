# Claude Task Template

Use this for `claude-task.md`.

```markdown
# Claude Task: <title>

## Source Of Truth

- Approved plan: `plan.approved.md`
- You may implement only what is approved there.

Do not create or modify Codex-owned files:

- `task.md`
- `product-decisions.md`
- `plan.draft.md`
- `plan.approved.md`
- `claude-task.md`
- `codex-plan-review.md`
- `codex-review.md`
- `followups.md`

## Required First Step

Use the `animi-planning-pass` skill before editing production code.

Write the Planning Pass result to:

- `claude-plan.md`

After writing `claude-plan.md`, stop. Do not edit production code, tests, project files, build scripts, or dependencies in the same pass.

Implementation may start only after Codex writes `codex-plan-review.md` with `Status: APPROVED`, the user explicitly tells Claude to implement, and `.codex-local/active-implementation.json` is valid for this task.

Do not implement if your plan changes scope, product behavior, or architecture decisions from `plan.approved.md`.

## Goal

<short goal copied from approved plan>

## Scope

In scope:

- <item>

Out of scope:

- <item>

## Files To Read First

- `<path>`: <why>

## Implementation Constraints

- <architecture invariant>
- <guardrail>

## Required Verification

- `<command>`: <expected evidence>

If a check cannot run, record why in `claude-summary.md`.

## Required Summary

Fill `claude-summary.md` using `Docs/agents/claude-summary-template.md`.

## Stop And Ask If

- approved plan conflicts with code;
- required product decision is missing;
- required verification cannot be run;
- implementation requires touching files not covered by the plan;
- no valid `.codex-local/active-implementation.json` exists when implementation is requested;
- dependency, CI, project file, hook, signing, or git action is needed.

If no approved plan exists, stop and ask for the path to `plan.approved.md`. Do not create a task folder or `claude-task.md`.

Do not offer bypassing, ignoring, or overriding the contract as an option.

Do not suggest that the user manually create, rename, or edit `plan.approved.md`, `claude-task.md`, `codex-plan-review.md`, or `.codex-local/active-implementation.json`. Those are created by Codex after user approval and review.

Do not offer to invoke, delegate to, install, or rescue Codex through plugins, connectors, slash commands, or automation. When a Codex-owned artifact is missing, stop and tell the user to return to the Codex workflow.
```
