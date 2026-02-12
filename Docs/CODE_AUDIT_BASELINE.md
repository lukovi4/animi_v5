# CODE AUDIT BASELINE — Snapshot Forensic Report

Snapshot date (report generated): 2026-02-11  
Evidence policy: **Every factual statement below is backed by at least one code anchor.** Anything not provable from snapshot is marked **NOT PROVEN** and is not used in verdict/issue counts.

---

## A. Snapshot metadata

### A1) Toolchain / Swift / Platforms

**Code anchor**
- `TVECore/Package.swift`
- `package header + platforms`
```swift
// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TVECore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "TVECore",
            targets: ["TVECore"]
        ),
        .library(
            name: "TVECompilerCore",
            targets: ["TVECompilerCore"]
        ),
        .executable(
            name: "TVETemplateCompiler",
            targets: ["TVETemplateCompiler"]
```

**Code anchor**
- `AnimiApp/project.yml`
- `options + packages + targets + dependencies`
```yaml
name: AnimiApp
options:
  bundleIdPrefix: com.animi
  deploymentTarget:
    iOS: "16.0"
  xcodeVersion: "15.0"
  generateEmptyDirectories: true

packages:
  TVECore:
    path: ../TVECore

targets:
  AnimiApp:
    type: application
    platform: iOS
    sources:
      - path: Sources
        type: group
      - path: Resources
        type: group
      - path: ../TestAssets
        type: folder
        buildPhase: resources
      - path: ../SharedAssets
        type: folder
        buildPhase: resources
    dependencies:
      - package: TVECore
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.animi.app
        MARKETING_VERSION: "1.0.0"
        CURRENT_PROJECT_VERSION: "1"
        INFOPLIST_FILE: Resources/Info.plist
        GENERATE_INFOPLIST_FILE: false
        SWIFT_VERSION: "5.9"
        CODE_SIGN_STYLE: Automatic
        DEVELOPMENT_TEAM: ""
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor
    info:
      path: Resources/Info.plist
      properties:
        CFBundleDevelopmentRegion: en
        CFBundleExecutable: $(EXECUTABLE_NAME)
        CFBundleIdentifier: $(PRODUCT_BUNDLE_IDENTIFIER)
        CFBundleInfoDictionaryVersion: "6.0"
        CFBundleName: $(PRODUCT_NAME)
        CFBundlePackageType: APPL
        CFBundleShortVersionString: $(MARKETING_VERSION)
        CFBundleVersion: $(CURRENT_PROJECT_VERSION)
        LSRequiresIPhoneOS: true
        UIApplicationSceneManifest:
          UIApplicationSupportsMultipleScenes: false
          UISceneConfigurations:
            UIWindowSceneSessionRoleApplication:
              - UISceneConfigurationName: Default Configuration
                UISceneDelegateClassName: $(PRODUCT_MODULE_NAME).SceneDelegate
        UILaunchStoryboardName: LaunchScreen
        UISupportedInterfaceOrientations:
          - UIInterfaceOrientationPortrait
        UISupportedInterfaceOrientations~ipad:
          - UIInterfaceOrientationPortrait
          - UIInterfaceOrientationPortraitUpsideDown
          - UIInterfaceOrientationLandscapeLeft
          - UIInterfaceOrientationLandscapeRight
        UIRequiresFullScreen: true
```

**Code anchor**
- `AnimiApp/AnimiApp.xcodeproj/project.pbxproj`
- `build settings excerpt (SWIFT_VERSION)`
```text
				CODE_SIGN_IDENTITY = "iPhone Developer";
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = KRX7JQ8GTF;
				EXCLUDED_SOURCE_FILE_NAMES = (
					"anim-*.json",
					"no-anim.json",
				);
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = Resources/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				MARKETING_VERSION = 1.0.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.animi.app;
				SDKROOT = iphoneos;
				SWIFT_VERSION = 5.9;
				TARGETED_DEVICE_FAMILY = "1,2";
			};
			name = Release;
		};
		7B36287936D21BDE7AC37BB3 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
				CODE_SIGN_IDENTITY = "iPhone Developer";
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = KRX7JQ8GTF;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = Resources/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				MARKETING_VERSION = 1.0.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.animi.app;
				SDKROOT = iphoneos;
				SWIFT_VERSION = 5.9;
				TARGETED_DEVICE_FAMILY = "1,2";
			};
			name = Debug;
		};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		A538D1F0746FDFB3E5B94A84 /* Build configuration list for PBXProject "AnimiApp" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				231CC8A1C3778D309AAA0F56 /* Debug */,
				1C286A63FCE03685CBE08418 /* Release */,
			);
```

### A2) Declared modules / targets / products

From SPM package `TVECore`:

**Code anchor**
- `TVECore/Package.swift`
- `products + targets + dependency edges`
```swift
// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TVECore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "TVECore",
            targets: ["TVECore"]
        ),
        .library(
            name: "TVECompilerCore",
            targets: ["TVECompilerCore"]
        ),
        .executable(
            name: "TVETemplateCompiler",
            targets: ["TVETemplateCompiler"]
        )
    ],
    targets: [
        .target(
            name: "TVECore",
            dependencies: [],
            path: "Sources/TVECore",
            resources: [
                .process("MetalRenderer/Shaders")
            ]
        ),
        .target(
            name: "TVECompilerCore",
            dependencies: ["TVECore"],
            path: "Sources/TVECompilerCore"
        ),
        .executableTarget(
            name: "TVETemplateCompiler",
            dependencies: ["TVECompilerCore"],
            path: "Tools/TVETemplateCompiler"
        ),
        // NOTE: TVECoreTests temporarily depends on TVECompilerCore (variant A from review.md)
        // TODO: Split into TVECoreTests + TVECompilerCoreTests (variant B) in separate task
        .testTarget(
            name: "TVECoreTests",
            dependencies: ["TVECore", "TVECompilerCore"],
            path: "Tests/TVECoreTests",
            resources: [
                .copy("Resources")
            ]
        )
    ]
)
```

From app project definition:

**Code anchor**
- `AnimiApp/project.yml`
- `options + packages + targets + dependencies`
```yaml
name: AnimiApp
options:
  bundleIdPrefix: com.animi
  deploymentTarget:
    iOS: "16.0"
  xcodeVersion: "15.0"
  generateEmptyDirectories: true

packages:
  TVECore:
    path: ../TVECore

targets:
  AnimiApp:
    type: application
    platform: iOS
    sources:
      - path: Sources
        type: group
      - path: Resources
        type: group
      - path: ../TestAssets
        type: folder
        buildPhase: resources
      - path: ../SharedAssets
        type: folder
        buildPhase: resources
    dependencies:
      - package: TVECore
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.animi.app
        MARKETING_VERSION: "1.0.0"
        CURRENT_PROJECT_VERSION: "1"
        INFOPLIST_FILE: Resources/Info.plist
        GENERATE_INFOPLIST_FILE: false
        SWIFT_VERSION: "5.9"
        CODE_SIGN_STYLE: Automatic
        DEVELOPMENT_TEAM: ""
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor
    info:
      path: Resources/Info.plist
      properties:
        CFBundleDevelopmentRegion: en
        CFBundleExecutable: $(EXECUTABLE_NAME)
        CFBundleIdentifier: $(PRODUCT_BUNDLE_IDENTIFIER)
        CFBundleInfoDictionaryVersion: "6.0"
        CFBundleName: $(PRODUCT_NAME)
        CFBundlePackageType: APPL
        CFBundleShortVersionString: $(MARKETING_VERSION)
        CFBundleVersion: $(CURRENT_PROJECT_VERSION)
        LSRequiresIPhoneOS: true
        UIApplicationSceneManifest:
          UIApplicationSupportsMultipleScenes: false
          UISceneConfigurations:
            UIWindowSceneSessionRoleApplication:
              - UISceneConfigurationName: Default Configuration
                UISceneDelegateClassName: $(PRODUCT_MODULE_NAME).SceneDelegate
        UILaunchStoryboardName: LaunchScreen
        UISupportedInterfaceOrientations:
          - UIInterfaceOrientationPortrait
        UISupportedInterfaceOrientations~ipad:
          - UIInterfaceOrientationPortrait
          - UIInterfaceOrientationPortraitUpsideDown
          - UIInterfaceOrientationLandscapeLeft
          - UIInterfaceOrientationLandscapeRight
        UIRequiresFullScreen: true
```

### A3) Linting / scripts / tooling present in snapshot

SwiftLint config exists:

