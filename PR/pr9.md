# PR9 — Track Mattes (alpha/luma) + offscreen matte pipeline

## 0) Цель PR9 (нормативно)

Добавить в **MetalRenderer** полноценное исполнение **track mattes** из RenderGraph команд через **offscreen passes**, чтобы:

* работали **tt/td** (matte source `td==1`, consumer “следующий слой” с `tt`)  
* поддерживались режимы:

  * **alpha matte** (normal) — `tt==1` 
  * **alpha matte inverted** — `tt==2` 
  * **luma matte** — `tt==3` (PR9 расширение по просьбе; не обязателен для TP, но MUST реализовать в renderer)
  * **luma matte inverted** — `tt==4` (аналогично)
* matte source **не рисуется напрямую** как обычный слой (он используется только для матчинга) — это уже заложено в Core Spec/контракте и IR 

> В Test Profile (reference package) минимум нужен `tt==1` и `tt==2` для anim-2/anim-3  . Luma добавляем как “универсальность PR9”, но тестовый пакет может его не использовать.

---

## 1) Входной контракт (RenderGraph) — что именно должен уметь MetalRenderer

RenderGraph уже декларирует matte-команды как MUST:
`BeginMatteAlpha / BeginMatteAlphaInverted / EndMatte` 

### 1.1 Изменения RenderCommand (PR9)

Чтобы поддержать **alpha + luma** без раздувания enum’а:

**Добавить:**

```swift
public enum MatteMode: Sendable, Equatable {
  case alpha
  case alphaInverted
  case luma
  case lumaInverted
}

public enum RenderCommand {
  case beginMatte(mode: MatteMode)
  case endMatte
  // остальные без изменений
}
```

**Миграция:**

* старые кейсы `beginMatteAlpha/beginMatteAlphaInverted` (если есть) либо:

  * заменить на `.beginMatte(mode: .alpha/.alphaInverted)`, либо
  * оставить как deprecated wrappers, но в тестах/IR использовать новый единый кейс.

---

## 2) Контракт структуры matte scope (чтобы у executor не было “магии”)

MetalRenderer не должен “искать” matte source где-то в AnimIR — ему нужен **детерминированный local scope**.

**Нормативное правило PR9:**
Внутри `BeginMatte(...) ... EndMatte` должно быть **ровно два дочерних group-scope**, в порядке:

1. `BeginGroup("matteSource") ... EndGroup`
2. `BeginGroup("matteConsumer") ... EndGroup`

И больше ничего на верхнем уровне matte-scope.

Если структура иная → `throw MetalRendererError.invalidCommandStack(...)`.

Почему так: это снимает необходимость “доставать” matte source по ID и делает executor чистым и предсказуемым.

---

## 3) Алгоритм рендера matte (offscreen pipeline)

Это прямое продолжение PR8 (маски уже через offscreen/stencil), но теперь “маска” — это другой слой.

### 3.1 Общий 3-pass алгоритм (минимум)

Для каждого `BeginMatte(mode)`:

1. **Render matteSourceGroup → matteTex**
2. **Render matteConsumerGroup → consumerTex**
3. **Composite consumerTex → parentTarget** с учётом matteTex и `mode`

Формулы (важно: у нас premultiplied alpha blending в renderer’е):

* **alpha**: `factor = matte.a`
* **alphaInverted**: `factor = 1 - matte.a`
* **luma**: `factor = luminance(matte.rgb)`
  Рекомендация: `luma = 0.2126*r + 0.7152*g + 0.0722*b`
* **lumaInverted**: `factor = 1 - luminance(matte.rgb)`

И применяем к premultiplied consumer:

* `out.rgb = consumer.rgb * factor`
* `out.a   = consumer.a   * factor`

### 3.2 Размеры и форматы текстур

* `consumerTex`: `.bgra8Unorm`
* `matteTex`: `.bgra8Unorm` (**всегда**, чтобы luma работал без спец-веток)
* `target`: как сейчас (offscreen / onscreen)

Текстуры берём через существующий `TexturePool` (как в PR8).

### 3.3 Наследование state (обязательное, как в PR8 fix)

Matte scope **MUST** наследовать:

* `transformStack`
* `clip/scissor stack`

То есть `drawInternal(... initialState: inheritedState)` применяется так же, как уже сделано для masks (PR8 fix).

И composite passes **MUST** выставлять scissor, если он был активен перед matte.

---

