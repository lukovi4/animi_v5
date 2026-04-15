#!/bin/bash
# PR11 Gate: Verify singleton bans and legacy pattern elimination.
# Ensures no banned singletons, controller-owned persistence, or stale
# placeholder-only references leak back into production/test code.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCES="$REPO_ROOT/AnimiApp/Sources"
TESTS="$REPO_ROOT/AnimiApp/Tests"

echo "=== PR11 Singleton & Legacy Pattern Audit ==="
echo ""

ERRORS=0

# 1. PlayerViewController must not exist as a production type reference.
echo "[1/7] Checking for PlayerViewController type references..."
HITS=$(grep -rn '\bPlayerViewController\b' "$SOURCES" "$TESTS" --include="*.swift" 2>/dev/null || true)
if [ -n "$HITS" ]; then
    echo "ERROR: Found PlayerViewController references:"
    echo "$HITS"
    ERRORS=$((ERRORS + 1))
else
    echo "  OK: No PlayerViewController references"
fi

# 2. ProjectStore.shared must not exist.
echo "[2/7] Checking for ProjectStore.shared..."
HITS=$(grep -rn 'ProjectStore\.shared' "$SOURCES" "$TESTS" --include="*.swift" 2>/dev/null || true)
if [ -n "$HITS" ]; then
    echo "ERROR: Found ProjectStore.shared:"
    echo "$HITS"
    ERRORS=$((ERRORS + 1))
else
    echo "  OK: No ProjectStore.shared"
fi

# 3. Product-owned singletons must not leak outside repository layer.
echo "[3/7] Checking for product-owned singleton leaks..."
HITS=$(grep -rn 'TemplateCatalog\.shared\|SceneLibrary\.shared\|BackgroundPresetLibrary\.shared\|StickerLibrary\.shared' "$SOURCES" --include="*.swift" --exclude="*Repository.swift" 2>/dev/null || true)
if [ -n "$HITS" ]; then
    echo "ERROR: Found product-owned singleton leak outside repository layer:"
    echo "$HITS"
    ERRORS=$((ERRORS + 1))
else
    echo "  OK: No singleton leaks outside repository layer"
fi

# 4. Controller-owned persistence state must not exist.
echo "[4/7] Checking for controller-owned persistence state..."
HITS=$(grep -rn 'currentProjectDraft\|draftIsDirty\|projectBackgroundOverride' "$SOURCES" "$TESTS" --include="*.swift" 2>/dev/null || true)
if [ -n "$HITS" ]; then
    echo "ERROR: Found controller-owned persistence state:"
    echo "$HITS"
    ERRORS=$((ERRORS + 1))
else
    echo "  OK: No controller-owned persistence state"
fi

# 5. Legacy entry-context symbols must not exist.
echo "[5/7] Checking for legacy entry-context symbols..."
HITS=$(grep -rn 'PlayerViewController\.EntryContext\|EditorEntryContext' "$SOURCES" "$TESTS" --include="*.swift" 2>/dev/null || true)
if [ -n "$HITS" ]; then
    echo "ERROR: Found legacy entry-context symbols:"
    echo "$HITS"
    ERRORS=$((ERRORS + 1))
else
    echo "  OK: No legacy entry-context symbols"
fi

# 6. PersistedVideoSelectionMigrationTests must be removed.
echo "[6/7] Checking for PersistedVideoSelectionMigrationTests..."
HITS=$(grep -rn 'PersistedVideoSelectionMigrationTests' "$SOURCES" "$TESTS" --include="*.swift" 2>/dev/null || true)
if [ -n "$HITS" ]; then
    echo "ERROR: Found PersistedVideoSelectionMigrationTests:"
    echo "$HITS"
    ERRORS=$((ERRORS + 1))
else
    echo "  OK: No PersistedVideoSelectionMigrationTests"
fi

# 7. Deprecated single-arg absoluteURL(for:) call sites must not exist.
echo "[7/7] Checking for deprecated absoluteURL(for:) call sites..."
# Match absoluteURL(for: <expr>) where there is NO comma before the closing paren.
# Exclude comments and the protocol/extension definition files.
HITS=$(grep -rn 'absoluteURL(for: [^,)]*)[^,]' "$SOURCES" --include="*.swift" 2>/dev/null | grep -v '//' | grep -v '@available' | grep -v 'deprecated' || true)
if [ -n "$HITS" ]; then
    echo "ERROR: Found deprecated single-arg absoluteURL(for:) call sites:"
    echo "$HITS"
    ERRORS=$((ERRORS + 1))
else
    echo "  OK: No deprecated absoluteURL(for:) call sites"
fi

echo ""
if [ $ERRORS -eq 0 ]; then
    echo "=== PASS: All singleton bans and legacy patterns clean ==="
    exit 0
else
    echo "=== FAIL: $ERRORS violation(s) found ==="
    exit 1
fi
