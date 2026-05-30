---
name: Animi Implement Approved Plan
description: Implement an Animi task only after all gates are approved. Manual gate skill for executing plan.approved.md and claude-plan.md when codex-plan-review.md is APPROVED and active-implementation.json authorizes exact paths.
disable-model-invocation: true
argument-hint: <task-folder>
arguments: task_folder
---

# Animi Implement Approved Plan

Use this skill only when the user explicitly invokes `/animi-implement-approved-plan <task-folder>` after Codex plan review and user implementation approval.

## Required Gates

Before editing anything, verify `$task_folder` contains:

- `plan.approved.md` with `Status: APPROVED`;
- `claude-task.md`;
- `claude-plan.md`;
- `codex-plan-review.md` with `Status: APPROVED`.

Also verify `.codex-local/active-implementation.json` exists and names this task. If any gate is missing, expired, blocked, or ambiguous, stop. Do not create or edit gate files.

## Implementation Rules

- Edit only files listed in the active marker's `approved_paths`.
- If a needed file is not listed, stop and ask for Codex review and a new marker.
- Do not change product behavior beyond `plan.approved.md`.
- Do not edit Codex-owned artifacts, marker files, hooks, settings, `.claude/`, `.agents/`, `AGENTS.md`, `CLAUDE.md`, or `Docs/agents/`.
- Do not run Bash commands unless they exactly match `allowed_bash_exact` in the active marker.
- Do not stage, commit, push, create PRs, change dependencies, change project files, or weaken tests unless explicitly approved in the plan and marker.
- Preserve unrelated dirty worktree changes.

## Workflow

1. Read `plan.approved.md`, `claude-task.md`, `claude-plan.md`, `codex-plan-review.md`, and the active marker.
2. Confirm planned changes are still inside approved scope.
3. Implement the smallest safe change that satisfies the approved plan.
4. Run only verification allowed by the marker. If verification is blocked, record the blocker.
5. Write `$task_folder/claude-summary.md` using `Docs/agents/claude-summary-template.md`.

## Summary Requirements

`claude-summary.md` must include:

- task id;
- marker id;
- marker status and expiry;
- Codex plan review status;
- files changed;
- plan compliance;
- exact verification commands and results;
- checks not run and why;
- deviations from plan, if any;
- known risks or follow-ups for Codex.

## Stop Rule

Stop immediately if scope changes, a new product decision is needed, a required file is outside `approved_paths`, verification needs an unlisted command, or the marker is invalid.

If a Codex-owned gate artifact is missing, do not offer to invoke, delegate to, install, or rescue Codex through plugins, connectors, slash commands, or automation. Stop and direct the user back to the Codex workflow.
