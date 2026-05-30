---
name: Animi Planning Pass
description: Create claude-plan.md for an approved Animi task without implementing. Manual gate skill for reading plan.approved.md and claude-task.md, analyzing real code read-only, writing only claude-plan.md, and stopping for Codex review.
disable-model-invocation: true
disallowed-tools: Bash
argument-hint: <task-folder>
arguments: task_folder
---

# Animi Planning Pass

Use this skill only when the user explicitly invokes `/animi-planning-pass <task-folder>`.

## Purpose

Analyze the approved task against the real codebase, write `claude-plan.md`, and stop. This replaces Claude's built-in Plan Mode for Animi.

## Required Input

`$task_folder` must point to a task folder containing:

- `plan.approved.md` with `Status: APPROVED`;
- `claude-task.md`.

If the task folder or either file is missing, stop and ask for the correct task folder. Do not create task folders or Codex-owned files.

## Allowed Output

Write exactly one task artifact:

- `$task_folder/claude-plan.md`

Do not edit production code, tests, build files, project files, dependencies, hooks, settings, marker files, or Codex-owned task artifacts.

## Read-Only Research

- Read `plan.approved.md` and `claude-task.md` first.
- Use targeted code reads and search.
- Use Explore/subagents when useful for focused read-only code investigation.
- Do not use Bash in this pass.
- Do not suggest that the user runs shell commands with `! <command>` as a substitute for blocked Bash.
- Do not infer product behavior beyond the approved plan.
- If code contradicts the approved plan, write a blocked `claude-plan.md` and stop.

## Plan Contents

Write `claude-plan.md` using the shape from `Docs/agents/claude-plan-template.md`.

It must include:

- `Status: Proposed` for a viable plan, or `Status: Blocked` when implementation should not proceed;
- confirmation that `plan.approved.md` and `claude-task.md` were read;
- `Implementation started: no`;
- exact files expected to change;
- implementation steps inside approved scope;
- verification planned;
- risks, blockers, or questions for Codex.

Do not write `Status: APPROVED` in `claude-plan.md`. Claude proposes; Codex approves only through `codex-plan-review.md`.

## Stop Rule

After writing `claude-plan.md`, stop. Do not implement. Tell the user that Codex must review the plan and create `codex-plan-review.md` before implementation can begin.

Do not offer to invoke, delegate to, install, or rescue Codex through plugins, connectors, slash commands, or automation. Just stop and direct the user back to the Codex workflow.
