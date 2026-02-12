## 100% причина: движок рендерит слои **в прямом порядке массива**, а в `polaroid_demo` (и вообще в Lottie/AE) верхний слой находится **раньше в массиве**, из-за чего z-order получается инвертирован

Ниже — **строго доказуемая цепочка по коду + данным шаблона**.

---

# 1) Точка, где создаётся z-order: `AnimIR.renderComposition` обходит `composition.layers` **в прямом порядке**

**Code anchor**

* `TVECore/Sources/TVECore/AnimIR/AnimIR.swift`
* `renderComposition(_:context:commands:)`
* ~строки 236–255

```swift
/// Renders a composition recursively
private mutating func renderComposition(
    _ composition: Composition,
    context: RenderContext,
    commands: inout [RenderCommand]
) {
    // Process layers in order (as they appear in JSON)
    for layer in composition.layers {
        renderLayer(layer, context: context, commands: &commands)
    }
}
```

Это означает: команды рисования добавляются в массив **в том же порядке**, что и `composition.layers`.

---

# 2) `composition.layers` приходит из компилятора **в том же порядке**, что и `lottie.layers` (никакого reverse на этапе компиляции нет)

**Code anchor**

* `TVECore/Sources/TVECompilerCore/AnimIRCompiler.swift`
* `compileLayers(_:compId:animRef:fallbackOp:pathRegistry:)`
* ~строки 245–305

```swift
// Second pass: compile all layers with matte info
var layers: [Layer] = []

for (index, lottieLayer) in lottieLayers.enumerated() {
    ...
    let layer = try compileLayer(
        lottie: lottieLayer,
        index: index,
        compId: compId,
        animRef: animRef,
        fallbackOp: fallbackOp,
        matteInfo: matteInfo,
        implicitMatteSourceIds: implicitMatteSourceIds,
        pathRegistry: &pathRegistry
    )
    layers.append(layer)
}

return layers
```

Т.е. порядок **Lottie JSON → AnimIR Composition.layers** сохраняется 1:1.

---

# 3) Доказательство на конкретном `polaroid_demo`: в JSON у блока `mediaBlock` слой рамки (`polaroid.png`) стоит **раньше**, чем слой `media`

В snapshot есть `polaroid/polaroid_full.json`, где `assets[id="comp_0"].layers` идут так (индексы массива):

**Data anchor (из файла)**

* `polaroid/polaroid_full.json`
* `assets[id="comp_0"].layers[0..4]` (порядок слоёв массива)

Экстракт (по факту содержимого файла, порядок сохранён):

* `[0] nm: "polaroid.png"  ty:2`  ← рамка/картинка полароида
* `[1] nm: "mask"         ty:4`
* `[2] nm: "plastik.png"  ty:2 (hd=true)`
* `[3] nm: "media"        ty:2`  ← медиа-плейсхолдер
* `[4] nm: "mediaInput"   ty:4`  ← форма inputClip

(Это видно прямо в начале файла — JSON one-line, но порядок элементов однозначен.)

---

# 4) Почему именно это даёт наблюдаемый симптом “media поверх рамки”

Факт по коду: движок рисует **в порядке массива**, значит в `comp_0` он нарисует:

1. `polaroid.png` (рамку)
   …
2. `media` (позже) → **перекроет** всё, что было нарисовано раньше, включая рамку.

Это ровно и объясняет симптом: “в preview/edit mediaInput (пользовательское фото/видео) сверху рамки”.

---

## Итог

**Причина на 100% в коде:**
`AnimIR.renderComposition` формирует render-команды, обходя `composition.layers` **в прямом порядке**; компилятор сохраняет порядок `lottie.layers` без инверсии; в `polaroid_demo` рамка стоит раньше слоя `media`, поэтому `media` рисуется позже и оказывается сверху.

Если хочешь — следующим шагом я дам **точный diff-текст** для фикса в стиле “минимальная правка + code anchors”, но ты просил сейчас именно причину, без решения.
