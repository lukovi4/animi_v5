#!/usr/bin/env bash
# Print a compact, Codex-safe summary for a test/build log.
# Full logs stay in task artifacts; this script emits only bounded evidence.

set -euo pipefail

usage() {
    cat <<'USAGE'
Usage:
  Scripts/animi_test_log_summary.sh [--label <name>] [--exit-code <code>] [--max-lines <n>] <log> [<log> ...]

Summarizes xcodebuild/AnimiApp test logs without printing full raw output.
USAGE
}

LABEL=""
EXIT_CODE=""
MAX_LINES=40

while [[ $# -gt 0 ]]; do
    case "$1" in
        --label)
            LABEL="${2:?missing value for --label}"
            shift 2
            ;;
        --exit-code)
            EXIT_CODE="${2:?missing value for --exit-code}"
            shift 2
            ;;
        --max-lines)
            MAX_LINES="${2:?missing value for --max-lines}"
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
            break
            ;;
    esac
done

if [[ $# -eq 0 ]]; then
    echo "error: at least one log path is required" >&2
    usage >&2
    exit 64
fi

if ! [[ "$MAX_LINES" =~ ^[0-9]+$ ]] || [[ "$MAX_LINES" -lt 1 ]]; then
    echo "error: --max-lines must be a positive integer" >&2
    exit 64
fi

summarize_log() {
    local log_path="$1"
    local display_label="$LABEL"
    local line_count byte_count status overall executed final_summaries failure_excerpt

    if [[ -z "$display_label" ]]; then
        display_label="$(basename "$log_path")"
    fi

    echo "label: $display_label"
    echo "log: $log_path"

    if [[ ! -f "$log_path" ]]; then
        echo "status: missing-log"
        echo
        return 1
    fi

    line_count="$(wc -l < "$log_path" | tr -d '[:space:]')"
    byte_count="$(wc -c < "$log_path" | tr -d '[:space:]')"

    status="unknown"
    if grep -Eq "TEST SUCCEEDED|\\*\\* TEST SUCCEEDED \\*\\*" "$log_path"; then
        status="passed"
    fi
    if grep -Eq "TEST FAILED|\\*\\* TEST FAILED \\*\\*|Testing failed|BUILD FAILED|BUILD FAILURE" "$log_path"; then
        status="failed"
    fi
    if [[ -n "$EXIT_CODE" && "$EXIT_CODE" != "0" ]]; then
        status="failed"
    fi

    echo "status: $status"
    if [[ -n "$EXIT_CODE" ]]; then
        echo "exit_code: $EXIT_CODE"
    fi
    echo "log_lines: $line_count"
    echo "log_bytes: $byte_count"

    overall="$(
        grep -E "\\*\\* TEST (SUCCEEDED|FAILED) \\*\\*|TEST (SUCCEEDED|FAILED)|Testing failed|BUILD (SUCCEEDED|FAILED|FAILURE)" "$log_path" \
            | tail -n 5 || true
    )"
    executed="$(
        grep -E "Executed [0-9]+ tests?|[0-9]+ tests?, [0-9]+ failures|[0-9]+ failures|[0-9]+ skipped" "$log_path" \
            | tail -n 8 || true
    )"
    final_summaries="$(
        grep -E "Test Suite '.*' (passed|failed)|Failing tests:|Failed tests:|Skipped tests:" "$log_path" \
            | tail -n 8 || true
    )"

    if [[ -n "$overall$executed$final_summaries" ]]; then
        echo "summary:"
        if [[ -n "$overall" ]]; then
            printf '%s\n' "$overall" | sed 's/^/  /'
        fi
        if [[ -n "$executed" ]]; then
            printf '%s\n' "$executed" | sed 's/^/  /'
        fi
        if [[ -n "$final_summaries" ]]; then
            printf '%s\n' "$final_summaries" | sed 's/^/  /'
        fi
    else
        echo "summary: no standard xcodebuild test summary lines found"
    fi

    if [[ "$status" == "failed" ]]; then
        failure_excerpt="$(
            grep -En "error:|failed|Failure|XCTAssert|Fatal error|\\*\\* TEST FAILED \\*\\*|Testing failed|BUILD FAILED|Command .* failed" "$log_path" \
                | tail -n "$MAX_LINES" || true
        )"
        if [[ -n "$failure_excerpt" ]]; then
            echo "failure_excerpt:"
            printf '%s\n' "$failure_excerpt" | sed 's/^/  /'
        fi
    fi

    echo
}

result=0
for log_path in "$@"; do
    summarize_log "$log_path" || result=1
done

exit "$result"
