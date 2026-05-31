# Claude Task Template

Use this for `claude-task.md`. The workflow contract is `workflow.md`; this file is only the handoff shape for Claude.

```markdown
# Claude Task: <title>

## Source Of Truth

- Approved plan: `plan.approved.md`
- Workflow: `Docs/agents/workflow.md`
- Guardrails: `Docs/agents/guardrails.md`

## Required First Step

The user must invoke:

```text
/animi-planning-pass <task-folder>
```

Planning Pass output:

- `claude-plan.md`

After `claude-plan.md`, stop for Codex plan review.

## Goal

<short goal copied from approved plan>

## Scope

In scope:

- <item>

Out of scope:

- <item>

## Files To Read First

- `<path>`: <why>

## Edge Cases / Regression Risks

- <edge case or adjacent behavior Codex expects Claude to preserve>

## Implementation Constraints

- <architecture invariant>
- <guardrail>

## Required Verification

- `<command>`: <expected evidence>

If a check cannot run, record why in `claude-summary.md`.

## Manual QA Expectation

- Required: yes/no
- If required: <exact user steps and expected result>

## Required Summary

Fill `claude-summary.md` using `Docs/agents/claude-summary-template.md`.

## Stop And Ask If

- approved plan conflicts with code;
- required product decision is missing;
- implementation requires touching files not covered by the plan/marker;
- required verification needs an unapproved command;
- dependency, CI, project file, hook, signing, or git action is needed.
```
