# PR: Scene Edit Mode (Full-screen) + Removal of Dev Editor + Edit Visibility Safety

**Версия:** 2.9 (PR-A, PR-B, PR-C, PR-D реализованы; PR-E специфицирован)

### Implementation Log:
- **2026-03-04:** PR-A (Model Layer) — COMPLETED. Архив: `PR-A_SceneEditMode_ModelLayer.zip`
- **2026-03-05:** PR-B (TVECore Safety) — COMPLETED. Архив: `PR-B_TVECore_Safety.zip`
- **2026-03-05:** PR-C (UI Layout) — COMPLETED. Архив: `PR-C_UI_Layout.zip`
- **2026-03-09:** PR-D (Wiring + Interaction + Video Persist) — COMPLETED. Архив: `PR-D-v2-review.zip`

### Changelog v2.9 (PR-E полная спецификация):
1. ✅ **ADD:** Детальная спецификация PR-E: Фаза 0 (wiring), удаление dev-UI, замена editorController
2. ✅ **ADD:** Полный grep-чеклист для верификации удаления
3. ✅ **ADD:** MediaBlockActionBar callbacks с blockId параметром
4. ✅ **ADD:** Список замен editorController → store/mapper в production path
5. ✅ **CLARIFY:** ScrubDiagnostics.swift — оставляем (используется в requestMetalRender)
6. ✅ **CLARIFY:** gestureRecognizerShouldBegin — замена на EditorStore condition

### Changelog v2.4 (финальный после полного аудита):
1. ✅ **CLARIFY:** BlockVisibilityPolicy vs TemplateMode — разделение ответственности (см. 6.1, 6.4)
2. ✅ **CLARIFY:** TimelinePlaybackCoordinator flow — coordinator "подхватывает" сцену автоматически (см. 8.3)
3. ✅ **CLARIFY:** Video scope — video persist входит строго в PR-D (см. 7.4.3)
4. ✅ **CONFIRM:** setBlockMedia расширение — устранение рассинхрона, НЕ breaking change
5. ✅ **CLARIFY:** Undo/Redo race protection — per-block generation pattern, БЕЗ global counter (см. 8.4)
6. ✅ **ADD:** Раздел 8.3 — детальный flow enterSceneEdit → coordinator
7. ✅ **ADD:** Раздел 8.4 — token-check guards в UserMediaService для PR-D

### Changelog v2.3:
1. ✅ **FIX:** `MediaBlock.mediaInput` → `MediaBlock.input` (соответствует реальному коду TVECore)
2. ✅ **CLARIFY:** Video persist flow — каноничный порядок операций без промежуточного temp
3. ✅ **CONFIRM:** `clearAll()` существует в UserMediaService, стратегия undo/redo корректна
4. ✅ **CONFIRM:** `wireEditorController()` удаляется в PR-E (часть dev-UI)
5. ✅ **CONFIRM:** TimelinePlaybackCoordinator остаётся в Scene Edit (единый render pipeline)

### Changelog v2.2:
1. ✅ `UserTransformsAllowed.translate/scale` → `pan/zoom` (соответствует MediaInput.swift)
2. ✅ `setBlockMedia` — явно помечено как PR-A изменение reducer'а
3. ✅ `saveUserVideo` — помечено как NEW API (PR-D)
4. ✅ `onStateRestoredFromUndoRedo` — помечено как NEW callback (PR-A)
5. ✅ Добавлены: `TransformType` enum + test helpers (`makeStateWithScenes`, `makeStateInSceneEdit`)

---

## 0) Контекст и цель

**Проблема:** в текущем релизном режиме `.editor(templateId:)` пользователь не может редактировать mediaBlocks (фото/видео/анимации/выкл ассеты) — редактирование "жило" в dev-UI, который скрывается в `.editor`.

**Цель:** добавить **production-Scene Edit**:

* пользователь выбирает сцену на таймлайне → снизу `ContextBar` показывает `Duplicate / Delete / Edit`;
* `Edit` включает **Scene Edit внутри того же UI**: таймлайн прячется, превью растягивается на весь экран, плейбек заморожен;
* в Scene Edit пользователь выбирает mediaInput тапом на сцене и выполняет операции: **Add Photo / Add Video / Change Animation / Disable(Enable) asset** (+ трансформы, если разрешены слотом);
* всё сохраняется в проект (per-sceneInstance), выход по **Done** возвращает к прежнему состоянию редактора;
* параллельно: **полностью удалить dev-редактор**, чтобы остался один канонический путь.

---

## 1) Текущее состояние кода (якоря)

### 1.1 Релизный layout редактора

`AnimiApp/Sources/Editor/EditorLayoutContainerView.swift`

* структура: navBar → previewContainer → timelineContainer → bottomBarContainer (стр. 9–17, 141–201)
* bottomBar переключается между `GlobalActionBar` и `ContextBar` по `TimelineSelection` (стр. 385–395)

### 1.2 Контекстное меню для сцены/аудио

`AnimiApp/Sources/Editor/ContextBar.swift`

* сейчас только `Duplicate` и `Delete` для `.scene(id:)` (кнопки на стр. 37–63, configure на стр. 119–143)

### 1.3 В `.editor` рендер идёт через coordinator в `.edit`

`AnimiApp/Sources/Player/PlayerViewController.swift`

* draw: в `.editor` берём `playbackCoordinator.currentRenderCommands(mode: .edit)` (стр. 3749–3755)

### 1.4 Edit mode = no-anim и frame 0 (подтверждено кодом)

`TVECore/Sources/TVECore/ScenePlayer/ScenePlayer.swift`

* `.edit`: `frameIndex = editFrameIndex`, overrides = `blockId → editVariantId` (стр. 650–675)

`TVECore/Sources/TVECore/ScenePlayer/ScenePlayerTypes.swift`

* `editVariantId` "always no-anim" (стр. 102–104)

`TVECore/Sources/TVECompilerCore/SceneCompiler.swift`

* `editVariant` обязателен и должен быть `"no-anim"` (стр. 161–164)
* проверка binding layer visible/rendered на `editFrameIndex = 0` (стр. 186–219)

### 1.5 Риск: сейчас timing режет edit (важно)

`TVECore/Sources/TVECore/ScenePlayer/SceneRenderPlan.swift`

* `guard block.timing.isVisible(at: sceneFrameIndex)` (стр. 49–54)
* комментарий прямо фиксирует: "в edit frame 0 → блоки, стартующие позже, НЕ редактируемы" (стр. 49–53)

И то же самое в hit-test/overlay:
`TVECore/Sources/TVECore/ScenePlayer/ScenePlayer.swift`

* `hitTest` фильтрует `block.timing.isVisible(at: frame)` (стр. 519–521)
* `overlays` фильтрует `block.timing.isVisible(at: frame)` (стр. 563–564)

---

## 2) UX-требования (канонически)

### 2.1 Добавить кнопку Edit для сцены

* Тап по сцене в таймлайне → `ContextBar` показывает `Duplicate / Delete / Edit`.
* `Edit` активна только для `TimelineSelection.scene(id:)`.
* Для `.audio` — без изменений (пока placeholder).

### 2.2 Scene Edit mode без перехода на новый экран

* Никакого push/present нового VC как "экран редактора сцены".
* Реализуем как **режим внутри `EditorLayoutContainerView`**:

  * таймлайн скрыт (коллапс),
  * превью занимает освободившееся место (до bottom bar),
  * плейбек заморожен,
  * вверху появляется **Done** (возврат из Scene Edit).

### 2.3 Выбор mediaInput и действия

В Scene Edit:

* пользователь тапает по mediaInput (по факту — по mediaBlock hit path) → выделение (overlay) + появление контекстных действий для блока:

  * Add Photo (если `allowedMedia` содержит `"photo"`)
  * Add Video (если `allowedMedia` содержит `"video"`)
  * Change Animation (variants)
  * Disable/Enable asset (без удаления медиа)
  * Remove media (отдельно от disable: удаляет assignment)
* Все действия выполняются **без перехода в другие режимы** (модальные системные пикеры допустимы: PHPicker).

### 2.4 Выход из Scene Edit (Done)

* `Done` возвращает в обычный редактор:

  * таймлайн снова виден,
  * состояние проекта и сцены сохранено,
  * редактор возвращается к **предыдущему playheadTimeUs** (до входа в Scene Edit) и продолжает показывать то же, что пользователь видел.

---

## 3) Модель состояния (EditorStore)

### 3.1 Новый UI-режим в EditorState

Файл: `AnimiApp/Sources/Editor/Store/EditorState.swift`

Добавить:

* `public var uiMode: EditorUIMode = .timeline`
* `public var selectedBlockId: String?` (актуально в `uiMode == .sceneEdit`)
* `public var sceneEditReturnPlayheadUs: TimeUs?` (внутренний "return slot")

`EditorUIMode` (добавить в тот же файл или `EditorUIMode.swift`):

```swift
public enum EditorUIMode: Equatable, Sendable {
    case timeline          // обычный режим
    case sceneEdit(sceneInstanceId: UUID)
}
```

**ВАЖНО: `uiMode`, `selectedBlockId`, `sceneEditReturnPlayheadUs` НЕ ВХОДЯТ в `EditorSnapshot`.**

Причина: Undo/redo должен откатывать **контент** (timeline + sceneInstanceStates), но не "телепортировать" пользователя между режимами UI. В Scene Edit undo работает: откатывает медиа/варианты/тогглы/трансформы, но режим не меняется.

Дополнительное правило: если после undo выбранный `selectedBlockId` стал невалиден — UI очищает selection блока.

### 3.2 Новые actions

Файл: `AnimiApp/Sources/Editor/Store/EditorAction.swift`

Добавить:

```swift
/// Входит в режим редактирования сцены.
/// НЕ пушит undo snapshot (UI-переход).
case enterSceneEdit(sceneId: UUID)

/// Выходит из режима редактирования сцены.
/// НЕ пушит undo snapshot (UI-переход).
case exitSceneEdit

/// Выбирает блок в Scene Edit.
/// НЕ пушит undo snapshot (UI-операция).
case selectBlock(blockId: String?)

/// Сбрасывает SceneState для инстанса к .empty.
/// ПУШИТ undo snapshot (model change).
case resetSceneState(sceneInstanceId: UUID)

/// Устанавливает userMediaPresent для блока (disable/enable asset).
/// ПУШИТ undo snapshot (model change).
case setBlockMediaPresent(sceneInstanceId: UUID, blockId: String, present: Bool)
```