**Code anchor**
- `.swiftlint.yml`
- `root swiftlint config`
```yaml
# SwiftLint Configuration for Animi Project

# Paths to include
included:
  - AnimiApp/Sources
  - TVECore/Sources

# Paths to exclude
excluded:
  - .build
  - "**/.build"
  - "**/DerivedData"
  - AnimiApp/Resources
  - TestAssets
  - TVECore/Tests

# Enabled rules
opt_in_rules:
  - force_unwrapping
  - closure_end_indentation
  - closure_spacing
  - collection_alignment
  - contains_over_filter_count
  - contains_over_filter_is_empty
  - contains_over_first_not_nil
  - discouraged_object_literal
  - empty_collection_literal
  - empty_count
  - empty_string
  - explicit_init
  - fatal_error_message
  - first_where
  - flatmap_over_map_reduce
  - identical_operands
  - joined_default_parameter
  - last_where
  - legacy_multiple
  - literal_expression_end_indentation
  - modifier_order
  - operator_usage_whitespace
  - overridden_super_call
  - prefer_self_in_static_references
  - prefer_self_type_over_type_of_self
  - prefer_zero_over_explicit_init
  - private_action
  - private_outlet
  - redundant_nil_coalescing
  - redundant_type_annotation
  - sorted_first_last
  - toggle_bool
  - unavailable_function
  - unneeded_parentheses_in_closure_argument
  - vertical_parameter_alignment_on_call
  - yoda_condition

# Disabled rules
disabled_rules:
  - todo
  - trailing_whitespace

# Rule configurations
line_length:
  warning: 120
  error: 150
  ignores_comments: true
  ignores_urls: true
  ignores_function_declarations: false

type_body_length:
  warning: 300
  error: 500

file_length:
  warning: 500
  error: 1000

function_body_length:
  warning: 50
  error: 100

function_parameter_count:
  warning: 6
  error: 8

cyclomatic_complexity:
  warning: 15
  error: 25

nesting:
  type_level: 2
  function_level: 3

identifier_name:
  min_length:
    warning: 2
    error: 1
  max_length:
    warning: 50
    error: 60
  excluded:
```

Module boundary / release bundle validation scripts exist:

**Code anchor**
- `Scripts/verify_module_boundary.sh`
- `boundary check script`
```bash
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
```

**Code anchor**
- `Scripts/verify_release_bundle.sh`
- `release bundle verification script`
```bash
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
```

---

## B. Module boundaries & ownership

### B1) Modules/targets and dependencies (provable)

- `AnimiApp` declares a single local package dependency `TVECore` (SPM).
- SPM package provides:
  - **TVECore** (library)
  - **TVECompilerCore** (library, depends on `TVECore`)
  - **TVETemplateCompiler** (executable, depends on `TVECompilerCore`)
  - `TVECoreTests` test target depends on both `TVECore` and `TVECompilerCore` (explicitly noted as temporary)

Evidence:

**Code anchor**
- `AnimiApp/project.yml`
- `options + packages + targets + dependencies`
```yaml
name: AnimiApp
options:
  bundleIdPrefix: com.animi
  deploymentTarget:
    iOS: "16.0"
  xcodeVersion: "15.0"
  generateEmptyDirectories: true

packages:
  TVECore:
    path: ../TVECore

targets:
  AnimiApp:
    type: application
    platform: iOS
    sources:
      - path: Sources
        type: group
      - path: Resources
        type: group
      - path: ../TestAssets
        type: folder
        buildPhase: resources
      - path: ../SharedAssets
        type: folder
        buildPhase: resources
    dependencies:
      - package: TVECore
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.animi.app
        MARKETING_VERSION: "1.0.0"
        CURRENT_PROJECT_VERSION: "1"
        INFOPLIST_FILE: Resources/Info.plist
        GENERATE_INFOPLIST_FILE: false
        SWIFT_VERSION: "5.9"
        CODE_SIGN_STYLE: Automatic
        DEVELOPMENT_TEAM: ""
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor
    info:
      path: Resources/Info.plist
      properties:
        CFBundleDevelopmentRegion: en
        CFBundleExecutable: $(EXECUTABLE_NAME)
        CFBundleIdentifier: $(PRODUCT_BUNDLE_IDENTIFIER)
        CFBundleInfoDictionaryVersion: "6.0"
        CFBundleName: $(PRODUCT_NAME)
        CFBundlePackageType: APPL
        CFBundleShortVersionString: $(MARKETING_VERSION)
        CFBundleVersion: $(CURRENT_PROJECT_VERSION)
        LSRequiresIPhoneOS: true
        UIApplicationSceneManifest:
          UIApplicationSupportsMultipleScenes: false
          UISceneConfigurations:
            UIWindowSceneSessionRoleApplication:
              - UISceneConfigurationName: Default Configuration
                UISceneDelegateClassName: $(PRODUCT_MODULE_NAME).SceneDelegate
        UILaunchStoryboardName: LaunchScreen
        UISupportedInterfaceOrientations:
          - UIInterfaceOrientationPortrait
        UISupportedInterfaceOrientations~ipad:
          - UIInterfaceOrientationPortrait
          - UIInterfaceOrientationPortraitUpsideDown
          - UIInterfaceOrientationLandscapeLeft
          - UIInterfaceOrientationLandscapeRight
        UIRequiresFullScreen: true
```

**Code anchor**
- `TVECore/Package.swift`
- `products + targets + dependency edges`
```swift
// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TVECore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "TVECore",
            targets: ["TVECore"]
        ),
        .library(
            name: "TVECompilerCore",
            targets: ["TVECompilerCore"]
        ),
        .executable(
            name: "TVETemplateCompiler",
            targets: ["TVETemplateCompiler"]
        )
    ],
    targets: [
        .target(
            name: "TVECore",
            dependencies: [],
            path: "Sources/TVECore",
            resources: [
                .process("MetalRenderer/Shaders")
            ]
        ),
        .target(
            name: "TVECompilerCore",
            dependencies: ["TVECore"],
            path: "Sources/TVECompilerCore"
        ),
        .executableTarget(
            name: "TVETemplateCompiler",
            dependencies: ["TVECompilerCore"],
            path: "Tools/TVETemplateCompiler"
        ),
        // NOTE: TVECoreTests temporarily depends on TVECompilerCore (variant A from review.md)
        // TODO: Split into TVECoreTests + TVECompilerCoreTests (variant B) in separate task
        .testTarget(
            name: "TVECoreTests",
            dependencies: ["TVECore", "TVECompilerCore"],
            path: "Tests/TVECoreTests",
            resources: [
                .copy("Resources")
            ]
        )
    ]
)
```

### B2) Boundary enforcement present (runtime vs compiler)

A script asserts `TVECore/Sources/TVECore` must not contain compiler/Lottie folders or import `TVECompilerCore`.

**Code anchor**
- `Scripts/verify_module_boundary.sh`
- `boundary check script`
```bash
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
```

**NOT PROVEN:** higher-level architectural intent beyond what the script/manifests state.

### B3) Key public API surfaces used by the app (provable from wiring)

The app-side composition uses `SceneCompiler`, `ScenePlayer`, `SceneTextureProviderFactory`, and `UserMediaService`.

