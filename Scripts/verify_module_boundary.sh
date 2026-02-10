#!/bin/bash
# PR3 Gate v1: Verify TVECore module boundary
# Ensures no Lottie/compiler code leaks into runtime module

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TVECORE_SRC="$REPO_ROOT/TVECore/Sources/TVECore"

echo "=== PR3 Module Boundary Check ==="
echo "Checking: $TVECORE_SRC"
echo ""

ERRORS=0

# Check 1: No Lottie folders/files in TVECore
echo "[1/4] Checking for Lottie folders..."
if find "$TVECORE_SRC" -type d -name "Lottie*" 2>/dev/null | grep -q .; then
    echo "ERROR: Found Lottie folder in TVECore:"
    find "$TVECORE_SRC" -type d -name "Lottie*"
    ERRORS=$((ERRORS + 1))
else
    echo "  OK: No Lottie folders"
fi

# Check 2: No AnimLoader/AnimValidator folders
echo "[2/4] Checking for AnimLoader/AnimValidator folders..."
if find "$TVECORE_SRC" -type d \( -name "AnimLoader" -o -name "AnimValidator" -o -name "Bridges" \) 2>/dev/null | grep -q .; then
    echo "ERROR: Found compiler folders in TVECore:"
    find "$TVECORE_SRC" -type d \( -name "AnimLoader" -o -name "AnimValidator" -o -name "Bridges" \)
    ERRORS=$((ERRORS + 1))
else
    echo "  OK: No compiler folders"
fi

# Check 3: No Lottie type imports in TVECore source files
echo "[3/4] Checking for Lottie type usage..."
LOTTIE_REFS=$(grep -rE '\bLottieJSON\b|\bLottieLayer\b|\bLottieAsset\b|\bLottieShape\b|\bLottieMask\b|\bLottieTransform\b' "$TVECORE_SRC" --include="*.swift" 2>/dev/null || true)
if [ -n "$LOTTIE_REFS" ]; then
    echo "ERROR: Found Lottie type references in TVECore:"
    echo "$LOTTIE_REFS"
    ERRORS=$((ERRORS + 1))
else
    echo "  OK: No Lottie type references"
fi

# Check 4: No import TVECompilerCore in TVECore
echo "[4/4] Checking for TVECompilerCore imports..."
COMPILER_IMPORTS=$(grep -rE '^import TVECompilerCore' "$TVECORE_SRC" --include="*.swift" 2>/dev/null || true)
if [ -n "$COMPILER_IMPORTS" ]; then
    echo "ERROR: Found TVECompilerCore import in TVECore:"
    echo "$COMPILER_IMPORTS"
    ERRORS=$((ERRORS + 1))
else
    echo "  OK: No TVECompilerCore imports"
fi

echo ""
if [ $ERRORS -eq 0 ]; then
    echo "=== PASS: Module boundary intact ==="
    exit 0
else
    echo "=== FAIL: $ERRORS boundary violation(s) found ==="
    exit 1
fi