### 3.3 Редьюсер

Файл: `AnimiApp/Sources/Editor/Store/EditorReducer.swift`

Реализовать обработку новых actions:

**`enterSceneEdit(sceneId:)`:**
```swift
// 1. Сохранить текущий playhead для возврата
newState.sceneEditReturnPlayheadUs = state.playheadTimeUs

// 2. Найти индекс сцены и вычислить её startUs
guard let index = state.canonicalTimeline.sceneItems.firstIndex(where: { $0.id == sceneId }) else {
    return ReducerResult(state: state, shouldPushSnapshot: false)
}
let startUs = state.canonicalTimeline.computedStartUs(forSceneAt: index)

// 3. Переместить playhead на начало сцены
newState.playheadTimeUs = startUs

// 4. Установить UI mode
newState.uiMode = .sceneEdit(sceneInstanceId: sceneId)
newState.selectedBlockId = nil

// 5. НЕ пушить snapshot (UI-переход)
return ReducerResult(state: newState, shouldPushSnapshot: false)
```

**`exitSceneEdit`:**
```swift
// 1. Восстановить playhead
if let returnPlayhead = state.sceneEditReturnPlayheadUs {
    newState.playheadTimeUs = returnPlayhead
}

// 2. Очистить Scene Edit state
newState.sceneEditReturnPlayheadUs = nil
newState.uiMode = .timeline
newState.selectedBlockId = nil

// 3. НЕ пушить snapshot (UI-переход)
return ReducerResult(state: newState, shouldPushSnapshot: false)
```

**`selectBlock(blockId:)`:**
```swift
newState.selectedBlockId = blockId
return ReducerResult(state: newState, shouldPushSnapshot: false)
```

**`resetSceneState(sceneInstanceId:)`:**
```swift
newState.draft.sceneInstanceStates[sceneInstanceId] = .empty
return ReducerResult(state: newState, shouldPushSnapshot: true)
```

**`setBlockMediaPresent(sceneInstanceId:, blockId:, present:)`:**
```swift
var sceneState = newState.draft.sceneInstanceStates[sceneInstanceId] ?? .empty
if sceneState.userMediaPresent == nil {
    sceneState.userMediaPresent = [:]
}
sceneState.userMediaPresent?[blockId] = present
newState.draft.sceneInstanceStates[sceneInstanceId] = sceneState
return ReducerResult(state: newState, shouldPushSnapshot: true)
```

### 3.4 Store callbacks

Файл: `AnimiApp/Sources/Editor/Store/EditorStore.swift`

Добавить split-callback'и:

```swift
/// Called when UI mode changes (timeline ↔ sceneEdit).
public var onUIModeChanged: ((EditorUIMode) -> Void)?

/// Called when selected block changes in Scene Edit.
public var onSelectedBlockChanged: ((String?) -> Void)?

/// Called after undo/redo restores snapshot.
/// Needed because runtime (ScenePlayer/UserMediaService) uses write-through
/// and must be explicitly re-applied for the active scene instance.
///
/// **NEW CALLBACK (PR-A):** Этот callback не существует в текущем коде.
/// Добавляется в EditorStore и вызывается из performUndo/performRedo после state.restore(from:).
public var onStateRestoredFromUndoRedo: (() -> Void)?
```

В методе `dispatch()` после обновления state добавить change detection:

```swift
// Detect UI mode change
if state.uiMode != oldState.uiMode {
    onUIModeChanged?(state.uiMode)
}

// Detect selected block change
if state.selectedBlockId != oldState.selectedBlockId {
    onSelectedBlockChanged?(state.selectedBlockId)
}
```

> `onStateRestoredFromUndoRedo` вызывается только из `performUndo/performRedo` после `state.restore(from:)`.

### 3.4.1 Undo/Redo: обязательный сигнал "snapshot restored" (NEW — PR-A)

> **NEW CALLBACK:** В текущем коде `performUndo()/performRedo()` уже вызывают
> `notifyTimelineChanged()`, `notifySelectionChanged()`, `onPlayheadChanged()`, `notifyUndoRedoChanged()`.
> Но **нет** отдельного callback `onStateRestoredFromUndoRedo` для re-apply runtime.
> Добавляем его в PR-A.

В `EditorStore.performUndo()` (после строки 212) и `performRedo()` (после строки 236)
после `state.restore(from:)` и notify-callbacks добавить:

```swift
onStateRestoredFromUndoRedo?()
```

> **Важно (из review.md):** Вызывается именно из `performUndo/performRedo` после `state.restore(from:)`,
> а НЕ из `dispatch()`, иначе будет лишняя нагрузка на каждый action.

---

## 4) UI/Layout изменения

### 4.1 ContextBar: добавить Edit

Файл: `AnimiApp/Sources/Editor/ContextBar.swift`

* добавить callback: `var onEditScene: ((UUID) -> Void)?`
* добавить кнопку `Edit` (иконка `"pencil"` или `"slider.horizontal.3"`), рядом с Duplicate/Delete
* `configure(for:)`: в `.scene(let sceneId)` — показывать кнопку Edit
* `@objc editTapped()` → `onEditScene?(sceneId)`

### 4.2 EditorLayoutContainerView: Scene Edit через constraint-группы (без конфликтов)

Файл: `AnimiApp/Sources/Editor/EditorLayoutContainerView.swift`

**Проблема текущих constraints:** внутри `timelineContainer` стоят required constraints (`rulerView.height = EditorConfig.rulerHeight`, `timelineContainer.height = rulerHeight + timelineHeight`). Если просто сделать `timelineContainer.height = 0`, будут AutoLayout конфликты.

**Релизное решение:** хранить **две группы constraint-ов** и переключать их через `activate/deactivate`.

> **Примечание (из review.md):** Сейчас constraints активируются одним `NSLayoutConstraint.activate([...])`,
> значит для групп нужно хранить ссылки на каждый constraint и раскладывать по массивам.
> Реализация будет чуть объёмнее чем описано здесь, но это не ошибка ТЗ.

Добавить stored properties:

```swift
private var timelineVisibleConstraints: [NSLayoutConstraint] = []
private var sceneEditConstraints: [NSLayoutConstraint] = []

private var previewBottomToTimeline: NSLayoutConstraint!
private var previewBottomToBottomBar: NSLayoutConstraint!
```

В `setupConstraints()`:

1. Создать оба варианта привязки preview:

```swift
previewBottomToTimeline = previewContainer.bottomAnchor.constraint(equalTo: timelineContainer.topAnchor)
previewBottomToBottomBar = previewContainer.bottomAnchor.constraint(equalTo: bottomBarContainer.topAnchor)
```

2. В `timelineVisibleConstraints` положить ВСЕ constraints таймлайна (контейнер + ruler + timelineView + playhead):

* `timelineContainer.leading/trailing/bottom/height`
* `rulerView.top/leading/trailing/height`
* `timelineView.top/leading/trailing/bottom`
* `playheadView.top/bottom/centerX/width`
* `previewBottomToTimeline`

3. В `sceneEditConstraints` положить:

* `previewBottomToBottomBar`

4. По умолчанию активировать `timelineVisibleConstraints`.

Публичный API:

```swift
func setSceneEditMode(_ enabled: Bool, animated: Bool) {
    if enabled {
        NSLayoutConstraint.deactivate(timelineVisibleConstraints)
        NSLayoutConstraint.activate(sceneEditConstraints)
        timelineContainer.isHidden = true
        menuStrip.isHidden = true  // скрываем (не disable) — UI чище
    } else {
        NSLayoutConstraint.deactivate(sceneEditConstraints)
        NSLayoutConstraint.activate(timelineVisibleConstraints)
        timelineContainer.isHidden = false
        menuStrip.isHidden = false
    }

    if animated {
        UIView.animate(withDuration: 0.25) { self.layoutIfNeeded() }
    } else {
        layoutIfNeeded()
    }
}
```

> **Из review.md:** menuStrip **скрывать**, не disable. UI чище, нет "плей" в замороженном режиме.
> Это не влияет на архитектуру.

### 4.3 EditorNavBar: режимы Timeline и SceneEdit

Файл: `AnimiApp/Sources/Editor/EditorNavBar.swift`

Добавить enum и API:

```swift
enum EditorNavBarMode {
    case timeline   // Close, Undo, Redo, Export
    case sceneEdit  // Done, Undo, Redo (без Close и Export)
}
```

Добавить:

* callback: `var onDone: (() -> Void)?`
* кнопка `doneButton` (title "Done", стиль как Export)
* метод `func setMode(_ mode: EditorNavBarMode)`

**Поведение режимов:**

| Элемент | `.timeline` | `.sceneEdit` |
|---------|-------------|--------------|
| Close   | ✅ показан   | ❌ скрыт     |
| Undo    | ✅ показан   | ✅ показан   |
| Redo    | ✅ показан   | ✅ показан   |
| Export  | ✅ показан   | ❌ скрыт     |
| Done    | ❌ скрыт     | ✅ показан   |

**Важно:** Undo/Redo **работают** в обоих режимах. Wiring через `store.onUndoRedoChanged` → `navBar.setUndoEnabled()` / `setRedoEnabled()` обязателен.

### 4.4 Встраивание overlay поверх Metal

`EditorOverlayView` уже существует (`AnimiApp/Sources/Editor/EditorOverlayView.swift`).

В `EditorLayoutContainerView` добавить:

```swift
func embedOverlayView(_ overlay: UIView) {
    overlay.translatesAutoresizingMaskIntoConstraints = false
    // Вставить между metalView и menuStrip
    previewContainer.insertSubview(overlay, belowSubview: menuStrip)
    NSLayoutConstraint.activate([
        overlay.topAnchor.constraint(equalTo: previewContainer.topAnchor),
        overlay.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
        overlay.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
        overlay.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
    ])
}
```