**Code anchor**
- `AnimiApp/Sources/Player/PlayerViewController.swift`
- `compileScene(for:) wiring excerpt`
```swift
        isSceneValid = !sceneReport.hasErrors
        guard isSceneValid else { log("Scene invalid"); metalView.setNeedsDisplay(); return }
        try loadAndValidateAnimations(for: package, resolver: resolver)
        try compileScene(for: package)
        metalView.setNeedsDisplay()
    }

    private func loadAndValidateAnimations(for package: ScenePackage, resolver: CompositeAssetResolver) throws {
        let loaded = try animLoader.loadAnimations(from: package)
        loadedAnimations = loaded
        log("Loaded \(loaded.lottieByAnimRef.count) animations")
        // PR-28: Pass resolver for basename-based asset validation (TL requirement B)
        let report = animValidator.validate(scene: package.scene, package: package, loaded: loaded, resolver: resolver)
        logValidationReport(report, title: "AnimValidation")
        isAnimValid = !report.hasErrors
        if report.hasErrors { log("Animations invalid") }
    }

    private func compileScene(for package: ScenePackage) throws {
        guard isAnimValid,
              let loaded = loadedAnimations,
              let device = metalView.device else { return }

        log("---\nCompiling scene...")

        // PR3: Use SceneCompiler from TVECompilerCore (compile logic moved out of ScenePlayer)
        let sceneCompiler = SceneCompiler()
        let compiled = try sceneCompiler.compile(package: package, loadedAnimations: loaded)
        compiledScene = compiled

        // Create ScenePlayer and load the compiled scene
        let player = ScenePlayer()
        player.loadCompiledScene(compiled)

        // PR-19: Store player as property and wire to editor controller
        scenePlayer = player
        editorController.setPlayer(player)

        // Store canvas size for render target
        canvasSize = compiled.runtime.canvasSize
        editorController.canvasSize = canvasSize

        // Update metalView aspect ratio to match canvas
        updateMetalViewAspectRatio(width: canvasSize.width, height: canvasSize.height)

        // Store merged asset sizes for renderer
        mergedAssetSizes = compiled.mergedAssetIndex.sizeById

        // Create texture provider (PR-28: reuse resolver from validation, pass bindingAssetIds)
        let resolver = currentResolver ?? CompositeAssetResolver(localIndex: .empty, sharedIndex: .empty)
        let provider = SceneTextureProviderFactory.create(
            device: device,
            mergedAssetIndex: compiled.mergedAssetIndex,
            resolver: resolver,
            bindingAssetIds: compiled.bindingAssetIds,
            logger: { [weak self] msg in self?.log(msg) }
        )
        textureProvider = provider

        // PR-B: Preload all textures before any draw/play (IO-free runtime invariant)
        provider.preloadAll()
        if let stats = provider.lastPreloadStats {
            log(String(format: "[Preload] loaded: %d, missing: %d, skipped: %d, duration: %.1fms",
                       stats.loadedCount, stats.missingCount, stats.skippedBindingCount, stats.durationMs))
        }

        // PR-32: Create UserMediaService for photo/video injection
        if let tp = textureProvider {
            userMediaService = UserMediaService(
                device: device,
                scenePlayer: player,
                textureProvider: tp
            )
            userMediaService?.setSceneFPS(Double(compiled.runtime.fps))
            // PR1.1: Wire callback for async updates (poster ready, clear)
            userMediaService?.onNeedsDisplay = { [weak self] in
                self?.metalView.setNeedsDisplay()
            }
            log("UserMediaService initialized")
        }

        // Log compilation results
        let runtime = compiled.runtime
        let blockCount = runtime.blocks.count
        let canvasSizeStr = "\(Int(canvasSize.width))x\(Int(canvasSize.height))"
        log("Scene compiled: \(canvasSizeStr) @ \(runtime.fps)fps, \(runtime.durationFrames) frames, \(blockCount) blocks")

        // Log block details
        for block in runtime.blocks {
            let rect = block.rectCanvas
            let rectStr = "(\(Int(rect.x)),\(Int(rect.y)) \(Int(rect.width))x\(Int(rect.height)))"
            log("  Block '\(block.blockId)' z=\(block.zIndex) rect=\(rectStr)")
        }

        // Log asset count
        log("Merged assets: \(compiled.mergedAssetIndex.byId.count) textures")

        // PR-B: Diagnostic — verify preload coverage (DEBUG only)
        // After preloadAll(), texture(for:) is IO-free cache lookup
        #if DEBUG
        for (assetId, _) in compiled.mergedAssetIndex.byId {
            if let tex = textureProvider?.texture(for: assetId) {
                log("Texture: \(assetId) [\(tex.width)x\(tex.height)]")
            } else {
                log("WARNING: Texture MISSING after preload: \(assetId)")
            }
        }
        #endif

        // Setup playback controls
        totalFrames = runtime.durationFrames
```

**NOT PROVEN:** complete API inventory of each module.

---

## C. Reachable runtime map (proved reachability)

### C1) App entry points

- `@main` entry point is `AppDelegate`.
- `SceneDelegate` creates a window and sets `PlayerViewController()` as root.

**Code anchor**
- `AnimiApp/Sources/App/AppDelegate.swift`
- `@main AppDelegate`
```swift
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        return true
    }

    // MARK: - UISceneSession Lifecycle

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        return UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
    }
}
```

**Code anchor**
- `AnimiApp/Sources/App/SceneDelegate.swift`
- `scene(_:willConnectTo:options:) root VC wiring`
```swift
import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        let playerViewController = PlayerViewController()
        window.rootViewController = playerViewController
        window.makeKeyAndVisible()

        self.window = window
    }
}
```

### C2) Proven runtime wiring (creation → ownership → usage)

Within `PlayerViewController.compileScene(for:)` (excerpt):
- Compiles a `ScenePackage` using `SceneCompiler`.
- Creates `ScenePlayer` and loads the compiled scene.
- Creates a texture provider and calls `preloadAll()`.
- Creates `UserMediaService` and wires `onNeedsDisplay` to trigger `metalView.setNeedsDisplay()`.

**Code anchor**
- `AnimiApp/Sources/Player/PlayerViewController.swift`
- `compileScene(for:) wiring excerpt`
```swift
        isSceneValid = !sceneReport.hasErrors
        guard isSceneValid else { log("Scene invalid"); metalView.setNeedsDisplay(); return }
        try loadAndValidateAnimations(for: package, resolver: resolver)
        try compileScene(for: package)
        metalView.setNeedsDisplay()
    }

    private func loadAndValidateAnimations(for package: ScenePackage, resolver: CompositeAssetResolver) throws {
        let loaded = try animLoader.loadAnimations(from: package)
        loadedAnimations = loaded
        log("Loaded \(loaded.lottieByAnimRef.count) animations")
        // PR-28: Pass resolver for basename-based asset validation (TL requirement B)
        let report = animValidator.validate(scene: package.scene, package: package, loaded: loaded, resolver: resolver)
        logValidationReport(report, title: "AnimValidation")
        isAnimValid = !report.hasErrors
        if report.hasErrors { log("Animations invalid") }
    }

    private func compileScene(for package: ScenePackage) throws {
        guard isAnimValid,
              let loaded = loadedAnimations,
              let device = metalView.device else { return }

        log("---\nCompiling scene...")

        // PR3: Use SceneCompiler from TVECompilerCore (compile logic moved out of ScenePlayer)
        let sceneCompiler = SceneCompiler()
        let compiled = try sceneCompiler.compile(package: package, loadedAnimations: loaded)
        compiledScene = compiled

        // Create ScenePlayer and load the compiled scene
        let player = ScenePlayer()
        player.loadCompiledScene(compiled)

        // PR-19: Store player as property and wire to editor controller
        scenePlayer = player
        editorController.setPlayer(player)

        // Store canvas size for render target
        canvasSize = compiled.runtime.canvasSize
        editorController.canvasSize = canvasSize

        // Update metalView aspect ratio to match canvas
        updateMetalViewAspectRatio(width: canvasSize.width, height: canvasSize.height)

        // Store merged asset sizes for renderer
        mergedAssetSizes = compiled.mergedAssetIndex.sizeById

        // Create texture provider (PR-28: reuse resolver from validation, pass bindingAssetIds)
        let resolver = currentResolver ?? CompositeAssetResolver(localIndex: .empty, sharedIndex: .empty)
        let provider = SceneTextureProviderFactory.create(
            device: device,
            mergedAssetIndex: compiled.mergedAssetIndex,
            resolver: resolver,
            bindingAssetIds: compiled.bindingAssetIds,
            logger: { [weak self] msg in self?.log(msg) }
        )
        textureProvider = provider

        // PR-B: Preload all textures before any draw/play (IO-free runtime invariant)
        provider.preloadAll()
        if let stats = provider.lastPreloadStats {
            log(String(format: "[Preload] loaded: %d, missing: %d, skipped: %d, duration: %.1fms",
                       stats.loadedCount, stats.missingCount, stats.skippedBindingCount, stats.durationMs))
        }

        // PR-32: Create UserMediaService for photo/video injection
        if let tp = textureProvider {
            userMediaService = UserMediaService(
                device: device,
                scenePlayer: player,
                textureProvider: tp
            )
            userMediaService?.setSceneFPS(Double(compiled.runtime.fps))
            // PR1.1: Wire callback for async updates (poster ready, clear)
            userMediaService?.onNeedsDisplay = { [weak self] in
                self?.metalView.setNeedsDisplay()
            }
            log("UserMediaService initialized")
        }

        // Log compilation results
        let runtime = compiled.runtime
        let blockCount = runtime.blocks.count
        let canvasSizeStr = "\(Int(canvasSize.width))x\(Int(canvasSize.height))"
        log("Scene compiled: \(canvasSizeStr) @ \(runtime.fps)fps, \(runtime.durationFrames) frames, \(blockCount) blocks")

        // Log block details
        for block in runtime.blocks {
            let rect = block.rectCanvas
            let rectStr = "(\(Int(rect.x)),\(Int(rect.y)) \(Int(rect.width))x\(Int(rect.height)))"
            log("  Block '\(block.blockId)' z=\(block.zIndex) rect=\(rectStr)")
        }

        // Log asset count
        log("Merged assets: \(compiled.mergedAssetIndex.byId.count) textures")

        // PR-B: Diagnostic — verify preload coverage (DEBUG only)
        // After preloadAll(), texture(for:) is IO-free cache lookup
        #if DEBUG
        for (assetId, _) in compiled.mergedAssetIndex.byId {
            if let tex = textureProvider?.texture(for: assetId) {
                log("Texture: \(assetId) [\(tex.width)x\(tex.height)]")
            } else {
                log("WARNING: Texture MISSING after preload: \(assetId)")
            }
        }
        #endif

        // Setup playback controls
        totalFrames = runtime.durationFrames
```

