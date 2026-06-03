#!/usr/bin/env python3
"""Animi Claude Code write gate.

This hook blocks only critical actions:
- deletion/destructive cleanup commands;
- git reset/clean/restore/checkout/rm cleanup commands.

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

SHA256_RE = re.compile(r"^[a-fA-F0-9]{64}$")
ENV_ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=.*$")
CURRENT_EVENT_NAME = ""

SHELL_CONTROL_TOKENS = {"|", "||", "&", "&&", ";"}
SHELL_REDIRECT_TOKENS = {">", ">>", "<", "<<", "2>", "2>>", "&>", ">&"}
DELETION_SHELL_COMMANDS = {
    "rm",
    "rmdir",
    "shred",
    "unlink",
}
GIT_DESTRUCTIVE_CLEANUP_SUBCOMMANDS = {
    "checkout",
    "clean",
    "reset",
    "restore",
    "rm",
}


class GateError(Exception):
    pass


class Marker:
    def __init__(self, data: Dict[str, Any], task_folder: Path) -> None:
        self.data = data
        self.task_folder = task_folder

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

    validate_string_list(data, "baseline_dirty_paths", allow_empty=True)
    return Marker(data, task_folder)


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


def normalize_shell_newlines(command: str) -> str:
    result: List[str] = []
    quote: Optional[str] = None
    escaped = False
    previous_was_separator = False
    for char in command:
        if escaped:
            result.append(char)
            escaped = False
            previous_was_separator = False
            continue
        if char == "\\" and quote != "'":
            result.append(char)
            escaped = True
            previous_was_separator = False
            continue
        if quote:
            result.append(char)
            if char == quote:
                quote = None
            previous_was_separator = False
            continue
        if char in {"'", '"'}:
            quote = char
            result.append(char)
            previous_was_separator = False
            continue
        if char in {"\n", "\r"}:
            if not previous_was_separator:
                result.append(" ; ")
                previous_was_separator = True
            continue
        result.append(char)
        previous_was_separator = char in SHELL_CONTROL_TOKENS
    return "".join(result)


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
    try:
        tokens = git_tokens_without_global_flags(shell_tokens(command))
    except GateError:
        return False
    if len(tokens) < 2:
        return False
    if tokens[0] != "git":
        return False
    subcommand = tokens[1]
    if subcommand == "branch":
        rest = tokens[2:]
        return any(token in {"-d", "-D", "--delete"} for token in rest)
    if subcommand == "tag":
        rest = tokens[2:]
        return any(token in {"-d", "--delete"} for token in rest)
    return subcommand in GIT_DESTRUCTIVE_CLEANUP_SUBCOMMANDS


def validate_find_command(root: Path, tokens: Sequence[str]) -> Optional[str]:
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if token == "-delete":
            return "mutating find delete expression is blocked"
        if token in {"-exec", "-execdir", "-ok", "-okdir"}:
            payload: List[str] = []
            index += 1
            while index < len(tokens) and tokens[index] != ";":
                if tokens[index] != "{}":
                    payload.append(tokens[index])
                index += 1
            if payload:
                reason = segment_is_dangerous(root, payload)
                if reason:
                    return f"find {token} payload is blocked: {reason}"
        index += 1
    return None


def shell_c_payload(tokens: Sequence[str]) -> Optional[str]:
    for index, token in enumerate(tokens[1:], start=1):
        if token == "-c" or (token.startswith("-") and "c" in token[1:]):
            if index + 1 >= len(tokens):
                return ""
            return tokens[index + 1]
    return None


def segment_is_dangerous(root: Path, segment: Sequence[str]) -> Optional[str]:
    tokens = strip_env_assignments(segment)
    if not tokens:
        return "empty command segment"
    first = tokens[0]
    if first in DELETION_SHELL_COMMANDS:
        return f"{first} is blocked"
    if first == "git":
        if is_mutating_git_command(" ".join(shlex.quote(token) for token in tokens)):
            return "git destructive cleanup is blocked"
    if first == "find":
        reason = validate_find_command(root, tokens)
        if reason:
            return reason
    if first in {"bash", "sh", "zsh"}:
        payload = shell_c_payload(tokens)
        if payload is not None:
            if not payload:
                return "shell -c is missing a command"
            reason = is_dangerous_bash_command(root, payload)
            if reason:
                return f"shell -c payload is blocked: {reason}"
    return None


def command_substitution_payloads(command: str) -> List[str]:
    payloads: List[str] = []
    index = 0
    while index < len(command):
        if command.startswith("$(", index):
            depth = 1
            start = index + 2
            cursor = start
            quote: Optional[str] = None
            escaped = False
            while cursor < len(command):
                char = command[cursor]
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif quote:
                    if char == quote:
                        quote = None
                elif char in {"'", '"'}:
                    quote = char
                elif command.startswith("$(", cursor):
                    depth += 1
                    cursor += 1
                elif char == ")":
                    depth -= 1
                    if depth == 0:
                        payloads.append(command[start:cursor])
                        index = cursor
                        break
                cursor += 1
            else:
                raise GateError("unterminated command substitution")
        elif command[index] == "`":
            start = index + 1
            cursor = start
            escaped = False
            while cursor < len(command):
                char = command[cursor]
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == "`":
                    payloads.append(command[start:cursor])
                    index = cursor
                    break
                cursor += 1
            else:
                raise GateError("unterminated backtick command substitution")
        index += 1
    return payloads


def is_dangerous_bash_command(root: Path, command: str, depth: int = 0) -> Optional[str]:
    if depth > 5:
        return "nested shell evaluation is too deep"
    for payload in command_substitution_payloads(command):
        reason = is_dangerous_bash_command(root, payload, depth + 1)
        if reason:
            return f"command substitution payload is blocked: {reason}"
    try:
        tokens = shell_tokens(normalize_shell_newlines(command))
    except GateError:
        return None
    for segment in command_segments(tokens):
        if segment[0] in SHELL_REDIRECT_TOKENS:
            continue
        else:
            reason = segment_is_dangerous(root, segment)
        if reason:
            return reason
    return None


def handle_bash(root: Path, tool_input: Dict[str, Any]) -> None:
    command = tool_input.get("command")
    if not isinstance(command, str) or not command.strip():
        raise GateError("Bash requires a non-empty command")
    command = command.strip()

    reason = is_dangerous_bash_command(root, command)
    if reason:
        raise GateError(reason)


def handle_write_tool(root: Path, tool_name: str, tool_input: Dict[str, Any]) -> None:
    return None


def handle_pre_tool_use(root: Path, data: Dict[str, Any]) -> None:
    tool_name = data.get("tool_name")
    tool_input = data.get("tool_input")
    if not isinstance(tool_name, str) or not isinstance(tool_input, dict):
        raise GateError("PreToolUse requires tool_name and tool_input")

    if tool_name == "Bash":
        handle_bash(root, tool_input)
        return
    if tool_name in WRITE_TOOLS:
        handle_write_tool(root, tool_name, tool_input)
        return


def handle_config_change(data: Dict[str, Any]) -> None:
    return None


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
    deleted = sorted(git_names(root, ["ls-files", "--deleted"]))
    if deleted:
        joined = ", ".join(deleted[:20])
        if len(deleted) > 20:
            joined += f", ... (+{len(deleted) - 20} more)"
        deny(f"repository has deleted tracked files: {joined}", "PostToolBatch")


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
        checks += self_test_expect_pass(
            "planning production write is allowed by hook",
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
            "read-only git tag listing is allowed",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": "git tag --list"},
                },
            ),
        )
        checks += self_test_expect_pass(
            "git tag creation is allowed by hook",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": "git tag v1.0.0"},
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
        checks += self_test_expect_pass(
            "date mutation form is allowed by hook",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": "date 010101011970"},
                },
            ),
        )
        checks += self_test_expect_pass(
            "git branch creation is allowed by hook",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": "git branch new-branch"},
                },
            ),
        )
        checks += self_test_expect_pass(
            "git output to temp is allowed",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": "git show --output=/tmp/out HEAD"},
                },
            ),
        )
        checks += self_test_expect_pass(
            "git output to protected path is allowed by hook",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": "git show --output=AGENTS.md HEAD"},
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
            "stderr redirect to dev null is allowed",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {
                        "command": 'grep -rn "No exact matches" /tmp/preview_decoder_budget_fix/Logs/Test/*.xcresult 2>/dev/null'
                    },
                },
            ),
        )
        checks += self_test_expect_pass(
            "read-only external absolute paths are allowed",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": "grep -rn Error /Library/Logs 2>/dev/null"},
                },
            ),
        )
        checks += self_test_expect_pass(
            "safe shell command substitution is allowed",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": "echo $(git status --short)"},
                },
            ),
        )
        checks += self_test_expect_block(
            "dangerous shell command substitution is blocked",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": "echo $(rm -rf AnimiApp/Sources)"},
                },
            ),
        )
        checks += self_test_expect_pass(
            "safe shell c payload is allowed",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": "bash -c 'git status --short && rg TextPayload AnimiApp/Sources'"},
                },
            ),
        )
        checks += self_test_expect_block(
            "dangerous shell c payload is blocked",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": "bash -c 'rm -rf AnimiApp/Sources'"},
                },
            ),
        )
        checks += self_test_expect_pass(
            "inline diagnostic scripts are allowed",
            lambda: [
                handle_pre_tool_use(root, {"tool_name": "Bash", "tool_input": {"command": command}})
                for command in (
                    "python3 -c 'print(1)'",
                    "node -e 'console.log(1)'",
                )
            ],
        )
        checks += self_test_expect_pass(
            "read-only find exec is allowed",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": "find AnimiApp -name '*.swift' -exec grep -n TextPayload {} \\;"},
                },
            ),
        )
        checks += self_test_expect_block(
            "dangerous find exec payload is blocked",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": "find AnimiApp -name '*.swift' -exec rm -rf {} \\;"},
                },
            ),
        )
        checks += self_test_expect_pass(
            "network read commands are allowed",
            lambda: [
                handle_pre_tool_use(root, {"tool_name": "Bash", "tool_input": {"command": command}})
                for command in (
                    "curl -I https://example.com",
                    "wget --spider https://example.com",
                    "curl -L https://example.com -o /tmp/example.html",
                    "wget https://example.com -O /tmp/example.html",
                )
            ],
        )
        checks += self_test_expect_pass(
            "network output to protected path is allowed by hook",
            lambda: [
                handle_pre_tool_use(root, {"tool_name": "Bash", "tool_input": {"command": command}})
                for command in (
                    "curl -L https://example.com -o AGENTS.md",
                    "wget https://example.com -O Docs/agents/hook-write-gate.md",
                )
            ],
        )
        checks += self_test_expect_pass(
            "sed in-place repo file edit is allowed",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": "sed -i '' 's/a/b/' AnimiApp/Sources/File.swift"},
                },
            ),
        )
        checks += self_test_expect_pass(
            "sed in-place protected path is allowed by hook",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": "sed -i '' 's/a/b/' AGENTS.md"},
                },
            ),
        )
        checks += self_test_expect_pass(
            "plutil mutation of repo file is allowed",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": "plutil -replace Key -string Value AnimiApp/Info.plist"},
                },
            ),
        )
        checks += self_test_expect_pass(
            "plutil mutation of protected path is allowed by hook",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": "plutil -replace Key -string Value AGENTS.md"},
                },
            ),
        )
        checks += self_test_expect_pass(
            "repo-local chmod is allowed",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": "chmod +x AnimiApp/local-tool.sh"},
                },
            ),
        )
        checks += self_test_expect_pass(
            "chmod protected path is allowed by hook",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": "chmod +x Scripts/run_animiapp_tests.sh"},
                },
            ),
        )
        checks += self_test_expect_pass(
            "multi-line normal inspection bash is allowed",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {
                        "command": 'cd AnimiApp\necho "=== callers ==="\nrg "TextPayload" Sources Tests'
                    },
                },
            ),
        )
        checks += self_test_expect_pass(
            "multi-line for loop with quoted payload is allowed",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {
                        "command": (
                            "cd 6_frames_template\n"
                            "for f in image_1.json image_2.json image_3.json; do\n"
                            "  echo \"=== $f ===\"\n"
                            "  python3 -c 'print(\"line 1\")\nprint(\"line 2\")'\n"
                            "done"
                        )
                    },
                },
            ),
        )
        checks += self_test_expect_pass(
            "bash parser failure is not a hook block by itself",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": 'echo "unterminated'},
                },
            ),
        )
        checks += self_test_expect_block(
            "multi-line bash still blocks dangerous commands",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {
                        "command": 'echo "safe first line"\nrm -rf AnimiApp/Sources'
                    },
                },
            ),
        )
        checks += self_test_expect_block(
            "multi-line for loop still blocks dangerous commands",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {
                        "command": (
                            "for f in image_1.json; do\n"
                            "  echo \"$f\"\n"
                            "  rm -rf AnimiApp/Sources\n"
                            "done"
                        )
                    },
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
        checks += self_test_expect_pass(
            "package install is allowed by hook",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": "npm install"},
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
        checks += self_test_expect_pass(
            "protected path write is allowed by hook",
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
            "git reset is blocked",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": "git reset --hard"},
                },
            ),
        )
        checks += self_test_expect_block(
            "git cleanup and rollback commands are blocked",
            lambda: [
                handle_pre_tool_use(root, {"tool_name": "Bash", "tool_input": {"command": command}})
                for command in (
                    "git clean -fd",
                    "git restore AnimiApp/Sources/File.swift",
                    "git checkout -- AnimiApp/Sources/File.swift",
                    "git rm AnimiApp/Sources/File.swift",
                )
            ],
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
        checks += self_test_expect_pass(
            "invalid marker does not block normal pre-tool bash",
            lambda: handle_pre_tool_use(
                root,
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": "git status --short"},
                },
            ),
        )

        subprocess.run(["git", "init"], cwd=str(root), stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
        self_test_write(root / ".git" / "info" / "exclude", ".codex-local/\n")
        self_test_make_task(root)
        self_test_make_marker(root, task)
        checks += self_test_expect_pass(
            "post-tool audit allows protected tree changes",
            lambda: handle_post_tool_batch(root),
        )
        deleted_fixture = root / "tracked-delete-fixture.txt"
        self_test_write(deleted_fixture, "tracked\n")
        subprocess.run(["git", "add", "tracked-delete-fixture.txt"], cwd=str(root), stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
        deleted_fixture.unlink()
        checks += self_test_expect_stop(
            "post-tool audit stops on tracked file deletion",
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
        checks += self_test_expect_pass(
            "external redirection is allowed by hook",
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