В `PlayerViewController.setupEditorLayout()`:

```swift
editorLayoutContainer.embedMetalView(metalView)
editorLayoutContainer.embedOverlayView(overlayView)  // добавить
```

### 4.5 Обновление overlay.canvasToView на layout changes (обязательно)

`EditorOverlayView` принимает преобразование через property `canvasToView`, а не через параметр `update(...)`.

Поэтому в `PlayerViewController.viewDidLayoutSubviews()` (или эквивалентном месте после смены режима layout) обязательно:

1. обновлять `sceneEditController.mapper.viewSize = metalView.bounds.size` (или previewContainer bounds),
2. выставлять `overlayView.canvasToView = sceneEditController.mapper.canvasToViewTransform()`,
3. вызывать `sceneEditController.updateOverlay()`.

---

## 5) Взаимодействие в Scene Edit: selection, overlay, gestures

### 5.1 Архитектура: EditorCanvasMapper + SceneEditInteractionController

Вместо `TemplateEditorController` создаём две чистые сущности:

**`AnimiApp/Sources/Editor/SceneEdit/EditorCanvasMapper.swift`** (pure math, `internal`):

> **Из review.md:** `SizeD` для canvasSize и `CGSize` для viewSize — это intentional.
> Canvas в движке использует double (`SizeD`), view — `CGSize`. Прецизионно это даже лучше
> (double внутри математики).

```swift
/// Pure math for canvas ↔ view coordinate transforms.
/// Uses aspect-fit (contain) mapping matching Metal renderer.
struct EditorCanvasMapper {
    var canvasSize: SizeD = .zero   // Double precision for canvas math
    var viewSize: CGSize = .zero    // CGFloat for UIKit coordinates

    /// Returns canvas-to-view affine transform (aspect-fit).
    func canvasToViewTransform() -> CGAffineTransform {
        guard canvasSize.width > 0, canvasSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return .identity }
        let targetRect = RectD(x: 0, y: 0,
                               width: Double(viewSize.width),
                               height: Double(viewSize.height))
        let m = GeometryMapping.animToInputContain(animSize: canvasSize, inputRect: targetRect)
        return CGAffineTransform(a: m.a, b: m.b, c: m.c, d: m.d, tx: m.tx, ty: m.ty)
    }

    /// Converts view point to canvas point.
    func viewToCanvas(_ viewPoint: CGPoint) -> CGPoint {
        viewPoint.applying(canvasToViewTransform().inverted())
    }

    /// Converts view delta to canvas delta (scale only, no offset).
    func viewDeltaToCanvas(_ delta: CGPoint) -> CGPoint {
        guard canvasSize.width > 0, canvasSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return delta }
        let containScale = min(
            Double(viewSize.width) / canvasSize.width,
            Double(viewSize.height) / canvasSize.height
        )
        guard containScale > 0 else { return delta }
        return CGPoint(x: Double(delta.x) / containScale,
                       y: Double(delta.y) / containScale)
    }
}
```

**`AnimiApp/Sources/Editor/SceneEdit/SceneEditInteractionController.swift`** (@MainActor):

```swift
@MainActor
final class SceneEditInteractionController {

    // MARK: - Dependencies (injected)

    var mapper: EditorCanvasMapper = EditorCanvasMapper()
    weak var overlayView: EditorOverlayView?
    var getScenePlayer: (() -> ScenePlayer?)?
    var getUIMode: (() -> EditorUIMode)?
    var getSelectedBlockId: (() -> String?)?

    // MARK: - Callbacks

    var onSelectBlock: ((String?) -> Void)?
    var onTransformChanged: ((String, Matrix2D, InteractionPhase) -> Void)?

    // MARK: - Gesture State

    private var gestureBaseTransform: Matrix2D = .identity
    private var lastAppliedTransform: Matrix2D = .identity

    // MARK: - Hit Test & Selection

    func handleTap(viewPoint: CGPoint) {
        guard case .sceneEdit = getUIMode?() else { return }
        guard let player = getScenePlayer?() else { return }

        let canvasPoint = mapper.viewToCanvas(viewPoint)
        let hit = player.hitTest(
            point: Vec2D(x: Double(canvasPoint.x), y: Double(canvasPoint.y)),
            frame: ScenePlayer.editFrameIndex,
            mode: .edit
        )
        onSelectBlock?(hit)
    }

    // MARK: - Overlay Update

    func updateOverlay() {
        guard case .sceneEdit = getUIMode?() else {
            overlayView?.update(overlays: [], selectedBlockId: nil)
            return
        }
        guard let player = getScenePlayer?() else {
            overlayView?.update(overlays: [], selectedBlockId: nil)
            return
        }

        let overlays = player.overlays(frame: ScenePlayer.editFrameIndex, mode: .edit)
        let canvasToView = mapper.canvasToViewTransform()
        overlayView?.canvasToView = canvasToView
        overlayView?.update(overlays: overlays, selectedBlockId: getSelectedBlockId?())
    }

    // MARK: - Gestures (pan/pinch/rotate)

    func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard case .sceneEdit = getUIMode?(),
              let blockId = getSelectedBlockId?(),
              let player = getScenePlayer?() else { return }

        // Check if transforms allowed for this block
        guard isTransformAllowed(blockId: blockId, type: .pan) else { return }

        let translation = recognizer.translation(in: recognizer.view)

        switch recognizer.state {
        case .began:
            gestureBaseTransform = player.userTransform(blockId: blockId)
            lastAppliedTransform = gestureBaseTransform
        case .changed:
            let canvasDelta = mapper.viewDeltaToCanvas(translation)
            let delta = Matrix2D.translation(x: canvasDelta.x, y: canvasDelta.y)
            let combined = gestureBaseTransform.concatenating(delta)
            lastAppliedTransform = combined
            onTransformChanged?(blockId, combined, .changed)
        case .ended:
            onTransformChanged?(blockId, lastAppliedTransform, .ended)
        case .cancelled:
            onTransformChanged?(blockId, gestureBaseTransform, .cancelled)
        default: break
        }
    }

    // Similar for handlePinch, handleRotation...

    private func isTransformAllowed(blockId: String, type: TransformType) -> Bool {
        // Use ScenePlayer.userTransformsAllowed(blockId:) - see 5.3.1
        // nil = all allowed (backward compatible)
        guard let player = getScenePlayer?(),
              let allowed = player.userTransformsAllowed(blockId: blockId) else {
            return true // nil = all allowed
        }
        switch type {
        case .pan: return allowed.pan != false
        case .pinch: return allowed.zoom != false
        case .rotate: return allowed.rotate != false
        }
    }
}

/// Transform gesture type for permission checking.
/// Defined in AnimiApp near SceneEditInteractionController.
enum TransformType {
    case pan
    case pinch
    case rotate
}
```

### 5.2 Что переносим из TemplateEditorController

**Переносим 1:1 (проверенная математика):**
* Gesture handling: pan/pinch/rotate с pivot-логикой
* Coordinate transforms (теперь в `EditorCanvasMapper`)

**НЕ переносим (удаляем вместе со старым редактором):**
* preview mode, displayLink, `currentPreviewTimeUs`, `currentPreviewFrame`
* autoplay, scrub logic
* timeline selection внутри контроллера
* любые `print()` и debug-поведение

### 5.3 Разрешения на трансформы из MediaInput

Источник правды: `TVECore/Sources/TVECore/Models/MediaInput.swift:26–28` (`userTransformsAllowed`)

Правило: `nil` = разрешены все трансформы (backward compatible с существующими шаблонами).

### 5.3.1 ScenePlayer convenience API для MediaInput (обязательно)

В TVECore (`ScenePlayer.swift`) добавить методы:

```swift
/// Returns MediaInput for the given block.
/// Note: MediaBlock.input (not .mediaInput) - verified against actual code.
public func mediaInput(blockId: String) -> MediaInput? {
    compiledScene?.runtime.scene.mediaBlocks.first { $0.id == blockId }?.input
}

public func allowedMedia(blockId: String) -> [String]? {
    mediaInput(blockId: blockId)?.allowedMedia
}

public func userTransformsAllowed(blockId: String) -> UserTransformsAllowed? {
    mediaInput(blockId: blockId)?.userTransformsAllowed
}
```

Использование:

* `MediaBlockActionBar` включает/выключает кнопки Add Photo/Video по `allowedMedia`.
* `SceneEditInteractionController` проверяет `userTransformsAllowed` для жестов.
* `nil` трактуется как "разрешено всё" (backward compatible).

### 5.4 Write-through (обязательно, строго по текущей архитектуре)

Текущая архитектура редактора write-through: UI-действия **сначала применяют runtime** (`ScenePlayer`/`UserMediaService`) и **после этого** диспатчат `EditorStore` для persistence/undo.

Store не является реактивным apply-слоем для runtime.

---

## 6) TVECore: safety-политика "в edit игнорируем timing"

### 6.1 BlockVisibilityPolicy (ТОЛЬКО для SceneRenderPlan)

Файл: `TVECore/Sources/TVECore/ScenePlayer/ScenePlayerTypes.swift`

> **ВАЖНО (из review.md):** `BlockVisibilityPolicy` нужен **только** для `SceneRenderPlan.renderCommands()`,
> потому что сейчас там нет параметра `mode`, а timing-фильтр сидит внутри плана.
>
> В `hitTest` и `overlays` **уже есть** параметр `mode: TemplateMode`, поэтому bypass
> делается **через него** (см. 6.4). Это минимально меняет API и не вводит "двух параллельных режимов".

Добавить enum (рядом с `BlockTiming`):

```swift
/// Policy for block visibility filtering in SceneRenderPlan.
/// - `timeline`: Filter by block.timing.isVisible(at: frame) - normal playback
/// - `all`: Show all blocks regardless of timing - edit mode
///
/// Note: hitTest/overlays use existing TemplateMode parameter instead (see 6.4).
public enum BlockVisibilityPolicy: Sendable {
    case timeline
    case all
}
```

### 6.2 SceneRenderPlan

Файл: `TVECore/Sources/TVECore/ScenePlayer/SceneRenderPlan.swift`

Изменить сигнатуру `renderCommands`:

```swift
public static func renderCommands(
    for runtime: SceneRuntime,
    sceneFrameIndex: Int,
    userTransforms: [String: Matrix2D] = [:],
    variantOverrides: [String: String] = [:],
    userMediaPresent: [String: Bool] = [:],
    layerToggleState: [String: [String: Bool]] = [:],
    visibility: BlockVisibilityPolicy = .timeline  // NEW
) -> [RenderCommand]
```

Заменить фильтр (строка 52):

```swift
// Было:
guard block.timing.isVisible(at: sceneFrameIndex) else { continue }

// Стало:
if visibility == .timeline {
    guard block.timing.isVisible(at: sceneFrameIndex) else { continue }
}
// При .all — не фильтруем, показываем все блоки
```

### 6.3 ScenePlayer.renderCommands(mode:)

Файл: `TVECore/Sources/TVECore/ScenePlayer/ScenePlayer.swift`

В методе `renderCommands(mode:sceneFrameIndex:)`:

```swift
case .preview:
    return SceneRenderPlan.renderCommands(
        for: compiledScene.runtime,
        sceneFrameIndex: frameIndex,
        // ... other params ...
        visibility: .timeline  // explicit
    )

case .edit:
    return SceneRenderPlan.renderCommands(
        for: compiledScene.runtime,
        sceneFrameIndex: Self.editFrameIndex,
        // ... other params ...
        visibility: .all  // показываем все блоки
    )
```

### 6.4 HitTest и Overlays

Файл: `TVECore/Sources/TVECore/ScenePlayer/ScenePlayer.swift`

> **Подтверждено в review.md:** hitTest и overlays уже принимают `mode: TemplateMode` параметр,
> поэтому достаточно добавить `if mode == .preview { guard timing... }` bypass.
> Не нужен новый enum — используем существующий `TemplateMode`.

**hitTest (строка ~519):**

```swift
public func hitTest(point: Vec2D, frame: Int, mode: TemplateMode = .preview) -> String? {
    // ...
    for block in runtime.blocks.reversed() {
        // В edit mode НЕ фильтруем по timing
        if mode == .preview {
            guard block.timing.isVisible(at: frame) else { continue }
        }
        // ... rest of hit test logic
    }
}
```

**overlays (строка ~555):**

```swift
public func overlays(frame: Int, mode: TemplateMode = .preview) -> [MediaInputOverlay] {
    // ...
    for block in runtime.blocks.reversed() {
        // В edit mode НЕ фильтруем по timing
        if mode == .preview {
            guard block.timing.isVisible(at: frame) else { continue }
        }
        // ... rest of overlay logic
    }
}
```

**Критично:** render, hitTest, overlays должны быть согласованы — все показывают все блоки в edit mode.

---

## 7) Персист и операции редактирования (per-sceneInstance)

### 7.1 SceneState: добавить userMediaPresent

Файл: `AnimiApp/Sources/Project/SceneState.swift`

Добавить поле:

```swift
/// Per-block visibility flag for binding layer.
/// Key: blockId, Value: whether to render the binding layer.
/// nil treated as [:] (empty dictionary).
///
/// Semantics:
/// - `userMediaPresent[blockId] = true` → render binding layer
/// - `userMediaPresent[blockId] = false` → hide binding layer (media still assigned)
/// - key absent → follows automatic logic from UserMediaService
///
/// Default in SceneRenderPlan: `userMediaPresent[blockId] ?? false`
/// This is correct because UserMediaService.setPhoto/setVideo automatically
/// sets `present = true` when media is added.
public var userMediaPresent: [String: Bool]?
```

**Семантика (ВАЖНО):**

| `mediaAssignments[blockId]` | `userMediaPresent[blockId]` | Результат |
|----------------------------|-----------------------------|----|
| есть медиа | `true` или отсутствует | ✅ Медиа видно |
| есть медиа | `false` | ❌ Медиа скрыто (Disable asset) |
| `nil` | любое | ❌ Нет медиа, слот пустой |

**Это два независимых флага:**
* `mediaAssignments[blockId]` — *что назначено* (фото/видео/ref)
* `userMediaPresent[blockId]` — *показывать ли binding layer*

**Порядок применения при загрузке сцены:**
1. Применить `mediaAssignments` через `userMediaService.setPhoto/setVideo` (это автоматически ставит `present=true`)
2. Затем применить persisted `userMediaPresent` (чтобы disable мог "перебить" наличие медиа)

### 7.2 Автоматическое setBlockMedia → userMediaPresent=true

> **PR-A ИЗМЕНЕНИЕ:** Текущий reducer `setBlockMedia` меняет только `mediaAssignments`.
> В рамках PR-A расширяем поведение: `setBlockMedia` теперь также управляет `userMediaPresent`.
>
> **Подтверждено в review.md:** Это **НЕ breaking change**, а устранение рассинхрона.
>
> Факты по коду:
> - `ScenePlayer.userMediaPresent` default false в render plan
> - `UserMediaService.setPhoto` и `clear(blockId:)` уже ставят `present=true/false` в runtime
> - `EditorAction.setBlockMedia` используется для persistence/undo, не как "silent assignment"
>
> Если reducer начнёт ставить `userMediaPresent=true` при добавлении медиа — это **синхронизирует
> persisted state с runtime** и предотвращает кейс "медиа добавлено, но при restore present=false
> по умолчанию и слот остаётся скрытым".

В reducer `setBlockMedia`:

```swift
case .setBlockMedia(let sceneInstanceId, let blockId, let media):
    var sceneState = newState.draft.sceneInstanceStates[sceneInstanceId] ?? .empty

    if sceneState.mediaAssignments == nil {
        sceneState.mediaAssignments = [:]
    }

    if let mediaRef = media {
        // Добавляем медиа
        sceneState.mediaAssignments?[blockId] = mediaRef

        // АВТОМАТИЧЕСКИ делаем видимым
        if sceneState.userMediaPresent == nil {
            sceneState.userMediaPresent = [:]
        }
        sceneState.userMediaPresent?[blockId] = true
    } else {
        // Удаляем медиа
        sceneState.mediaAssignments?.removeValue(forKey: blockId)

        // Скрываем слот
        if sceneState.userMediaPresent == nil {
            sceneState.userMediaPresent = [:]
        }
        sceneState.userMediaPresent?[blockId] = false
    }

    newState.draft.sceneInstanceStates[sceneInstanceId] = sceneState
    return ReducerResult(state: newState, shouldPushSnapshot: true)
```

### 7.3 Bottom bars в Scene Edit

В `EditorLayoutContainerView` добавить два новых bar'а:

**`SceneEditBar`** — показывается когда `uiMode == .sceneEdit` и `selectedBlockId == nil`:

| Элемент | Действие |
|---------|----------|
| Background | Открывает `BackgroundEditorViewController` |
| Reset Scene | Сбрасывает `SceneState` к `.empty` (с confirmation если сцена "грязная") |
| Подсказка | "Tap a media slot to edit" (label) |

**`MediaBlockActionBar`** — показывается когда `uiMode == .sceneEdit` и `selectedBlockId != nil`:

| Элемент | Условие | Действие |
|---------|---------|----------|
| Add Photo | `allowedMedia` содержит `"photo"` | PHPicker → setBlockMedia |
| Add Video | `allowedMedia` содержит `"video"` | PHPicker → setBlockMedia |
| Animation | есть варианты | Показать picker вариантов |
| Disable/Enable | всегда | Переключает `userMediaPresent[blockId]` |
| Remove | есть медиа | Очищает `mediaAssignments[blockId]` + `userMediaPresent=false` |

**Reset Scene confirmation:**
* Показывать только если `SceneState != .empty`
* После reset — действие undoable (Undo вернёт всё назад)

### 7.4 Media assignments: фото + видео (строго по текущему MediaRef + безопасный video ownership)

#### 7.4.1 Текущий формат `MediaRef` (важно)

`MediaRef` не содержит `type`. В проекте:

* `MediaRef.kind` — только `.file`
* `MediaRef.id` — relative path (в `ProjectStore`)

Тип медиа определяется **по расширению файла** (как уже сделано в `PlayerViewController.applyMediaAssignments` для фото).

#### 7.4.2 Обязательное изменение `UserMediaService` для persisted video (ownership)

Сейчас `UserMediaService.setVideo(blockId: tempURL:)` считает файл "temp" и удаляет его при cleanup.
Поэтому для persisted video требуется новый API:

```swift
enum MediaOwnership { case temporaryOwnedByService, persistentExternal }

@discardableResult
func setVideo(blockId: String, url: URL, ownership: MediaOwnership) -> Bool

// Старый API остаётся как convenience:
func setVideo(blockId: String, tempURL: URL) -> Bool {
    setVideo(blockId: blockId, url: tempURL, ownership: .temporaryOwnedByService)
}
```

Cleanup удаляет файл **только** если ownership = `.temporaryOwnedByService`.

#### 7.4.3 Сохранение видео в ProjectStore (NEW API — PR-D)

> **NEW API:** Метод `saveUserVideo` **не существует** в текущем коде.
> Реализуется в PR-D как новая функциональность.
>
> **Подтверждено в review.md:** Видео-персист и восстановление **обязаны входить в PR-D**, потому что:
> - UI в Scene Edit предлагает "Add Video" как first-class action
> - Сейчас `applyMediaAssignments` явно ограничен "photo only" (строка 1227)
> - После перезапуска/undo видео не восстановится без этого функционала

Текущий `ProjectStore.saveUserMedia(...)` сохраняет только JPEG.
Для видео добавляем метод копирования файла:

```swift
func saveUserVideo(
    from sourceURL: URL,
    sceneInstanceId: UUID,
    blockId: String
) throws -> MediaRef
```

Реализация: копировать файл в `userMediaDirectory`, сохранить расширение (`mov/mp4/m4v`), сформировать filename с `(sceneInstanceId_blockId_uuid.ext)`, вернуть `MediaRef.file(relativePath)`.

#### 7.4.3.1 Каноничный порядок video persist flow (ВАЖНО)

> **Подтверждено в review.md:** Порядок операций для video без data loss.

В PHPicker callback (когда `sourceURL` валиден только внутри callback):