### C3) Critical lifecycle chains (provable)

#### Texture provider preload lifecycle (init → preload → steady-state lookup)
`preloadAll()` resolves URLs and loads textures in a loop, writing into an in-memory cache.

**Code anchor**
- `TVECore/Sources/TVECore/MetalRenderer/ScenePackageTextureProvider.swift`
- `preloadAll() loop + resolveURL + loadTexture`
```swift
    /// bypassing resolver-based resolution. Used for binding layer user media.
    ///
    /// Model A contract: texture mutations happen only on main during playback/render.
    ///
    /// - Parameters:
    ///   - texture: Metal texture to inject
    ///   - assetId: Asset ID to associate the texture with (namespaced)
    public func setTexture(_ texture: MTLTexture, for assetId: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        cache[assetId] = texture
        missingAssets.remove(assetId)
    }

    /// Removes an injected texture, allowing re-resolution or marking as missing.
    ///
    /// Model A contract: texture mutations happen only on main during playback/render.
    ///
    /// - Parameter assetId: Asset ID to remove from cache
    public func removeTexture(for assetId: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        cache.removeValue(forKey: assetId)
        missingAssets.remove(assetId)
    }

    // MARK: - Preloading

    /// Preloads all resolvable textures from the asset index.
    ///
    /// **PR-B: Must be called before any rendering.** After this call, `texture(for:)`
    /// becomes a pure O(1) cache lookup with no IO.
    ///
    /// Binding assets (identified by `bindingAssetIds`) are expected to have no file on disk
    /// and are skipped with a debug log. All other non-resolvable assets are logged as errors
    /// and added to `missingAssets` — this indicates a corrupted template.
    ///
    /// Statistics are stored in `lastPreloadStats` after completion.
    public func preloadAll() {
        let startTime = CFAbsoluteTimeGetCurrent()
        var loadedCount = 0
        var skippedBindingCount = 0

        for (assetId, basename) in assetIndex.basenameById {
            // Skip already cached (including injected textures)
            if cache[assetId] != nil {
                loadedCount += 1 // Count as loaded (was pre-injected)
                continue
            }

            guard let textureURL = try? resolver.resolveURL(forKey: basename) else {
                if bindingAssetIds.contains(assetId) {
                    // Expected: binding asset has no file (user media injected at runtime)
                    logger?("[TextureProvider] Preload skipped binding asset '\(assetId)'")
                    skippedBindingCount += 1
                } else {
                    // Unexpected: non-binding asset missing — template corrupted
                    logger?("[TextureProvider] ERROR: Asset '\(assetId)' (basename='\(basename)') not resolvable — template may be corrupted")
                    missingAssets.insert(assetId)
                }
                continue
            }

            if let texture = loadTexture(from: textureURL, assetId: assetId) {
                cache[assetId] = texture
                loadedCount += 1
            }
            // Note: loadTexture already adds to missingAssets on failure
        }

        let durationMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0

        lastPreloadStats = PreloadStats(
            loadedCount: loadedCount,
            missingCount: missingAssets.count,
            skippedBindingCount: skippedBindingCount,
            durationMs: durationMs
        )
    }

    /// Clears the texture cache and missing assets set.
    public func clearCache() {
        cache.removeAll()
        missingAssets.removeAll()
    }

    // MARK: - Private

```

#### Video provider async load lifecycle (init → async duration load → release)
`VideoFrameProvider` uses a `Task` to `await asset.load(.duration)` and commits state on `MainActor`; `release()` cancels the task and tears down AV objects.

**Code anchor**
- `AnimiApp/Sources/UserMedia/VideoFrameProvider.swift`
- `loadDuration(from:) + release()`
```swift
        guard now - lastDiagnosticLogTime >= diagnosticLogInterval else { return }

        let total = nilExtractCount + successExtractCount
        if total > 0 {
            let nilRate = Double(nilExtractCount) / Double(total) * 100
            print("[VideoFrameProvider] extractTexture: \(successExtractCount) OK, \(nilExtractCount) nil (\(String(format: "%.1f", nilRate))% nil rate)")
        }

        // Reset counters
        nilExtractCount = 0
        successExtractCount = 0
        lastDiagnosticLogTime = now
    }
    #endif

    /// Loads video duration asynchronously.
    /// PR-async-race: Token-protected to prevent stale updates after release().
    private func loadDuration(from asset: AVURLAsset) {
        let token = generation
        durationTask = Task {
            do {
                let loadedDuration = try await asset.load(.duration)
                await MainActor.run {
                    // PR-async-race: Ignore result if generation changed (provider released/reused)
                    guard self.generation == token, !Task.isCancelled else { return }
                    self.duration = loadedDuration
                    self.state = .ready
                }
            } catch {
                await MainActor.run {
                    // PR-async-race: Ignore error if generation changed
                    guard self.generation == token, !Task.isCancelled else { return }
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Cleanup

    /// Releases video resources.
    /// PR-async-race: Increments generation and cancels pending tasks to prevent stale updates.
    public func release() {
        // PR-async-race: Invalidate all pending async operations
        generation += 1
        durationTask?.cancel()
        durationTask = nil

        stopPlayback()
        playerItem.remove(videoOutput)
        player.replaceCurrentItem(with: nil)
        lastTexture = nil
        textureFactory.flushCache()
        state = .idle
    }

    deinit {
        release()
    }
}
```

#### User media video setup lifecycle (setVideo → async poster → commit state)
`UserMediaService` is `@MainActor` and uses generation tokens + task cancellation to prevent stale async commits.

