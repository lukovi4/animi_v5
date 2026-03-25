#!/bin/bash
# compile_scenes.sh — Compiles all scenes from SceneSources/ to AnimiApp/Resources/Scenes/
#
# Usage:
#   ./Scripts/compile_scenes.sh
#   ./Scripts/compile_scenes.sh --clean    # Remove existing compiled.tve before compiling
#   ./Scripts/compile_scenes.sh --verify   # Only verify that compiled.tve exists and images match
#
# Exit codes:
#   0 - All scenes compiled successfully
#   1 - One or more scenes failed to compile

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TVECORE_ROOT="$REPO_ROOT/TVECore"
SCENE_SOURCES_DIR="$REPO_ROOT/SceneSources"
SCENES_OUTPUT_DIR="$REPO_ROOT/AnimiApp/Resources/Scenes"
SHARED_ASSETS_DIR="$REPO_ROOT/SharedAssets"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Parse arguments
CLEAN_MODE=false
VERIFY_MODE=false

for arg in "$@"; do
    case $arg in
        --clean)
            CLEAN_MODE=true
            ;;
        --verify)
            VERIFY_MODE=true
            ;;
        --help|-h)
            echo "Usage: $0 [--clean] [--verify]"
            echo ""
            echo "Options:"
            echo "  --clean   Remove existing compiled.tve before compiling"
            echo "  --verify  Only verify that compiled.tve exists and images match (no compilation)"
            echo ""
            exit 0
            ;;
    esac
done

echo "======================================"
echo "TVE Scene Compiler Script"
echo "======================================"
echo ""
echo "Repository:     $REPO_ROOT"
echo "Scene Sources:  $SCENE_SOURCES_DIR"
echo "Scenes Output:  $SCENES_OUTPUT_DIR"
echo "Shared Assets:  $SHARED_ASSETS_DIR"
echo ""

# Check scene sources directory exists
if [ ! -d "$SCENE_SOURCES_DIR" ]; then
    echo -e "${RED}ERROR: SceneSources directory not found: $SCENE_SOURCES_DIR${NC}"
    exit 1
fi

# Build the compiler first (only if not verify mode)
if [ "$VERIFY_MODE" = false ]; then
    echo "Building TVETemplateCompiler..."
    cd "$TVECORE_ROOT"
    swift build --target TVETemplateCompiler 2>&1 | grep -v "^warning:" || true
    echo ""
fi

# Find all scene directories (directories containing scene.json)
SCENES=()
while IFS= read -r -d '' scene_file; do
    scene_dir="$(dirname "$scene_file")"
    SCENES+=("$scene_dir")
done < <(find "$SCENE_SOURCES_DIR" -name "scene.json" -print0)

if [ ${#SCENES[@]} -eq 0 ]; then
    echo -e "${YELLOW}WARNING: No scenes found (no scene.json files in SceneSources/)${NC}"
    exit 0
fi

echo "Found ${#SCENES[@]} scene(s):"
for scene in "${SCENES[@]}"; do
    echo "  - $(basename "$scene")"
done
echo ""

# Counters
SUCCESS_COUNT=0
FAIL_COUNT=0
FAILED_SCENES=()

# Process each scene
for scene_dir in "${SCENES[@]}"; do
    scene_name="$(basename "$scene_dir")"
    output_dir="$SCENES_OUTPUT_DIR/$scene_name"
    compiled_path="$output_dir/compiled.tve"

    echo "----------------------------------------"
    echo "Scene: $scene_name"
    echo "  Source: $scene_dir"
    echo "  Output: $output_dir"

    if [ "$VERIFY_MODE" = true ]; then
        SCENE_OK=true

        # Verify compiled.tve exists
        if [ -f "$compiled_path" ]; then
            size=$(ls -lh "$compiled_path" | awk '{print $5}')
            echo -e "  ${GREEN}OK${NC} - compiled.tve exists ($size)"
        else
            echo -e "  ${RED}MISSING${NC} - compiled.tve not found"
            SCENE_OK=false
        fi

        # Verify images match if source has images/
        if [ -d "$scene_dir/images" ]; then
            if [ -d "$output_dir/images" ]; then
                # Compare file lists
                src_files=$(cd "$scene_dir/images" && find . -type f | sort)
                dst_files=$(cd "$output_dir/images" && find . -type f | sort)
                if [ "$src_files" = "$dst_files" ]; then
                    echo -e "  ${GREEN}OK${NC} - images/ in sync"
                else
                    echo -e "  ${RED}MISMATCH${NC} - images/ out of sync"
                    SCENE_OK=false
                fi
            else
                echo -e "  ${RED}MISSING${NC} - images/ directory not found in output"
                SCENE_OK=false
            fi
        fi

        if [ "$SCENE_OK" = true ]; then
            ((SUCCESS_COUNT++))
        else
            ((FAIL_COUNT++))
            FAILED_SCENES+=("$scene_name")
        fi
        continue
    fi

    # Ensure output directory exists
    mkdir -p "$output_dir"

    # Clean mode: remove existing compiled.tve
    if [ "$CLEAN_MODE" = true ] && [ -f "$compiled_path" ]; then
        echo "  Removing existing compiled.tve..."
        rm "$compiled_path"
    fi

    # Sync images from source to output
    if [ -d "$scene_dir/images" ]; then
        mkdir -p "$output_dir/images"
        rsync -a --delete "$scene_dir/images/" "$output_dir/images/"
        echo "  Synced images/"
    fi

    # Compile
    echo "  Compiling..."
    cd "$TVECORE_ROOT"

    # Run compiler: input from SceneSources, output to Scenes
    compile_exit=0
    compile_output=$(swift run TVETemplateCompiler \
        --input "$scene_dir" \
        --output "$output_dir" \
        --shared "$SHARED_ASSETS_DIR" 2>&1) || compile_exit=$?

    if [ "$compile_exit" -eq 0 ]; then
        if [ -f "$compiled_path" ]; then
            size=$(ls -lh "$compiled_path" | awk '{print $5}')
            echo -e "  ${GREEN}SUCCESS${NC} - compiled.tve ($size)"
            ((SUCCESS_COUNT++))
        else
            echo -e "  ${RED}FAILED${NC} - compiled.tve not created"
            echo "$compile_output" | head -20
            ((FAIL_COUNT++))
            FAILED_SCENES+=("$scene_name")
        fi
    else
        echo -e "  ${RED}FAILED${NC} - Compiler error (exit code $compile_exit)"
        echo "$compile_output" | grep -E "(ERROR|Error:)" | head -10
        ((FAIL_COUNT++))
        FAILED_SCENES+=("$scene_name")
    fi
done

# Summary
echo ""
echo "======================================"
echo "Summary"
echo "======================================"
echo -e "  Successful: ${GREEN}$SUCCESS_COUNT${NC}"
echo -e "  Failed:     ${RED}$FAIL_COUNT${NC}"

if [ $FAIL_COUNT -gt 0 ]; then
    echo ""
    echo "Failed scenes:"
    for name in "${FAILED_SCENES[@]}"; do
        echo -e "  ${RED}- $name${NC}"
    done
    echo ""
    exit 1
fi

echo ""
echo -e "${GREEN}All scenes compiled successfully!${NC}"
exit 0
