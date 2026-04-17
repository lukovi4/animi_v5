#!/bin/bash
# AnimiApp test runner.
# Always uses a fresh DerivedData path to avoid stale-bundle failures
# (e.g. manifestNotFound for Templates/Catalog/manifest.json).
# Override with ANIMIAPP_DERIVED_DATA_PATH to pin a specific path.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_PATH="$REPO_ROOT/AnimiApp/AnimiApp.xcodeproj"
SCHEME="AnimiApp"
TMP_ROOT="${TMPDIR:-/tmp}"

# Fresh unique DerivedData per run unless explicitly overridden
if [[ -n "${ANIMIAPP_DERIVED_DATA_PATH:-}" ]]; then
    DERIVED_DATA_PATH="$ANIMIAPP_DERIVED_DATA_PATH"
else
    DERIVED_DATA_PATH="$(mktemp -d "${TMP_ROOT%/}/AnimiAppTests.XXXXXX")"
fi

FALLBACK_SIMULATOR_NAME="${ANIMIAPP_SIMULATOR_NAME:-iPhone 16}"
FALLBACK_SIMULATOR_OS="${ANIMIAPP_SIMULATOR_OS:-latest}"
FALLBACK_SIMULATOR_ARCH="${ANIMIAPP_SIMULATOR_ARCH:-$(uname -m)}"

resolve_destination() {
    local destinations_output preferred_devices device versions latest_version
    destinations_output="$(xcodebuild -showdestinations -project "$PROJECT_PATH" -scheme "$SCHEME" 2>&1)"

    if [[ -n "${ANIMIAPP_SIMULATOR_NAME:-}" && -n "${ANIMIAPP_SIMULATOR_OS:-}" ]]; then
        printf 'platform=iOS Simulator,arch=%s,name=%s,OS=%s\n' "$FALLBACK_SIMULATOR_ARCH" "$ANIMIAPP_SIMULATOR_NAME" "$ANIMIAPP_SIMULATOR_OS"
        return 0
    fi

    if [[ -n "${ANIMIAPP_SIMULATOR_NAME:-}" ]]; then
        preferred_devices=("${ANIMIAPP_SIMULATOR_NAME}")
    else
        preferred_devices=(
            "iPhone 17 Pro"
            "iPhone 16 Pro"
            "iPhone 17"
            "iPhone 16"
            "iPhone 15"
            "iPhone SE (3rd generation)"
        )
    fi

    for device in "${preferred_devices[@]}"; do
        versions="$(
            {
                printf '%s\n' "$destinations_output" \
                    | awk -F 'name:' -v device="$device" '
                        /platform:iOS Simulator/ && NF > 1 {
                            name = $2
                            sub(/[[:space:]]*}[[:space:]]*$/, "", name)
                            if (name == device && match($0, /OS:[^,}]*/)) {
                                os = substr($0, RSTART + 3, RLENGTH - 3)
                                gsub(/^[[:space:]]+|[[:space:]]+$/, "", os)
                                print os
                            }
                        }
                    ' \
                    | sort -V
            } || true
        )"

        if [[ -n "$versions" ]]; then
            latest_version="$(printf '%s\n' "$versions" | tail -n 1)"
            printf 'platform=iOS Simulator,arch=%s,name=%s,OS=%s\n' "$FALLBACK_SIMULATOR_ARCH" "$device" "$latest_version"
            return 0
        fi
    done

    local first_available_device first_available_os
    first_available_device="$(
        printf '%s\n' "$destinations_output" \
            | awk -F 'name:' '
                /platform:iOS Simulator/ && NF > 1 {
                    name = $2
                    sub(/[[:space:]]*}[[:space:]]*$/, "", name)
                    if (name ~ /^iPhone /) {
                        print name
                        exit
                    }
                }
            ' || true
    )"
    first_available_os="$(
        printf '%s\n' "$destinations_output" \
            | awk -v device="$first_available_device" '
                /platform:iOS Simulator/ && index($0, "name:" device) && match($0, /OS:[^,}]*/) {
                    os = substr($0, RSTART + 3, RLENGTH - 3)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", os)
                    print os
                    exit
                }
            ' || true
    )"

    if [[ -n "$first_available_device" && -n "$first_available_os" ]]; then
        echo "Falling back to first available iPhone simulator: $first_available_device ($first_available_os)" >&2
        printf 'platform=iOS Simulator,arch=%s,name=%s,OS=%s\n' "$FALLBACK_SIMULATOR_ARCH" "$first_available_device" "$first_available_os"
        return 0
    fi

    echo "Falling back to platform=iOS Simulator,arch=$FALLBACK_SIMULATOR_ARCH,name=$FALLBACK_SIMULATOR_NAME,OS=$FALLBACK_SIMULATOR_OS" >&2
    printf 'platform=iOS Simulator,arch=%s,name=%s,OS=%s\n' "$FALLBACK_SIMULATOR_ARCH" "$FALLBACK_SIMULATOR_NAME" "$FALLBACK_SIMULATOR_OS"
}

DESTINATION="$(resolve_destination)"

if [[ "${1:-}" == "--print-destination" ]]; then
    printf '%s\n' "$DESTINATION"
    exit 0
fi

echo "Running AnimiApp tests"
echo "Project: $PROJECT_PATH"
echo "Scheme: $SCHEME"
echo "Destination: $DESTINATION"
echo "DerivedData: $DERIVED_DATA_PATH"

xcodebuild test \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO
