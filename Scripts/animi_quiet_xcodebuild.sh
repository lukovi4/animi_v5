#!/usr/bin/env bash
# Run a noisy xcodebuild/test command while keeping raw output out of Codex context.
# The full command output is written to --log; stdout receives a compact summary only.

set -uo pipefail

usage() {
    cat <<'USAGE'
Usage:
  Scripts/animi_quiet_xcodebuild.sh --log <artifact-log> [--label <name>] [--summary-lines <n>] -- <command> [args...]

Examples:
  Scripts/animi_quiet_xcodebuild.sh --log .codex-local/tasks/t/artifacts/focused-tests.log --label focused-tests -- xcodebuild test ...
  Scripts/animi_quiet_xcodebuild.sh --log .codex-local/tasks/t/artifacts/full-gate.log --label full-gate -- bash Scripts/run_animiapp_tests.sh

Raw stdout/stderr from the command is never printed to the Codex thread.
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUMMARY_SCRIPT="$SCRIPT_DIR/animi_test_log_summary.sh"

LOG_PATH=""
LABEL=""
SUMMARY_LINES=40

while [[ $# -gt 0 ]]; do
    case "$1" in
        --log)
            LOG_PATH="${2:?missing value for --log}"
            shift 2
            ;;
        --label)
            LABEL="${2:?missing value for --label}"
            shift 2
            ;;
        --summary-lines)
            SUMMARY_LINES="${2:?missing value for --summary-lines}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "error: unknown option: $1" >&2
            usage >&2
            exit 64
            ;;
        *)
            echo "error: command must be passed after --" >&2
            usage >&2
            exit 64
            ;;
    esac
done

if [[ -z "$LOG_PATH" ]]; then
    echo "error: --log is required" >&2
    usage >&2
    exit 64
fi

if [[ $# -eq 0 ]]; then
    echo "error: command is required after --" >&2
    usage >&2
    exit 64
fi

if [[ ! -x "$SUMMARY_SCRIPT" ]]; then
    echo "error: summary script is missing or not executable: $SUMMARY_SCRIPT" >&2
    exit 70
fi

mkdir -p "$(dirname "$LOG_PATH")"

STARTED_AT="$(date +%Y-%m-%dT%H:%M:%S%z)"

{
    echo "quiet_wrapper: Scripts/animi_quiet_xcodebuild.sh"
    echo "started_at: $STARTED_AT"
    echo "label: ${LABEL:-$1}"
    echo "command:"
    printf '  '
    printf '%q ' "$@"
    printf '\n'
    echo "output:"
    "$@"
} > "$LOG_PATH" 2>&1
STATUS=$?

{
    echo
    echo "finished_at: $(date +%Y-%m-%dT%H:%M:%S%z)"
    echo "exit_code: $STATUS"
} >> "$LOG_PATH"

"$SUMMARY_SCRIPT" --label "${LABEL:-$1}" --exit-code "$STATUS" --max-lines "$SUMMARY_LINES" "$LOG_PATH"

exit "$STATUS"
