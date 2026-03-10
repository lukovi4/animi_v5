Провёл аудит **строго по реальному коду из `PR-E-Scene-Edit-Mode-Cleanup-v2.zip`** (только `PlayerViewController.swift` + `ScrubDiagnostics.swift`).

## TL-вердикт

⚠️ **Почти ок, но НЕ “100%”** — есть **1 реальная регрессия в жестах Scene Edit** (делегаты распознавалок не назначены). Это не ломает сборку, но ломает часть ожидаемого поведения (simultaneous pinch+rotate и gating через `gestureRecognizerShouldBegin` фактически не работает).

В остальном: layout теперь действительно **один**, overlay встроен правильно, preparingOverlay перенесён верно, dev-UI удалён.

---

## ✅ Что теперь сделано правильно (подтверждено кодом)

### 1) Единственный layout path

В `viewDidLoad()` теперь **нет `setupUI()`**, только:

* `setupRenderer()`
* `setupEditorLayout()`

Это фиксит прежнюю P0-проблему “два layout-пути”.

### 2) overlayView корректно embedded в production контейнер

В `setupEditorLayout()` вызывается:

* `editorLayoutContainer.embedMetalView(metalView)`
* **`editorLayoutContainer.embedOverlayView(overlayView)`** ✅

Теперь тап/жесты реально попадают в overlay, а не “под” контейнер.

### 3) preparingOverlay переехал в правильный контейнер

`preparingOverlay` добавлен как subview `editorLayoutContainer` и pinned “full-edge”. Это устраняет прежний конфликт с переносом `metalView`.

### 4) Playback UI теперь поддерживается через production UI

В `startPlayback()/stopPlayback()` выставляется:

* `editorLayoutContainer.setPlaying(true/false)` ✅
  То есть удаление старых `playPauseButton/updatePlayPauseButton` корректно: production UI (MenuStrip) получает состояние.

### 5) `ScrubDiagnostics.swift` — комментарии обновлены корректно

Упоминания `TemplateEditorController` заменены на `ScenePlayer` в комментариях (сам файл DEBUG-only, функционально не затронут).

---

## ❌ Что НЕ верно на 100% (реально по коду)

### P1 (но для “100%” обязателен фикс): Gesture recognizers **без delegate**

В `setupOverlayGestureRecognizers()` вы создаёте tap/pan/pinch/rotation и добавляете на `overlayView`, но **ни одному recognizer’у не назначаете `delegate = self`**.

При этом `PlayerViewController` всё ещё реализует `UIGestureRecognizerDelegate`:

* `shouldRecognizeSimultaneouslyWith` (для pinch+rotation)
* `gestureRecognizerShouldBegin` (гейтинг “только в sceneEdit и только при selectedBlockId != nil”)

Но без `recognizer.delegate = self` эти методы **никогда не вызовутся**.

### Минимальный фикс (ровно как было в PR-D)

Добавьте делегат для pan/pinch/rotation (и при желании для tap тоже):

```swift
private func setupOverlayGestureRecognizers() {
    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(overlayViewTapped(_:)))
    overlayView.addGestureRecognizer(tapGesture)

    let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
    let rotationGesture = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))

    panGesture.delegate = self
    pinchGesture.delegate = self
    rotationGesture.delegate = self

    overlayView.addGestureRecognizer(panGesture)
    overlayView.addGestureRecognizer(pinchGesture)
    overlayView.addGestureRecognizer(rotationGesture)
}
```

После этого:

* снова заработает simultaneous pinch+rotate,
* `gestureRecognizerShouldBegin` начнёт реально предотвращать “пустые” жесты без выбора блока.

---

## ⚠️ Потенциальное UI-замечание (P2, не блокер)

`metalView` в lazy init имеет `cornerRadius = 8` и `clipsToBounds = true`. В fullscreen preview вы переносите **тот же** `metalView` в `FullScreenPreviewViewController`, но нигде не сбрасываете radius → есть риск, что fullscreen будет с закруглениями.

Если это видно/мешает — лечится в `handleFullScreenPreview()`:

* перед переносом `metalView.layer.cornerRadius = 0`,
* при возврате в container — восстановить 8 (или пусть previewContainer сам маскирует).

---

## Итог

* **Ничего критически “лишнего” по функционалу editor mode вы не удалили**: play/pause, scrub, export, background flow — всё осталось в production-пути и wired через `EditorLayoutContainerView`.
* Но **до “100%” не хватает одного маленького, но важного фикса**: назначить `delegate` у gesture recognizers на overlay.