Да, ответы нужны — и я дам **однозначные решения** по всем 5 пунктам, чтобы программист мог стартовать без риска “переделывать”.

---

## 1) PR-A: как декодить `s` для path keyframes (там массив из одного PathData)

**Выбираем Вариант B (отдельный enum значения keyframe).**
Причина: это **самый чистый, расширяемый и недвусмысленный** способ, без “особых случаев” в декодере и без дублирования полей.

### Конкретно

В `TVECore/Sources/TVECore/Lottie/LottieTransform.swift`:

* Вводим:

```swift
enum LottieKeyframeValue: Decodable, Equatable, Sendable {
  case numbers([Double])                 // p/s/r/o и т.п.
  case path(LottiePathData)              // path keyframe (один объект)
}
```

* В `init(from:)`:

  * если `s` декодится как `[Double]` → `.numbers`
  * else если `s` декодится как `[[LottiePathData]]` или `[LottiePathData]` → взять **первый элемент** и сделать `.path(...)`
    (Да, в Lottie часто это `[{...}]` — массив из одного элемента; мы фиксируем это как норму.)
  * аналогично для `e` если присутствует.

* `LottieKeyframe` хранит:

  * `startValue: LottieKeyframeValue?`
  * `endValue: LottieKeyframeValue?`

Это снимет все проблемы с типами и не поломает числовые треки.

---

## 2) PR-B: интерполяция path — linear или easing?

**Делаем Вариант B: применяем bezier easing к progress, затем vertex-lerp.**
Причина: ты просила “релизное решение, без MVP”. Игнор easing = заметная “не та” динамика (особенно на morphing matte), и это потом будет дороже чинить, потому что станет “поведенческим контрактом”.

### Конкретно

* У keyframe есть `i/o` (cubic bezier easing).
* Делаете функцию `easedT = cubicBezier(i,o).solve(t)` и дальше:

  * `v = lerp(v0, v1, easedT)`
  * `inTangent = lerp(i0, i1, easedT)`
  * `outTangent = lerp(o0, o1, easedT)`

**Условие поддержки (MUST):** топология совпадает (vertex count + closed). Иначе — `UnsupportedFeature(PATH_TOPOLOGY_MISMATCH)`.

---

## 3) PR-C: триангуляция и breaking change RenderCommand

### 3A) Триангуляция: свой код или библиотека?

**Используем порт earcut (сторонний код) как vendored-source в репо.**
Причины:

* earcut — де-факто стандарт, хорошо работает на сложных контурах, с отверстиями (если появятся).
* свой ear-clipping на 300–500 строк почти всегда приводит к багам на самопересечениях/почти-коллинеарных точках, а нам нужно “релизно”.

**Как подключать:**

* без внешних зависимостей через SPM, чтобы не усложнять.
* просто положить в `TVECore/Sources/TVECore/ThirdParty/Earcut/*` с лицензией.
* обернуть в маленький `PathTriangulator` API.

### 3B) RenderCommand: сохранить совместимость или сразу pathId?

**Сразу переходим на `pathId` (breaking change допустим).**
Причина: это core-движок на ранней стадии; сохранение старого API удвоит код (BezierPath payload + pathId), и это напрямую нарушит твое требование “без дубликатов”.

Правило: один путь данных, одна команда.

---

## 4) PR-C: где интерполировать vertices — CPU или GPU?

**Выбираем Вариант B: все keyframes в GPU buffer + интерполяция на GPU.**
Это прямо следует из твоего требования: “финальный рендер без CPU”. CPU-интерполяция каждый кадр — это не “рисование”, но это всё равно per-frame heavy CPU work + постоянные uploads.

### Конкретно (реализация без overkill)

* На компиляции:

  * складываем `positions` всех keyframes подряд в один `MTLBuffer` (или два: positions + tangents если нужно).
  * сохраняем `frameIndex -> (kf0Index, kf1Index, localT, easingParams)` в маленькую таблицу или считаем на CPU (это ок; CPU может считать scalars).
* На рендере:

  * передаём в шейдер (через uniforms):

    * `kf0Offset`, `kf1Offset`, `easedT`
  * vertex shader берёт `pos0 = positions[kf0Offset + vid]`
  * `pos1 = positions[kf1Offset + vid]`
  * `pos = mix(pos0, pos1, easedT)`

Для anim-3 (2 keyframe, 4 вершины) это вообще копейки.

---

## 5) Scope: animated path только для shape matte или и для masksProperties?

**ДЕЛАЕМ ДЛЯ ОБОИХ:**

* shape matte (td/tt) — обязательно (anim-3 это требует)
* masksProperties.pt — тоже поддерживаем в этом же релизе

Причины:

* архитектура одна и та же (`AnimPath` + `pathId` + GPU path pipeline).
* если сделать “только для matte”, вы всё равно потом будете возвращаться и расширять validator/compiler/renderer — это и есть дубликаты и полумеры.

**Но:** валидация для `masksProperties` и `shape matte` одинаковая: topology match, поддержка режима (add/alpha…), и т.д.

---

# Итоговый “командирский” ответ программисту

1. **Keyframe значения:** делаем `LottieKeyframeValue` enum (numbers/path), вынимаем path из `[PathData]` как first element.
2. **Интерполяция path:** применяем easing (cubic bezier) и потом vertex-lerp; без easing нельзя.
3. **Triangulation:** берём vendored earcut; свой писать не надо.
   **RenderCommand:** сразу `pathId`, без обратной совместимости.
4. **GPU ресурсы:** keyframes храним в GPU buffer, интерполируем в shader; CPU только считает скаляры (какие два kf и t).
5. **Scope:** animated path поддерживаем и в matte shapes, и в masksProperties, одной архитектурой.

Можешь передать это разработчику как “решение лида”, и он может стартовать с PR-A без дополнительных вопросов.
