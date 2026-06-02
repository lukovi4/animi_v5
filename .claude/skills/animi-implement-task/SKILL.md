---
name: Animi Implement Task
description: Implement an Animi task only after all gates are approved. Manual gate skill for executing task-contract.md and claude-plan.md when codex-plan-review.md is APPROVED and active-implementation.json authorizes the task.
disable-model-invocation: true
argument-hint: <task-folder>
arguments: task_folder
---

# Animi Implement Task

Use this skill only when the user explicitly invokes `/animi-implement-task <task-folder>` after Codex plan review and marker creation.

## Required Gates

Before editing anything, verify `$task_folder` contains:

- `task-contract.md` with `Status: Approved`;
- `claude-plan.md`;
- `codex-plan-review.md` with `Status: APPROVED`.

Also verify `.codex-local/active-implementation.json` exists and names this task. If any gate is missing, expired, blocked, or ambiguous, stop. Do not create or edit gate files.

## Implementation Rules

- Edit normal repository code/test/project files needed for the task contract.
- If a needed change expands product scope, architecture, dependencies, protected infrastructure, or dangerous actions, stop and ask for Codex review.
- Do not change product behavior beyond `task-contract.md`.
- Do not edit Codex-owned artifacts or protected infrastructure paths.
- Use normal development Bash when needed: search/read, shell composition, pipes, redirects to repo/temp paths, focused tests, builds, verification, and repo-local scripts.
- Do not stage, commit, push, create PRs, change dependencies, change protected infrastructure, delete files, or weaken tests in the Claude implementation pass; stop for Codex/user handling.
- Preserve unrelated dirty worktree changes.
- If `codex-review.md` has `Status: Changes Requested`, treat it as a same-task repair pass and fix only the `Repair Instructions For Claude` section.

## Workflow

1. Read `task-contract.md`, `claude-plan.md`, `codex-plan-review.md`, the active marker, and `codex-review.md` if present.
2. Confirm planned changes are still inside contracted scope.
3. Implement the smallest safe change that satisfies the task contract or same-task repair instructions.
4. Run the narrowest meaningful verification for the approved task. Search/read commands are not verification evidence unless they directly support the summary.
5. Write `$task_folder/claude-summary.md` using `Docs/agents/claude-summary-template.md`.

## Summary Requirements

`claude-summary.md` must include:

- task id;
- marker id;
- marker status and expiry;
- marker snapshot fields required by `Docs/agents/claude-summary-template.md`;
- Codex plan review status;
- files changed;
- task contract compliance;
- exact verification commands and results;
- checks not run and why;
- manual QA notes from the task contract;
- deviations from the task contract, if any;
- known risks or follow-ups for Codex.

## Stop Rule

Stop immediately if scope changes, a new product decision is needed, protected infrastructure changes are needed, a dangerous command is needed, dependency/tooling changes are needed, or the marker is invalid.

If a Codex-owned gate artifact is missing, stop and direct the user back to the Codex workflow.
