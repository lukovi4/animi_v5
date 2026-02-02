# PR-20: AnimiApp UI Integration — Variant Switching V1

## Summary

Adds per-block variant picker and scene preset picker to the AnimiApp editor.
TemplateEditorController gets proxy methods; PlayerViewController gets UI components + handlers.
New demo scene `variant_switch_demo` for manual testing.

**Build result:** AnimiApp BUILD SUCCEEDED, TVECore 725 tests 0 failures.

---

## File List

| # | File | Status |
|---|------|--------|
| 1 | `AnimiApp/Sources/Editor/TemplateEditorController.swift` | MODIFIED |
| 2 | `AnimiApp/Sources/Player/PlayerViewController.swift` | MODIFIED |
| 3 | `TestAssets/ScenePackages/variant_switch_demo/scene.json` | NEW |
| 4 | `TestAssets/ScenePackages/variant_switch_demo/anim-v1.json` | NEW |
| 5 | `TestAssets/ScenePackages/variant_switch_demo/anim-v2.json` | NEW |
| 6 | `TestAssets/ScenePackages/variant_switch_demo/anim-b2.json` | NEW |
| 7 | `TestAssets/ScenePackages/variant_switch_demo/images/img_1.png` | NEW |
| 8 | `TestAssets/ScenePackages/variant_switch_demo/images/img_2.png` | NEW |
| 9 | `TestAssets/ScenePackages/variant_switch_demo/images/img_3.png` | NEW |
| 10 | `AnimiApp/project.yml` | NOT MODIFIED (verified) |

---

## 1. TemplateEditorController.swift

**Lines:** 295 → 336 (+41 lines)

### Added: Variant Selection proxy methods (after `applyTransform`, before `// MARK: - Overlay`)

**WAS:**
```swift
    private func applyTransform(_ transform: Matrix2D, for blockId: String) {
        player?.setUserTransform(blockId: blockId, transform: transform)
        requestDisplay()
    }

    // MARK: - Overlay
```

**BECAME:**
```swift
    private func applyTransform(_ transform: Matrix2D, for blockId: String) {
        player?.setUserTransform(blockId: blockId, transform: transform)
        requestDisplay()
    }

    // MARK: - Variant Selection (PR-20)

    /// Returns available variants for the currently selected block, or empty.
    func selectedBlockVariants() -> [VariantInfo] {
        guard let player = player,
              let blockId = state.selectedBlockId else { return [] }
        return player.availableVariants(blockId: blockId)
    }

    /// Returns the active variant ID for the currently selected block, or nil.
    func selectedBlockVariantId() -> String? {
        guard let player = player,
              let blockId = state.selectedBlockId else { return nil }
        return player.selectedVariantId(blockId: blockId)
    }

    /// Sets the variant for the currently selected block.
    ///
    /// Does NOT touch playback — VC is responsible for stopping displayLink first.
    /// Updates overlay and triggers display + state callbacks.
    func setSelectedVariantForSelectedBlock(_ variantId: String) {
        guard let player = player,
              let blockId = state.selectedBlockId else { return }
        player.setSelectedVariant(blockId: blockId, variantId: variantId)
        refreshOverlayIfNeeded()
        requestDisplay()
        onStateChanged?(state)
    }

    /// Applies a scene-level variant preset (mapping of blockId → variantId).
    ///
    /// Does NOT touch playback — VC is responsible for stopping displayLink first.
    /// Updates overlay and triggers display + state callbacks.
    func applyScenePreset(_ mapping: [String: String]) {
        guard let player = player else { return }
        player.applyVariantSelection(mapping)
        refreshOverlayIfNeeded()
        requestDisplay()
        onStateChanged?(state)
    }

    // MARK: - Overlay
```

---

## 2. PlayerViewController.swift

**Lines:** 710 → 858 (+148 lines)

### 2a. Added: SceneVariantPreset struct (before class definition)

**WAS:**
```swift
import UIKit
import MetalKit
import TVECore

/// Main player view controller with Metal rendering surface and debug log.
```

