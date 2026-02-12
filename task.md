Ниже — **релизное, универсальное** решение, которое **гарантирует правильный z-order для любых шаблонов**, и при этом **не ломает matte/mask** (по текущей реализации движка). Всё — **только на основе реального кода snapshot**.

---

# Почему “просто развернуть массив” — это правильный уровень фикса

## Факт 1: z-order сейчас определяется **порядком эмиссии RenderCommand**

`MetalRenderer.drawInternal` исполняет команды **последовательно**, “что нарисовали позже — лежит сверху”.
**Anchor:** `TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift: while index < commands.count { ... renderSegment(... commands in: range) }` (команды идут по индексу, без сортировок).

## Факт 2: команды сейчас генерируются обходом `composition.layers` **в прямом порядке**

Это и есть причина инверсии z-order.
**Anchor:** `TVECore/Sources/TVECore/AnimIR/AnimIR.swift` → `renderComposition`:

```swift
// Process layers in order (as they appear in JSON)
for layer in composition.layers {
    renderLayer(layer, context: context, commands: &commands)
}
```

## Факт 3: matte не зависит от “сначала/потом в массиве”, потому что matte source рендерится **по ссылке layerId**

`emitMatteScope` всегда рендерит `matte.sourceLayerId` через `context.layerById[...]`, а не надеется на порядок итерации.
**Anchor:** `TVECore/Sources/TVECore/AnimIR/AnimIR.swift` → `emitMatteScope`:

```swift
commands.append(.beginGroup(name: "matteSource"))
emitLayerForMatteSource(layerId: matte.sourceLayerId, ...)
...
commands.append(.beginGroup(name: "matteConsumer"))
emitRegularLayerCommands(consumer, ...)
```

➡️ Поэтому **правильный и универсальный фикс**: **рендерить слои композиции снизу-вверх**, то есть **итерация в обратном порядке**.

---

# Релизное решение (универсальное)

## 1) Изменить порядок обхода слоёв во всех композициях: bottom→top

### Единственная точка правки: `AnimIR.renderComposition`

**До:**

```swift
// Process layers in order (as they appear in JSON)
for layer in composition.layers {
    renderLayer(layer, context: context, commands: &commands)
}
```

### После (релизный вариант, без лишних аллокаций, с ясной семантикой AE):

```swift
// AE/Lottie stacking: earlier in layers[] is visually on top.
// Therefore we must render from bottom to top (reverse array order).
for layer in composition.layers.reversed() {
    renderLayer(layer, context: context, commands: &commands)
}
```

**Почему это универсально:** применяется **ко всем композициям, включая precomp**, потому что `renderLayerContent(.precomp)` внутри вызывает `renderComposition(precomp, ...)` тем же кодом.

---

## 2) Обязательная регрессия тестом на реальном `polaroid_full` (чтобы это больше никогда не сломали)

У вас уже есть golden fixture `Resources/polaroid_full/data.json` и компиляция в тестах (`ImplicitMatteSourceTests`). На базе этого добавляем новый тест, который проверяет **порядок `drawImage`**:

### Что проверяем

В `comp_0` порядок layers в JSON такой:

* `image_0` (рамка polaroid) стоит **раньше** → должна быть **сверху**
* `image_2` (media placeholder / user media) стоит позже → должна быть **под рамкой**

Значит в render commands:

* `drawImage(image_2)` должен идти **раньше**
* `drawImage(image_0)` должен идти **позже** (и перекрывать)

### Тест (идея, 1:1 к вашему текущему стеку тестов)

Создать `LayerOrderTests.swift`:

* загрузить `Resources/polaroid_full/data.json`
* `compiler.compile(...)` (как в `ImplicitMatteSourceTests`)
* `ir.renderCommandsWithIssues(frameIndex: 0, ...)`
* найти индексы первой встречи `.drawImage(assetId: "image_2")` и `.drawImage(assetId: "image_0")`
* assert: `idxMedia < idxFrame`

Это **релизный** тест, потому что проверяет финальный контракт движка: “команды генерятся в корректном порядке”.

---

## 3) Обновить комментарии/контракт в коде (чтобы не вернулись к прямому обходу)

* В `renderComposition` заменить текущий misleading-комментарий (“as they appear in JSON”) на точный:
  **“AE/Lottie: layers earlier in array are on top → render reversed to respect stacking.”**

---

# Почему это решение “максимально правильное”

1. **Минимальный change surface**: 1 точка генерации команд (`renderComposition`), без расползания по компилятору/рендереру.
2. **Универсально**: работает для любых типов слоёв (image/shape/precomp), любых вложенностей, любых шаблонов.
3. **Не ломает matte**: matte source рендерится через `layerId`, а не через “порядок итерации”, и matte-source слои всё равно “не рисуются напрямую” в основном потоке (`guard !layer.isMatteSource else { return }`).
4. **Защищено тестом на реальном шаблоне**: `polaroid_full` станет “вечным” регресс-фикстуром.

---

# Готов дать точный diff

Если скажешь “да”, я пришлю **точный `diff`**:

* 1 правка в `AnimIR.swift`
* 1 новый файл теста `LayerOrderTests.swift`
* (по желанию) мини-правку комментария в `AnimIR.swift`

Без “переписывания всего”, но **релизно и навсегда**.
