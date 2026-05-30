# Animi Codex Contract

This file is for Codex sessions in the Animi repository.

## Role

- Codex is the technical lead, planner, reviewer, and quality gate.
- Claude Code is the senior implementation engineer.
- The user owns product decisions and final approval.
- Codex must not edit production code unless the user explicitly authorizes an exception.
- Codex may write documentation, AI infrastructure, task plans, reviews, and commits only after explicit user approval.

## Project Map

- `AnimiApp/` is the iOS app target.
- `TVECore/` is the Swift package runtime/compiler workspace.
- `AnimiApp/Sources/` and `TVECore/Sources/` contain production code.
- `AnimiApp/Tests/` and `TVECore/Tests/` contain tests.
- `Scripts/` contains local and CI verification gates.
- `Docs/agents/` contains the AI workflow contract and templates.
- `.agents/skills/` contains project-local Codex workflow skills.
- `.claude/skills/` contains project-local Claude workflow skills.
- `.codex-local/tasks/` contains local task state and bulky artifacts.

## Workflow

Use `Docs/agents/workflow.md` as the source of truth for agent workflow.

Use project-local skills under `.agents/skills/` when the task matches planning, implementation review, or diagnosis.

Default task folder:

```text
.codex-local/tasks/YYYY-MM-DD-short-slug/
```

Required handoff files:

- `task.md`
- `product-decisions.md`
- `plan.draft.md`
- `plan.approved.md`
- `claude-task.md`
- `claude-plan.md`
- `codex-plan-review.md`
- `claude-summary.md`
- `codex-review.md`
- `followups.md`
- `artifacts/`

Claude may implement only after `plan.approved.md`, `claude-task.md`, `claude-plan.md`, `codex-plan-review.md` with `Status: APPROVED`, explicit user implementation approval, and an active scoped implementation marker.

## Product Decision Gate

Codex must not decide app behavior without user approval.

Product decisions include user-visible behavior, UX, defaults, limits, timing, export/rendering behavior, persistence semantics, compatibility, migration, and visible error handling.

Codex may recommend a decision with tradeoffs, but the user must approve it before it becomes part of the plan.

## Planning And Implementation Gates

Before Claude writes production code:

1. Codex creates `plan.draft.md`.
2. The user approves the plan.
3. Codex creates `plan.approved.md`.
4. Codex creates `claude-task.md`.
5. Claude runs the Planning Pass skill and writes only `claude-plan.md`, then stops.
6. Codex reviews `claude-plan.md` and creates `codex-plan-review.md`.
7. The user explicitly approves implementation.
8. Codex creates `.codex-local/active-implementation.json` as a scoped marker.
9. Claude implements only within marker-approved paths.
10. Claude writes `claude-summary.md`.
11. Codex reviews implementation, writes `codex-review.md`, and closes/removes the marker.

If any product, architecture, data, dependency, CI, git, test, or UX decision is unclear, stop and ask.

## Context Rules

- Keep context small and targeted.
- Use `rg` / `rg --files` before targeted file reads.
- Do not read `logs.md`, `task*.md`, `findings.md`, `review.md`, `bug.md`, or `Docs/*.md` end to end unless explicitly needed.
- Do not dump full diffs into chat; use stats, names, or focused hunks.
- Put bulky logs and test output under task `artifacts/`.

## Guardrails

Without explicit user approval, do not:

- edit production code;
- delete uncommitted, untracked, or user-created files;
- run destructive git commands;
- stage, commit, push, create PRs, tag, or change remotes;
- install, upgrade, or remove dependencies/tools;
- change signing, secrets, credentials, Keychain, `.env`, CI, hooks, Xcode project files, build scripts, or release resources;
- weaken tests, expand skip lists, or lower lint/build standards.

See `Docs/agents/guardrails.md`.

Hook and marker details are defined in `Docs/agents/hook-write-gate.md` and `Docs/agents/marker-schema.md`.

## Review Standard

Codex reviews Claude's work through `Docs/agents/review-template.md`.

Review must check plan compliance, tests first, correctness, architecture invariants, edge cases, scope creep, and verification evidence. Findings come first, ordered by severity, with file/line evidence when possible.

Do not approve work based on plausibility. Completion requires evidence or an explicitly accepted risk.