**Code anchor**
- `AnimiApp/Sources/UserMedia/UserMediaService.swift`
- `@MainActor + setVideo(...) token/cancel flow`
```swift

    /// Sets a video as user media for a block.
    ///
    /// PR1: Creates provider, generates poster before enabling binding.
    /// Uses poster gating: `userMediaPresent` is only set to `true` after poster is ready.
    /// PR-async-race: Token-protected to prevent stale updates on rapid replace.
    ///
    /// Note: Caller (PlayerViewController) must copy video to temp before calling.
    /// This is required by PHPicker API — the source URL is only valid inside the callback.
    ///
    /// - Parameters:
    ///   - blockId: Identifier of the media block
    ///   - tempURL: URL of the video file (already copied to temp by caller)
    /// - Returns: `true` if video accepted (async poster generation started), `false` on validation error
    @discardableResult
    public func setVideo(blockId: String, tempURL: URL) -> Bool {
        guard let player = scenePlayer else {
            print("[UserMediaService] setVideo failed: no scene player")
            return false
        }

        // PR1: Clean up any existing video provider and temp file
        cleanupVideoResources(for: blockId)

        // PR-async-race: Increment generation and cancel previous setup task
        let newGeneration = (videoSetupGenerationByBlock[blockId] ?? 0) + 1
        videoSetupGenerationByBlock[blockId] = newGeneration
        let token = newGeneration

        videoSetupTasksByBlock[blockId]?.cancel()

        // Store temp URL for cleanup (caller already copied, we manage lifecycle)
        tempVideoURLByBlockId[blockId] = tempURL

        // Create video frame provider with scene FPS
        let provider = VideoFrameProvider(device: device, url: tempURL, sceneFPS: sceneFPS)
        videoProviders[blockId] = provider

        // PR1: Store state immediately but userMediaPresent = false (poster gating)
        // We'll set the proper VideoSelection after we know the duration
        // For now, create a placeholder that will be updated
        // Note: userMediaPresent stays false until poster is ready

        // Start async poster generation
        // PR-async-race: Store task for cancellation on replace/cleanup
        let setupTask = Task { @MainActor [weak self] in
            guard let self = self else { return }

            do {
                // PR1 FIX: requestPoster waits for ready internally, no need for separate polling
                // Request poster at time 0 first to ensure provider is ready
                let poster = try await provider.requestPoster(at: 0)

                // PR-async-race: Check token after await — abort if generation changed
                guard self.videoSetupGenerationByBlock[blockId] == token, !Task.isCancelled else {
                    #if DEBUG
                    print("[UserMediaService] setVideo: stale task ignored for blockId=\(blockId)")
                    #endif
                    return
                }

                // Get duration after provider is ready
                let duration = provider.duration.seconds

                // Validate duration
                guard duration > Self.epsilon else {
                    print("[UserMediaService] setVideo failed: video duration too short (\(duration)s)")
                    self.clear(blockId: blockId)
                    return
                }

                // Create proper VideoSelection with duration
                let selection = VideoSelection(url: tempURL, duration: duration)

                // Validate selection
                guard selection.isValid else {
                    print("[UserMediaService] setVideo failed: invalid selection (winEnd <= winStart)")
                    self.clear(blockId: blockId)
                    return
                }

                // PR-async-race: Final check before side effects
                guard self.videoSetupGenerationByBlock[blockId] == token, !Task.isCancelled else {
                    #if DEBUG
                    print("[UserMediaService] setVideo: stale task ignored (pre-commit) for blockId=\(blockId)")
                    #endif
                    return
                }

                // Update state with proper selection
                self.mediaState[blockId] = .video(selection)

                // Inject poster texture into all variant binding asset IDs
                // (poster at winStart=0 is the default, which is what we already have)
                let assetIds = player.bindingAssetIdsByVariant(blockId: blockId)
                for (_, assetId) in assetIds {
                    self.textureProvider.setTexture(poster, for: assetId)
                }

                // NOW enable binding layer (poster gating complete)
                player.setUserMediaPresent(blockId: blockId, present: true)

                // PR1.1: Trigger redraw after async poster injection
                self.onNeedsDisplay?()

                #if DEBUG
                print("[UserMediaService] setVideo success: blockId=\(blockId), duration=\(duration)s, needsDisplay fired")
                #endif

            } catch is CancellationError {
                // PR-async-race: Expected on cancel/replace — silent ignore
                #if DEBUG
                print("[UserMediaService] setVideo: cancelled for blockId=\(blockId)")
                #endif
            } catch {
                // PR-async-race: Only clear if still current
                guard self.videoSetupGenerationByBlock[blockId] == token else { return }
                // PR1: On poster error, log and clear
                print("[UserMediaService] setVideo failed: poster generation error - \(error.localizedDescription)")
                self.clear(blockId: blockId)
            }
        }

        videoSetupTasksByBlock[blockId] = setupTask

        return true
    }

    /// Copies video to temp directory.
    private func copyVideoToTemp(sourceURL: URL, blockId: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let destURL = tempDir.appendingPathComponent("\(blockId)_\(UUID().uuidString).mov")

        try FileManager.default.copyItem(at: sourceURL, to: destURL)
        return destURL
    }

    // MARK: - Playback Control

    /// Starts video playback for visible video providers.
    ///
```

---

## D. Architecture assessment (facts only)

### D1) App-level composition root (provable)

`SceneDelegate` directly instantiates `PlayerViewController()` and sets it as root.

**Code anchor**
- `AnimiApp/Sources/App/SceneDelegate.swift`
- `scene(_:willConnectTo:options:) root VC wiring`
```swift
import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        let playerViewController = PlayerViewController()
        window.rootViewController = playerViewController
        window.makeKeyAndVisible()

        self.window = window
    }
}
```

### D2) Boundary enforcement exists (provable)

**Code anchor**
- `Scripts/verify_module_boundary.sh`
- `boundary check script`
```bash
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
```

---

## E. Concurrency & state safety (facts only)

### E1) Main-thread contract enforcement for texture mutations

**Code anchor**
- `TVECore/Sources/TVECore/MetalRenderer/ScenePackageTextureProvider.swift`
- `dispatchPrecondition in setTexture/removeTexture`
```swift
    ///
    /// Externally injected textures (via `setTexture`) are returned from cache directly.
    ///
    /// Model A contract: texture access happens only on main during playback/render.
    public func texture(for assetId: String) -> MTLTexture? {
        dispatchPrecondition(condition: .onQueue(.main))

        // Check cache (includes preloaded and injected user media textures)
        if let cached = cache[assetId] {
            return cached
        }

        // Skip known missing assets (don't spam assertions)
        if missingAssets.contains(assetId) {
            return nil
        }

        // PR-B: Cache miss in runtime = preload contract violation
        // In DEBUG: signal developer about missing preload
        // In Release: assertionFailure is stripped, just return nil
        assertionFailure("[TextureProvider] Asset not preloaded: '\(assetId)' — call preloadAll() before rendering")
        missingAssets.insert(assetId)
        return nil
    }

    // MARK: - External Texture Injection

    /// Injects an externally provided texture (e.g. user-selected media photo).
    ///
    /// Injected textures are stored in cache and returned directly by `texture(for:)`,
    /// bypassing resolver-based resolution. Used for binding layer user media.
    ///
    /// Model A contract: texture mutations happen only on main during playback/render.
    ///
    /// - Parameters:
    ///   - texture: Metal texture to inject
    ///   - assetId: Asset ID to associate the texture with (namespaced)
    public func setTexture(_ texture: MTLTexture, for assetId: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        cache[assetId] = texture
        missingAssets.remove(assetId)
    }

    /// Removes an injected texture, allowing re-resolution or marking as missing.
    ///
    /// Model A contract: texture mutations happen only on main during playback/render.
    ///
    /// - Parameter assetId: Asset ID to remove from cache
    public func removeTexture(for assetId: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        cache.removeValue(forKey: assetId)
```

### E2) Async tasks used with explicit cancellation/generation tokens

**Code anchor**
- `AnimiApp/Sources/UserMedia/UserMediaService.swift`
- `@MainActor + setVideo(...) token/cancel flow`
```swift

    /// Sets a video as user media for a block.
    ///
    /// PR1: Creates provider, generates poster before enabling binding.
    /// Uses poster gating: `userMediaPresent` is only set to `true` after poster is ready.
    /// PR-async-race: Token-protected to prevent stale updates on rapid replace.
    ///
    /// Note: Caller (PlayerViewController) must copy video to temp before calling.
    /// This is required by PHPicker API — the source URL is only valid inside the callback.
    ///
    /// - Parameters:
    ///   - blockId: Identifier of the media block
    ///   - tempURL: URL of the video file (already copied to temp by caller)
    /// - Returns: `true` if video accepted (async poster generation started), `false` on validation error
    @discardableResult
    public func setVideo(blockId: String, tempURL: URL) -> Bool {
        guard let player = scenePlayer else {
            print("[UserMediaService] setVideo failed: no scene player")
            return false
        }

        // PR1: Clean up any existing video provider and temp file
        cleanupVideoResources(for: blockId)

        // PR-async-race: Increment generation and cancel previous setup task
        let newGeneration = (videoSetupGenerationByBlock[blockId] ?? 0) + 1
        videoSetupGenerationByBlock[blockId] = newGeneration
        let token = newGeneration

        videoSetupTasksByBlock[blockId]?.cancel()

        // Store temp URL for cleanup (caller already copied, we manage lifecycle)
        tempVideoURLByBlockId[blockId] = tempURL

        // Create video frame provider with scene FPS
        let provider = VideoFrameProvider(device: device, url: tempURL, sceneFPS: sceneFPS)
        videoProviders[blockId] = provider

        // PR1: Store state immediately but userMediaPresent = false (poster gating)
        // We'll set the proper VideoSelection after we know the duration
        // For now, create a placeholder that will be updated
        // Note: userMediaPresent stays false until poster is ready

        // Start async poster generation
        // PR-async-race: Store task for cancellation on replace/cleanup
        let setupTask = Task { @MainActor [weak self] in
            guard let self = self else { return }

            do {
                // PR1 FIX: requestPoster waits for ready internally, no need for separate polling
                // Request poster at time 0 first to ensure provider is ready
                let poster = try await provider.requestPoster(at: 0)

                // PR-async-race: Check token after await — abort if generation changed
                guard self.videoSetupGenerationByBlock[blockId] == token, !Task.isCancelled else {
                    #if DEBUG
                    print("[UserMediaService] setVideo: stale task ignored for blockId=\(blockId)")
                    #endif
                    return
                }

                // Get duration after provider is ready
                let duration = provider.duration.seconds

                // Validate duration
                guard duration > Self.epsilon else {
                    print("[UserMediaService] setVideo failed: video duration too short (\(duration)s)")
                    self.clear(blockId: blockId)
                    return
                }

                // Create proper VideoSelection with duration
                let selection = VideoSelection(url: tempURL, duration: duration)

                // Validate selection
                guard selection.isValid else {
                    print("[UserMediaService] setVideo failed: invalid selection (winEnd <= winStart)")
                    self.clear(blockId: blockId)
                    return
                }

                // PR-async-race: Final check before side effects
                guard self.videoSetupGenerationByBlock[blockId] == token, !Task.isCancelled else {
                    #if DEBUG
                    print("[UserMediaService] setVideo: stale task ignored (pre-commit) for blockId=\(blockId)")
                    #endif
                    return
                }

                // Update state with proper selection
                self.mediaState[blockId] = .video(selection)

                // Inject poster texture into all variant binding asset IDs
                // (poster at winStart=0 is the default, which is what we already have)
                let assetIds = player.bindingAssetIdsByVariant(blockId: blockId)
                for (_, assetId) in assetIds {
                    self.textureProvider.setTexture(poster, for: assetId)
                }

                // NOW enable binding layer (poster gating complete)
                player.setUserMediaPresent(blockId: blockId, present: true)

                // PR1.1: Trigger redraw after async poster injection
                self.onNeedsDisplay?()

                #if DEBUG
                print("[UserMediaService] setVideo success: blockId=\(blockId), duration=\(duration)s, needsDisplay fired")
                #endif

            } catch is CancellationError {
                // PR-async-race: Expected on cancel/replace — silent ignore
                #if DEBUG
                print("[UserMediaService] setVideo: cancelled for blockId=\(blockId)")
                #endif
            } catch {
                // PR-async-race: Only clear if still current
                guard self.videoSetupGenerationByBlock[blockId] == token else { return }
                // PR1: On poster error, log and clear
                print("[UserMediaService] setVideo failed: poster generation error - \(error.localizedDescription)")
                self.clear(blockId: blockId)
            }
        }

        videoSetupTasksByBlock[blockId] = setupTask

        return true
    }

    /// Copies video to temp directory.
    private func copyVideoToTemp(sourceURL: URL, blockId: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let destURL = tempDir.appendingPathComponent("\(blockId)_\(UUID().uuidString).mov")

        try FileManager.default.copyItem(at: sourceURL, to: destURL)
        return destURL
    }

    // MARK: - Playback Control

    /// Starts video playback for visible video providers.
    ///
```

