#!/usr/bin/env python3
"""Animi Claude Code write gate.

This hook is intentionally conservative:
- unknown write tool input shapes are blocked;
- no-marker mode allows only Planning Pass claude-plan.md writes;
- marker mode allows only exact approved paths and derived task artifacts.
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
from typing import Any, Dict, Iterable, List, Optional, Sequence, Set


MARKER_REL = ".codex-local/active-implementation.json"
TASKS_REL = ".codex-local/tasks"
ANIMI_PLANNING_SKILL = "animi-planning-pass"
ANIMI_IMPLEMENT_SKILL = "animi-implement-approved-plan"
WRITE_TOOLS = {"Write", "Edit", "MultiEdit", "NotebookEdit"}

ETERNAL_DENY_EXACT = {
    ".codex-local/active-implementation.json",
    "AGENTS.md",
    "CLAUDE.md",
}
ETERNAL_DENY_PREFIXES = (
    ".claude/",
    ".agents/",
    "Docs/agents/",
)
POST_TOOL_TRANSIENT_PATHS = {
    ".claude/scheduled_tasks.lock",
}

MUTATING_GIT_SUBCOMMANDS = {
    "add",
    "am",
    "apply",
    "bisect",
    "branch",
    "checkout",
    "cherry-pick",
    "clean",
    "commit",
    "config",
    "gc",
    "merge",
    "mv",
    "push",
    "rebase",
    "reflog",
    "reset",
    "restore",
    "revert",
    "rm",
    "stash",
    "switch",
    "tag",
    "update-index",
    "update-ref",
}

UNSAFE_BASH_PATTERNS = (
    ";",
    "&&",
    "||",
    "|",
    ">",
    "<",
    "$(",
    "`",
    "<<",
)
UNSAFE_BASH_WORDS = re.compile(r"(^|\s)(tee|eval)(\s|$)")
UNSAFE_BASH_SHELL_C = re.compile(r"(^|\s)(bash|sh)\s+-c(\s|$)")
SHA256_RE = re.compile(r"^[a-fA-F0-9]{64}$")
ENV_ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=.*$")
CURRENT_EVENT_NAME = ""

READ_ONLY_BASH_COMMANDS = {
    "pwd",
    "ls",
    "rg",
    "grep",
    "sed",
    "head",
    "tail",
    "wc",
    "find",
    "git",
    "plutil",
}
FIND_MUTATING_EXPRESSIONS = {"-delete", "-exec", "-execdir", "-ok", "-okdir", "-fls", "-fprint", "-fprintf"}
GIT_DIFF_ALLOWED_FLAGS = {
    "--cached",
    "--staged",
    "--name-only",
    "--name-status",
    "--stat",
    "--numstat",
    "--shortstat",
    "--check",
}


class GateError(Exception):
    pass


class Marker:
    def __init__(self, data: Dict[str, Any], task_folder: Path, approved_paths: Set[Path], allowed_bash: Set[str], baseline_dirty: Set[str]) -> None:
        self.data = data
        self.task_folder = task_folder
        self.approved_paths = approved_paths
        self.allowed_bash = allowed_bash
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


def bash_string_is_simple(command: str) -> bool:
    if "\n" in command or "\r" in command:
        return False
    if any(pattern in command for pattern in UNSAFE_BASH_PATTERNS):
        return False
    if UNSAFE_BASH_WORDS.search(command):
        return False
    if UNSAFE_BASH_SHELL_C.search(command):
        return False
    return True


def validate_allowed_bash(commands: Iterable[str]) -> Set[str]:
    allowed: Set[str] = set()
    for command in commands:
        trimmed = command.strip()
        if not bash_string_is_simple(trimmed):
            raise GateError(f"unsafe allowed_bash_exact entry: {trimmed}")
        allowed.add(trimmed)
    return allowed


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

    plan_approved = task_folder / "plan.approved.md"
    claude_task = task_folder / "claude-task.md"
    claude_plan = task_folder / "claude-plan.md"
    codex_review = task_folder / "codex-plan-review.md"
    if not has_status(plan_approved, "APPROVED"):
        raise GateError("plan.approved.md must contain Status: APPROVED")
    require_file(claude_task, "claude-task.md")
    require_file(claude_plan, "claude-plan.md")
    if not has_status(codex_review, "APPROVED"):
        raise GateError("codex-plan-review.md must contain Status: APPROVED")

    expected_review_hash = data.get("codex_plan_review_sha256")
    if not isinstance(expected_review_hash, str) or not SHA256_RE.match(expected_review_hash):
        raise GateError("codex_plan_review_sha256 must be a 64-character hex string")
    actual_review_hash = hashlib.sha256(codex_review.read_bytes()).hexdigest()
    if actual_review_hash.lower() != expected_review_hash.lower():
        raise GateError("codex-plan-review.md SHA256 does not match marker")

    approved_path_values = validate_string_list(data, "approved_paths", allow_empty=False)
    approved_paths: Set[Path] = set()
    for item in approved_path_values:
        approved = canonicalize_repo_relative(root, item, "approved_paths")
        if not is_under(approved, root):
            raise GateError(f"approved path is outside repository: {item}")
        if is_eternal_denied(root, approved):
            raise GateError(f"approved path is eternally denied: {item}")
        approved_paths.add(approved)

    allowed_bash = validate_allowed_bash(validate_string_list(data, "allowed_bash_exact", allow_empty=True))
    baseline_dirty = set(validate_string_list(data, "baseline_dirty_paths", allow_empty=True))
    return Marker(data, task_folder, approved_paths, allowed_bash, baseline_dirty)


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
    if not has_status(task_folder / "plan.approved.md", "APPROVED"):
        raise GateError("planning pass requires plan.approved.md with Status: APPROVED")
    require_file(task_folder / "claude-task.md", "claude-task.md")
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


def implementation_target_allowed(marker: Marker, target: Path) -> bool:
    if target in marker.approved_paths:
        return True
    summary = (marker.task_folder / "claude-summary.md").resolve(strict=False)
    artifacts = (marker.task_folder / "artifacts").resolve(strict=False)
    return target == summary or is_under(target, artifacts)


def strip_env_assignments(tokens: Sequence[str]) -> List[str]:
    result = list(tokens)
    while result and ENV_ASSIGN_RE.match(result[0]):
        result.pop(0)
    return result


def is_mutating_git_command(command: str) -> bool:
    try:
        tokens = shlex.split(command)
    except ValueError:
        return True
    tokens = strip_env_assignments(tokens)
    if len(tokens) < 2:
        return False
    if tokens[0] != "git":
        return False
    subcommand = tokens[1]
    if subcommand == "-C" and len(tokens) >= 4:
        subcommand = tokens[3]
    if subcommand == "branch":
        return any(token in {"-d", "-D", "--delete"} for token in tokens[2:])
    return subcommand in MUTATING_GIT_SUBCOMMANDS


def is_dangerous_direct_command(command: str) -> bool:
    try:
        tokens = shlex.split(command)
    except ValueError:
        return True
    tokens = strip_env_assignments(tokens)
    if not tokens:
        return True
    first = tokens[0]
    if first in {"rm", "mv", "cp", "chmod", "chown", "touch", "mkdir", "python", "python3", "perl", "ruby", "node"}:
        return True
    if first == "sed" and "-i" in tokens:
        return True
    return False


def token_looks_like_path(token: str) -> bool:
    if not token or token.startswith("-"):
        return False
    return token.startswith(("/", "./", "../", "~")) or "/" in token or token in {".", ".."}


def validate_repo_path_token(root: Path, token: str) -> None:
    path = Path(token)
    if token.startswith("~"):
        raise GateError(f"read-only Bash path is outside repository: {token}")
    if not path.is_absolute():
        path = root / path
    resolved = path.resolve(strict=False)
    if not is_under(resolved, root):
        raise GateError(f"read-only Bash path is outside repository: {token}")


def validate_path_like_tokens(root: Path, tokens: Sequence[str], start_index: int = 1) -> None:
    for token in tokens[start_index:]:
        if token_looks_like_path(token):
            validate_repo_path_token(root, token)


def read_only_git_allowed(root: Path, tokens: Sequence[str]) -> bool:
    args = list(strip_env_assignments(tokens))
    if len(args) < 2 or args[0] != "git":
        return False
    subcommand = args[1]
    rest = args[2:]

    if subcommand == "status":
        return all(not token.startswith("--porcelain=v1=") for token in rest)

    if subcommand == "diff":
        path_mode = False
        for token in rest:
            if path_mode:
                validate_repo_path_token(root, token)
                continue
            if token == "--":
                path_mode = True
                continue
            if token in GIT_DIFF_ALLOWED_FLAGS or re.match(r"^-U\d+$", token) or re.match(r"^--unified=\d+$", token):
                continue
            return False
        return True

    return False


def read_only_find_allowed(root: Path, tokens: Sequence[str]) -> bool:
    if any(token in FIND_MUTATING_EXPRESSIONS for token in tokens):
        return False
    args = list(tokens[1:])
    path_tokens: List[str] = []
    for token in args:
        if token.startswith("-") or token in {"!", "(", ")"}:
            break
        path_tokens.append(token)
    if not path_tokens:
        path_tokens = ["."]
    for token in path_tokens:
        validate_repo_path_token(root, token)
    validate_path_like_tokens(root, args, 0)
    return True


def read_only_plutil_allowed(root: Path, tokens: Sequence[str]) -> bool:
    if "-lint" not in tokens[1:]:
        return False
    validate_path_like_tokens(root, tokens)
    return True


def read_only_sed_allowed(root: Path, tokens: Sequence[str]) -> bool:
    if any(token == "-i" or token.startswith("-i") for token in tokens[1:]):
        return False
    if not any(token == "-n" or token.startswith("-n") for token in tokens[1:]):
        return False
    validate_path_like_tokens(root, tokens)
    return True


def read_only_tail_allowed(root: Path, tokens: Sequence[str]) -> bool:
    if any(token == "-f" or token.startswith("-f") or token == "--follow" or token.startswith("--follow=") for token in tokens[1:]):
        return False
    validate_path_like_tokens(root, tokens)
    return True


def read_only_bash_allowed(root: Path, command: str) -> bool:
    if not bash_string_is_simple(command):
        return False
    if is_mutating_git_command(command) or is_dangerous_direct_command(command):
        return False
    try:
        tokens = shlex.split(command)
    except ValueError as exc:
        raise GateError(f"cannot parse Bash command: {exc}") from exc
    tokens = strip_env_assignments(tokens)
    if not tokens:
        return False
    if tokens[0] not in READ_ONLY_BASH_COMMANDS:
        return False

    if tokens[0] == "git":
        return read_only_git_allowed(root, tokens)
    if tokens[0] == "find":
        return read_only_find_allowed(root, tokens)
    if tokens[0] == "plutil":
        return read_only_plutil_allowed(root, tokens)
    if tokens[0] == "sed":
        return read_only_sed_allowed(root, tokens)
    if tokens[0] == "tail":
        return read_only_tail_allowed(root, tokens)

    validate_path_like_tokens(root, tokens)
    return True


def handle_bash(root: Path, tool_input: Dict[str, Any], marker: Optional[Marker]) -> None:
    command = tool_input.get("command")
    if not isinstance(command, str) or not command.strip():
        raise GateError("Bash requires a non-empty command")
    command = command.strip()

    if is_mutating_git_command(command):
        raise GateError("git-mutating commands are blocked")

    if read_only_bash_allowed(root, command):
        return

    if marker is None:
        raise GateError("Bash command is not an allowed read-only inspection command")

    if command not in marker.allowed_bash:
        raise GateError("Bash command is neither safe read-only inspection nor marker allowed_bash_exact")
    if not bash_string_is_simple(command):
        raise GateError("Bash command contains blocked shell composition")
    if is_dangerous_direct_command(command):
        raise GateError("Bash command uses a blocked mutating executable")


def handle_write_tool(root: Path, tool_name: str, tool_input: Dict[str, Any], marker: Optional[Marker]) -> None:
    targets = extract_target_paths(root, tool_name, tool_input)
    for target in targets:
        if is_eternal_denied(root, target):
            raise GateError(f"write to protected path is blocked: {rel_string(root, target)}")
        if marker is None:
            if not planning_target_allowed(root, target):
                raise GateError(f"planning mode may write only claude-plan.md: {rel_string(root, target)}")
        elif not implementation_target_allowed(marker, target):
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
        if implementation_target_allowed(marker, target):
            continue
        violations.append(rel)

    if violations:
        joined = ", ".join(violations[:20])
        if len(violations) > 20:
            joined += f", ... (+{len(violations) - 20} more)"
        deny(f"repository changed outside marker-approved scope: {joined}", "PostToolBatch")


def self_test_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def self_test_make_task(root: Path) -> Path:
    task = root / TASKS_REL / "2026-05-31-hook-self-test"
    self_test_write(task / "plan.approved.md", "# Plan\n\nStatus: APPROVED\n")
    self_test_write(task / "claude-task.md", "# Claude Task\n")
    self_test_write(task / "claude-plan.md", "# Claude Plan\n\nStatus: Proposed\n")
    self_test_write(task / "codex-plan-review.md", "# Codex Plan Review\n\nStatus: APPROVED\n")
    return task


def self_test_make_marker(root: Path, task: Path, allowed_bash: Optional[List[str]] = None) -> None:
    codex_review = task / "codex-plan-review.md"
    review_hash = hashlib.sha256(codex_review.read_bytes()).hexdigest()
    now = dt.datetime.now(dt.timezone.utc)
    data = {
        "schema_version": 1,
        "status": "IMPLEMENTATION_APPROVED",
        "task_id": task.name,
        "task_folder": f"{TASKS_REL}/{task.name}",
        "approved_paths": [
            "AnimiApp/Sources/Allowed.swift",
        ],
        "baseline_dirty_paths": [],
        "allowed_bash_exact": allowed_bash if allowed_bash is not None else [
            "ANIMI_HOOK_SELF_TEST=1 bash Scripts/run_animiapp_tests.sh",
        ],
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
        checks += self_test_expect_block(
            "expensive bash is blocked without marker",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": "swift test --package-path TVECore"},
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
            "marker-approved write is allowed",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Edit",
                    "tool_input": {"file_path": "AnimiApp/Sources/Allowed.swift"},
                },
            ),
        )
        checks += self_test_expect_block(
            "unapproved implementation write is blocked",
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
            "marker exact bash is allowed",
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
        checks += self_test_expect_block(
            "unsafe allowed_bash_exact invalidates marker",
            lambda: (
                self_test_make_marker(root, task, ["echo ok && rm -rf x"]),
                validate_marker(root),
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
        self_test_write(root / "Unapproved.swift", "// outside marker\n")
        checks += self_test_expect_stop(
            "post-tool audit stops on unapproved tree change",
            lambda: handle_post_tool_batch(root),
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