```swift
// 1. Копируем sourceURL СРАЗУ в persistent (без промежуточного temp!)
let mediaRef = try ProjectStore.shared.saveUserVideo(
    from: sourceURL,
    sceneInstanceId: instanceId,
    blockId: blockId
)

// 2. Получаем persistent URL
let persistentURL = try ProjectStore.shared.absoluteURL(for: mediaRef)

// 3. Применяем в runtime с правильным ownership
userMediaService.setVideo(
    blockId: blockId,
    url: persistentURL,
    ownership: .persistentExternal  // cleanup НЕ удалит файл
)

// 4. Диспатчим в store для persistence + undo
editorStore.dispatch(.setBlockMedia(
    sceneInstanceId: instanceId,
    blockId: blockId,
    media: mediaRef
))
```

**Критично:** Никакого "runtime продолжит использовать temp и потом удалится" — это был бы data loss баг.

#### 7.4.4 Применение persisted assignments в runtime (PlayerViewController)

В `PlayerViewController.applyMediaAssignments(_:)` поддерживаем фото и видео через extension:

* Фото (`jpg/jpeg/png/heic`):

  * `UIImage(contentsOfFile:)` → `userMediaService.setPhoto(blockId:image:)`
* Видео (`mov/mp4/m4v`):

  * `userMediaService.setVideo(blockId:url:ownership:.persistentExternal)`

**Важно:** `UserMediaService.setPhoto/setVideo` **сами** выставляют `player.setUserMediaPresent(blockId: present:true)` (видео через poster-gating выставит true, когда poster готов).

После `applyMediaAssignments` обязательно применить persisted `SceneState.userMediaPresent`, чтобы "Disable asset" мог перебить наличие медиа:

```swift
// 1) apply assignments -> will set present=true automatically for assigned blocks
applyMediaAssignments(mediaAssignments)

// 2) apply explicit present overrides (disable/enable)
for (blockId, present) in (state.userMediaPresent ?? [:]) {
    player.setUserMediaPresent(blockId: blockId, present: present)
}
```

---

## 8) PlayerViewController: единый релизный хост + удаление dev-редактора

### 8.1 Удалить dev presentation mode

Файл: `AnimiApp/Sources/Player/PlayerViewController.swift`

**Удалить полностью:**
* `enum PlayerPresentationMode` и кейс `.dev` (стр. 51–57)
* `presentationMode` property и `applyPresentationMode()` с `.dev` (стр. 610–627)
* `override init(nibName:bundle:)` — оставить только `init(mode: .editor(templateId:))`
* dev-UI: `templateSelector`, `scrollView`, `contentView`, `logTextView`, `mainControlsStack`
* dev-UI: `variantPicker`, `toggleStack`, `userMediaContainer`, все debug-кнопки
* `wireEditorController()` и зависимость от `TemplateEditorController` (включая `syncUIWithState()` — часть dev path)
* Файл `TemplateEditorController.swift` — удалить полностью

**Оставить:**
* Релизный путь через `EditorLayoutContainerView` + `EditorStore` + `TimelinePlaybackCoordinator`
* `TimelinePlaybackCoordinator` **остаётся и в Scene Edit** (подтверждено в review.md):
  - держит `currentSceneInstanceId`
  - решает active scene по `playheadTimeUs`
  - управляет lazy-loading сцены
  - Render pipeline единый: `coordinator.currentRenderCommands(mode: .edit)`
* Точечные `#if DEBUG` логи/сигнпосты (без UI-дубликатов)
* Export функциональность

### 8.2 Wiring Scene Edit

В `configureEditorTimeline()`:

```swift
// Existing callbacks...

// NEW: UI mode changes
store.onUIModeChanged = { [weak self] mode in
    guard let self = self else { return }

    switch mode {
    case .timeline:
        self.editorLayoutContainer.setSceneEditMode(false, animated: true)
        self.editorLayoutContainer.navBar.setMode(.timeline)
        self.sceneEditController.updateOverlay()

    case .sceneEdit(let sceneId):
        // Stop playback
        if self.isPlaying {
            self.stopPlayback()
        }
        self.editorLayoutContainer.setSceneEditMode(true, animated: true)
        self.editorLayoutContainer.navBar.setMode(.sceneEdit)
        self.sceneEditController.updateOverlay()
    }
}

// NEW: Selected block changes
store.onSelectedBlockChanged = { [weak self] blockId in
    self?.updateBottomBarForSceneEdit(selectedBlockId: blockId)
    self?.sceneEditController.updateOverlay()
}

// NEW: Undo/Redo state → navBar
store.onUndoRedoChanged = { [weak self] canUndo, canRedo in
    self?.editorLayoutContainer.navBar.setUndoEnabled(canUndo)
    self?.editorLayoutContainer.navBar.setRedoEnabled(canRedo)
}

// NEW: Undo/Redo restored snapshot -> re-apply runtime for active scene instance
//
// ВАЖНО (подтверждено в review.md):
// - clearAll() существует в UserMediaService и удаляет textures + ставит present=false
// - applySceneInstanceState применяет mediaAssignments, но НЕ очищает то, что было раньше
// - Поэтому без clearAll() после undo останутся "stale textures" (старое фото/видео)
// - Стратегия "undo/redo → clearAll → applySceneInstanceState" — строго обязательна
//
store.onStateRestoredFromUndoRedo = { [weak self] in
    guard let self = self else { return }
    guard let instanceId = self.activeSceneInstanceId else { return }
    guard let player = self.scenePlayer else { return }

    // Clear runtime user media to avoid "stale textures" after undo
    self.userMediaService?.clearAll()

    // Re-apply full persisted state for active instance (variants/transforms/toggles/media + userMediaPresent)
    self.applySceneInstanceState(instanceId: instanceId)

    // Refresh overlay (if in sceneEdit) and redraw
    self.sceneEditController.updateOverlay()
    self.metalView.setNeedsDisplay()
}
```

В `wireEditorLayoutCallbacks()`:

```swift
// Existing callbacks...

// NEW: Edit scene
contextBar.onEditScene = { [weak self] sceneId in
    self?.editorStore?.dispatch(.enterSceneEdit(sceneId: sceneId))
}

// NEW: Done from Scene Edit
navBar.onDone = { [weak self] in
    self?.editorStore?.dispatch(.exitSceneEdit)
}
```

### 8.3 TimelinePlaybackCoordinator: автоматическая синхронизация (ВАЖНО)

> **Подтверждено в review.md:** Coordinator "подхватывает" правильную сцену автоматически.
> Явный re-apply НЕ нужен.

**Полный flow `enterSceneEdit` → coordinator:**

```
enterSceneEdit(sceneId:) [reducer]
    ↓
state.playheadTimeUs = sceneStartUs [reducer изменяет playhead]
    ↓
EditorStore.dispatch() детектирует playheadChanged
    ↓
store.onPlayheadChanged?(newPlayhead) [EditorStore.swift:163]
    ↓
PlayerViewController.handlePlayheadChanged(timeUs) [строка 1235]
    ↓
coordinator.setGlobalTimeUs(timeUs) [строка 1275, async path]
    ↓
findActiveScene(at: timeUs) → определяет активную сцену
    ↓
Если сцена изменилась:
    currentSceneInstanceId = newInstanceId
    onActiveSceneChanged?(sceneInfo) [строка 163-166]
    ↓
PlayerViewController.handleActiveSceneChanged() [строка 1133]
    ↓
applySceneInstanceState(instanceId:) [применяет variants/transforms/toggles/media]
```

**Гарантии:**
1. `enterSceneEdit` меняет `playheadTimeUs` → `onPlayheadChanged` срабатывает обязательно
2. `handlePlayheadChanged` **всегда** вызывает coordinator (`syncSetGlobalTimeUs` или `setGlobalTimeUs`)
3. Coordinator вызывает `onActiveSceneChanged` если instance изменился
4. Никакого "явного re-apply" не требуется — flow уже работает корректно

**Важно:** Если в будущем кто-то оптимизирует `onPlayheadChanged` и перестанет вызывать coordinator
при "малых" изменениях — это будет регресс, не часть текущего плана.

### 8.4 Undo/Redo: per-block generation pattern (PR-D)

> **Подтверждено в review.md:** Используем **per-block generation**, НЕ добавляем global counter.

**Текущий pattern в UserMediaService (уже реализован):**

```swift
// Строки 183-190:
private var videoSetupGenerationByBlock: [String: UInt64] = [:]
private var videoSetupTasksByBlock: [String: Task<Void, Never>] = [:]

// При setVideo (строки 299-303):
let newGeneration = (videoSetupGenerationByBlock[blockId] ?? 0) + 1
videoSetupGenerationByBlock[blockId] = newGeneration
let token = newGeneration
videoSetupTasksByBlock[blockId]?.cancel()

// Token checks после await (строки 328, 356):
guard self.videoSetupGenerationByBlock[blockId] == token, !Task.isCancelled else { return }
```

**clearAll() уже работает корректно:**
- `clearAll()` → `clear(blockId:)` → `cleanupVideoResources(for:)` → generation bump

**Каноническое решение для PR-D (из review.md):**

Добавить helper для консистентности стиля:

```swift
@inline(__always)
private func guardToken(_ blockId: String, _ token: UInt64) -> Bool {
    videoSetupGenerationByBlock[blockId] == token && !Task.isCancelled
}
```

Использовать:
- после `await requestPoster()`
- перед `mediaState[...] = ...`
- перед `setUserMediaPresent(... true)`

**Почему global counter НЕ нужен:**
1. Per-block позволяет параллельную обработку разных блоков
2. `clearAll()` уже bump'ает generation для каждого блока через `cleanupVideoResources`
3. Global counter был бы избыточным и добавил бы новый источник истины

---

## 9) Критерии приёмки (Definition of Done)

### 9.1 UX

* ✅ Выбор сцены в таймлайне показывает `Duplicate/Delete/Edit`
* ✅ Нажатие `Edit`:
  * таймлайн исчезает (коллапс), превью расширяется
  * плейбек остановлен
  * вверху Done (вместо Close/Export)
  * Undo/Redo работают