**Code anchor**
- `AnimiApp/Sources/UserMedia/VideoFrameProvider.swift`
- `loadDuration(from:) + release()`
```swift
        guard now - lastDiagnosticLogTime >= diagnosticLogInterval else { return }

        let total = nilExtractCount + successExtractCount
        if total > 0 {
            let nilRate = Double(nilExtractCount) / Double(total) * 100
            print("[VideoFrameProvider] extractTexture: \(successExtractCount) OK, \(nilExtractCount) nil (\(String(format: "%.1f", nilRate))% nil rate)")
        }

        // Reset counters
        nilExtractCount = 0
        successExtractCount = 0
        lastDiagnosticLogTime = now
    }
    #endif

    /// Loads video duration asynchronously.
    /// PR-async-race: Token-protected to prevent stale updates after release().
    private func loadDuration(from asset: AVURLAsset) {
        let token = generation
        durationTask = Task {
            do {
                let loadedDuration = try await asset.load(.duration)
                await MainActor.run {
                    // PR-async-race: Ignore result if generation changed (provider released/reused)
                    guard self.generation == token, !Task.isCancelled else { return }
                    self.duration = loadedDuration
                    self.state = .ready
                }
            } catch {
                await MainActor.run {
                    // PR-async-race: Ignore error if generation changed
                    guard self.generation == token, !Task.isCancelled else { return }
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Cleanup

    /// Releases video resources.
    /// PR-async-race: Increments generation and cancels pending tasks to prevent stale updates.
    public func release() {
        // PR-async-race: Invalidate all pending async operations
        generation += 1
        durationTask?.cancel()
        durationTask = nil

        stopPlayback()
        playerItem.remove(videoOutput)
        player.replaceCurrentItem(with: nil)
        lastTexture = nil
        textureFactory.flushCache()
        state = .idle
    }

    deinit {
        release()
    }
}
```

### E3) Unchecked Sendable present

**Code anchor**
- `AnimiApp/Sources/Player/PlayerViewController.swift`
- `BackgroundLoadResult @unchecked Sendable`
```swift
// MARK: - Scene Variant Preset (PR-20)

/// A named mapping of blockId -> variantId for scene-level style switching.
struct SceneVariantPreset {
    let id: String
    let title: String
    let mapping: [String: String]  // blockId -> variantId
}

// MARK: - PR-D: Async Loading Helper Structs

/// Result from background phase of template loading.
/// Note: @unchecked Sendable because CompiledScenePackage is a value type with immutable data.
private struct BackgroundLoadResult: @unchecked Sendable {
    let compiledPackage: CompiledScenePackage
    let resolver: CompositeAssetResolver
}

/// Result from ScenePlayer setup phase (main actor only, not Sendable).
private struct SceneSetupResult {
    let player: ScenePlayer
    let compiled: CompiledScene
}

/// Main player view controller with Metal rendering surface and debug log.
/// Supports full scene playback with multiple media blocks.
final class PlayerViewController: UIViewController {

    // MARK: - UI Components

    #if DEBUG
    private lazy var sceneSelector: UISegmentedControl = {
        let control = UISegmentedControl(items: ["4 Blocks", "Alpha Matte", "Variant Demo", "Shared Decor"])
```

---

## F. Memory & performance (facts only)

### F1) Potential main-thread blocking: texture preloading invoked inline

**Code anchor**
- `AnimiApp/Sources/Player/PlayerViewController.swift`
- `provider.preloadAll() call site`
```swift
        provider.preloadAll()
        if let stats = provider.lastPreloadStats {
            log(String(format: "[Preload] loaded: %d, missing: %d, skipped: %d, duration: %.1fms",
                       stats.loadedCount, stats.missingCount, stats.skippedBindingCount, stats.durationMs))
        }

        // PR-32: Create UserMediaService for photo/video injection
        if let tp = textureProvider {
            userMediaService = UserMediaService(
                device: device,
                scenePlayer: player,
                textureProvider: tp
            )
            userMediaService?.setSceneFPS(Double(compiled.runtime.fps))
            // PR1.1: Wire callback for async updates (poster ready, clear)
            userMediaService?.onNeedsDisplay = { [weak self] in
                self?.metalView.setNeedsDisplay()
            }
            log("UserMediaService initialized")
        }

        // Log compilation results
        let runtime = compiled.runtime
        let blockCount = runtime.blocks.count
        let canvasSizeStr = "\(Int(canvasSize.width))x\(Int(canvasSize.height))"
        log("Scene compiled: \(canvasSizeStr) @ \(runtime.fps)fps, \(runtime.durationFrames) frames, \(blockCount) blocks")
```

**Code anchor**
- `TVECore/Sources/TVECore/MetalRenderer/ScenePackageTextureProvider.swift`
- `preloadAll() loop + resolveURL + loadTexture`
```swift
    /// bypassing resolver-based resolution. Used for binding layer user media.
    ///
    /// Model A contract: texture mutations happen only on main during playback/render.
    ///
    /// - Parameters:
    ///   - texture: Metal texture to inject
    ///   - assetId: Asset ID to associate the texture with (namespaced)
    public func setTexture(_ texture: MTLTexture, for assetId: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        cache[assetId] = texture
        missingAssets.remove(assetId)
    }

    /// Removes an injected texture, allowing re-resolution or marking as missing.
    ///
    /// Model A contract: texture mutations happen only on main during playback/render.
    ///
    /// - Parameter assetId: Asset ID to remove from cache
    public func removeTexture(for assetId: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        cache.removeValue(forKey: assetId)
        missingAssets.remove(assetId)
    }

    // MARK: - Preloading

    /// Preloads all resolvable textures from the asset index.
    ///
    /// **PR-B: Must be called before any rendering.** After this call, `texture(for:)`
    /// becomes a pure O(1) cache lookup with no IO.
    ///
    /// Binding assets (identified by `bindingAssetIds`) are expected to have no file on disk
    /// and are skipped with a debug log. All other non-resolvable assets are logged as errors
    /// and added to `missingAssets` — this indicates a corrupted template.
    ///
    /// Statistics are stored in `lastPreloadStats` after completion.
    public func preloadAll() {
        let startTime = CFAbsoluteTimeGetCurrent()
        var loadedCount = 0
        var skippedBindingCount = 0

        for (assetId, basename) in assetIndex.basenameById {
            // Skip already cached (including injected textures)
            if cache[assetId] != nil {
                loadedCount += 1 // Count as loaded (was pre-injected)
                continue
            }

            guard let textureURL = try? resolver.resolveURL(forKey: basename) else {
                if bindingAssetIds.contains(assetId) {
                    // Expected: binding asset has no file (user media injected at runtime)
                    logger?("[TextureProvider] Preload skipped binding asset '\(assetId)'")
                    skippedBindingCount += 1
                } else {
                    // Unexpected: non-binding asset missing — template corrupted
                    logger?("[TextureProvider] ERROR: Asset '\(assetId)' (basename='\(basename)') not resolvable — template may be corrupted")
                    missingAssets.insert(assetId)
                }
                continue
            }

            if let texture = loadTexture(from: textureURL, assetId: assetId) {
                cache[assetId] = texture
                loadedCount += 1
            }
            // Note: loadTexture already adds to missingAssets on failure
        }

        let durationMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0

        lastPreloadStats = PreloadStats(
            loadedCount: loadedCount,
            missingCount: missingAssets.count,
            skippedBindingCount: skippedBindingCount,
            durationMs: durationMs
        )
    }

    /// Clears the texture cache and missing assets set.
    public func clearCache() {
        cache.removeAll()
        missingAssets.removeAll()
    }

    // MARK: - Private

```

