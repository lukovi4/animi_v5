#!/bin/bash
# verify_release_bundle.sh — Verifies Release bundle has no anim-*.json and has compiled.tve
#
# Usage:
#   ./Scripts/verify_release_bundle.sh <app_bundle_path>
#   ./Scripts/verify_release_bundle.sh /path/to/AnimiApp.app
#
# Exit codes:
#   0 - Bundle is valid (no anim-*.json, has compiled.tve for all templates)
#   1 - Bundle validation failed

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

if [ $# -lt 1 ]; then
    echo "Usage: $0 <app_bundle_path>"
    echo ""
    echo "Example: $0 /path/to/Build/Products/Release-iphoneos/AnimiApp.app"
    exit 1
fi

APP_BUNDLE="$1"

echo "======================================"
echo "Release Bundle Verification"
echo "======================================"
echo ""
echo "Bundle: $APP_BUNDLE"
echo ""

if [ ! -d "$APP_BUNDLE" ]; then
    echo -e "${RED}ERROR: Bundle not found: $APP_BUNDLE${NC}"
    exit 1
fi

ERRORS=0

# Check 1: No anim-*.json files
echo "Check 1: No anim-*.json files in bundle..."
ANIM_FILES=$(find "$APP_BUNDLE" -name "anim-*.json" -o -name "no-anim.json" 2>/dev/null)

if [ -n "$ANIM_FILES" ]; then
    echo -e "  ${RED}FAILED${NC} - Found animation JSON files that should be excluded:"
    echo "$ANIM_FILES" | while read -r f; do
        echo "    - $f"
    done
    ((ERRORS++))
else
    echo -e "  ${GREEN}PASSED${NC} - No animation JSON files found"
fi

# Check 2: All templates have compiled.tve
echo ""
echo "Check 2: All templates have compiled.tve..."
TEMPLATES_DIR="$APP_BUNDLE/Templates"

if [ ! -d "$TEMPLATES_DIR" ]; then
    echo -e "  ${YELLOW}SKIPPED${NC} - No Templates directory in bundle"
else
    TEMPLATE_COUNT=0
    COMPILED_COUNT=0
    MISSING_TEMPLATES=()

    for scene_file in $(find "$TEMPLATES_DIR" -name "scene.json" 2>/dev/null); do
        template_dir="$(dirname "$scene_file")"
        template_name="$(basename "$template_dir")"
        ((TEMPLATE_COUNT++))

        if [ -f "$template_dir/compiled.tve" ]; then
            ((COMPILED_COUNT++))
            echo -e "  ${GREEN}OK${NC} - $template_name has compiled.tve"
        else
            MISSING_TEMPLATES+=("$template_name")
            echo -e "  ${RED}MISSING${NC} - $template_name lacks compiled.tve"
        fi
    done

    if [ ${#MISSING_TEMPLATES[@]} -gt 0 ]; then
        ((ERRORS++))
    fi

    echo ""
    echo "  Templates: $TEMPLATE_COUNT, Compiled: $COMPILED_COUNT"
fi

# Check 3: No compiler symbols in binary (optional, for Release validation)
echo ""
echo "Check 3: No compiler pipeline symbols in binary..."
BINARY_PATH="$APP_BUNDLE/$(basename "$APP_BUNDLE" .app)"

if [ ! -f "$BINARY_PATH" ]; then
    # Try iOS bundle structure
    BINARY_PATH="$APP_BUNDLE/AnimiApp"
fi

if [ -f "$BINARY_PATH" ]; then
    COMPILER_SYMBOLS=(
        "AnimIRCompiler"
        "ScenePackageLoader"
        "AnimLoader"
        "SceneValidator"
        "AnimValidator"
        "TVECompilerCore"
    )

    FOUND_SYMBOLS=()
    for sym in "${COMPILER_SYMBOLS[@]}"; do
        if strings "$BINARY_PATH" 2>/dev/null | grep -q "$sym"; then
            FOUND_SYMBOLS+=("$sym")
        fi
    done

    if [ ${#FOUND_SYMBOLS[@]} -gt 0 ]; then
        echo -e "  ${RED}FAILED${NC} - Found compiler pipeline symbols (should not be in Release):"
        for sym in "${FOUND_SYMBOLS[@]}"; do
            echo "    - $sym"
        done
        ((ERRORS++))
    else
        echo -e "  ${GREEN}PASSED${NC} - No compiler pipeline symbols found"
    fi
else
    echo -e "  ${YELLOW}SKIPPED${NC} - Binary not found at expected path"
fi

# Summary
echo ""
echo "======================================"
echo "Summary"
echo "======================================"

if [ $ERRORS -gt 0 ]; then
    echo -e "${RED}FAILED${NC} - $ERRORS check(s) failed"
    exit 1
else
    echo -e "${GREEN}PASSED${NC} - All checks passed"
    exit 0
fi
