# Agent Guardrails

These guardrails apply to Codex and Claude.

## Always Protected

- Uncommitted, untracked, or user-created files.
- Product behavior without user approval.
- Credentials, secrets, Keychain, signing, provisioning, `.env` files.
- CI, hooks, Xcode project files, build scripts, release resources.
- Test strength, lint/build standards, skip lists.

## Codex

Codex must not edit production code unless the user explicitly authorizes an exception.

Codex may draft documentation, workflow files, plans, reviews, and task artifacts after user approval.

Codex may stage, commit, push, or open PRs only after explicit user approval for that action.

## Claude

Claude may plan only from `plan.approved.md` and `claude-task.md`.

Claude may edit production code only after:

- `plan.approved.md` has `Status: APPROVED`;
- `claude-task.md` exists;
- `claude-plan.md` exists;
- `codex-plan-review.md` has `Status: APPROVED`;
- the user explicitly approves implementation;
- `.codex-local/active-implementation.json` is valid for the task.

Claude must use the Planning Pass skill and write `claude-plan.md` before production code changes.

Claude must not:

- create task folders;
- create or modify `task.md`, `product-decisions.md`, `plan.draft.md`, `plan.approved.md`, `claude-task.md`, `codex-plan-review.md`, `codex-review.md`, `followups.md`, or `.codex-local/active-implementation.json`;
- offer bypassing, ignoring, or overriding this contract as an option;
- suggest that the user manually create, rename, or edit `plan.approved.md`, `claude-task.md`, `codex-plan-review.md`, or `.codex-local/active-implementation.json`;
- rewrite `plan.approved.md`;
- expand scope;
- infer product behavior;
- delete uncommitted files;
- weaken tests;
- hide verification failures.

## Hook / Marker Policy

Hooks and markers are the deterministic protection layer, not the workflow itself.

The intended write gate uses:

- `PreToolUse` to block writes outside marker-approved paths, block mutating/dangerous Bash, allow safe read-only inspection Bash, and allow marker-listed verification Bash;
- `ConfigChange` to block unauthorized changes to Claude settings, hooks, skills, marker, and gate files;
- `PostToolBatch` to audit actual git changes after a tool batch and stop the session if a bypass is detected.

The marker is `.codex-local/active-implementation.json`. It is created and removed only by Codex after explicit user approval.

Planning mode allows only safe read-only inspection Bash. Implementation mode allows safe read-only inspection Bash plus exact verification commands from marker `allowed_bash_exact`.
