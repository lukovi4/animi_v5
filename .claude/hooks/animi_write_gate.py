#!/usr/bin/env python3
"""Animi Claude Code write gate.

This hook blocks only critical actions:
- protected infrastructure writes;
- destructive git/file/system/package/network commands;
- implementation without a valid marker.

Normal code/test edits and normal development Bash are allowed during an
approved implementation task.
"""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import hashlib
import io
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Set


MARKER_REL = ".codex-local/active-implementation.json"
TASKS_REL = ".codex-local/tasks"
ANIMI_PLANNING_SKILL = "animi-planning-pass"
ANIMI_IMPLEMENT_SKILL = "animi-implement-task"
WRITE_TOOLS = {"Write", "Edit", "MultiEdit", "NotebookEdit"}

ETERNAL_DENY_EXACT = {
    ".codex-local/active-implementation.json",
    ".env",
    ".env.local",
    ".env.production",
    "AGENTS.md",
    "CLAUDE.md",
    "Makefile",
}
ETERNAL_DENY_PREFIXES = (
    ".claude/",
    ".agents/",
    ".github/",
    "Docs/agents/",
    "Scripts/",
)
POST_TOOL_TRANSIENT_PATHS = {
    ".claude/scheduled_tasks.lock",
}

SHA256_RE = re.compile(r"^[a-fA-F0-9]{64}$")
ENV_ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=.*$")
CURRENT_EVENT_NAME = ""

SHELL_CONTROL_TOKENS = {"|", "||", "&", "&&", ";"}
SHELL_REDIRECT_TOKENS = {">", ">>", "<", "<<", "2>", "2>>", "&>", ">&"}
BLOCKED_RAW_SHELL_PATTERNS = ("$(", "`", "<<")
BLOCKED_SHELL_COMMANDS = {
    "chmod",
    "chown",
    "curl",
    "dd",
    "diskutil",
    "eval",
    "kill",
    "killall",
    "launchctl",
    "mkfs",
    "pkill",
    "rm",
    "rmdir",
    "rsync",
    "scp",
    "security",
    "shred",
    "su",
    "sudo",
    "unlink",
    "wget",
}
PATH_WRITE_COMMANDS = {"cp", "mkdir", "mv", "touch"}
FIND_MUTATING_EXPRESSIONS = {"-delete", "-exec", "-execdir", "-ok", "-okdir", "-fls", "-fprint", "-fprintf"}
SCRIPT_INLINE_FLAGS = {"python": "-c", "python3": "-c", "node": "-e", "ruby": "-e", "perl": "-e"}
PACKAGE_COMMANDS = {"brew", "bundle", "cargo", "gem", "npm", "pip", "pip3", "pnpm", "yarn", "bun"}
PACKAGE_MUTATING_ARGS = {
    "add",
    "ci",
    "install",
    "link",
    "publish",
    "remove",
    "uninstall",
    "update",
    "upgrade",
}
GIT_READ_ONLY_SUBCOMMANDS = {
    "branch",
    "describe",
    "diff",
    "grep",
    "log",
    "ls-files",
    "rev-parse",
    "show",
    "status",
}
GIT_BRANCH_READ_ONLY_FLAGS = {"--show-current", "--list", "-a", "-r", "-v", "-vv", "--all", "--remotes", "--verbose"}
CLAUDE_TOOL_RESULTS_PART = "/.claude/projects/"
CLAUDE_TOOL_RESULTS_DIR = "/tool-results/"


class GateError(Exception):
    pass


class Marker:
    def __init__(self, data: Dict[str, Any], task_folder: Path, baseline_dirty: Set[str]) -> None:
        self.data = data
        self.task_folder = task_folder
        self.baseline_dirty = baseline_dirty

    @property
    def task_id(self) -> str:
        return str(self.data["task_id"])


def repo_root() -> Path:
    env_root = os.environ.get("CLAUDE_PROJECT_DIR")
    if env_root:
        root = Path(env_root)
    else:
        root = Path(__file__).resolve().parents[2]
    return root.resolve(strict=False)


def deny(message: str, event_name: str = "") -> None:
    if event_name == "PostToolBatch":
        print(json.dumps({"continue": False, "stopReason": message}, separators=(",", ":")))
        raise SystemExit(0)
    print(f"Animi write gate blocked: {message}", file=sys.stderr)
    raise SystemExit(2)