**BECAME:**
```swift
import UIKit
import MetalKit
import TVECore

// MARK: - Scene Variant Preset (PR-20)

/// A named mapping of blockId -> variantId for scene-level style switching.
struct SceneVariantPreset {
    let id: String
    let title: String
    let mapping: [String: String]  // blockId -> variantId
}

/// Main player view controller with Metal rendering surface and debug log.
```

### 2b. Updated: sceneSelector items

**WAS:**
```swift
    private lazy var sceneSelector: UISegmentedControl = {
        let control = UISegmentedControl(items: ["4 Blocks", "Alpha Matte"])
```

**BECAME:**
```swift
    private lazy var sceneSelector: UISegmentedControl = {
        let control = UISegmentedControl(items: ["4 Blocks", "Alpha Matte", "Variant Demo"])
```

### 2c. Added: Variant switching UI properties (after closeButton, before Properties section)

**WAS:**
```swift
        return btn
    }()

    // MARK: - Properties
```

**BECAME:**
```swift
        return btn
    }()

    // MARK: - Variant Switching UI (PR-20)

    /// Per-block variant picker — visible in Edit mode when a block is selected.
    private lazy var variantPicker: UISegmentedControl = {
        let control = UISegmentedControl()
        control.translatesAutoresizingMaskIntoConstraints = false
        control.addTarget(self, action: #selector(variantPickerChanged), for: .valueChanged)
        control.isHidden = true
        return control
    }()

    /// Label shown above variant picker to indicate which block is selected.
    private lazy var variantLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabel
        label.text = ""
        label.isHidden = true
        return label
    }()

    /// Scene preset picker — always visible when scene is loaded.
    private lazy var presetPicker: UISegmentedControl = {
        let control = UISegmentedControl()
        control.translatesAutoresizingMaskIntoConstraints = false
        control.addTarget(self, action: #selector(presetPickerChanged), for: .valueChanged)
        control.isHidden = true
        return control
    }()

    /// Current presets for the loaded scene. Empty for scenes without variant data.
    private var scenePresets: [SceneVariantPreset] = []

    /// Cached variant IDs for the current picker — avoids reading titles from UIKit (lead fix #2).
    private var lastVariantIds: [String] = []

    // MARK: - Properties
```

### 2d. Updated: setupUI() — subview list + constraint chain

**WAS:**
```swift
    [sceneSelector, loadButton, modeToggle, metalView, overlayView,
     controlsStack, frameLabel, logTextView].forEach { view.addSubview($0) }
```

**BECAME:**
```swift
    [sceneSelector, loadButton, modeToggle, presetPicker, metalView, overlayView,
     variantLabel, variantPicker, controlsStack, frameLabel, logTextView].forEach { view.addSubview($0) }
```

**WAS (metalView top constraint):**
```swift
    // PR-19: metalView top anchors to modeToggle (not loadButton)
    metalViewTopToLoadButtonConstraint = metalView.topAnchor.constraint(
        equalTo: modeToggle.bottomAnchor, constant: 8)
```

**BECAME:**
```swift
    // PR-20: metalView top anchors to presetPicker (which follows modeToggle)
    metalViewTopToLoadButtonConstraint = metalView.topAnchor.constraint(
        equalTo: presetPicker.bottomAnchor, constant: 8)
```

**WAS (constraints array — between modeToggle and metalView):**
```swift
    modeToggle.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
    metalViewTopToLoadButtonConstraint!,
```

**BECAME:**
```swift
    modeToggle.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
    // PR-20: presetPicker between modeToggle and metalView
    presetPicker.topAnchor.constraint(equalTo: modeToggle.bottomAnchor, constant: 6),
    presetPicker.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
    presetPicker.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
    metalViewTopToLoadButtonConstraint!,
```

**WAS (constraints — between overlayView and controlsStack):**
```swift
    overlayView.bottomAnchor.constraint(equalTo: metalView.bottomAnchor),
    controlsStack.topAnchor.constraint(equalTo: metalView.bottomAnchor, constant: 12),
```

**BECAME:**
```swift
    overlayView.bottomAnchor.constraint(equalTo: metalView.bottomAnchor),
    // PR-20: variant picker below metalView (edit mode only)
    variantLabel.topAnchor.constraint(equalTo: metalView.bottomAnchor, constant: 8),
    variantLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
    variantLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
    variantPicker.topAnchor.constraint(equalTo: variantLabel.bottomAnchor, constant: 4),
    variantPicker.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
    variantPicker.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
    controlsStack.topAnchor.constraint(equalTo: variantPicker.bottomAnchor, constant: 8),
```

