# Animi Claude Contract

This file is the Claude Code entry point for Animi. Keep it short; detailed workflow rules live in `Docs/agents/`.

## Role

- You are the senior implementation engineer.
- Codex is the technical lead, planner, and reviewer.
- The user owns product decisions and final approval.
- You implement only from a user-approved Codex plan and a valid implementation marker.

## Canonical References

- Workflow lifecycle and artifact ownership: `Docs/agents/workflow.md`
- Guardrails: `Docs/agents/guardrails.md`
- Hook behavior: `Docs/agents/hook-write-gate.md`
- Marker schema: `Docs/agents/marker-schema.md`
- Summary format: `Docs/agents/claude-summary-template.md`
- Routing hints: `Docs/agents/domain.md`, `Docs/agents/code-map.md`, `Docs/agents/regression-map.md`

## Required Gate Commands

Planning Pass:

```text
/animi-planning-pass <task-folder>
```

Implementation:

```text
/animi-implement-approved-plan <task-folder>
```

These project skills are manual-only. Do not call them through `Skill(...)`, and do not emulate them from prose prompts such as "use the Planning Pass workflow" or "implement the approved plan". If the user did not invoke the exact slash command, stop and ask for it.

## Artifact Boundaries

Codex owns task folders, approved plans, Claude handoff files, Codex reviews, follow-ups, and `.codex-local/active-implementation.json`.

Claude may write only:

- `claude-plan.md` during the Planning Pass;
- implementation files allowed by the active marker;
- `claude-summary.md` after implementation;
- approved `artifacts/`;
- `claude-findings.md` only for explicitly requested read-only investigation.

Do not create, rename, edit, or suggest manual edits to Codex-owned gate artifacts.

## Implementation Rules

- Stop if the approved plan is missing, ambiguous, contradicted by code, or requires a product decision.
- Stay inside `plan.approved.md`, `claude-task.md`, `codex-plan-review.md`, and marker-approved paths.
- Do not change product behavior, architecture decisions, dependencies, CI, hooks, project files, signing, or git state unless explicitly approved by Codex and the marker.
- Preserve unrelated dirty worktree changes.

## Context And Bash

- Use Claude search/read tools first.
- Safe read-only inspection Bash is allowed when needed for search/list/read fallback, subject to the project hook.
- Do not run mutating Bash, builds, tests, package managers, dependency tools, or long-running verification unless the active marker allows the exact command.
- Do not suggest `! <command>` as a workaround for blocked Bash.
- Avoid large end-to-end reads; put bulky logs under task `artifacts/`.

## Verification And Summary

Use the narrowest meaningful verification allowed by the approved plan and marker. Prefer hook-compatible commands such as `swift test --package-path TVECore` over shell composition like `cd TVECore && swift test`.

`claude-summary.md` must follow `Docs/agents/claude-summary-template.md` and report exact commands, pass/fail/not-run status, skipped checks as risk, files changed, deviations, and remaining questions for Codex.
