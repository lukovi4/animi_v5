# Agent Guardrails

These guardrails apply to Codex and Claude. Workflow sequencing lives in `workflow.md`; hook mechanics live in `hook-write-gate.md`; marker shape lives in `marker-schema.md`.

## User-Owned Decisions

Agents must not decide product behavior without user approval.

Product decisions include user-visible behavior, UX, defaults, timing, export/rendering behavior, persistence semantics, compatibility, migration, and visible error handling.

## High-Risk Actions

Without explicit approval, agents must not:

- delete uncommitted, untracked, or user-created files;
- run deletion, destructive cleanup, or git rollback cleanup commands;
- stage, commit, push, create PRs, tag, or change remotes;
- install, upgrade, or remove dependencies/tools outside the approved task scope;
- change signing, secrets, credentials, Keychain, `.env`, CI, hooks, build scripts, release resources, or dependencies outside the approved task scope;
- weaken tests, add skips, silence failures, or lower lint/build standards.

Only deletion/destructive cleanup and git rollback cleanup are hard-blocked by the hook. Other high-risk actions are workflow-controlled: they are allowed when explicitly inside an approved task contract and user/Codex approvals required by `workflow.md` are present.

## Codex

- Codex must not edit production code by default.
- Codex production-code edits require a literal user override naming Codex as the implementer, for example: `Codex, edit production code` or `Codex, сам внеси production changes`.
- Requests like `fix`, `implement`, `исправь`, `почини`, `найди и исправь`, or `сделай` are not Codex production-code authorization.
- When a user request needs production-code changes and no literal Codex override exists, Codex must diagnose/plan/review and route implementation through Claude using `task-contract.md`.
- Codex may draft documentation, workflow files, plans, reviews, task artifacts, and commits only after explicit user approval for that action.
- Codex must verify relevant current code before planning or reviewing.

## Claude

- Claude implements only through the Animi gate skills and a valid marker.
- During approved implementation, Claude may use normal development commands and edit normal repository code/test/project files needed for the approved task.
- Claude must not create or edit Codex-owned gate artifacts.
- Claude must not expand scope, infer product behavior, rewrite `task-contract.md`, hide verification failures, run deletion/cleanup/rollback, or intentionally modify unrelated dirty worktree state.
- Claude may modify dependencies, tooling, project files, hooks, docs, or infrastructure only when that work is explicitly inside the approved task contract.

## Codex-Owned Gate Artifacts

Claude must not create, rename, edit, or delete these gate artifacts:

- `.codex-local/active-implementation.json`
- `task-contract.md`
- `codex-analysis.md`
- `codex-plan-review.md`
- `codex-review.md`
- `followups.md`

Workflow/infrastructure files such as `.claude/**`, `.agents/**`, `AGENTS.md`, `CLAUDE.md`, `Docs/agents/**`, `Scripts/**`, and project configuration are not hook-blocked. They require explicit task-contract scope because they change the AI/product workflow or build surface.