## 4) Исполнение команд в MetalRenderer (Executor design)

### 4.1 Извлечение scope

Переходим на **index-based iteration** (у вас это уже есть из PR8) и добавляем:

* `extractMatteScope(from:startIndex:) -> MatteScope?`

  * находит matching `EndMatte`
  * корректно учитывает вложенные mattes/masks (nested depth)
  * возвращает:

    * `mode: MatteMode`
    * `sourceCommands: [RenderCommand]` (внутри `matteSource` group)
    * `consumerCommands: [RenderCommand]` (внутри `matteConsumer` group)
    * `endIndex`

Если `BeginMatte` без `EndMatte` → **throw** (никаких silent skip).

### 4.2 Взаимодействие с masks

Внутри `sourceCommands` и `consumerCommands` могут встречаться маски (`BeginMaskAdd`) — они должны работать рекурсивно, т.к. `drawInternal` уже умеет masks (PR8).

---

## 5) Изменения в AnimIR (генерация команд)

PR9 должен гарантировать, что:

* для пар `td==1` (source) и `tt in {1,2,3,4}` (consumer) генерируется **matte wrapper scope** согласно п.2
* matte source **не появляется как обычный DrawImage в потоке** (он включается только в matteSourceGroup)

Основание: PR9 в плане релиза прямо фиксирует `td==1` и `tt==1/2` и offscreen-композит , а Core Spec закрепляет командный контракт для mattes .

### 5.1 Shape layer как matte source

В Part 1 shape поддерживается **только как matte source** .
Значит matteSourceGroup может содержать shape-команды (через уже существующий путь: rasterize/рисовать в texture). В PR9 допустим тот же подход, что в masks: CPU raster → texture → quad draw, либо прямой shape→alpha pass (на ваше усмотрение), но результат должен попасть в `matteTex`.

---

## 6) Ошибки и DoD

### 6.1 Ошибки (renderer-level)

Добавить/использовать существующий `MetalRendererError.invalidCommandStack(reason:)` для:

* missing EndMatte
* неверной структуры matte scope (нет двух group’ов, порядок нарушен)
* unbalanced stacks после выполнения

### 6.2 DoD PR9 (минимальный)

1. MetalRenderer:

* корректно исполняет `.beginMatte(mode:) / .endMatte` через offscreen pipeline
* работает с `alpha / alphaInverted` (обяз.) и `luma / lumaInverted` (в PR9)

2. AnimIR:

* генерирует matte scopes для anim-2 и anim-3 (TP)  

3. Tests:

* новые unit/integration тесты покрывают:

  * alpha matte клиппит consumer
  * inverted alpha работает
  * luma (и inverted) на синтетическом примере
  * matte наследует transform + clip (аналогично PR8 тестам)
  * malformed matte stack throws

4. Test Profile expectations:

* **anim-2: tt=1 работает**
* **anim-3: tt=2 работает**  

---

## 7) Тесты PR9 (конкретный список)

Создать `MetalRendererMatteTests.swift` (или расширить существующий):

### 7.1 Synthetic renderer-level tests (быстрые, без Lottie)

1. `testAlphaMatte_clipsConsumer()`

* matteTex: половина экрана alpha=1, остальное 0
* consumerTex: полностью непрозрачный
* ожидание: пиксель вне matte → alpha=0

2. `testAlphaMatteInverted_clipsOpposite()`

3. `testLumaMatte_usesRGBLuminance()`

* matteTex: слева белый, справа чёрный (rgb), alpha=1
* consumerTex: белый
* ожидание: справа alpha=0, слева alpha>0

4. `testMatteInheritsTransform_translation()`

* pushTransform перед matte → consumer должен сдвинуться вместе с matte

5. `testMatteInheritsClip_scissorAppliedToComposite()`

6. `testUnbalancedMatteThrows()`

### 7.2 Integration tests с реальными anim-2/anim-3 (обязательно)

`TestProfileMattesIntegrationTests.swift`:

* компилировать реальные `anim-2.json` и `anim-3.json`
* рендерить оффскрин кадры из TP3: 30/60/90 (минимум) 
* проверка не “красоты”, а факта matte:

  * выбрать 2 точки: одна гарантированно “внутри”, другая “снаружи” matte (если сложно — делаем coarse: сравниваем суммарную alpha/кол-во ненулевых пикселей: **с matte их меньше**, чем без matte).
  * важно: тест детерминированный.
