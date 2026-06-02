# Claude Write Gate

The write gate is the deterministic protection layer for Claude Code sessions.

It uses a simple permission model:

```text
allow normal development work; block only critical dangerous actions
```

Markdown instructions guide Claude. The hook enforces the hard boundaries.

## Core Rules

- Direct `/animi-planning-pass` and `/animi-implement-task` arguments are validated before expansion.
- Planning mode has no implementation marker. It may write only `claude-plan.md` in a valid approved task folder.
- Implementation mode requires a valid `.codex-local/active-implementation.json` marker.
- During implementation, Claude may edit normal repository code, tests, project files, and task artifacts.
- The marker is a task authorization token, not a microscopic allow-list of every file or command.
- Bash is allowed by default for normal development work: search, read, build, test, scripts, pipes, redirects, and shell composition.
- The hook blocks critical dangerous Bash classes listed below.
- Protected infrastructure paths are blocked in normal planning and implementation tasks.
- Unknown write tool input shapes are blocked.
- Internal hook errors fail closed.

## Protected Paths

Claude must not write these paths through normal planning or implementation tasks:

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

These paths are outside normal Claude planning and implementation. Handle them through Codex/user workflow changes, not through this gate.

## Planning Mode

Planning mode is active when no implementation marker exists.

Allowed:

- normal non-dangerous Bash;
- writing exactly `<task-folder>/claude-plan.md` when the task folder is under `.codex-local/tasks/` and contains:
  - `task-contract.md` with `Status: Approved`.

Denied:

- production/test/project writes through write tools;
- `claude-summary.md`;
- Codex-owned artifacts;
- protected infrastructure paths;
- critical dangerous Bash.

## Implementation Mode

Implementation mode is active only when the marker exists and validates.

The hook validates the marker against:

- schema version;
- marker status;
- `approved_by`;
- `issued_by`;
- expiry;
- task folder existence;
- `task-contract.md` with `Status: Approved`;
- `claude-plan.md`;
- `codex-plan-review.md` with `Status: APPROVED`;
- `codex_plan_review_sha256`.

Allowed writes:

- normal repository code/test/project files;
- `<task-folder>/claude-summary.md`;
- files under `<task-folder>/artifacts/`.

Denied writes:

- anything outside the repository;
- protected infrastructure paths.

## Bash Policy

Allowed by default:

- `rg`, `grep`, `find`, `sed -n`, `awk`, `cat`, `ls`, `head`, `tail`, `wc`, `stat`, `du`, `file`;
- read-only git commands such as `git status`, `git diff`, `git log`, `git show`, `git ls-files`, `git grep`, `git rev-parse`;
- build/test/verification commands such as `swift test`, `xcodebuild test`, `make build`, and project-local scripts;
- shell composition and pipes such as `cd TVECore && swift test` or `rg TextPayload AnimiApp/Sources | wc -l`;
- multi-line Bash when each line is a normal non-dangerous development command;
- safe command substitution and shell payloads such as `echo $(git status --short)` or `bash -c 'git status && rg TextPayload AnimiApp/Sources'`;
- inline diagnostic scripts such as `python3 -c 'print(1)'` or `node -e 'console.log(1)'`;
- read-only `find -exec` payloads such as `find AnimiApp -name '*.swift' -exec grep -n TextPayload {} \;`;
- repo-local `sed -i` and `plutil` mutations when they do not target protected infrastructure;
- network read commands and output to approved temp paths, such as `curl -I https://example.com`, `wget --spider https://example.com`, or `curl -o /tmp/file https://example.com`;
- repo-local `chmod` when it does not target protected infrastructure;
- redirects to repository paths, approved temp paths, or `/dev/null`;
- read-only absolute paths outside the repository;
- repo-local scripting such as `python3 Scripts/report.py` or `node Scripts/tool.js`;
- `mkdir -p`, `touch`, `cp`, and `mv` when they do not target protected infrastructure or global paths.

Blocked:

- destructive git and git state changes: `git reset`, `git clean`, `git checkout`, `git restore`, `git switch`, `git add`, `git commit`, `git push`, `git pull`, `git merge`, `git rebase`, `git stash`, branch creation/deletion, tags, remotes, config, apply/cherry-pick/revert;
- deletion/destructive file commands: `rm`, `rmdir`, `unlink`, `shred`, `find -delete`, and `find -exec` / `find -ok` when the payload is dangerous;
- permission/system/process commands: `sudo`, `su`, `chown`, `kill`, `pkill`, `killall`, `launchctl`, `dd`, `mkfs`, `diskutil`;
- protected-path permission changes, such as `chmod +x Scripts/run_animiapp_tests.sh`;
- package/dependency mutation: `npm install`, `pnpm add`, `yarn add`, `brew install`, `pip install`, `gem install`, `cargo add`, `swift package update`, and similar update/install/remove forms;
- secrets/signing/keychain commands such as `security`;
- network write/sync commands such as `scp` and `rsync`, plus `curl` / `wget` output to protected infrastructure;
- shell parser bypass forms with dangerous payloads, heredoc, and `eval`.

## ConfigChange

`ConfigChange` blocks Claude settings and skill changes from applying during the session.

This prevents configuration changes from silently weakening the active gate. It does not replace `PreToolUse`.

## PostToolBatch Audit

`PostToolBatch` audit runs only when a valid marker exists.

When marker exists, audit checks actual repository state:

- `git diff --name-only`;
- `git diff --cached --name-only`;
- `git ls-files --others --exclude-standard`.

It stops the Claude session if protected infrastructure paths changed during a normal implementation task. Baseline dirty paths avoid false positives for normal pre-existing dirty work, but protected infrastructure paths are never ignored by baseline.

Known Claude runtime lock files, such as `.claude/scheduled_tasks.lock`, are ignored by `PostToolBatch` because they are tool runtime state, not implementation output.

## Known Residual Risk

The hook is loaded by Claude Code. If Claude Code does not load the configured hook, the script cannot enforce anything by itself. Once loaded, the script treats internal errors as deny/stop.