### F2) Cache growth behavior (provable)

`preloadAll()` writes textures to `cache[assetId]` and does not evict entries during preload.

**Code anchor**
- `TVECore/Sources/TVECore/MetalRenderer/ScenePackageTextureProvider.swift`
- `preloadAll() loop + resolveURL + loadTexture`
```swift
    /// bypassing resolver-based resolution. Used for binding layer user media.
    ///
    /// Model A contract: texture mutations happen only on main during playback/render.
    ///
    /// - Parameters:
    ///   - texture: Metal texture to inject
    ///   - assetId: Asset ID to associate the texture with (namespaced)
    public func setTexture(_ texture: MTLTexture, for assetId: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        cache[assetId] = texture
        missingAssets.remove(assetId)
    }

    /// Removes an injected texture, allowing re-resolution or marking as missing.
    ///
    /// Model A contract: texture mutations happen only on main during playback/render.
    ///
    /// - Parameter assetId: Asset ID to remove from cache
    public func removeTexture(for assetId: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        cache.removeValue(forKey: assetId)
        missingAssets.remove(assetId)
    }

    // MARK: - Preloading

    /// Preloads all resolvable textures from the asset index.
    ///
    /// **PR-B: Must be called before any rendering.** After this call, `texture(for:)`
    /// becomes a pure O(1) cache lookup with no IO.
    ///
    /// Binding assets (identified by `bindingAssetIds`) are expected to have no file on disk
    /// and are skipped with a debug log. All other non-resolvable assets are logged as errors
    /// and added to `missingAssets` — this indicates a corrupted template.
    ///
    /// Statistics are stored in `lastPreloadStats` after completion.
    public func preloadAll() {
        let startTime = CFAbsoluteTimeGetCurrent()
        var loadedCount = 0
        var skippedBindingCount = 0

        for (assetId, basename) in assetIndex.basenameById {
            // Skip already cached (including injected textures)
            if cache[assetId] != nil {
                loadedCount += 1 // Count as loaded (was pre-injected)
                continue
            }

            guard let textureURL = try? resolver.resolveURL(forKey: basename) else {
                if bindingAssetIds.contains(assetId) {
                    // Expected: binding asset has no file (user media injected at runtime)
                    logger?("[TextureProvider] Preload skipped binding asset '\(assetId)'")
                    skippedBindingCount += 1
                } else {
                    // Unexpected: non-binding asset missing — template corrupted
                    logger?("[TextureProvider] ERROR: Asset '\(assetId)' (basename='\(basename)') not resolvable — template may be corrupted")
                    missingAssets.insert(assetId)
                }
                continue
            }

            if let texture = loadTexture(from: textureURL, assetId: assetId) {
                cache[assetId] = texture
                loadedCount += 1
            }
            // Note: loadTexture already adds to missingAssets on failure
        }

        let durationMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0

        lastPreloadStats = PreloadStats(
            loadedCount: loadedCount,
            missingCount: missingAssets.count,
            skippedBindingCount: skippedBindingCount,
            durationMs: durationMs
        )
    }

    /// Clears the texture cache and missing assets set.
    public func clearCache() {
        cache.removeAll()
        missingAssets.removeAll()
    }

    // MARK: - Private

```

**NOT PROVEN:** whether cache bounds are acceptable without profiling data.

---

## G. Error handling & resilience (facts only)

### G1) Forced unwraps / IUOs exist in runtime code

**Code anchor**
- `TVECore/Sources/TVECore/MetalRenderer/MetalRendererResources.swift`
- `descriptor.colorAttachments[0]!`
```swift
// MARK: - GPU Mask Pipeline Creation

extension MetalRendererResources {
    /// Creates pipeline for rendering path triangles to R8 coverage texture.
    /// Uses additive blending for overlapping triangles.
    private static func makeCoveragePipeline(
        device: MTLDevice,
        library: MTLLibrary
    ) throws -> MTLRenderPipelineState {
        guard let vertexFunc = library.makeFunction(name: "coverage_vertex") else {
            throw MetalRendererError.failedToCreatePipeline(reason: "coverage_vertex not found")
        }
        guard let fragmentFunc = library.makeFunction(name: "coverage_fragment") else {
            throw MetalRendererError.failedToCreatePipeline(reason: "coverage_fragment not found")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunc
        descriptor.fragmentFunction = fragmentFunc

        // R8Unorm output for coverage
        let colorAttachment = descriptor.colorAttachments[0]!
        colorAttachment.pixelFormat = .r8Unorm
        // No blending - triangulation should not produce overlapping triangles
        // If overlap occurs, it's a bug in triangulation data
        // saturate() in compute kernel handles any edge cases
        colorAttachment.isBlendingEnabled = false

        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            let msg = "Coverage pipeline failed: \(error.localizedDescription)"
            throw MetalRendererError.failedToCreatePipeline(reason: msg)
        }
    }

    /// Creates pipeline for compositing content with R8 mask (content × mask.r).
    private static func makeMaskedCompositePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        colorPixelFormat: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {
        guard let vertexFunc = library.makeFunction(name: "masked_composite_vertex") else {
            throw MetalRendererError.failedToCreatePipeline(reason: "masked_composite_vertex not found")
        }
        guard let fragmentFunc = library.makeFunction(name: "masked_composite_fragment") else {
            throw MetalRendererError.failedToCreatePipeline(reason: "masked_composite_fragment not found")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunc
```

**Code anchor**
- `TVECore/Sources/TVECore/MetalRenderer/Earcut.swift`
- `triangulate(vertices:holeIndices:) forced unwrap`
```swift
import Foundation

// MARK: - Earcut Triangulator

/// Ear-clipping triangulation algorithm for simple polygons.
/// Based on the earcut.js algorithm by Mapbox.
/// Converts a polygon (with optional holes) into triangles for GPU rendering.
public enum Earcut {

    /// Triangulates a simple polygon defined by its vertices.
    /// - Parameters:
    ///   - vertices: Flat array of coordinates [x0, y0, x1, y1, ...]
    ///   - holeIndices: Array of indices where holes start (empty for no holes)
    /// - Returns: Array of triangle indices into the vertices array
    public static func triangulate(vertices: [Double], holeIndices: [Int] = []) -> [Int] {
        let vertexCount = vertices.count / 2
        guard vertexCount >= 3 else { return [] }

        let hasHoles = !holeIndices.isEmpty
        let outerLen = hasHoles ? holeIndices[0] : vertexCount

        var outerNode = linkedList(vertices: vertices, start: 0, end: outerLen, clockwise: true)
        guard var node = outerNode else { return [] }

        var triangles: [Int] = []

        if hasHoles {
            outerNode = eliminateHoles(vertices: vertices, holeIndices: holeIndices, outerNode: node)
            node = outerNode!
        }

        // For simple polygons, use fast ear-clipping
        if vertexCount <= 80 {
            earcutLinked(&node, &triangles, pass: 0)
        } else {
            // For complex polygons, use z-order curve hashing
            let (minX, minY, maxX, maxY) = computeBounds(vertices: vertices, start: 0, end: outerLen)
            let invSize = max(maxX - minX, maxY - minY)
            indexCurve(node, minX: minX, minY: minY, invSize: invSize == 0 ? 1 : 1 / invSize)
            earcutLinked(&node, &triangles, pass: 0)
        }

        return triangles
    }

    /// Triangulates a BezierPath by flattening curves and triangulating the result.
    /// - Parameters:
    ///   - path: BezierPath to triangulate
    ///   - flatness: Maximum distance from curve to line segment (default: 1.0)
    /// - Returns: Array of triangle indices
    public static func triangulate(path: BezierPath, flatness: Double = 1.0) -> [Int] {
        let flattenedVertices = flattenPath(path, flatness: flatness)
        return triangulate(vertices: flattenedVertices)
    }

```