* ✅ Тап по mediaInput в Scene Edit:
  * появляется outline/overlay
  * показывается `MediaBlockActionBar` (photo/video/animation/disable/remove)
  * действия работают и отражаются в превью
* ✅ Background/Reset Scene доступны когда block не выбран
* ✅ `Done` возвращает к timeline:
  * таймлайн виден
  * playhead восстановлен
  * изменения сохранены

### 9.2 Engine safety

* ✅ В `.edit` блоки **не фильтруются** по `block.timing`:
  * render показывает все блоки
  * overlays работают для всех блоков
  * hitTest работает для всех блоков

### 9.3 Чистота кода

* ✅ `TemplateEditorController.swift` удалён
* ✅ Dev-UI удалён из `PlayerViewController`
* ✅ `PlayerPresentationMode.dev` удалён
* ✅ Нет debug prints в релизном коде (только `#if DEBUG`)
* ✅ Один канонический путь: Templates → Editor

---

## 10) Тесты

### 10.1 AnimiApp unit tests

Файл: `AnimiApp/Tests/EditorReducerTests.swift`

> **NEW TEST HELPERS:** В текущих тестах есть `makeDraft(sceneDurations:)` и `makeDefaultSceneSequence(durations:)`.
> Для Scene Edit тестов создаём новые helpers на их основе.
>
> **Из review.md:** `canonicalTimeline.sceneItems` существует как computed property.
> В тестах явно писать `state.canonicalTimeline.sceneItems[1].id` для избежания неоднозначности.

```swift
// MARK: - Test Helpers (NEW)

/// Creates EditorState with N scenes for Scene Edit testing.
/// Uses existing makeDraft/makeDefaultSceneSequence under the hood.
private func makeStateWithScenes(count: Int, durationUs: TimeUs = 2_000_000) -> EditorState {
    let durations = Array(repeating: durationUs, count: count)
    let draft = makeDraft(sceneDurations: durations)
    return EditorState(draft: draft)
}

/// Creates EditorState already in Scene Edit mode (first scene selected).
private func makeStateInSceneEdit() -> EditorState {
    var state = makeStateWithScenes(count: 2)
    state.uiMode = .sceneEdit(sceneInstanceId: state.canonicalTimeline.sceneItems[0].id)
    return state
}

// MARK: - Scene Edit Mode Tests

func test_enterSceneEdit_savesReturnPlayhead() {
    // Given: state with playhead at 5_000_000us
    var state = makeStateWithScenes(count: 3)
    state.playheadTimeUs = 5_000_000
    // Note: use canonicalTimeline.sceneItems for clarity (state.sceneItems is shorthand)
    let sceneId = state.canonicalTimeline.sceneItems[1].id

    // When
    let result = EditorReducer.reduce(state: state, action: .enterSceneEdit(sceneId: sceneId))

    // Then
    XCTAssertEqual(result.state.sceneEditReturnPlayheadUs, 5_000_000)
    XCTAssertEqual(result.state.uiMode, .sceneEdit(sceneInstanceId: sceneId))
    XCTAssertNil(result.state.selectedBlockId)
    XCTAssertFalse(result.shouldPushSnapshot) // UI transition
}

func test_enterSceneEdit_movesPlayheadToSceneStart() {
    // Given: 3 scenes, each 2 seconds
    var state = makeStateWithScenes(count: 3, durationUs: 2_000_000)
    let sceneId = state.canonicalTimeline.sceneItems[1].id // second scene starts at 2s

    // When
    let result = EditorReducer.reduce(state: state, action: .enterSceneEdit(sceneId: sceneId))

    // Then
    XCTAssertEqual(result.state.playheadTimeUs, 2_000_000)
}

func test_exitSceneEdit_restoresPlayhead() {
    // Given: state in sceneEdit with saved return playhead
    var state = makeStateWithScenes(count: 2)
    state.uiMode = .sceneEdit(sceneInstanceId: state.canonicalTimeline.sceneItems[0].id)
    state.sceneEditReturnPlayheadUs = 1_500_000
    state.playheadTimeUs = 0

    // When
    let result = EditorReducer.reduce(state: state, action: .exitSceneEdit)

    // Then
    XCTAssertEqual(result.state.playheadTimeUs, 1_500_000)
    XCTAssertEqual(result.state.uiMode, .timeline)
    XCTAssertNil(result.state.sceneEditReturnPlayheadUs)
    XCTAssertNil(result.state.selectedBlockId)
    XCTAssertFalse(result.shouldPushSnapshot)
}

func test_selectBlock_doesNotPushSnapshot() {
    var state = makeStateInSceneEdit()

    let result = EditorReducer.reduce(state: state, action: .selectBlock(blockId: "block_1"))

    XCTAssertEqual(result.state.selectedBlockId, "block_1")
    XCTAssertFalse(result.shouldPushSnapshot)
}

func test_setBlockMediaPresent_pushesSnapshot() {
    var state = makeStateInSceneEdit()
    let sceneId = state.canonicalTimeline.sceneItems[0].id

    let result = EditorReducer.reduce(
        state: state,
        action: .setBlockMediaPresent(sceneInstanceId: sceneId, blockId: "block_1", present: false)
    )

    XCTAssertEqual(result.state.draft.sceneInstanceStates[sceneId]?.userMediaPresent?["block_1"], false)
    XCTAssertTrue(result.shouldPushSnapshot)
}
```

### 10.2 TVECore unit tests

Файл: `TVECore/Tests/TVECoreTests/ScenePlayerEditModeTests.swift` (новый или расширить существующие)

```swift
func test_editMode_showsAllBlocks_regardlessOfTiming() {
    // Given: block with timing.startFrame = 30 (not visible at frame 0)
    let block = makeBlock(startFrame: 30, endFrame: 60)
    let runtime = makeRuntime(blocks: [block])
    let player = ScenePlayer()
    player.loadCompiledScene(makeCompiledScene(runtime: runtime))

    // When: render in edit mode (always frame 0)
    let commands = player.renderCommands(mode: .edit)

    // Then: block is rendered despite timing
    XCTAssertTrue(commands.contains { $0.containsBlockGroup(block.blockId) })
}

func test_editMode_hitTest_findsBlockWithDelayedTiming() {
    // Given: block starting at frame 30, positioned at (100, 100)
    let block = makeBlock(startFrame: 30, endFrame: 60, rect: RectD(x: 50, y: 50, width: 100, height: 100))
    let player = makePlayerWithBlock(block)

    // When: hit test in edit mode
    let hit = player.hitTest(point: Vec2D(x: 100, y: 100), frame: 0, mode: .edit)

    // Then: block is found
    XCTAssertEqual(hit, block.blockId)
}

func test_editMode_overlays_includesBlockWithDelayedTiming() {
    // Given: block starting at frame 30
    let block = makeBlock(startFrame: 30, endFrame: 60)
    let player = makePlayerWithBlock(block)

    // When: get overlays in edit mode
    let overlays = player.overlays(frame: 0, mode: .edit)

    // Then: block overlay is present
    XCTAssertTrue(overlays.contains { $0.blockId == block.blockId })
}

func test_previewMode_hidesBlockBeforeStartFrame() {
    // Given: block starting at frame 30
    let block = makeBlock(startFrame: 30, endFrame: 60)
    let player = makePlayerWithBlock(block)

    // When: render at frame 0 in preview mode
    let commands = player.renderCommands(mode: .preview, sceneFrameIndex: 0)

    // Then: block is NOT rendered
    XCTAssertFalse(commands.contains { $0.containsBlockGroup(block.blockId) })
}
```

---

## 11) Совместимость данных

* `SceneState.userMediaPresent` — optional `[String: Bool]?`
* Старые проекты без этого поля загружаются нормально (`decodeIfPresent`)
* schemaVersion не меняем — decoding безопасен
* Тест `testProjectDraft_jsonRoundtrip` должен проходить

---

## 12) План реализации (PR-шаги)

### PR-A: Model Layer ✅ COMPLETED (2026-03-04)
**Файлы:**
- `EditorState.swift` — `EditorUIMode`, `uiMode`, `selectedBlockId`, `sceneEditReturnPlayheadUs`
- `EditorAction.swift` — новые actions
- `EditorReducer.swift` — обработка новых actions
- `EditorStore.swift` — `onUIModeChanged`, `onSelectedBlockChanged`, `onStateRestoredFromUndoRedo`
- `SceneState.swift` — `userMediaPresent`
- `EditorReducerTests.swift` — тесты

**Критерий готовности:** Тесты проходят, store корректно диспатчит actions

**Что реализовано:**
- ✅ `EditorUIMode` enum с `.timeline` и `.sceneEdit(sceneInstanceId:)`
- ✅ Новые поля `uiMode`, `selectedBlockId`, `sceneEditReturnPlayheadUs` (НЕ входят в EditorSnapshot)
- ✅ 5 новых actions: `enterSceneEdit`, `exitSceneEdit`, `selectBlock`, `resetSceneState`, `setBlockMediaPresent`
- ✅ Reducer обработка всех новых actions
- ✅ Расширение `setBlockMedia` для auto `userMediaPresent = true/false`
- ✅ Callbacks: `onUIModeChanged`, `onSelectedBlockChanged`, `onStateRestoredFromUndoRedo`
- ✅ Change detection в `dispatch()` для uiMode и selectedBlockId
- ✅ Вызов `onStateRestoredFromUndoRedo` в `performUndo()`/`performRedo()`
- ✅ `SceneState.userMediaPresent: [String: Bool]?` с полной семантикой
- ✅ 15 новых тестов для Scene Edit Mode

**Архив для ревью:** `PR-A_SceneEditMode_ModelLayer.zip`

### PR-B: TVECore Safety ✅ COMPLETED (2026-03-05)
**Файлы:**
- `ScenePlayerTypes.swift` — `BlockVisibilityPolicy`
- `SceneRenderPlan.swift` — параметр `visibility`
- `ScenePlayer.swift` — edit mode bypass timing в hitTest/overlays/renderCommands + convenience API (`mediaInput`, `allowedMedia`, `userTransformsAllowed`)
- `ScenePlayerEditModeTests.swift` — тесты

**Критерий готовности:** В edit mode все блоки видны/кликабельны независимо от timing

