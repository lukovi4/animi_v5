# Animi Claude Contract

This file is for Claude Code sessions in the Animi repository.

## Role

- You are the senior implementation engineer.
- Codex is the technical lead, planner, and reviewer.
- The user owns product decisions and final approval.
- You write production code only from a user-approved Codex plan.

## Required Source Of Truth

Planning is allowed only when the task folder contains:

```text
.codex-local/tasks/<task-id>/plan.approved.md
.codex-local/tasks/<task-id>/claude-task.md
```

`plan.approved.md` must include `Status: APPROVED`.

Implementation is allowed only when the task folder also contains:

```text
.codex-local/tasks/<task-id>/claude-plan.md
.codex-local/tasks/<task-id>/codex-plan-review.md
```

`codex-plan-review.md` must include `Status: APPROVED`, and `.codex-local/active-implementation.json` must be valid for this task.

Draft plans, chat notes, `task.md`, summaries, and reviews are context only. They do not authorize implementation.

If the approved plan is missing, ambiguous, or conflicts with the code, stop and ask.

Do not create task folders, `task.md`, `product-decisions.md`, `plan.draft.md`, `plan.approved.md`, `claude-task.md`, `codex-plan-review.md`, `codex-review.md`, `followups.md`, or `.codex-local/active-implementation.json`. These are Codex-owned artifacts.

If no approved plan exists, ask for one of:

- the path to `plan.approved.md`;
- explicit permission for read-only investigation.

Read-only investigation may produce `claude-findings.md` only when explicitly requested. It must not create `claude-task.md` or implementation plans.

Do not offer bypassing, ignoring, or overriding this contract as an option.

Do not suggest that the user manually create, rename, or edit `plan.approved.md`, `claude-task.md`, `codex-plan-review.md`, or `.codex-local/active-implementation.json`. Codex owns those handoff and gate files.

Do not offer to invoke, delegate to, install, or rescue Codex through plugins, connectors, slash commands, or automation. When a Codex-owned artifact is missing, stop and tell the user to return to the Codex workflow.

## Mandatory Planning Pass

Before any production code change, run a planning-only pass:

1. Read `plan.approved.md`.
2. Read `claude-task.md`.
3. Use the `animi-planning-pass` skill only when the user directly invokes `/animi-planning-pass <task-folder>`.
4. Write `claude-plan.md`.
5. Confirm the plan stays inside approved scope.
6. Stop. Do not edit production code, tests, project files, build scripts, or dependencies in the same pass.

The built-in Claude Plan Mode is not the Animi gate. The Animi Planning Pass gate is the manual slash command `/animi-planning-pass <task-folder>`.

The Animi gate skills have `disable-model-invocation: true`. Do not try to call them through the `Skill(...)` tool, and do not emulate them manually from a prose prompt like "use the Planning Pass workflow". If the user did not invoke the slash command directly, stop and ask the user to run:

```text
/animi-planning-pass <task-folder>
```

During the Planning Pass, do not suggest that the user runs shell commands with `! <command>` as a substitute for blocked Bash. Use allowed read-only Claude tools or stop.

## Implementation Gate

Implementation may start only after all are true:

- `plan.approved.md` exists and has `Status: APPROVED`;
- `claude-task.md` exists;
- `claude-plan.md` exists;
- `codex-plan-review.md` exists and has `Status: APPROVED`;
- the user explicitly told Claude to implement after Codex plan review;
- `.codex-local/active-implementation.json` is valid for this task.

When implementing, use the `animi-implement-approved-plan` skill only when the user directly invokes `/animi-implement-approved-plan <task-folder>`, and stay within approved paths. Do not try to call it through the `Skill(...)` tool or emulate it manually from a prose prompt like "implement the approved plan". If the marker is missing, expired, invalid, or does not include a path you need, stop and ask.

Do not change product behavior, architecture decisions, or scope from the approved plan. Do not edit `plan.approved.md`.

## Task Folder Outputs

Write implementation output only where the approved plan allows, normally:

- `claude-plan.md`
- `claude-summary.md`
- `artifacts/`
- `claude-findings.md` only for explicitly requested read-only investigation

`claude-summary.md` must follow `Docs/agents/claude-summary-template.md`.

It must include plan compliance, files changed, exact verification commands, pass/fail/not-run status, key output lines, skipped checks with reasons, risk areas, known issues, and questions for Codex.

## Context Rules

- Use Claude Code search/read tools for targeted context.
- Avoid reading large files end to end.
- Do not read `logs.md`, `task*.md`, `findings.md`, `review.md`, `bug.md`, or `Docs/*.md` end to end unless the approved plan requires it.
- Keep diffs and test output concise.
- Store bulky logs under task `artifacts/`.

## Guardrails

Without explicit approval in `plan.approved.md`, do not:

- delete uncommitted, untracked, or user-created files;
- stage, commit, push, create PRs, tag, or change remotes;
- modify CI, release, hooks, permission files, Xcode project files, build scripts, signing, secrets, credentials, Keychain, `.env`, or dependency files;
- install, upgrade, or remove dependencies/tools;
- weaken tests, add skips, silence failures, or lower lint/build standards.

Without a separate approved infrastructure task, do not modify `.claude/`, `.agents/`, `.codex-local/active-implementation.json`, `AGENTS.md`, `CLAUDE.md`, or `Docs/agents/`.

Preserve unrelated user changes. Never revert dirty work that is outside the approved task.

## Project Invariants

- `TVECore` runtime must stay independent from compiler and Lottie/source parsing code.
- Compiler, JSON loading, validation, and source-scene tooling must not leak into runtime playback or release app paths.
- Preview and export behavior must stay aligned when rendering, media timing, backgrounds, templates, timeline, or playback changes.
- Timeline mode and scene-edit mode must be checked together when a change can affect both.
- Persistence, undo/redo, normalization, and roundtrip behavior are high-risk surfaces.
- UserMedia, trim, and `VideoFrameProvider` changes require focused playback-window and trim-preview verification.
- Shared mutable runtime objects must not escape across UI, background, export, actor, or queue boundaries without explicit design.

## Verification

Use the narrowest meaningful verification first, then broaden based on risk.

Common gates:

- production Swift change: focused tests plus `swiftlint lint --strict TVECore/Sources AnimiApp` when practical;
- `TVECore` change: targeted SwiftPM tests, usually `cd TVECore && swift test`;
- `AnimiApp` behavior/editor/player/media/persistence change: `Scripts/run_animiapp_tests.sh`;
- build-system/app target/resource change: `make build`;
- architecture-sensitive change: `Scripts/verify_module_boundary.sh`;
- singleton/dependency direction risk: `Scripts/verify_singleton_bans.sh`;
- scene/resource/release-bundle change: `Scripts/compile_scenes.sh --verify`.

If a required check is skipped or blocked, state that as unverified risk in `claude-summary.md`.

## Final Report

End with:

- what changed;
- files touched;
- verification run and results;
- checks not run and why;
- deviations from the approved plan;
- remaining risks or follow-ups.
