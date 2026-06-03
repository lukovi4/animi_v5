---
name: Animi Planning Pass
description: Create claude-plan.md for an approved Animi task contract without implementing. Manual gate skill for reading task-contract.md, analyzing real code read-only, writing only claude-plan.md, and stopping for Codex review.
disable-model-invocation: true
argument-hint: <task-folder>
arguments: task_folder
---

# Animi Planning Pass

Use this skill only when the user explicitly invokes `/animi-planning-pass <task-folder>`.

## Purpose

Analyze the approved task against the real codebase, write `claude-plan.md`, and stop. This replaces Claude's built-in Plan Mode for Animi.

## Required Input

`$task_folder` must point to a task folder containing:

- `task-contract.md` with `Status: Approved`.

If the task folder or contract is missing or not approved, stop and ask for the correct task folder. Do not create task folders or Codex-owned files.

## Allowed Output

Write exactly one task artifact:

- `$task_folder/claude-plan.md`

Do not write anything else in this pass.

## Read-Only Research

- Read `task-contract.md` first.
- Use targeted code reads and search.
- If normal search/read tools are unavailable or insufficient, Bash is allowed by the project hook. Use normal development commands for investigation, including search, read, shell composition, and focused verification when it materially improves the plan.
- Use Explore/subagents when useful for focused read-only code investigation.
- Do not run deletion, destructive cleanup, or git rollback cleanup commands. The hook hard-blocks forms such as `rm`, `find -delete`, dangerous `find -exec`, `git reset`, `git clean`, `git restore`, `git checkout`, `git rm`, and branch/tag deletion.
- Do not suggest that the user runs shell commands with `! <command>` as a substitute for blocked Bash.
- Do not infer product behavior beyond `task-contract.md`.
- If code contradicts `task-contract.md`, write a blocked `claude-plan.md` and stop.

## Plan Contents

Write `claude-plan.md` using the shape from `Docs/agents/claude-plan-template.md`.

It must include:

- `Status: Proposed` for a viable plan, or `Status: Blocked` when implementation should not proceed;
- confirmation that `task-contract.md` was read and has `Status: Approved`;
- `Implementation started: no`;
- exact files expected to change;
- implementation steps inside contracted scope;
- verification planned;
- edge cases, regression checks, and manual QA expectations from `task-contract.md`;
- risks, blockers, or questions for Codex.

Do not write `Status: APPROVED` in `claude-plan.md`. Claude proposes; Codex approves only through `codex-plan-review.md`.

## Stop Rule

After writing `claude-plan.md`, stop. Do not implement. Tell the user that Codex must review the plan, write `codex-plan-review.md`, and create the marker before implementation can begin.