**Что реализовано:**
- ✅ `BlockVisibilityPolicy` enum с `.timeline` и `.all`
- ✅ Параметр `visibility` в `SceneRenderPlan.renderCommands()`
- ✅ Timing bypass в `ScenePlayer.renderCommands(mode:)` — `.edit` → `.all`
- ✅ Timing bypass в `hitTest()` — `if mode == .preview { guard timing... }`
- ✅ Timing bypass в `overlays()` — `if mode == .preview { guard timing... }`
- ✅ Convenience API: `mediaInput()`, `allowedMedia()`, `userTransformsAllowed()`
- ✅ 5 тестов для edit mode timing bypass

**Архив для ревью:** `PR-B_TVECore_Safety.zip`

### PR-C: UI Layout ✅ COMPLETED (2026-03-05)
**Файлы:**
- `ContextBar.swift` — кнопка Edit
- `EditorLayoutContainerView.swift` — `setSceneEditMode()` через constraint-группы, `embedOverlayView()`
- `EditorNavBar.swift` — `EditorNavBarMode`, Done button
- `SceneEditBar.swift` — новый
- `MediaBlockActionBar.swift` — новый

**Критерий готовности:** UI переключается между режимами, layout корректный, без AutoLayout warnings

**Что реализовано:**
- ✅ `ContextBar`: добавлен callback `onEditScene` и кнопка Edit
- ✅ `EditorNavBar`: добавлен `EditorNavBarMode` enum, кнопка Done, метод `setMode()`
- ✅ `EditorLayoutContainerView`:
  - Constraint groups (`timelineVisibleConstraints`, `sceneEditConstraints`)
  - `setSceneEditMode(_:animated:)` — переключает constraints, скрывает timeline и menuStrip
  - `embedOverlayView()` — добавляет overlay между metalView и menuStrip
  - `updateSceneEditBottomBar(selectedBlockId:)` — переключает SceneEditBar/MediaBlockActionBar
  - Callbacks: `onEditScene`, `onDone`
  - P2 fix: `setSceneEditMode()` теперь устанавливает bottom bar в консистентное состояние
- ✅ `SceneEditBar`: Background, Reset Scene, hint label
  - P1 fix: Anti-overlap constraint + compression priorities для hintLabel
- ✅ `MediaBlockActionBar`: Photo, Video, Animation, Disable/Enable, Remove
  - P1 fix: scrollView использует contentLayoutGuide/frameLayoutGuide для корректного скролла

**Архив для ревью:** `PR-C_UI_Layout.zip`

### PR-D: Wiring + Interaction + Video Persist ✅ COMPLETED (2026-03-09)
**Файлы:**
- `EditorCanvasMapper.swift` — новый
- `SceneEditInteractionController.swift` — новый
- `UserMediaService.swift` — новый API `setVideo(url:ownership:)`, хранение ownership, cleanup удаляет только temp
- `ProjectStore.swift` — `saveUserVideo(from:sceneInstanceId:blockId:)`
- `PlayerViewController.swift` — wiring store↔layout, gesture setup, `applyMediaAssignments` с video через extension + ownership
- `EditorOverlayView.swift` — `isUserInteractionEnabled = true` для gesture pass-through

**Критерий готовности:** Полный flow работает: Edit→tap→select→action→Done, video persist без data loss

**Что реализовано:**
- ✅ `EditorCanvasMapper`: pure math struct для canvas ↔ view coordinate transforms (aspect-fit)
- ✅ `SceneEditInteractionController`: hit testing, selection, gesture handling (pan/pinch/rotate)
  - Uses existing `InteractionPhase` from `TimelineEvents.swift`
  - `TransformType` enum for permission checking
  - Callbacks: `onSelectBlock`, `onTransformChanged`
- ✅ `MediaOwnership` enum: `.temporary` (delete on cleanup) vs `.persistent` (keep file)
- ✅ `setVideo(blockId:url:ownership:presentOnReady:)` — новая сигнатура с ownership и presentOnReady
  - P0-3 fix: `presentOnReady` параметр для сохранения Disable/Enable состояния при restore
- ✅ `saveUserVideo(from:sceneInstanceId:blockId:)` — копирование через `FileManager.copyItem`
- ✅ `handleUserMediaVideoPicked(blockId:tempURL:)` — полный persistence flow:
  1. `saveUserVideo()` → MediaRef
  2. `absoluteURL(for:)` → persistedURL
  3. `setVideo(ownership: .persistent)`
  4. `dispatch(.setBlockMedia(...))`
  5. Cleanup tempURL
- ✅ `applyMediaAssignments(_:userMediaPresent:)` — расширена для video + presentOnReady
- ✅ `applySceneInstanceState()` — правильный порядок: assignments → userMediaPresent overrides → variants → transforms → toggles
- ✅ Store callbacks wiring: `onUIModeChanged`, `onSelectedBlockChanged`, `onStateRestoredFromUndoRedo`
- ✅ `sceneEditController` setup и wiring в `configureEditorTimeline()`
- ✅ Gestures перенесены на `overlayView` с routing по `uiMode`
- ✅ P1: `clearAll()` использует union ключей для корректной очистки pending tasks
- ✅ P1: Poster throttling с `AsyncSemaphore(limit: 2)`
- ✅ P1: `sceneEditController?.updateOverlay()` в `viewDidLayoutSubviews()` для Scene Edit mode

**P2 (не блокирующие, можно после мержа):**
- Orphan persisted file при runtime-fail setVideo
- `onNeedsDisplay` vs `requestMetalRender` консистентность

**Архив для ревью:** `PR-D-v2-review.zip`

### PR-E: Cleanup + Wiring Completion
**Статус:** Специфицирован, готов к реализации

**Цель:** Удалить dev-редактор, оставить один canonical production path (Scene Edit через EditorStore + SceneEditInteractionController + EditorLayoutContainerView).

---

#### Фаза 0: Wiring Callbacks (ОБЯЗАТЕЛЬНО до удаления dev-UI!)

**Проблема:** В PR-C созданы `SceneEditBar` и `MediaBlockActionBar` с callbacks, но они **НЕ подключены** к PlayerViewController. Если удалить dev-UI без wiring — Scene Edit станет "немым".

**0.1 MediaBlockActionBar — добавить blockId:**

Файл: `AnimiApp/Sources/Editor/MediaBlockActionBar.swift`

```swift
// Добавить хранение blockId
private(set) var blockId: String?

func configure(blockId: String?) {
    self.blockId = blockId
}

// Изменить сигнатуры callbacks
var onAddPhoto: ((String) -> Void)?   // было: (() -> Void)?
var onAddVideo: ((String) -> Void)?
var onAnimation: ((String) -> Void)?
var onToggleEnabled: ((String) -> Void)?
var onRemove: ((String) -> Void)?

// В обработчиках кнопок
@objc private func addPhotoTapped() {
    guard let id = blockId else { return }
    onAddPhoto?(id)
}
// Аналогично для остальных
```

**0.2 EditorLayoutContainerView — прокинуть callbacks:**

Файл: `AnimiApp/Sources/Editor/EditorLayoutContainerView.swift`

```swift
// Публичные callbacks для Scene Edit actions
var onBackground: (() -> Void)?
var onResetScene: (() -> Void)?
var onAddPhoto: ((String) -> Void)?
var onAddVideo: ((String) -> Void)?
var onAnimation: ((String) -> Void)?
var onToggleEnabled: ((String) -> Void)?
var onRemove: ((String) -> Void)?

// В wireCallbacks() связать с SceneEditBar/MediaBlockActionBar
private func wireCallbacks() {
    // ... existing code ...

    // Scene Edit Bar
    sceneEditBar.onBackground = { [weak self] in self?.onBackground?() }
    sceneEditBar.onResetScene = { [weak self] in self?.onResetScene?() }

    // Media Block Action Bar
    mediaBlockActionBar.onAddPhoto = { [weak self] blockId in self?.onAddPhoto?(blockId) }
    mediaBlockActionBar.onAddVideo = { [weak self] blockId in self?.onAddVideo?(blockId) }
    mediaBlockActionBar.onAnimation = { [weak self] blockId in self?.onAnimation?(blockId) }
    mediaBlockActionBar.onToggleEnabled = { [weak self] blockId in self?.onToggleEnabled?(blockId) }
    mediaBlockActionBar.onRemove = { [weak self] blockId in self?.onRemove?(blockId) }
}

// В updateSceneEditBottomBar(selectedBlockId:) — передавать blockId
func updateSceneEditBottomBar(selectedBlockId: String?) {
    if let blockId = selectedBlockId {
        mediaBlockActionBar.configure(blockId: blockId)
        // ... show mediaBlockActionBar ...
    }
    // ...
}
```

**0.3 PlayerViewController — подключить handlers:**

Файл: `AnimiApp/Sources/Player/PlayerViewController.swift`

В `wireEditorLayoutCallbacks()` (или новом методе):

```swift
// Scene Edit Bar actions
editorLayoutContainer.onBackground = { [weak self] in
    self?.backgroundTapped()
}

editorLayoutContainer.onResetScene = { [weak self] in
    guard let self = self,
          case .sceneEdit(let instanceId) = self.editorStore?.state.uiMode else { return }
    self.editorStore?.dispatch(.resetSceneState(sceneInstanceId: instanceId))
}

// Media Block Action Bar actions
editorLayoutContainer.onAddPhoto = { [weak self] blockId in
    self?.presentPhotoPicker(for: blockId)
}

editorLayoutContainer.onAddVideo = { [weak self] blockId in
    self?.presentVideoPicker(for: blockId)
}

editorLayoutContainer.onAnimation = { [weak self] blockId in
    self?.presentVariantPicker(for: blockId)
}

editorLayoutContainer.onToggleEnabled = { [weak self] blockId in
    guard let self = self,
          case .sceneEdit(let instanceId) = self.editorStore?.state.uiMode else { return }
    // Toggle current state
    let currentPresent = self.editorStore?.state.draft.sceneInstanceStates[instanceId]?.userMediaPresent?[blockId] ?? true
    self.editorStore?.dispatch(.setBlockMediaPresent(
        sceneInstanceId: instanceId,
        blockId: blockId,
        present: !currentPresent
    ))
}

editorLayoutContainer.onRemove = { [weak self] blockId in
    guard let self = self,
          case .sceneEdit(let instanceId) = self.editorStore?.state.uiMode else { return }
    self.userMediaService?.clear(blockId: blockId)
    self.editorStore?.dispatch(.setBlockMedia(
        sceneInstanceId: instanceId,
        blockId: blockId,
        media: nil
    ))
}
```

