# Claude Write Gate

The write gate is the deterministic protection layer for Claude Code sessions.

It uses one simple hard-enforcement model:

```text
allow normal development work; block only deletion, destructive cleanup, and git rollback cleanup
```

Markdown instructions still define workflow ownership and task scope. The hook enforces only the critical technical boundary.

## Core Rules

- Direct `/animi-planning-pass` and `/animi-implement-task` arguments are validated before expansion.
- The implementation slash command must match a valid `.codex-local/active-implementation.json` marker.
- The marker is a task authorization token, not a microscopic allow-list of every file or command.
- `PreToolUse:Bash` is allowed by default for normal development work.
- `PreToolUse` write tools are allowed by default. Scope is governed by `task-contract.md`, `claude-plan.md`, `codex-plan-review.md`, and review, not by hook path allow-lists.
- `ConfigChange` is allowed by the hook. Config edits still require the normal workflow approval for infrastructure changes.
- `PostToolBatch` stops only when tracked repository files are deleted.
- Internal hook errors fail closed only at the hook entrypoint. Bash parser ambiguity does not block by default unless the hook finds a dangerous payload.

## Planning And Implementation

Planning and implementation are workflow modes, not broad hook deny modes.

Planning pass:

- User invokes `/animi-planning-pass <task-folder>`.
- The hook validates that the task folder exists under `.codex-local/tasks/` and that `task-contract.md` has `Status: Approved`.
- Claude workflow instructions require writing only `claude-plan.md` and stopping for Codex review.

Implementation pass:

- User invokes `/animi-implement-task <task-folder>`.
- The hook validates the active marker, approved task contract, existing `claude-plan.md`, approved `codex-plan-review.md`, expiry, and review hash.
- Claude workflow instructions require staying inside the approved task contract.

The hook does not block normal code edits, tests, project-file edits, scripts, dependency commands, network commands, protected-path writes, commits, pushes, or config changes by category. Those actions are controlled by task scope, artifact ownership, and explicit user/Codex approval where the workflow requires it.

## Bash Policy

Allowed by default:

- search/read commands, including `rg`, `grep`, `find`, `awk`, `cat`, `ls`, `head`, `tail`, `wc`, `stat`, `du`, and `file`;
- normal shell composition, including pipes, redirects, multi-line commands, loops, quoted payloads, and command substitution;
- build, test, verification, local scripts, inline diagnostic scripts, dependency commands, network commands, git metadata/history commands, branch/tag creation, commits, pushes, and other normal development commands;
- redirects to repository paths, temp paths, `/dev/null`, and external paths;
- writes to repository paths, task artifacts, AI infrastructure paths, and project files when the approved workflow scope permits them.

Blocked:

- deletion/destructive file commands: `rm`, `rmdir`, `unlink`, `shred`;
- mutating find deletion forms: `find -delete`;
- `find -exec`, `find -execdir`, `find -ok`, or `find -okdir` when the payload is dangerous;
- git rollback/cleanup deletion commands: `git reset`, `git clean`, `git restore`, `git checkout`, `git rm`;
- branch/tag deletion: `git branch -d`, `git branch -D`, `git branch --delete`, `git tag -d`, `git tag --delete`;
- dangerous payloads hidden inside `bash -c`, `sh -c`, `zsh -c`, `$()`, or backticks.

## ConfigChange

`ConfigChange` is allowed by the hook.

Config, hook, skill, and workflow edits are still infrastructure changes. They must be authorized through the normal Codex/user workflow, but the hook does not technically block them.

## PostToolBatch Audit

`PostToolBatch` checks actual repository state with:

- `git ls-files --deleted`.

It stops the Claude session only if tracked files are deleted. It does not stop because protected infrastructure paths changed, dependencies changed, network commands ran, commits were created, or config changed.

## Known Residual Risk

The hook is loaded by Claude Code. If Claude Code does not load the configured hook, the script cannot enforce anything by itself.

The hook is intentionally not a full shell sandbox. It blocks common deterministic deletion and git cleanup forms. Workflow review remains responsible for catching scope violations, unrelated churn, unsafe dependency/tooling changes, and other non-deletion risks.