def load_input() -> Dict[str, Any]:
    raw = sys.stdin.read()
    if not raw.strip():
        raise GateError("empty hook input")
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise GateError(f"invalid hook JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise GateError("hook input must be a JSON object")
    return value


def rel_string(root: Path, path: Path) -> str:
    try:
        rel = path.resolve(strict=False).relative_to(root)
    except ValueError as exc:
        raise GateError(f"path is outside repository: {path}") from exc
    return rel.as_posix()


def canonicalize(root: Path, value: str) -> Path:
    if not isinstance(value, str) or not value.strip():
        raise GateError("path must be a non-empty string")
    path = Path(value)
    if not path.is_absolute():
        path = root / path
    return path.resolve(strict=False)


def canonicalize_repo_relative(root: Path, value: str, field: str) -> Path:
    path = Path(value)
    if path.is_absolute():
        raise GateError(f"{field} must be repository-relative: {value}")
    return canonicalize(root, value)


def is_under(path: Path, parent: Path) -> bool:
    try:
        path.resolve(strict=False).relative_to(parent.resolve(strict=False))
        return True
    except ValueError:
        return False


def is_eternal_denied(root: Path, path: Path) -> bool:
    rel = rel_string(root, path)
    if rel in ETERNAL_DENY_EXACT:
        return True
    return any(rel == prefix.rstrip("/") or rel.startswith(prefix) for prefix in ETERNAL_DENY_PREFIXES)


def require_file(path: Path, name: str) -> None:
    if not path.is_file():
        raise GateError(f"missing required {name}: {path}")


def has_status(path: Path, status: str) -> bool:
    require_file(path, path.name)
    text = path.read_text(encoding="utf-8", errors="replace")
    wanted = f"Status: {status}"
    return any(line.strip() == wanted for line in text.splitlines())


def parse_iso_datetime(value: Any, field: str) -> dt.datetime:
    if not isinstance(value, str) or not value.strip():
        raise GateError(f"{field} must be a non-empty ISO8601 string")
    raw = value.strip()
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    try:
        parsed = dt.datetime.fromisoformat(raw)
    except ValueError as exc:
        raise GateError(f"{field} is not valid ISO8601: {value}") from exc
    if parsed.tzinfo is None:
        raise GateError(f"{field} must include timezone offset")
    return parsed


def validate_string_list(data: Dict[str, Any], field: str, allow_empty: bool) -> List[str]:
    value = data.get(field)
    if not isinstance(value, list):
        raise GateError(f"{field} must be an array")
    if not allow_empty and not value:
        raise GateError(f"{field} must not be empty")
    result: List[str] = []
    for item in value:
        if not isinstance(item, str) or not item.strip():
            raise GateError(f"{field} entries must be non-empty strings")
        result.append(item.strip())
    return result


def validate_marker(root: Path) -> Marker:
    marker_path = root / MARKER_REL
    require_file(marker_path, MARKER_REL)
    try:
        data = json.loads(marker_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise GateError(f"marker JSON is invalid: {exc}") from exc
    if not isinstance(data, dict):
        raise GateError("marker must be a JSON object")

    if data.get("schema_version") != 1:
        raise GateError("marker schema_version must be 1")
    if data.get("status") != "IMPLEMENTATION_APPROVED":
        raise GateError("marker status must be IMPLEMENTATION_APPROVED")
    if data.get("approved_by") != "user":
        raise GateError("marker approved_by must be user")
    if data.get("issued_by") != "Codex":
        raise GateError("marker issued_by must be Codex")
    if not isinstance(data.get("task_id"), str) or not data["task_id"].strip():
        raise GateError("marker task_id must be a non-empty string")
    if not isinstance(data.get("marker_id"), str) or not data["marker_id"].strip():
        raise GateError("marker_id must be a non-empty string")

    parse_iso_datetime(data.get("issued_at"), "issued_at")
    expires_at = parse_iso_datetime(data.get("expires_at"), "expires_at")
    now = dt.datetime.now(dt.timezone.utc)
    if expires_at <= now:
        raise GateError("marker is expired")

    task_folder_raw = data.get("task_folder")
    if not isinstance(task_folder_raw, str) or not task_folder_raw.strip():
        raise GateError("task_folder must be a non-empty string")
    task_folder = canonicalize_repo_relative(root, task_folder_raw.strip(), "task_folder")
    if not is_under(task_folder, root / TASKS_REL):
        raise GateError("task_folder must be under .codex-local/tasks/")
    if task_folder.name != data["task_id"].strip():
        raise GateError("task_folder basename must match task_id")
    if not task_folder.is_dir():
        raise GateError(f"task_folder does not exist: {task_folder}")

    task_contract = task_folder / "task-contract.md"
    claude_plan = task_folder / "claude-plan.md"
    codex_review = task_folder / "codex-plan-review.md"
    if not has_status(task_contract, "Approved"):
        raise GateError("task-contract.md must contain Status: Approved")
    require_file(claude_plan, "claude-plan.md")
    if not has_status(codex_review, "APPROVED"):
        raise GateError("codex-plan-review.md must contain Status: APPROVED")

    expected_review_hash = data.get("codex_plan_review_sha256")
    if not isinstance(expected_review_hash, str) or not SHA256_RE.match(expected_review_hash):
        raise GateError("codex_plan_review_sha256 must be a 64-character hex string")
    actual_review_hash = hashlib.sha256(codex_review.read_bytes()).hexdigest()
    if actual_review_hash.lower() != expected_review_hash.lower():
        raise GateError("codex-plan-review.md SHA256 does not match marker")

    baseline_dirty = set(validate_string_list(data, "baseline_dirty_paths", allow_empty=True))
    return Marker(data, task_folder, baseline_dirty)


def marker_if_present(root: Path) -> Optional[Marker]:
    marker_path = root / MARKER_REL
    if not marker_path.exists():
        return None
    return validate_marker(root)


def parse_one_task_arg(raw_args: Any) -> str:
    if raw_args is None:
        raw_args = ""
    if not isinstance(raw_args, str):
        raise GateError("command_args must be a string")
    try:
        parts = shlex.split(raw_args)
    except ValueError as exc:
        raise GateError(f"cannot parse command_args: {exc}") from exc
    if len(parts) != 1:
        raise GateError("skill must be invoked with exactly one <task-folder> argument")
    return parts[0]


def validate_planning_task_folder(root: Path, task_folder_arg: str) -> Path:
    task_folder = canonicalize(root, task_folder_arg)
    if not is_under(task_folder, root / TASKS_REL):
        raise GateError("planning task folder must be under .codex-local/tasks/")
    if not task_folder.is_dir():
        raise GateError(f"planning task folder does not exist: {task_folder}")
    if not has_status(task_folder / "task-contract.md", "Approved"):
        raise GateError("planning pass requires task-contract.md with Status: Approved")
    return task_folder


def handle_user_prompt_expansion(root: Path, data: Dict[str, Any]) -> None:
    command_name = data.get("command_name")
    if command_name not in {ANIMI_PLANNING_SKILL, ANIMI_IMPLEMENT_SKILL}:
        return
    task_folder_arg = parse_one_task_arg(data.get("command_args", ""))

    if command_name == ANIMI_PLANNING_SKILL:
        if (root / MARKER_REL).exists():
            raise GateError("cannot run planning pass while active implementation marker exists")
        validate_planning_task_folder(root, task_folder_arg)
        return

    marker = validate_marker(root)
    task_folder = canonicalize_repo_relative(root, task_folder_arg, "task-folder")
    if task_folder != marker.task_folder:
        raise GateError("implementation skill task folder does not match active marker")


def extract_target_paths(root: Path, tool_name: str, tool_input: Dict[str, Any]) -> List[Path]:
    if tool_name in {"Write", "Edit"}:
        file_path = tool_input.get("file_path")
        if not isinstance(file_path, str):
            raise GateError(f"{tool_name} requires tool_input.file_path")
        return [canonicalize(root, file_path)]

    if tool_name == "MultiEdit":
        file_path = tool_input.get("file_path")
        edits = tool_input.get("edits")
        if not isinstance(file_path, str) or not isinstance(edits, list):
            raise GateError("MultiEdit requires file_path and edits[]")
        return [canonicalize(root, file_path)]

    if tool_name == "NotebookEdit":
        file_path = tool_input.get("notebook_path") or tool_input.get("file_path")
        if not isinstance(file_path, str):
            raise GateError("NotebookEdit requires notebook_path or file_path")
        return [canonicalize(root, file_path)]

    raise GateError(f"unsupported write tool: {tool_name}")


def planning_target_allowed(root: Path, target: Path) -> bool:
    rel = rel_string(root, target)
    parts = rel.split("/")
    if len(parts) != 4:
        return False
    if parts[0] != ".codex-local" or parts[1] != "tasks" or parts[3] != "claude-plan.md":
        return False
    task_folder = root / ".codex-local" / "tasks" / parts[2]
    validate_planning_task_folder(root, task_folder.as_posix())
    return target == (task_folder / "claude-plan.md").resolve(strict=False)


def implementation_target_allowed(root: Path, marker: Marker, target: Path) -> bool:
    try:
        target.resolve(strict=False).relative_to(root)
    except ValueError:
        return False
    if is_eternal_denied(root, target):
        return False
    return True


def strip_env_assignments(tokens: Sequence[str]) -> List[str]:
    result = list(tokens)
    while result and ENV_ASSIGN_RE.match(result[0]):
        result.pop(0)
    return result


def shell_tokens(command: str) -> List[str]:
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars="|&;<>")
        lexer.whitespace_split = True
        return list(lexer)
    except ValueError as exc:
        raise GateError(f"cannot parse Bash command: {exc}") from exc


def command_segments(tokens: Sequence[str]) -> List[List[str]]:
    segments: List[List[str]] = []
    current: List[str] = []
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if token in SHELL_CONTROL_TOKENS:
            if current:
                segments.append(current)
                current = []
            index += 1
            continue
        if token in SHELL_REDIRECT_TOKENS:
            if index + 1 >= len(tokens):
                raise GateError("Bash redirection is missing a target")
            if current:
                segments.append(current)
                current = []
            segments.append([token, tokens[index + 1]])
            index += 2
            continue
        current.append(token)
        index += 1
    if current:
        segments.append(current)
    return segments


def git_tokens_without_global_flags(tokens: Sequence[str]) -> List[str]:
    result = list(strip_env_assignments(tokens))
    if not result or result[0] != "git":
        return result
    index = 1
    while index < len(result):
        token = result[index]
        if token == "-C":
            index += 2
            continue
        if token in {"-c", "--config-env"}:
            index += 2
            continue
        if token.startswith("--git-dir=") or token.startswith("--work-tree=") or token.startswith("-c"):
            index += 1
            continue
        break
    return [result[0], *result[index:]]


def is_mutating_git_command(command: str) -> bool:
    tokens = git_tokens_without_global_flags(shell_tokens(command))
    if len(tokens) < 2:
        return False
    if tokens[0] != "git":
        return False
    subcommand = tokens[1]
    if subcommand == "branch":
        rest = tokens[2:]
        if not rest:
            return False
        return not (
            rest
            and all(token in GIT_BRANCH_READ_ONLY_FLAGS or not token.startswith("-") for token in rest)
            and any(token in GIT_BRANCH_READ_ONLY_FLAGS for token in rest)
        )
    return subcommand not in GIT_READ_ONLY_SUBCOMMANDS


def is_safe_external_path(path: Path) -> bool:
    text = path.resolve(strict=False).as_posix()
    return text.startswith("/tmp/") or text.startswith("/private/tmp/") or is_allowed_external_read_path(path)


def validate_shell_path(root: Path, token: str, *, write: bool) -> None:
    if not token or token.startswith("-"):
        return
    if token in {"/", "~"}:
        raise GateError(f"Bash path targets a global location: {token}")
    path = Path(token).expanduser() if token.startswith("~") else Path(token)
    if not path.is_absolute():
        path = root / path
    resolved = path.resolve(strict=False)
    if is_under(resolved, root):
        if write and is_eternal_denied(root, resolved):
            raise GateError(f"Bash targets protected infrastructure: {token}")
        return
    if is_safe_external_path(resolved):
        return
    raise GateError(f"Bash path is outside repository or approved temp space: {token}")


def validate_path_write_command(root: Path, tokens: Sequence[str]) -> None:
    for token in tokens[1:]:
        if token.startswith("-"):
            continue
        validate_shell_path(root, token, write=True)


def package_command_is_mutating(tokens: Sequence[str]) -> bool:
    command = tokens[0]
    args = [token for token in tokens[1:] if not token.startswith("-")]
    if command in {"brew", "bundle", "gem", "pip", "pip3", "pnpm", "yarn", "bun"}:
        return any(arg in PACKAGE_MUTATING_ARGS for arg in args)
    if command == "npm":
        return any(arg in PACKAGE_MUTATING_ARGS or arg == "i" for arg in args)
    if command == "cargo":
        return bool(args and args[0] in {"add", "install", "publish", "remove", "update"})
    return False


def segment_is_dangerous(root: Path, segment: Sequence[str]) -> Optional[str]:
    tokens = strip_env_assignments(segment)
    if not tokens:
        return "empty command segment"
    first = tokens[0]
    if first in BLOCKED_SHELL_COMMANDS:
        return f"{first} is blocked"
    if first in PATH_WRITE_COMMANDS:
        validate_path_write_command(root, tokens)
    if first == "git" and is_mutating_git_command(" ".join(shlex.quote(token) for token in tokens)):
        return "git mutation is blocked"
    if first == "git" and any(token == "--output" or token.startswith("--output=") or token == "-o" for token in tokens[1:]):
        return "git output writes are blocked"
    if first == "date" and len(tokens) > 1 and not all(token == "-u" or token.startswith("+") for token in tokens[1:]):
        return "date mutation form is blocked"
    if first == "find" and any(token in FIND_MUTATING_EXPRESSIONS for token in tokens):
        return "mutating find expression is blocked"
    if first == "sed" and any(token == "-i" or token.startswith("-i") for token in tokens[1:]):
        return "sed in-place edits are blocked"
    if first == "plutil" and any(token in {"-replace", "-remove", "-insert", "-convert"} for token in tokens[1:]):
        return "mutating plutil command is blocked"
    if first == "swift" and len(tokens) >= 3 and tokens[1] == "package" and tokens[2] in {"update", "resolve"}:
        return "dependency mutation is blocked"
    if first in {"bash", "sh", "zsh"} and "-c" in tokens[1:]:
        return "shell -c execution is blocked; use direct commands or repo-local scripts"
    inline_flag = SCRIPT_INLINE_FLAGS.get(first)
    if inline_flag and inline_flag in tokens[1:]:
        return f"{first} inline execution is blocked; use repo-local scripts instead"
    if first in PACKAGE_COMMANDS and package_command_is_mutating(tokens):
        return "package/dependency mutation is blocked"
    return None


def is_allowed_external_read_path(path: Path) -> bool:
    text = path.resolve(strict=False).as_posix()
    return CLAUDE_TOOL_RESULTS_PART in text and CLAUDE_TOOL_RESULTS_DIR in text


def validate_redirection(root: Path, segment: Sequence[str]) -> Optional[str]:
    if len(segment) != 2:
        return "invalid redirection"
    operator, target = segment
    if operator == "<<":
        return "heredoc is blocked"
    validate_shell_path(root, target, write=operator != "<")
    return None


def is_dangerous_bash_command(root: Path, command: str) -> Optional[str]:
    if "\n" in command or "\r" in command:
        return "multi-line Bash is blocked"
    if any(pattern in command for pattern in BLOCKED_RAW_SHELL_PATTERNS):
        return "command substitution/heredoc is blocked"
    tokens = shell_tokens(command)
    for segment in command_segments(tokens):
        if segment[0] in SHELL_REDIRECT_TOKENS:
            reason = validate_redirection(root, segment)
        else:
            reason = segment_is_dangerous(root, segment)
        if reason:
            return reason
    return None


def handle_bash(root: Path, tool_input: Dict[str, Any], marker: Optional[Marker]) -> None:
    command = tool_input.get("command")
    if not isinstance(command, str) or not command.strip():
        raise GateError("Bash requires a non-empty command")
    command = command.strip()

    reason = is_dangerous_bash_command(root, command)
    if reason:
        raise GateError(reason)


def handle_write_tool(root: Path, tool_name: str, tool_input: Dict[str, Any], marker: Optional[Marker]) -> None:
    targets = extract_target_paths(root, tool_name, tool_input)
    for target in targets:
        if is_eternal_denied(root, target):
            raise GateError(f"write to protected path is blocked: {rel_string(root, target)}")
        if marker is None:
            if not planning_target_allowed(root, target):
                raise GateError(f"planning mode may write only claude-plan.md: {rel_string(root, target)}")
        elif not implementation_target_allowed(root, marker, target):
            raise GateError(f"path is not authorized by active marker: {rel_string(root, target)}")


def handle_pre_tool_use(root: Path, data: Dict[str, Any]) -> None:
    tool_name = data.get("tool_name")
    tool_input = data.get("tool_input")
    if not isinstance(tool_name, str) or not isinstance(tool_input, dict):
        raise GateError("PreToolUse requires tool_name and tool_input")

    marker = marker_if_present(root)
    if tool_name == "Bash":
        handle_bash(root, tool_input, marker)
        return
    if tool_name in WRITE_TOOLS:
        handle_write_tool(root, tool_name, tool_input, marker)
        return


def handle_config_change(data: Dict[str, Any]) -> None:
    source = data.get("source")
    raise GateError(f"configuration changes are blocked by Animi write gate: {source or 'unknown source'}")


def git_names(root: Path, args: Sequence[str]) -> Set[str]:
    result = subprocess.run(
        ["git", *args],
        cwd=str(root),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise GateError(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return {line.strip() for line in result.stdout.splitlines() if line.strip()}


def handle_post_tool_batch(root: Path) -> None:
    marker_path = root / MARKER_REL
    if not marker_path.exists():
        return
    marker = validate_marker(root)
    changed = set()
    changed |= git_names(root, ["diff", "--name-only"])
    changed |= git_names(root, ["diff", "--cached", "--name-only"])
    changed |= git_names(root, ["ls-files", "--others", "--exclude-standard"])

    violations: List[str] = []
    for rel in sorted(changed):
        if rel in POST_TOOL_TRANSIENT_PATHS:
            continue
        target = canonicalize(root, rel)
        if is_eternal_denied(root, target):
            violations.append(rel)
            continue
        if rel in marker.baseline_dirty:
            continue
        if implementation_target_allowed(root, marker, target):
            continue
        violations.append(rel)

    if violations:
        joined = ", ".join(violations[:20])
        if len(violations) > 20:
            joined += f", ... (+{len(violations) - 20} more)"
        deny(f"repository changed protected infrastructure paths: {joined}", "PostToolBatch")


def self_test_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def self_test_make_task(root: Path) -> Path:
    task = root / TASKS_REL / "2026-05-31-hook-self-test"
    self_test_write(task / "task-contract.md", "# Task Contract\n\nStatus: Approved\n")
    self_test_write(task / "claude-plan.md", "# Claude Plan\n\nStatus: Proposed\n")
    self_test_write(task / "codex-plan-review.md", "# Codex Plan Review\n\nStatus: APPROVED\n")
    return task


def self_test_make_marker(root: Path, task: Path) -> None:
    codex_review = task / "codex-plan-review.md"
    review_hash = hashlib.sha256(codex_review.read_bytes()).hexdigest()
    now = dt.datetime.now(dt.timezone.utc)
    data = {
        "schema_version": 1,
        "status": "IMPLEMENTATION_APPROVED",
        "task_id": task.name,
        "task_folder": f"{TASKS_REL}/{task.name}",
        "baseline_dirty_paths": [],
        "codex_plan_review_sha256": review_hash,
        "approved_by": "user",
        "issued_by": "Codex",
        "issued_at": now.isoformat(),
        "expires_at": (now + dt.timedelta(hours=1)).isoformat(),
        "marker_id": "hook-self-test",
    }
    self_test_write(root / MARKER_REL, json.dumps(data, indent=2, sort_keys=True) + "\n")


def self_test_expect_pass(name: str, func: Any) -> int:
    try:
        func()
    except BaseException as exc:
        raise GateError(f"self-test expected pass but failed [{name}]: {exc}") from exc
    return 1


def self_test_expect_block(name: str, func: Any) -> int:
    try:
        func()
    except GateError:
        return 1
    except SystemExit as exc:
        if exc.code == 2:
            return 1
        raise GateError(f"self-test expected block but got SystemExit({exc.code}) [{name}]") from exc
    raise GateError(f"self-test expected block but passed [{name}]")


def self_test_expect_stop(name: str, func: Any) -> int:
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            func()
    except SystemExit as exc:
        if exc.code == 0:
            return 1
        raise GateError(f"self-test expected stop but got SystemExit({exc.code}) [{name}]") from exc
    raise GateError(f"self-test expected stop but passed [{name}]")


def run_self_test() -> int:
    checks = 0
    with tempfile.TemporaryDirectory(prefix="animi-write-gate-") as temp_dir:
        root = Path(temp_dir).resolve(strict=False)
        task = self_test_make_task(root)

        checks += self_test_expect_pass(
            "planning slash validates approved task",
            lambda: handle_user_prompt_expansion(
                root,
                {
                    "command_name": ANIMI_PLANNING_SKILL,
                    "command_args": f"{TASKS_REL}/{task.name}",
                },
            ),
        )
        checks += self_test_expect_pass(
            "planning may write claude-plan.md only",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Write",
                    "tool_input": {"file_path": f"{TASKS_REL}/{task.name}/claude-plan.md"},
                },
            ),
        )
        checks += self_test_expect_block(
            "planning blocks production write",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Write",
                    "tool_input": {"file_path": "AnimiApp/Sources/Blocked.swift"},
                },
            ),
        )
        checks += self_test_expect_pass(
            "read-only bash is allowed",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": "ls ."},
                },
            ),
        )
        checks += self_test_expect_pass(
            "date inspection is allowed",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": 'date "+%Y-%m-%dT%H:%M:%S%z"'},
                },
            ),
        )
        checks += self_test_expect_pass(
            "stat inspection is allowed",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": "stat ."},
                },
            ),
        )
        checks += self_test_expect_pass(
            "official read-only commands are allowed",
            lambda: [
                handle_pre_tool_use(root, {"tool_name": "Bash", "tool_input": {"command": command}})
                for command in (
                    "cat README.md",
                    "echo ok",
                    "which git",
                    "diff README.md README.md",
                    "du -sh .",
                    "cd .",
                )
            ],
        )
        checks += self_test_expect_pass(
            "read-only git metadata is allowed",
            lambda: [
                handle_pre_tool_use(root, {"tool_name": "Bash", "tool_input": {"command": command}})
                for command in (
                    "git branch",
                    "git branch --show-current",
                )
            ],
        )
        checks += self_test_expect_pass(
            "read-only git history is allowed",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": "git log --oneline -1"},
                },
            ),
        )
        checks += self_test_expect_pass(
            "rg regex alternation is allowed",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": 'rg "TextPayload|StickerPayload" AnimiApp/Sources TVECore/Sources'},
                },
            ),
        )
        checks += self_test_expect_pass(
            "shell pipe is allowed for normal inspection",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": 'rg "TextPayload" AnimiApp/Sources | wc -l'},
                },
            ),
        )
        checks += self_test_expect_block(
            "date mutation form is blocked",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": "date 010101011970"},
                },
            ),
        )
        checks += self_test_expect_block(
            "git branch creation is blocked",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": "git branch new-branch"},
                },
            ),
        )
        checks += self_test_expect_block(
            "git output writes are blocked",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": "git show --output=/tmp/out HEAD"},
                },
            ),
        )
        checks += self_test_expect_pass(
            "normal verification bash is allowed",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": "swift test --package-path TVECore"},
                },
            ),
        )
        checks += self_test_expect_pass(
            "cd composition is allowed for normal verification",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": "cd TVECore && swift test"},
                },
            ),
        )
        checks += self_test_expect_pass(
            "grep with multiple repo paths is allowed",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": 'grep -rn "TextPayload" AnimiApp/Sources TVECore/Sources'},
                },
            ),
        )
        checks += self_test_expect_pass(
            "repo-local scripting is allowed",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": "python3 Scripts/read_only_report.py"},
                },
            ),
        )
        checks += self_test_expect_pass(
            "artifact mkdir is allowed",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": f"mkdir -p {TASKS_REL}/{task.name}/artifacts"},
                },
            ),
        )
        checks += self_test_expect_block(
            "delete command is blocked",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": "rm -rf AnimiApp/Sources"},
                },
            ),
        )
        checks += self_test_expect_block(
            "package install is blocked",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": "npm install"},
                },
            ),
        )
        checks += self_test_expect_block(
            "shell command substitution is blocked",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": "echo $(git status)"},
                },
            ),
        )

        self_test_make_marker(root, task)
        checks += self_test_expect_pass(
            "implementation slash matches active marker",
            lambda: handle_user_prompt_expansion(
                root,
                {
                    "command_name": ANIMI_IMPLEMENT_SKILL,
                    "command_args": f"{TASKS_REL}/{task.name}",
                },
            ),
        )
        checks += self_test_expect_pass(
            "legacy marker-listed write is allowed",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Edit",
                    "tool_input": {"file_path": "AnimiApp/Sources/Allowed.swift"},
                },
            ),
        )
        checks += self_test_expect_pass(
            "normal implementation write is allowed",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Edit",
                    "tool_input": {"file_path": "AnimiApp/Sources/Other.swift"},
                },
            ),
        )
        checks += self_test_expect_block(
            "eternal protected path is blocked",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Edit",
                    "tool_input": {"file_path": "AGENTS.md"},
                },
            ),
        )
        checks += self_test_expect_pass(
            "claude-summary.md is allowed during implementation",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Write",
                    "tool_input": {"file_path": f"{TASKS_REL}/{task.name}/claude-summary.md"},
                },
            ),
        )
        checks += self_test_expect_pass(
            "task artifacts are allowed during implementation",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Write",
                    "tool_input": {"file_path": f"{TASKS_REL}/{task.name}/artifacts/log.txt"},
                },
            ),
        )
        checks += self_test_expect_pass(
            "normal implementation bash is allowed",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": "ANIMI_HOOK_SELF_TEST=1 bash Scripts/run_animiapp_tests.sh"},
                },
            ),
        )
        checks += self_test_expect_block(
            "mutating git is always blocked",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": "git reset --hard"},
                },
            ),
        )
        checks += self_test_expect_pass(
            "normal implementation verification is allowed",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": "xcodebuild test -project AnimiApp/AnimiApp.xcodeproj"},
                },
            ),
        )

        self_test_make_marker(root, task)
        self_test_write(task / "codex-plan-review.md", "# Codex Plan Review\n\nStatus: APPROVED\n\nTampered.\n")
        checks += self_test_expect_block(
            "codex-plan-review hash mismatch invalidates marker",
            lambda: validate_marker(root),
        )

        subprocess.run(["git", "init"], cwd=str(root), stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
        self_test_write(root / ".git" / "info" / "exclude", ".codex-local/\n")
        self_test_make_task(root)
        self_test_make_marker(root, task)
        self_test_write(root / "AGENTS.md", "# protected\n")
        checks += self_test_expect_stop(
            "post-tool audit stops on protected tree change",
            lambda: handle_post_tool_batch(root),
        )

        tool_result = root.parent / ".claude" / "projects" / "fixture" / "tool-results" / "result.txt"
        self_test_write(tool_result, "ok\n")
        checks += self_test_expect_pass(
            "Claude tool-result paths are readable",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": f"rg ok {tool_result.as_posix()}"},
                },
            ),
        )
        checks += self_test_expect_block(
            "external redirection stays blocked",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": "echo ok > ~/.ssh/animi-test"},
                },
            ),
        )

    print(f"animi_write_gate self-test passed ({checks} checks)")
    return 0


def main() -> int:
    global CURRENT_EVENT_NAME
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return run_self_test()

    data = load_input()
    root = repo_root()
    event_name = data.get("hook_event_name")
    if not isinstance(event_name, str):
        raise GateError("hook_event_name is missing")
    CURRENT_EVENT_NAME = event_name

    if event_name == "UserPromptExpansion":
        handle_user_prompt_expansion(root, data)
    elif event_name == "PreToolUse":
        handle_pre_tool_use(root, data)
    elif event_name == "ConfigChange":
        handle_config_change(data)
    elif event_name == "PostToolBatch":
        handle_post_tool_batch(root)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except GateError as exc:
        deny(str(exc), CURRENT_EVENT_NAME)
    except SystemExit:
        raise
    except Exception as exc:
        print(f"Animi write gate failed closed: {exc}", file=sys.stderr)
        raise SystemExit(2)