---

#### Фаза 1: Удаление файла

**Удалить:**
- `AnimiApp/Sources/Editor/TemplateEditorController.swift` (включая `TemplateEditorState`)

**Обновить project.pbxproj:**
- Удалить ссылки на `TemplateEditorController.swift` (строки с fileRef)

---

#### Фаза 2: Build → Fix compilation errors

**Замены editorController в production path:**

| Место | Строка | Было | Стало |
|-------|--------|------|-------|
| `viewDidLayoutSubviews()` | ~1573-1574 | `overlayView.canvasToView = editorController.canvasToViewTransform()` | `overlayView.canvasToView = sceneEditController?.mapper.canvasToViewTransform() ?? .identity` |
| `viewDidLayoutSubviews()` | ~1581 | `editorController.refreshOverlayIfNeeded()` | Удалить (дублируется L1585) |
| `draw(in:)` | ~4027 | `else if let editorCommands = editorController.currentRenderCommands()` | Удалить всю ветку, оставить только coordinator path |
| `playPauseTapped()` | ~2374, 2376 | `editorController.setPlaying(...)` | Удалить (не влияет на production) |
| `frameSliderChanged()` | ~2384 | `editorController.scrub(to:)` | Удалить (dev-only) |
| `metalViewTapped()` | ~2393 | `editorController.handleTap(viewPoint:)` | Удалить (есть overlayViewTapped) |
| `gestureRecognizerShouldBegin` | ~4184 | `editorController.state.mode == .edit && editorController.state.selectedBlockId != nil` | См. ниже |

**gestureRecognizerShouldBegin — замена:**

```swift
func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    if gestureRecognizer is UIPanGestureRecognizer ||
       gestureRecognizer is UIPinchGestureRecognizer ||
       gestureRecognizer is UIRotationGestureRecognizer {
        guard case .sceneEdit = editorStore?.state.uiMode else { return false }
        return editorStore?.state.selectedBlockId != nil
    }
    return true
}
```

**handlePan/Pinch/Rotation — удалить else-ветки:**

```swift
// Было:
if case .sceneEdit = editorStore?.state.uiMode {
    sceneEditController?.handlePan(recognizer)
} else {
    editorController.handlePan(recognizer)  // ← удалить
}

// Стало:
guard case .sceneEdit = editorStore?.state.uiMode else { return }
sceneEditController?.handlePan(recognizer)
```

---

#### Фаза 3: Удаление dev-UI properties и methods

**Properties (удалить полностью):**

| Property | Строка | Описание |
|----------|--------|----------|
| `enum PlayerPresentationMode` | ~52-55 | Enum с `.dev` case |
| `presentationMode` | ~81 | Property + inits (~93, ~98) |
| `scrollView` | ~104-111 | Dev layout container |
| `contentView` | ~113-124 | Dev layout container |
| `templateSelector` | ~127-134 | Dev template picker |
| `sceneSelector` | ~152 | DEBUG scene picker |
| `loadButton` | ~159 | DEBUG load button |
| `smokeTestButton` | ~163-165 | DEBUG test button |
| `smokeTestStatusLabel` | ~167 | DEBUG label |
| `smokeTestResults` | ~187 | DEBUG array |
| `logTextView` | ~237-273 | Dev log view |
| `variantPicker` | ~276-281 | Dev variant picker |
| `variantLabel` | ~284-308 | Dev label |
| `presetPicker` | ~294-300 | Dev preset picker |
| `toggleLabel` | ~311-318 | Dev label |
| `toggleStack` | ~321-329 | Dev toggle stack |
| `editorController` | ~439 | `TemplateEditorController()` |
| `modeToggle` | ~475-481 | Dev Edit/Preview toggle |
| `logTextViewHeightConstraint` | ~514 | Dev constraint |
| `logTextViewBottomConstraint` | ~515 | Dev constraint |
| `mainControlsStackBottomConstraint` | ~516 | Dev constraint |
| `mainControlsStack` | ~1590 | Dev stack |
| `userMediaContainer` | ~1616 | Dev container |
| `playbackContainer` | ~1624 | Dev container |
| `state` computed property | ~3012-3014 | `editorController.state` wrapper |

**Methods (удалить полностью):**

| Method | Строка | Описание |
|--------|--------|----------|
| `wireEditorController()` | ~1831-1841 | Dev wiring |
| `syncUIWithState(_:)` | ~2633-2652 | Dev state sync |
| `updateVariantPickerUI(state:)` | ~2655-2686 | Dev UI update |
| `updateToggleUI(state:)` | ~2689-2743 | Dev UI update |
| `updateUserMediaUI(state:)` | ~2759-2778 | Dev UI update |
| `templateSelectorChanged()` | ~2513-2520 | Dev handler |
| `variantPickerChanged()` | ~2522-2531 | Dev handler |
| `modeToggleChanged()` | ~2502-2508 | Dev handler |
| `presetPickerChanged()` | ~2545-2549 | Dev handler |
| `log(_:)` | ~3862-3866 | Dev logging |
| `smokeTestTapped()` и smoke test methods | various | DEBUG testing |

**Switch cases (удалить .dev ветки):**

| Место | Строка | Действие |
|-------|--------|----------|
| `setupUI()` | ~531-608 | Удалить `case .dev:` блок |
| `applyPresentationMode()` | ~615-628 | Удалить `case .dev:` блок |

**Layout code (удалить):**
- Строки ~1635-1805: setup scrollView/contentView/constraints для dev-UI

**Init (упростить):**
- Оставить только `init(mode: PlayerPresentationMode)` с `case .editor`
- Удалить `init()` и `init?(coder:)` с `.dev` default

---

#### Фаза 4: Финальный grep-чеклист

**Должно быть 0 вхождений (кроме удалённых файлов и документации):**

```bash
grep -rn "TemplateEditorController" AnimiApp/Sources/
grep -rn "editorController" AnimiApp/Sources/
grep -rn "wireEditorController" AnimiApp/Sources/
grep -rn "PlayerPresentationMode" AnimiApp/Sources/
grep -rn "\.dev" AnimiApp/Sources/Player/
grep -rn "variantPicker" AnimiApp/Sources/
grep -rn "logTextView" AnimiApp/Sources/
grep -rn "toggleStack" AnimiApp/Sources/
grep -rn "templateSelector" AnimiApp/Sources/
grep -rn "syncUIWithState" AnimiApp/Sources/
grep -rn "updateUserMediaUI" AnimiApp/Sources/
grep -rn "userMediaContainer" AnimiApp/Sources/
grep -rn "scrollView" AnimiApp/Sources/Player/PlayerViewController.swift
grep -rn "contentView" AnimiApp/Sources/Player/PlayerViewController.swift
grep -rn "mainControlsStack" AnimiApp/Sources/Player/PlayerViewController.swift
grep -rn "modeToggle" AnimiApp/Sources/Player/PlayerViewController.swift
```

---

#### Файлы НЕ удалять:

| Файл | Причина |
|------|---------|
| `ScrubDiagnostics.swift` | Используется в `requestMetalRender()` для DEBUG toggles |

**В `ScrubDiagnostics.swift` обновить комментарий:**
```swift
// Было: "MARK: - TemplateEditorController.setCurrentTimeUs"
// Стало: "MARK: - Scrub time update diagnostics"
```

---

#### Критерий готовности PR-E

1. ✅ `TemplateEditorController.swift` удалён
2. ✅ `.dev` режим удалён из `PlayerPresentationMode`
3. ✅ Все dev-UI properties/methods удалены из `PlayerViewController`
4. ✅ Scene Edit callbacks (`SceneEditBar`, `MediaBlockActionBar`) подключены к handlers
5. ✅ По grep-чеклисту — 0 вхождений dev-символов
6. ✅ `xcodebuild build` — успешно (все конфиги)
7. ✅ `xcodebuild test` — все тесты проходят
8. ✅ Smoke test: Home → Details → Editor → Scene Edit → все actions работают → Done → Export

---

#### Оценка объёма

| Действие | Примерный объём |
|----------|-----------------|
| Фаза 0: Wiring | +80-100 строк |
| Удалить файл | -1 файл (~300 строк) |
| Удалить properties | ~20 properties |
| Удалить methods | ~10 методов |
| Удалить layout code | ~170 строк |
| Замены editorController | ~15 мест |
| **Итого нетто** | **~-600 строк** |

---

## 13) QA Checklist

### Happy Path
- [ ] Выбрать сцену → видеть Duplicate/Delete/Edit
- [ ] Edit → таймлайн скрыт, превью full-screen
- [ ] Tap на media slot → overlay + MediaBlockActionBar
- [ ] Add Photo → медиа видно
- [ ] Add Video → видео видно (poster)
- [ ] Disable → медиа скрыто
- [ ] Enable → медиа видно
- [ ] Remove → медиа удалено
- [ ] Done → таймлайн виден, playhead восстановлен

### Edge Cases
- [ ] Duplicate scene → edit duplicate → изменения только в копии
- [ ] Undo в Scene Edit → откатывает контент, режим остаётся, runtime обновлён
- [ ] Redo после Undo → восстанавливает контент, runtime обновлён
- [ ] Reset Scene → все изменения сброшены, undoable
- [ ] Block с timing.startFrame > 0 → виден и кликабелен в edit
- [ ] allowedMedia = ["photo"] only → Add Video disabled
- [ ] Exit без изменений → playhead восстановлен корректно
- [ ] Persisted video → после перезапуска видео восстановлено (не удалено)

### Regression
- [ ] Export работает после Scene Edit
- [ ] Timeline scrub работает
- [ ] Playback работает
- [ ] Старые проекты загружаются
- [ ] Нет AutoLayout warnings в консоли