### G2) Intentional fatalError in UIKit initializers

**Code anchor**
- `AnimiApp/Sources/Editor/EditorOverlayView.swift`
- `required init?(coder:) fatalError`
```swift
import UIKit
import TVECore

/// Transparent overlay view drawn on top of Metal rendering surface.
/// Displays interactive block outlines using CAShapeLayer.
///
/// PR-19: Editor overlay — CAShapeLayer-based (lead-approved).
/// `isUserInteractionEnabled = false` — all gestures go to metalView underneath.
final class EditorOverlayView: UIView {

    // MARK: - Properties

    /// Canvas-to-View affine transform. Set by controller on layout changes.
    /// Must match the Metal renderer's contain (aspect-fit) mapping.
    var canvasToView: CGAffineTransform = .identity

    // MARK: - Layers

    private var selectedLayer: CAShapeLayer?
    private var inactiveLayers: [CAShapeLayer] = []

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - Update

    /// Update overlay display with current block overlays.
    ///
    /// - Parameters:
    ///   - overlays: From `player.overlays(frame:)` — hit paths in canvas coords.
    ///   - selectedBlockId: Currently selected block (nil = none selected).
    func update(overlays: [MediaInputOverlay], selectedBlockId: String?) {
        // Remove old layers
        selectedLayer?.removeFromSuperlayer()
        selectedLayer = nil
        inactiveLayers.forEach { $0.removeFromSuperlayer() }
        inactiveLayers.removeAll()

        guard !overlays.isEmpty else { return }

        for overlay in overlays {
            let isSelected = overlay.blockId == selectedBlockId

            let shapeLayer = CAShapeLayer()
            shapeLayer.frame = bounds

            // Convert BezierPath (canvas coords) -> CGPath -> view coords
            let canvasPath = overlay.hitPath.cgPath
```

---

## H. Testing & tooling (facts only)

### H1) Test target exists in SPM

**Code anchor**
- `TVECore/Package.swift`
- `products + targets + dependency edges`
```swift
// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TVECore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "TVECore",
            targets: ["TVECore"]
        ),
        .library(
            name: "TVECompilerCore",
            targets: ["TVECompilerCore"]
        ),
        .executable(
            name: "TVETemplateCompiler",
            targets: ["TVETemplateCompiler"]
        )
    ],
    targets: [
        .target(
            name: "TVECore",
            dependencies: [],
            path: "Sources/TVECore",
            resources: [
                .process("MetalRenderer/Shaders")
            ]
        ),
        .target(
            name: "TVECompilerCore",
            dependencies: ["TVECore"],
            path: "Sources/TVECompilerCore"
        ),
        .executableTarget(
            name: "TVETemplateCompiler",
            dependencies: ["TVECompilerCore"],
            path: "Tools/TVETemplateCompiler"
        ),
        // NOTE: TVECoreTests temporarily depends on TVECompilerCore (variant A from review.md)
        // TODO: Split into TVECoreTests + TVECompilerCoreTests (variant B) in separate task
        .testTarget(
            name: "TVECoreTests",
            dependencies: ["TVECore", "TVECompilerCore"],
            path: "Tests/TVECoreTests",
            resources: [
                .copy("Resources")
            ]
        )
    ]
)
```

### H2) Release validation script exists

**Code anchor**
- `Scripts/verify_release_bundle.sh`
- `release bundle verification script`
```bash
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
```

### H3) SwiftLint config exists

**Code anchor**
- `.swiftlint.yml`
- `root swiftlint config`
```yaml
# SwiftLint Configuration for Animi Project

# Paths to include
included:
  - AnimiApp/Sources
  - TVECore/Sources

# Paths to exclude
excluded:
  - .build
  - "**/.build"
  - "**/DerivedData"
  - AnimiApp/Resources
  - TestAssets
  - TVECore/Tests

# Enabled rules
opt_in_rules:
  - force_unwrapping
  - closure_end_indentation
  - closure_spacing
  - collection_alignment
  - contains_over_filter_count
  - contains_over_filter_is_empty
  - contains_over_first_not_nil
  - discouraged_object_literal
  - empty_collection_literal
  - empty_count
  - empty_string
  - explicit_init
  - fatal_error_message
  - first_where
  - flatmap_over_map_reduce
  - identical_operands
  - joined_default_parameter
  - last_where
  - legacy_multiple
  - literal_expression_end_indentation
  - modifier_order
  - operator_usage_whitespace
  - overridden_super_call
  - prefer_self_in_static_references
  - prefer_self_type_over_type_of_self
  - prefer_zero_over_explicit_init
  - private_action
  - private_outlet
  - redundant_nil_coalescing
  - redundant_type_annotation
  - sorted_first_last
  - toggle_bool
  - unavailable_function
  - unneeded_parentheses_in_closure_argument
  - vertical_parameter_alignment_on_call
  - yoda_condition

# Disabled rules
disabled_rules:
  - todo
  - trailing_whitespace

# Rule configurations
line_length:
  warning: 120
  error: 150
  ignores_comments: true
  ignores_urls: true
  ignores_function_declarations: false

type_body_length:
  warning: 300
  error: 500

file_length:
  warning: 500
  error: 1000

function_body_length:
  warning: 50
  error: 100

function_parameter_count:
  warning: 6
  error: 8

cyclomatic_complexity:
  warning: 15
  error: 25

nesting:
  type_level: 2
  function_level: 3

identifier_name:
  min_length:
    warning: 2
    error: 1
  max_length:
    warning: 50
    error: 60
  excluded:
```

**NOT PROVEN:** whether scripts are executed automatically in CI/build phases (no CI config anchored here).

---

## I. Summary verdict

### I1) Can we safely continue developing new functionality right now?

**Verdict: YES (with P1 items recommended before scaling complexity).**

### I2) P0 blockers list (only if proven)

**None proven in this snapshot.**

---

## Mandatory coverage map (presence)

- App entry & dependency wiring: **PRESENT**.
- Media/video/render pipeline: **PRESENT**.
- Caching & file I/O: **PRESENT**.
- Concurrency & threading policy: **PRESENT**.
- Build scripts / release validation: **PRESENT**.

- - Networking / analytics / remote config: **NOT PRESENT IN SNAPSHOT (code scope)** — per `Docs/AUDIT_SCAN_REPORT.md` keyword scans.
- Persistence/DB/storage: **NOT PRESENT IN SNAPSHOT (code scope)** — per `Docs/AUDIT_SCAN_REPORT.md` keyword scans.
- Logging/analytics frameworks: **NOT PRESENT IN SNAPSHOT (code scope)** — per `Docs/AUDIT_SCAN_REPORT.md` keyword scans.

**Code anchor**
- `Docs/AUDIT_SCAN_REPORT.md`
- `Keyword scans — code scope`
```
### Persistence / storage — code scope (AnimiApp/Sources, TVECore/Sources, TVECore/Tests, Scripts)
Keywords: CoreData, NSPersistentContainer, NSManagedObject, SQLite, FMDB, Realm, GRDB, UserDefaults, Keychain, SecItem, SecureEnclave, NSUbiquitousKeyValueStore, .xcdatamodeld
Matches:
- Total matches: 0
- Matched files: (none)

### Networking / analytics / remote config — code scope (AnimiApp/Sources, TVECore/Sources, TVECore/Tests, Scripts)
Keywords: URLSession, NSURLSession, Alamofire, Moya, GraphQL, Apollo, FirebaseRemoteConfig, RemoteConfig, FirebaseAnalytics, Crashlytics, Sentry, Mixpanel, Amplitude, AppsFlyer, Analytics.logEvent, Appsflyer, AFSDK, FirebaseApp, FIRApp
Matches:
- Total matches: 0
- Matched files: (none)
```

- Feature flags/config: **NOT PROVEN** (no dedicated feature-flag system anchored in this baseline).
