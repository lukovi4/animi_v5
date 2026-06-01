# Claude Write Gate

The write gate is the deterministic protection layer for Claude Code sessions.

It is based on the official Claude Code hook contract:

- `UserPromptExpansion` validates direct `/skill-name` invocations before the skill prompt reaches Claude.
- `PreToolUse` blocks unsafe tool calls before execution.
- `ConfigChange` blocks unauthorized settings and skill changes from applying to the running session.
- `PostToolBatch` audits the actual repository state after a batch of tool calls, before the next model call.

`PreToolUse` is the primary lock. `PostToolBatch` is only a bypass detector because it cannot undo a write that already happened.

## Core Rules

- Direct `/animi-planning-pass` and `/animi-implement-approved-plan` invocations are validated before expansion.
- Current v1 does not persist a slash-invocation provenance token into later tool calls. `PreToolUse` enforces allowed output shape and marker scope; Claude instructions still require direct slash invocation.
- Planning mode allows safe read-only inspection Bash only.
- Planning mode may write only `claude-plan.md` in a valid approved task folder.
- Planning mode cannot write production code, tests, project files, build scripts, dependencies, settings, hooks, or gate files.
- Implementation mode requires a valid `.codex-local/active-implementation.json` marker.
- Implementation mode can write code/test files only when their exact canonical paths are listed in marker `approved_paths`.
- Implementation mode may write only derived Claude task artifacts in the active task folder: `claude-summary.md` and files under `artifacts/`.
- Implementation mode can run safe read-only inspection Bash and marker-listed verification Bash.
- Git-mutating commands are blocked in all normal modes.
- Dangerous direct shell commands, shell composition, redirection, and dependency/tool mutation are blocked in all normal modes.
- Unknown tool input structure is blocked, not ignored.
- Any ambiguity inside the hook script blocks the action.

## Eternal Deny List

Claude must not write these paths through normal planning or implementation tasks:

- `.codex-local/active-implementation.json`
- `.claude/**`
- `.agents/**`
- `AGENTS.md`
- `CLAUDE.md`
- `Docs/agents/**`
- hook scripts and hook settings

Changes to these paths require a separate approved infrastructure task and separate infra gate. A normal implementation marker never grants access to them.

## Planning Mode

Planning mode is active when no implementation marker exists.

Allowed:

- `UserPromptExpansion` accepts direct `/animi-planning-pass <task-folder>` only when the folder is under `.codex-local/tasks/` and contains:
  - `plan.approved.md` with `Status: APPROVED`;
  - `claude-task.md`.
- writing exactly `<task-folder>/claude-plan.md`.

Denied:

- mutating, expensive, or unsafe Bash;
- production/test/project writes;
- `claude-summary.md`;
- Codex-owned artifacts;
- settings, hooks, root contracts, and agent docs.

## Implementation Mode

Implementation mode is active only when the marker exists and validates.

The hook validates every relevant tool call against:

- marker schema version;
- marker status;
- `approved_by`;
- `issued_by`;
- expiry;
- task folder existence;
- `plan.approved.md` with `Status: APPROVED`;
- `claude-task.md`;
- `claude-plan.md`;
- `codex-plan-review.md` with `Status: APPROVED`;
- `codex_plan_review_sha256`;
- exact approved paths;
- exact allowed Bash commands.

Allowed writes:

- exact canonical paths from `approved_paths`;
- `<task-folder>/claude-summary.md`;
- files under `<task-folder>/artifacts/`.

Denied writes:

- anything outside the above;
- anything in the eternal deny list, even if marker `approved_paths` tries to include it.

## Bash Policy

The hook favors Claude productivity for read/search work and strict control for writes and expensive commands.

Allowed in planning and implementation:

- safe read-only inspection commands aligned with Claude Code's built-in read-only set: `ls`, `cat`, `echo`, `pwd`, `head`, `tail`, `grep`, `find`, `wc`, `which`, `diff`, `stat`, `du`, `cd`, read-only `git` forms, plus common local inspection commands `rg`, `date`, `sed -n`, and `plutil -lint`;
- repository-local path inspection, plus Claude-generated tool result logs under `~/.claude/projects/**/tool-results/**`;
- no shell composition or redirection. Regex alternation inside a quoted `rg`/`grep` pattern is allowed; shell pipes are not.

Implementation verification Bash is additionally allowed when:

- marker is valid;
- the command equals one full string from `allowed_bash_exact` after trimming;
- the allowed string does not contain shell composition or redirection such as `;`, `&&`, `||`, `|`, `>`, `<`, `$(`, backticks, heredoc, `tee`, `eval`, `bash -c`, or `sh -c`;
- the command is not a git-mutating command.

Denied in all normal modes:

- mutating git commands;
- build/test/package/dependency commands unless exact-listed in marker `allowed_bash_exact`;
- `rm`, `mv`, `cp`, `chmod`, `chown`, `touch`, `mkdir`, scripting runtimes used as direct commands, `sed -i`, `find -exec`, `find -delete`, and similar mutation paths;
- command composition, pipes, redirection, command substitution, heredocs, `tee`, `eval`, `bash -c`, and `sh -c`.

`allowed_bash_exact` is for assigned verification commands, not general shell access. Read-only inspection commands do not need to be listed there.

## ConfigChange

`ConfigChange` blocks changes to Claude settings and skills from applying during the session:

- project settings;
- local project settings;
- user settings when they affect the current session;
- `.claude/skills/**`.

This does not replace `PreToolUse`; it prevents configuration changes from silently weakening the active gate.

## PostToolBatch Audit

`PostToolBatch` audit runs only when a valid marker exists. Without a marker, planning protection is handled by `UserPromptExpansion` and `PreToolUse`; there is no marker baseline to distinguish old dirty worktree state from new writes.

When marker exists, audit checks actual repository state:

- `git diff --name-only`;
- `git diff --cached --name-only`;
- `git ls-files --others --exclude-standard`.

It compares changed and new files against:

- the eternal deny list, before baseline filtering;
- `approved_paths`;
- derived task artifacts: `claude-summary.md` and `artifacts/**`;
- `baseline_dirty_paths`.

Known Claude runtime lock files, such as `.claude/scheduled_tasks.lock`, are ignored by `PostToolBatch` because they are tool runtime state, not agent contract changes. They are still not approved implementation outputs.

If it detects a path outside scope, it stops the Claude session and reports the violation. Baseline paths prevent false positives from pre-existing dirty files; they do not grant write permission because `PreToolUse` still blocks writes to non-approved paths.

Eternal deny paths are never ignored by baseline. If `.claude/**`, `.agents/**`, root contracts, agent docs, hooks, settings, or the marker change during a normal implementation task, audit treats that as a violation even when the file was already dirty before marker creation.

Operational rule: Codex must not issue a normal implementation marker while any eternal-deny path is already dirty. Finish and close the infrastructure task first, then create markers for normal implementation tasks.

## Known Residual Risk

Claude Code hook handlers are invoked by the platform. If a hook is not loaded, disabled, or never spawned, the script cannot fail closed by itself. The script therefore treats every internal error as deny/stop, but the project still relies on Claude Code loading the hook configuration correctly.
