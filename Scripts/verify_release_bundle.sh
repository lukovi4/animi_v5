#!/bin/bash
# verify_release_bundle.sh — Verifies app bundle topology
#
# Usage:
#   ./Scripts/verify_release_bundle.sh <app_bundle_path>
#   ./Scripts/verify_release_bundle.sh <app_bundle_path> --check-symbols
#   ./Scripts/verify_release_bundle.sh <app_bundle_path> --verify-sources
#
# Options:
#   --check-symbols    Check for compiler pipeline symbols in binary (Release only)
#   --verify-sources   Verify Scenes/<id>/images/ matches SceneSources/<id>/images/
#
# Exit codes:
#   0 - Bundle is valid
#   1 - Bundle validation failed

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

if [ $# -lt 1 ]; then
    echo "Usage: $0 <app_bundle_path> [--check-symbols] [--verify-sources]"
    echo ""
    echo "Example: $0 /path/to/Build/Products/Release-iphoneos/AnimiApp.app"
    exit 1
fi

APP_BUNDLE="$1"
CHECK_SYMBOLS=false
VERIFY_SOURCES=false

for arg in "${@:2}"; do
    case $arg in
        --check-symbols)
            CHECK_SYMBOLS=true
            ;;
        --verify-sources)
            VERIFY_SOURCES=true
            ;;
    esac
done

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

# Check 1: No scene source files anywhere in bundle
echo "Check 1: No scene source files anywhere in bundle..."
FORBIDDEN_FILES=$(find "$APP_BUNDLE" \( -name "scene.json" -o -name "anim-*.json" -o -name "no-anim.json" \) 2>/dev/null)
# Also check for TestAssets directory
TEST_ASSETS_DIR=$(find "$APP_BUNDLE" -name "TestAssets" -type d 2>/dev/null)

CHECK1_FAILED=false
if [ -n "$FORBIDDEN_FILES" ]; then
    echo -e "  ${RED}FAILED${NC} - Found scene source files in bundle:"
    echo "$FORBIDDEN_FILES" | while read -r f; do
        echo "    - $f"
    done
    CHECK1_FAILED=true
fi
if [ -n "$TEST_ASSETS_DIR" ]; then
    echo -e "  ${RED}FAILED${NC} - Found TestAssets directory in bundle:"
    echo "$TEST_ASSETS_DIR" | while read -r f; do
        echo "    - $f"
    done
    CHECK1_FAILED=true
fi
if [ "$CHECK1_FAILED" = true ]; then
    ((ERRORS++))
else
    echo -e "  ${GREEN}PASSED${NC} - No scene source files or TestAssets in bundle"
fi

# Check 2: All scenes from library.json have compiled.tve in Scenes/
echo ""
echo "Check 2: All scenes have compiled.tve in Scenes/..."
SCENES_DIR="$APP_BUNDLE/Scenes"
LIBRARY_JSON="$SCENES_DIR/library.json"

if [ ! -f "$LIBRARY_JSON" ]; then
    echo -e "  ${RED}FAILED${NC} - Scenes/library.json not found"
    ((ERRORS++))
else
    # Extract scene IDs from library.json
    SCENE_IDS=$(python3 -c "
import json, sys
with open('$LIBRARY_JSON') as f:
    data = json.load(f)
for s in data['scenes']:
    print(s['id'])
" 2>&1) || { echo -e "  ${RED}FAILED${NC} - cannot parse library.json"; ((ERRORS++)); }

    SCENE_COUNT=0
    COMPILED_COUNT=0
    MISSING_SCENES=()

    while IFS= read -r scene_id; do
        [ -z "$scene_id" ] && continue
        ((SCENE_COUNT++))

        if [ -f "$SCENES_DIR/$scene_id/compiled.tve" ]; then
            ((COMPILED_COUNT++))
            echo -e "  ${GREEN}OK${NC} - $scene_id has compiled.tve"
        else
            MISSING_SCENES+=("$scene_id")
            echo -e "  ${RED}MISSING${NC} - $scene_id lacks compiled.tve"
        fi
    done <<< "$SCENE_IDS"

    if [ ${#MISSING_SCENES[@]} -gt 0 ]; then
        ((ERRORS++))
    fi

    if [ "$SCENE_COUNT" -eq 0 ]; then
        echo -e "  ${RED}FAILED${NC} - no scenes found in library.json"
        ((ERRORS++))
    fi

    echo ""
    echo "  Scenes: $SCENE_COUNT, Compiled: $COMPILED_COUNT"
fi

# Check 3: Preview assets exist (if referenced in manifest)
echo ""
echo "Check 3: Preview assets exist for templates with previewAsset..."
MANIFEST_JSON="$APP_BUNDLE/Templates/Catalog/manifest.json"

if [ -f "$MANIFEST_JSON" ]; then
    PREVIEW_ASSETS=$(python3 -c "
import json, sys
with open('$MANIFEST_JSON') as f:
    data = json.load(f)
for t in data['templates']:
    pa = t.get('previewAsset')
    if pa:
        print(t['id'] + '|' + pa)
" 2>/dev/null)

    if [ -z "$PREVIEW_ASSETS" ]; then
        echo -e "  ${GREEN}PASSED${NC} - No templates have previewAsset"
    else
        while IFS='|' read -r tid asset; do
            [ -z "$tid" ] && continue
            if [ -f "$APP_BUNDLE/Templates/Previews/$asset" ]; then
                echo -e "  ${GREEN}OK${NC} - $tid preview exists: $asset"
            else
                echo -e "  ${RED}MISSING${NC} - $tid preview not found: Templates/Previews/$asset"
                ((ERRORS++))
            fi
        done <<< "$PREVIEW_ASSETS"
    fi
else
    echo -e "  ${YELLOW}SKIPPED${NC} - manifest.json not found"
fi

# Check 4 (optional): Verify images match SceneSources
if [ "$VERIFY_SOURCES" = true ]; then
    echo ""
    echo "Check 4: Scenes images match SceneSources..."
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
    SCENE_SOURCES_DIR="$REPO_ROOT/SceneSources"

    if [ -d "$SCENE_SOURCES_DIR" ]; then
        for src_scene_dir in "$SCENE_SOURCES_DIR"/*/; do
            scene_id="$(basename "$src_scene_dir")"
            if [ -d "$src_scene_dir/images" ]; then
                bundle_images="$SCENES_DIR/$scene_id/images"
                if [ -d "$bundle_images" ]; then
                    src_files=$(cd "$src_scene_dir/images" && find . -type f | sort)
                    dst_files=$(cd "$bundle_images" && find . -type f | sort)
                    if [ "$src_files" = "$dst_files" ]; then
                        echo -e "  ${GREEN}OK${NC} - $scene_id images in sync"
                    else
                        echo -e "  ${RED}MISMATCH${NC} - $scene_id images out of sync"
                        ((ERRORS++))
                    fi
                else
                    echo -e "  ${RED}MISSING${NC} - $scene_id images/ not in bundle"
                    ((ERRORS++))
                fi
            fi
        done
    else
        echo -e "  ${YELLOW}SKIPPED${NC} - SceneSources/ not found"
    fi
fi

# Check 5 (optional): No compiler symbols in binary
if [ "$CHECK_SYMBOLS" = true ]; then
    echo ""
    echo "Check 5: No compiler pipeline symbols in binary..."
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
            if strings "$BINARY_PATH" 2>/dev/null | grep -qw "$sym"; then
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
