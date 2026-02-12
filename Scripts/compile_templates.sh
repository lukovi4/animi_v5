#!/bin/bash
# compile_templates.sh — Compiles all templates in AnimiApp/Resources/Templates to compiled.tve
#
# Usage:
#   ./Scripts/compile_templates.sh
#   ./Scripts/compile_templates.sh --clean    # Remove existing compiled.tve before compiling
#   ./Scripts/compile_templates.sh --verify   # Only verify that compiled.tve exists for each template
#
# Exit codes:
#   0 - All templates compiled successfully
#   1 - One or more templates failed to compile

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TVECORE_ROOT="$REPO_ROOT/TVECore"
TEMPLATES_DIR="$REPO_ROOT/AnimiApp/Resources/Templates"
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
            echo "  --verify  Only verify that compiled.tve exists (no compilation)"
            echo ""
            exit 0
            ;;
    esac
done

echo "======================================"
echo "TVE Template Compiler Script"
echo "======================================"
echo ""
echo "Repository:    $REPO_ROOT"
echo "Templates:     $TEMPLATES_DIR"
echo "Shared Assets: $SHARED_ASSETS_DIR"
echo ""

# Check templates directory exists
if [ ! -d "$TEMPLATES_DIR" ]; then
    echo -e "${RED}ERROR: Templates directory not found: $TEMPLATES_DIR${NC}"
    exit 1
fi

# Build the compiler first (only if not verify mode)
if [ "$VERIFY_MODE" = false ]; then
    echo "Building TVETemplateCompiler..."
    cd "$TVECORE_ROOT"
    swift build --target TVETemplateCompiler 2>&1 | grep -v "^warning:" || true
    echo ""
fi

# Find all template directories (directories containing scene.json)
TEMPLATES=()
while IFS= read -r -d '' scene_file; do
    template_dir="$(dirname "$scene_file")"
    TEMPLATES+=("$template_dir")
done < <(find "$TEMPLATES_DIR" -name "scene.json" -print0)

if [ ${#TEMPLATES[@]} -eq 0 ]; then
    echo -e "${YELLOW}WARNING: No templates found (no scene.json files)${NC}"
    exit 0
fi

echo "Found ${#TEMPLATES[@]} template(s):"
for template in "${TEMPLATES[@]}"; do
    echo "  - $(basename "$template")"
done
echo ""

# Counters
SUCCESS_COUNT=0
FAIL_COUNT=0
FAILED_TEMPLATES=()

# Process each template
for template_dir in "${TEMPLATES[@]}"; do
    template_name="$(basename "$template_dir")"
    compiled_path="$template_dir/compiled.tve"

    echo "----------------------------------------"
    echo "Template: $template_name"
    echo "  Path: $template_dir"

    if [ "$VERIFY_MODE" = true ]; then
        # Verify mode: just check if compiled.tve exists
        if [ -f "$compiled_path" ]; then
            size=$(ls -lh "$compiled_path" | awk '{print $5}')
            echo -e "  ${GREEN}OK${NC} - compiled.tve exists ($size)"
            ((SUCCESS_COUNT++))
        else
            echo -e "  ${RED}MISSING${NC} - compiled.tve not found"
            ((FAIL_COUNT++))
            FAILED_TEMPLATES+=("$template_name")
        fi
        continue
    fi

    # Clean mode: remove existing compiled.tve
    if [ "$CLEAN_MODE" = true ] && [ -f "$compiled_path" ]; then
        echo "  Removing existing compiled.tve..."
        rm "$compiled_path"
    fi

    # Compile
    echo "  Compiling..."
    cd "$TVECORE_ROOT"

    # Run compiler and capture output (with shared assets path)
    compile_output=$(swift run TVETemplateCompiler \
        --input "$template_dir" \
        --output "$template_dir" \
        --shared "$SHARED_ASSETS_DIR" 2>&1) || compile_exit=$?

    if [ -z "${compile_exit:-}" ] || [ "${compile_exit:-0}" -eq 0 ]; then
        if [ -f "$compiled_path" ]; then
            size=$(ls -lh "$compiled_path" | awk '{print $5}')
            echo -e "  ${GREEN}SUCCESS${NC} - compiled.tve ($size)"
            ((SUCCESS_COUNT++))
        else
            echo -e "  ${RED}FAILED${NC} - compiled.tve not created"
            echo "$compile_output" | head -20
            ((FAIL_COUNT++))
            FAILED_TEMPLATES+=("$template_name")
        fi
    else
        echo -e "  ${RED}FAILED${NC} - Compiler error (exit code $compile_exit)"
        echo "$compile_output" | grep -E "(ERROR|Error:)" | head -10
        ((FAIL_COUNT++))
        FAILED_TEMPLATES+=("$template_name")
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
    echo "Failed templates:"
    for name in "${FAILED_TEMPLATES[@]}"; do
        echo -e "  ${RED}- $name${NC}"
    done
    echo ""
    exit 1
fi

echo ""
echo -e "${GREEN}All templates compiled successfully!${NC}"
exit 0
