Не принимаю PR-10 в текущем виде. По тестам всё зелёное, но есть **2 блокера по “релизному” качеству** (корректность рендера + консистентный fail-fast как у PR-07/08/09).

---

## Блокер 1 — **strokeWidth не масштабируется transform’ом**

Сейчас вы:

* трансформируете **геометрию path** в viewport (через `pathToViewport`),
* но **`ctx.setLineWidth(strokeWidth)`** оставляете в “сырых” единицах Lottie.

В результате при `animToViewport` scale ≠ 1 (а это типичный кейс) **обводка будет неверной толщины** (тоньше/толще ожидаемой). В Lottie stroke width живёт в той же системе координат, что и path — значит при переводе в viewport **толщина обязана масштабироваться тем же uniform scale**.

### Как починить (канонично)

1. Вычислить uniform scale из матрицы, которой вы переводите path в viewport (у вас это `pathToViewport`):

* `scale = hypot(a, b)` (длина X-базиса) — корректно при rotation и uniform scale.

2. В `strokeTexture(...)` передавать **scaledStrokeWidth = strokeWidth * scale**.
3. И именно scaledStrokeWidth использовать в `ctx.setLineWidth(...)` и в ключе кэша (иначе кэш/рендер разъедутся).

> Важно: если у вас где-то допускается non-uniform scale (не должно), тогда нужна политика (например, брать `max(hypot(a,b), hypot(c,d))`), но по вашему пайплайну сейчас предполагается uniform.

---

## Блокер 2 — extractor для animated width **не fail-fast**, а “тихо пропускает” кривые keyframes

В `extractAnimatedWidth(...)` сейчас есть поведение:

* keyframe без `time` или без `startValue` → **`continue`**, трек собирается “как получится”.

Это противоречит принятым у нас правилам после PR-07/08:

* **никаких silent ignore**, любая невалидность → `nil` (и валидатор обязан дать ошибку).

### Как починить (канонично)

В `extractAnimatedWidth`:

* при **любой** невозможности распарсить keyframe (нет `t`, нет `s`, формат не number) → **return nil** (не continue).
* если `isAnimated == true`, но `value` не `.keyframes` → **return nil** (как в PR-07 v3).

Да, валидатор уже проверяет формат — но extractor должен быть строгим **сам по себе** (как защита от пропуска валидатора/регресса в будущем).

---

## Неблокирующие замечания (но лучше поправить сразу)

1. **StrokeCacheKey** включает `strokeWidth: Double` без квантизации → при animated width кэш будет почти всегда промахиваться. У вас `maxEntries=64`, память не взорвётся, но CPU-нагрузка может.
   Рекомендация: квантизировать width для ключа (например `rounded(width * 8)/8` или в px до Int).
2. В `MetalRenderer+Execute` добавлен `computeMaxAlpha(...)` (debug-хелпер). Если он не используется в прод-коде — лучше удалить, чтобы не плодить “мёртвый” код в релизной ветке.

---

## Что жду в PR-10 v2 (минимально достаточно для “принять”)

1. Масштабирование stroke width через `pathToViewport` (uniform scale) — **обязательное**.
2. `extractAnimatedWidth` — строгий fail-fast без `continue` и без “частичных” треков.
3. +1–2 теста:

   * тест на **invalid keyframe format для width**: validator выдаёт `UNSUPPORTED_STROKE_WIDTH_KEYFRAME_FORMAT` + extractor возвращает `nil`.
   * (опционально) тест на helper `strokeWidthScale(from:)` если вынесете scale-логику в отдельную функцию.