### 2e. Updated: loadTestPackageTapped() — scene name lookup

**WAS:**
```swift
    let sceneName = sceneSelector.selectedSegmentIndex == 0
        ? "example_4blocks" : "alpha_matte_test"
```

**BECAME:**
```swift
    let sceneNames = ["example_4blocks", "alpha_matte_test", "variant_switch_demo"]
    let idx = sceneSelector.selectedSegmentIndex
    let sceneName = idx < sceneNames.count ? sceneNames[idx] : sceneNames[0]
```

### 2f. Added: Variant switching action handlers (after modeToggleTapped, before toggleFullscreen)

**WAS:**
```swift
    }  // end of modeToggleTapped

    private func toggleFullscreen() {
```

**BECAME:**
```swift
    }  // end of modeToggleTapped

    // MARK: - Variant Switching Actions (PR-20)

    @objc private func variantPickerChanged() {
        let idx = variantPicker.selectedSegmentIndex
        let variants = editorController.selectedBlockVariants()
        guard idx >= 0, idx < variants.count else { return }

        // Policy: stop playback before switching (frame preserved)
        if isPlaying { stopPlayback() }
        editorController.setSelectedVariantForSelectedBlock(variants[idx].id)
        log("[Variant] block=\(editorController.state.selectedBlockId ?? "?") -> \(variants[idx].id)")
    }

    @objc private func presetPickerChanged() {
        let idx = presetPicker.selectedSegmentIndex
        guard idx >= 0, idx < scenePresets.count else { return }

        // Policy: stop playback before switching (frame preserved)
        if isPlaying { stopPlayback() }
        editorController.applyScenePreset(scenePresets[idx].mapping)
        log("[Preset] \(scenePresets[idx].title)")
    }

    private func toggleFullscreen() {
```

### 2g. Updated: toggleFullscreen() — hide new views

**WAS:**
```swift
    sceneSelector.alpha = hidden ? 0 : 1
    loadButton.alpha = hidden ? 0 : 1
    modeToggle.alpha = hidden ? 0 : 1
    controlsStack.alpha = hidden ? 0 : 1
```

**BECAME:**
```swift
    sceneSelector.alpha = hidden ? 0 : 1
    loadButton.alpha = hidden ? 0 : 1
    modeToggle.alpha = hidden ? 0 : 1
    presetPicker.alpha = hidden ? 0 : 1
    variantLabel.alpha = hidden ? 0 : 1
    variantPicker.alpha = hidden ? 0 : 1
    controlsStack.alpha = hidden ? 0 : 1
```

### 2h. Updated: syncUIWithState() — added variant picker update call

**WAS:**
```swift
    overlayView.isHidden = isPreview
}
```

**BECAME:**
```swift
    overlayView.isHidden = isPreview

    // PR-20: variant picker — only in edit mode with a selected block that has 2+ variants
    updateVariantPickerUI(state: state)
}
```

### 2i. Added: updateVariantPickerUI() (after syncUIWithState)

