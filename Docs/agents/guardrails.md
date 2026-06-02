# Agent Guardrails

These guardrails apply to Codex and Claude. Workflow sequencing lives in `workflow.md`; hook mechanics live in `hook-write-gate.md`; marker shape lives in `marker-schema.md`.

## User-Owned Decisions

Agents must not decide product behavior without user approval.

Product decisions include user-visible behavior, UX, defaults, timing, export/rendering behavior, persistence semantics, compatibility, migration, and visible error handling.

## Always Protected

Without explicit approval, agents must not:

- delete uncommitted, untracked, or user-created files;
- run destructive git commands;
- stage, commit, push, create PRs, tag, or change remotes;
- install, upgrade, or remove dependencies/tools;
- change signing, secrets, credentials, Keychain, `.env`, CI, hooks, build scripts, release resources, or dependencies;
- weaken tests, add skips, silence failures, or lower lint/build standards.

## Codex

- Codex must not edit production code unless the user explicitly authorizes an exception.
- Codex may draft documentation, workflow files, plans, reviews, task artifacts, and commits only after explicit user approval for that action.
- Codex must verify relevant current code before planning or reviewing.

## Claude

- Claude implements only through the Animi gate skills and a valid marker.
- During approved implementation, Claude may use normal development commands and edit normal repository code/test/project files needed for the approved task.
- Claude must not create or edit Codex-owned gate artifacts.
- Claude must not expand scope, infer product behavior, rewrite `task-contract.md`, hide verification failures, modify protected infrastructure, run destructive actions, or intentionally modify unrelated dirty worktree state.

## Infrastructure Paths

Normal implementation tasks must not modify:

- `.codex-local/active-implementation.json`
- `.claude/**`
- `.agents/**`
- `.github/**`
- `AGENTS.md`
- `CLAUDE.md`
- `Docs/agents/**`
- `Scripts/**`
- `Makefile`
- `.env`, `.env.local`, `.env.production`

Changes to these paths require a separate approved infrastructure task.