**NEW METHOD (after lead review fixes #1, #2):**
```swift
/// Rebuilds variant picker segments and selection for current state.
private func updateVariantPickerUI(state: TemplateEditorState) {
    let variants = editorController.selectedBlockVariants()
    let showPicker = state.mode == .edit
        && state.selectedBlockId != nil
        && variants.count > 1

    variantLabel.isHidden = !showPicker
    variantPicker.isHidden = !showPicker

    guard showPicker else { return }

    variantLabel.text = "Block: \(state.selectedBlockId ?? "")"

    // Rebuild segments only if variant IDs changed (lead fix #2: compare cached data, not UIKit titles)
    let newIds = variants.map(\.id)
    if lastVariantIds != newIds {
        variantPicker.removeAllSegments()
        for (i, v) in variants.enumerated() {
            variantPicker.insertSegment(withTitle: v.id, at: i, animated: false)
        }
        lastVariantIds = newIds
    }

    // Sync selected segment with active variantId (lead fix #1: reset first to avoid stale selection)
    variantPicker.selectedSegmentIndex = UISegmentedControl.noSegment
    if let activeId = editorController.selectedBlockVariantId(),
       let idx = variants.firstIndex(where: { $0.id == activeId }) {
        variantPicker.selectedSegmentIndex = idx
    }
}
```

### 2j. Updated: compileScene() — added setupScenePresets call

**WAS:**
```swift
    modeToggle.selectedSegmentIndex = 0
    editorController.enterPreview()

    log("Ready for playback!")
```

**BECAME:**
```swift
    modeToggle.selectedSegmentIndex = 0
    editorController.enterPreview()

    // PR-20: Setup scene presets
    setupScenePresets(for: package)

    log("Ready for playback!")
```

### 2k. Added: setupScenePresets() (after compileScene)

**NEW METHOD:**
```swift
// MARK: - Scene Presets (PR-20)

/// Configures scene presets based on loaded scene. Only variant_switch_demo has real presets.
private func setupScenePresets(for package: ScenePackage) {
    if package.scene.sceneId == "scene_variant_switch_demo" {
        scenePresets = [
            SceneVariantPreset(id: "default", title: "Default", mapping: [:]),
            SceneVariantPreset(id: "style_a", title: "Style A",
                               mapping: ["block_01": "v1", "block_02": "v1"]),
            SceneVariantPreset(id: "style_b", title: "Style B",
                               mapping: ["block_01": "v2", "block_02": "v1"])
        ]
    } else {
        scenePresets = [
            SceneVariantPreset(id: "default", title: "Default", mapping: [:])
        ]
    }

    // Rebuild preset picker segments
    presetPicker.removeAllSegments()
    for (i, preset) in scenePresets.enumerated() {
        presetPicker.insertSegment(withTitle: preset.title, at: i, animated: false)
    }
    presetPicker.selectedSegmentIndex = 0
    // Debug-UI optimisation: hide if only "Default" preset — no useful choice to offer (lead fix #3)
    presetPicker.isHidden = scenePresets.count <= 1
}
```

---

## 3. TestAssets/ScenePackages/variant_switch_demo/ (NEW — entire directory)

### 3a. scene.json

2 blocks: `block_01` (2 variants: v1, v2), `block_02` (1 variant: v1).
Canvas 1080x1920, 30fps, 300 frames.

```json
{
  "schemaVersion": "0.1",
  "sceneId": "scene_variant_switch_demo",
  "canvas": { "width": 1080, "height": 1920, "fps": 30, "durationFrames": 300 },
  "mediaBlocks": [
    {
      "blockId": "block_01",
      "zIndex": 0,
      "rect": { "x": 0.0, "y": 0.0, "width": 540.0, "height": 960.0 },
      "variants": [
        { "variantId": "v1", "animRef": "anim-v1.json", ... },
        { "variantId": "v2", "animRef": "anim-v2.json", ... }
      ]
    },
    {
      "blockId": "block_02",
      "zIndex": 1,
      "rect": { "x": 540.0, "y": 0.0, "width": 540.0, "height": 960.0 },
      "variants": [
        { "variantId": "v1", "animRef": "anim-b2.json", ... }
      ]
    }
  ]
}
```

### 3b. anim-v1.json

Minimal Lottie (1080x1920), `nm: "variant_A"`, image asset `img_1.png`, precomp with `nm: "media"` layer.

### 3c. anim-v2.json

Minimal Lottie (1080x1920), `nm: "variant_B"`, image asset `img_2.png`, precomp with `nm: "media"` layer.

### 3d. anim-b2.json

Minimal Lottie (1080x1920), `nm: "block2_anim"`, image asset `img_3.png`, precomp with `nm: "media"` layer.

### 3e. images/

- `img_1.png` — copied from example_4blocks (placeholder for variant A)
- `img_2.png` — copied from example_4blocks (placeholder for variant B)
- `img_3.png` — copied from example_4blocks (placeholder for block_02)

---

## Layout Chain (constraint order top → bottom)

```
sceneSelector
    ↓ 8pt
loadButton
    ↓ 8pt
modeToggle
    ↓ 6pt
presetPicker          ← NEW (hidden if ≤1 preset)
    ↓ 8pt
metalView + overlayView
    ↓ 8pt
variantLabel          ← NEW (hidden unless edit mode + block selected + 2+ variants)
    ↓ 4pt
variantPicker         ← NEW (hidden unless edit mode + block selected + 2+ variants)
    ↓ 8pt
controlsStack
    ↓ 12pt
frameLabel
    ↓ 12pt
logTextView
```

---

## Separation of Concerns

| Responsibility | Owner |
|----------------|-------|
| Stop playback before variant change | VC (`if isPlaying { stopPlayback() }`) |
| Call `player.setSelectedVariant` / `applyVariantSelection` | EditorController proxy |
| Refresh overlay after variant change | EditorController (`refreshOverlayIfNeeded()`) |
| Trigger Metal redraw | EditorController (`requestDisplay()` → `onNeedsDisplay`) |
| Notify VC of state change | EditorController (`onStateChanged?(state)`) |
| Rebuild variant picker segments | VC (`updateVariantPickerUI`) |
| Configure scene presets | VC (`setupScenePresets(for:)`) |

---

## Lead Review Fixes (applied on top of initial implementation)

Only `PlayerViewController.swift` was modified. 3 fixes, +3 net lines.

### Fix #1: noSegment fallback (stale selection edge case)

**WAS:**
```swift
    // Sync selected segment with active variantId
    let activeId = editorController.selectedBlockVariantId()
    if let idx = variants.firstIndex(where: { $0.id == activeId }) {
        variantPicker.selectedSegmentIndex = idx
    }
```

**BECAME:**
```swift
    // Sync selected segment with active variantId (lead fix #1: reset first to avoid stale selection)
    variantPicker.selectedSegmentIndex = UISegmentedControl.noSegment
    if let activeId = editorController.selectedBlockVariantId(),
       let idx = variants.firstIndex(where: { $0.id == activeId }) {
        variantPicker.selectedSegmentIndex = idx
    }
```

**Why:** When switching between blocks or scenes, if `activeId` is nil or not found, the segment stayed on the previous index — showing a stale selection.

### Fix #2: lastVariantIds cache (data-driven comparison)

**WAS:**
```swift
    /// Current presets for the loaded scene.
    private var scenePresets: [SceneVariantPreset] = []

    // MARK: - Properties
```

**BECAME:**
```swift
    /// Current presets for the loaded scene.
    private var scenePresets: [SceneVariantPreset] = []

    /// Cached variant IDs for the current picker — avoids reading titles from UIKit (lead fix #2).
    private var lastVariantIds: [String] = []

    // MARK: - Properties
```

**WAS (in `updateVariantPickerUI`):**
```swift
    // Rebuild segments only if count or IDs changed
    let currentIds = (0..<variantPicker.numberOfSegments).map {
        variantPicker.titleForSegment(at: $0) ?? ""
    }
    let newIds = variants.map(\.id)
    if currentIds != newIds {
        variantPicker.removeAllSegments()
        for (i, v) in variants.enumerated() {
            variantPicker.insertSegment(withTitle: v.id, at: i, animated: false)
        }
    }
```

**BECAME:**
```swift
    // Rebuild segments only if variant IDs changed (lead fix #2: compare cached data, not UIKit titles)
    let newIds = variants.map(\.id)
    if lastVariantIds != newIds {
        variantPicker.removeAllSegments()
        for (i, v) in variants.enumerated() {
            variantPicker.insertSegment(withTitle: v.id, at: i, animated: false)
        }
        lastVariantIds = newIds
    }
```

**Why:** Reading `titleForSegment` works when title == id, but breaks if we later show human-readable titles. Comparing against a cached `[String]` is robust regardless of display format.

### Fix #3: Comment on preset picker hiding

**WAS:**
```swift
    presetPicker.selectedSegmentIndex = 0
    presetPicker.isHidden = scenePresets.count <= 1
```

**BECAME:**
```swift
    presetPicker.selectedSegmentIndex = 0
    // Debug-UI optimisation: hide if only "Default" preset — no useful choice to offer (lead fix #3)
    presetPicker.isHidden = scenePresets.count <= 1
```

**Why:** Spec said "always visible", but hiding when only "Default" is better UX. Comment documents the intentional deviation.
