# Добавление шаблона в приложение

## Структура проекта

```
SceneSources/<scene_id>/          — исходники сцены (scene.json + Lottie-файлы)
SharedAssets/                     — общие изображения между сценами
AnimiApp/Resources/Scenes/        — скомпилированные сцены (compiled.tve + images/)
AnimiApp/Resources/Templates/     — каталог шаблонов (manifest.json + превью)
```

**Сцена** — единица рендеринга (анимации + слоты для медиа). **Шаблон** — пользовательский продукт, ссылается на одну или несколько сцен.

---

## Шаг 1. Подготовить Lottie-файлы

Каждая сцена требует минимум два Lottie JSON файла:

- `no-anim.json` — статичный вариант (без анимации), обязателен для режима редактирования
- `anim-*.json` — анимированные варианты (один или несколько)

### Требования к Lottie

| Параметр | Значение | Примечание |
|----------|----------|------------|
| Размер канвы (`w`, `h`) | 1080 x 1920 | Должен совпадать с `canvas` в `scene.json` |
| FPS (`fr`) | 30 | Должен совпадать с `canvas.fps` в `scene.json` |
| Длительность (`op`) | Количество кадров | 150 = 5 сек, 300 = 10 сек при 30fps |

### Запрещённые возможности Lottie

Компилятор отклонит файл, если в нём используются:

- 3D-слои (`ddd: 1`)
- Auto-orient (`ao: 1`)
- Time stretch (`sr` != 1)
- Blend modes (`bm` != 0)
- Skew-трансформ (`sk` != 0 или анимированный)

### Поддерживаемые типы слоёв

| `ty` | Тип | Назначение |
|------|-----|------------|
| 0 | Precomp | Ссылка на вложенную композицию |
| 2 | Image | Изображение (binding-слой, декор) |
| 3 | Null | Пустой трансформ-слой |
| 4 | Shape | Фигуры (mediaInput, matte-источники) |

Другие типы слоёв (text, solid и т.д.) **не поддерживаются**.

### Обязательные слои внутри каждого медиа-блока

Binding-слой и mediaInput могут быть как в root-композиции, так и внутри precomp.

**1. Binding-слой (обязательный)**

- Тип: `ty: 2` (image)
- Имя (`nm`): должно точно совпадать с `bindingKey` из `scene.json` (обычно `"media"`). **Сравнение регистрозависимое** (`layer.name == bindingKey` в `AnimIRCompiler.swift`)
- Должен иметь `refId`, указывающий на image-ассет
- Ровно один binding-слой на один `bindingKey` (компилятор выдаст ошибку при 0 или >1)
- **Файл-placeholder для binding-ассета не нужен и его наличие не проверяется.** Валидатор (`AnimValidator.findBindingAssetIds`) находит `refId` всех binding-слоёв и пропускает их при проверке файлов на диске — текстуру подставляет пользователь в рантайме. Поле `p` в ассете (`"p":"что_угодно.png"`) может ссылаться на несуществующий файл — это не ошибка. Это касается **только** binding-ассетов; см. «Декоративные слои» ниже про обычные ассеты.

**2. mediaInput (обязательный в `no-anim.json`)**

- Тип: `ty: 4` (shape)
- Имя (`nm`): **строго `"mediaInput"`, регистрозависимо** (`layer.name == "mediaInput"`, `AnimIRCompiler.swift:584`). Частая ошибка: Lottie-экспортёры и ручное именование дают `mediainput` (всё в нижнем регистре) — компилятор такой слой **не найдёт** и выдаст `MEDIA_INPUT_MISSING`. Проверяйте регистр первым делом.
- Скрытый: `"hd": true`
- Содержит ровно один shape path (определяющий зону тапа и clip-маску)
- Должен находиться в той же композиции, что и binding-слой (общая composition: оба в root, либо оба в одном precomp). Несоблюдение → ошибка `mediaInputNotInSameComp`
- Запрещены модификаторы: Trim Paths (`tm`), Merge Paths (`mm`), Repeater (`rp`)
- В анимированных вариантах (`anim-*.json`) mediaInput опционален
- Если anim-вариант содержит свой mediaInput, его path должен совпадать с edit variant

**Placement contract:**
- Placement (cover/contain/fill + pan/zoom/rotate) вычисляется относительно binding-слоя placeholder asset, а не mediaInput path
- mediaInput path определяет только clip-маску и hit-test зону
- Это позволяет шаблонам с диагональными масками и рамками (polaroid) корректно вставлять медиа

**3. Декоративные слои (опционально)**

Любые дополнительные image/shape слои (рамки, оверлеи). Файлы изображений для них размещаются в `images/` или `SharedAssets/`.

В отличие от binding-ассета, **файлы для декоративных image-ассетов обязаны существовать**: валидатор резолвит их по basename из поля `p` (`Local → Shared`) и при отсутствии выдаёт ошибку `ASSET_MISSING` (`AnimValidator.swift`). Проще говоря: ассет, на который ссылается binding-слой `media`, файла не требует; любой другой image-ассет — требует.

**4. Toggle-слои (опционально)**

Переключаемые декоративные элементы. Имя слоя должно иметь формат `toggle:<id>` (регистрозависимо):
- `toggle:frame` — id = `"frame"`
- `toggle:hearts` — id = `"hearts"`

Ограничения toggle-слоёв:
- Не могут быть matte-источниками (`td: 1`) или matte-потребителями (`tt`)
- Не могут быть родительскими слоями для других слоёв
- Набор toggle-id должен совпадать во всех вариантах одного блока

### Файловая структура

**Одноблочная сцена** — файлы в корне:

```
SceneSources/my_scene/
├── scene.json
├── no-anim.json
├── anim-1.json
└── images/           (опционально)
```

**Многоблочная сцена** — файлы в подпапках по блокам:

```
SceneSources/my_scene/
├── scene.json
├── block_01/
│   ├── no-anim.json
│   └── anim-1.1.json
├── block_02/
│   ├── no-anim.json
│   └── anim-2.1.json
└── images/
```

---

## Шаг 2. Создать scene.json

Файл `SceneSources/<scene_id>/scene.json`. Пример полной одноблочной сцены:

```json
{
  "schemaVersion": "0.1",
  "sceneId": "<scene_id>",
  "canvas": { "width": 1080, "height": 1920, "fps": 30, "durationFrames": 150 },
  "mediaBlocks": [
    {
      "blockId": "block_01",
      "zIndex": 0,
      "rect": { "x": 0, "y": 0, "width": 1080, "height": 1920 },
      "containerClip": "none",
      "timing": { "startFrame": 0, "endFrame": 150 },
      "input": {
        "bindingKey": "media",
        "hitTest": "mask",
        "allowedMedia": ["photo", "video", "color"],
        "emptyPolicy": "hideWholeBlock",
        "fitModesAllowed": ["cover", "contain", "fill"],
        "userTransformsAllowed": { "pan": true, "zoom": true, "rotate": true },
        "defaultFit": "cover",
        "audio": { "enabled": false, "gain": 1.0 }
      },
      "variants": [
        {
          "variantId": "no-anim",
          "animRef": "no-anim.json",
          "defaultDurationFrames": 150,
          "ifAnimationShorter": "holdLastFrame",
          "ifAnimationLonger": "cut",
          "loop": false
        },
        {
          "variantId": "anim-1",
          "animRef": "anim-1.json",
          "defaultDurationFrames": 150,
          "ifAnimationShorter": "holdLastFrame",
          "ifAnimationLonger": "cut",
          "loop": false
        }
      ],
      "layerToggles": []
    }
  ]
}
```

### Справочник полей scene.json

#### Корневой уровень (Scene)

| Поле | Тип | Обяз. | Описание |
|------|-----|-------|----------|
| `schemaVersion` | String | да | Версия схемы. Текущая: `"0.1"` |
| `sceneId` | String | нет | Уникальный ID. Должен совпадать с именем папки. Если не задан — берётся из имени папки. |
| `canvas` | Object | да | Размеры, fps, длительность |
| `mediaBlocks` | Array | да | Массив блоков. Не может быть пустым. |

#### Canvas

| Поле | Тип | Описание |
|------|-----|----------|
| `width` | Int | Ширина в пикселях. Должно быть > 0 |
| `height` | Int | Высота в пикселях. Должно быть > 0 |
| `fps` | Int | Кадров в секунду. Должно быть > 0. Должно совпадать с fps в Lottie. |
| `durationFrames` | Int | Длительность сцены в кадрах. Должно быть > 0 |

#### MediaBlock

| Поле | Тип | Обяз. | Описание |
|------|-----|-------|----------|
| `blockId` | String | да | Уникальный ID блока внутри сцены |
| `zIndex` | Int | да | Порядок отрисовки (0 = задний план) |
| `rect` | Object | да | Логические границы блока на канве `{x, y, width, height}` в пикселях (Double). Width/height > 0. Используется как clip-прямоугольник (при `containerClip != "none"`) и bounds для UI/тапа. **Сама анимация рисуется по координатам Lottie root-слоя, а не по этому `rect`** — см. раздел «Связь rect блока и Lottie-координат». |
| `containerClip` | String | да | Режим обрезки: `"none"`, `"slotRect"`, `"slotRectAfterSettle"`. При `"none"` clip по `rect` не применяется. |
| `timing` | Object | нет | Окно видимости `{startFrame, endFrame}`. Если не задано — виден всё время. Правило: `0 <= startFrame < endFrame <= durationFrames` |
| `input` | Object | да | Настройки слота для пользовательского медиа |
| `variants` | Array | да | Варианты анимаций. Не может быть пустым. |
| `layerToggles` | Array | нет | Переключаемые декоративные слои |

#### MediaInput (input)

Соответствует Codable-модели `TVECore/Sources/TVECore/Models/MediaInput.swift`. Поля, которых нет в модели, при декодировании молча игнорируются (в частности, `input.rect` в модели **отсутствует** — не добавляйте его).

| Поле | Тип | Обяз. | Описание |
|------|-----|-------|----------|
| `bindingKey` | String | да | Имя binding-слоя в Lottie. Не может быть пустым. |
| `hitTest` | String | нет | Режим определения тапа: `"mask"` (точная маска) или `"rect"` (прямоугольник) |
| `allowedMedia` | Array | да | Допустимые типы медиа: `"photo"`, `"video"`, `"color"`. Не может быть пустым. Без дубликатов. |
| `emptyPolicy` | String | нет | Поведение при отсутствии медиа: `"hideWholeBlock"` или `"renderWithColorFallback"` |
| `fitModesAllowed` | Array | нет | Допустимые режимы вписывания: `"cover"`, `"contain"`, `"fill"` |
| `defaultFit` | String | нет | Режим по умолчанию: `"cover"`, `"contain"` или `"fill"` |
| `userTransformsAllowed` | Object | нет | `{pan: Bool, zoom: Bool, rotate: Bool}` — какие трансформы доступны пользователю |
| `audio` | Object | нет | `{enabled: Bool, gain: Double}` — настройки аудио для видео-вставок |
| `maskRef` | String | нет | Ссылка на маску из каталога масок (для UI) |

#### Variant

| Поле | Тип | Обяз. | Описание |
|------|-----|-------|----------|
| `variantId` | String | да | Уникальный ID варианта |
| `animRef` | String | да | Путь к Lottie-файлу относительно корня сцены. Не может быть пустым. |
| `defaultDurationFrames` | Int | нет | Длительность по умолчанию. Если задано — должно быть > 0 |
| `ifAnimationShorter` | String | нет | Если анимация короче: `"holdLastFrame"`, `"cut"`, `"loop"` |
| `ifAnimationLonger` | String | нет | Если анимация длиннее: `"holdLastFrame"`, `"cut"`, `"loop"` |
| `loop` | Bool | нет | Зацикливание |
| `loopRange` | Object | нет | `{startFrame, endFrame}` — диапазон зацикливания. Правило: `0 <= startFrame < endFrame` |

#### LayerToggle

| Поле | Тип | Обяз. | Описание |
|------|-----|-------|----------|
| `id` | String | да | ID переключателя. Не может быть пустым. Должен совпадать с `<id>` в имени Lottie-слоя `toggle:<id>`. Уникален в пределах блока. |
| `title` | String | да | Отображаемое название. Не может быть пустым. |
| `group` | String | нет | Группировка в UI |
| `defaultOn` | Bool | да | Включён по умолчанию |

### Связь `rect` блока и Lottie-координат

Это самый неочевидный момент при многоблочных сценах. Два независимых источника координат:

1. **Lottie root-слой** (`layers[0]`) — определяет, **где фактически рисуется анимация** на канве. Эффективный верхний-левый угол блока = `p − a` (позиция минус anchor) root-слоя.
2. **`rect` блока в `scene.json`** — логические границы: clip-прямоугольник (`pushClipRect(block.rectCanvas)` в `SceneRenderPlan.swift`) и bounds для UI/тапа.

**Правило согласования:** `rect.{x,y}` должен совпадать с `p − a` root-слоя, а `rect.{width,height}` — с размером блока в Lottie. Иначе:
- при `containerClip: "none"` — рассогласование не даёт ошибки компиляции, но clip/тап и рисунок разъедутся (логически блок в одном месте, картинка в другом);
- при `containerClip: "slotRect"` / `"slotRectAfterSettle"` — анимация будет обрезана по `rect`, и при несовпадении часть контента исчезнет.

**Как посчитать `rect` из готового Lottie:** взять `p` и `a` root-слоя (`.layers[0].ks.p.k`, `.layers[0].ks.a.k`), тогда `rect.x = p.x − a.x`, `rect.y = p.y − a.y`. Размер блока — из `w`/`h` root-слоя или габаритов precomp.

Пример (блок 540×640 в позиции `p=[810,320]`, `a=[270,320]`): `rect.x = 810−270 = 540`, `rect.y = 320−320 = 0` → `rect = {x:540, y:0, width:540, height:640}`.

mediaInput внутри precomp задаётся в **локальных** координатах своей композиции (например центр `[270,320]` для ячейки 540×640) — он не привязан к canvas-позиции блока, его смещает root-слой.

### Несколько блоков

Для многоблочной сцены — добавить объекты в массив `mediaBlocks` с разными `blockId`, `zIndex` и `rect`. Каждый блок — свои варианты и свой `bindingKey`.

В многоблочной структуре каждый файл `block_0N/no-anim.json` — самодостаточная одноблочная композиция своего блока: его root-слой уже спозиционирован в нужную ячейку канвы, а `animRef` в `scene.json` указывает на `block_0N/no-anim.json`.

Пример сетки 2x2:

```json
{ "blockId": "block_01", "zIndex": 0, "rect": { "x": 0, "y": 0, "width": 540, "height": 960 }, ... }
{ "blockId": "block_02", "zIndex": 1, "rect": { "x": 540, "y": 0, "width": 540, "height": 960 }, ... }
{ "blockId": "block_03", "zIndex": 2, "rect": { "x": 0, "y": 960, "width": 540, "height": 960 }, ... }
{ "blockId": "block_04", "zIndex": 3, "rect": { "x": 540, "y": 960, "width": 540, "height": 960 }, ... }
```

---

## Шаг 3. Разместить изображения

Компилятор резолвит изображения по **basename** (имя файла без расширения). Порядок поиска:

1. Локальные `SceneSources/<scene_id>/images/` — приоритет
2. `SharedAssets/` (рекурсивно, включая подпапки) — fallback

| Правило | Детали |
|---------|--------|
| Форматы | `.png`, `.jpg`, `.jpeg`, `.webp` |
| Уникальность | Basename уникален в пределах каждого индекса. Нельзя: `SharedAssets/a/bg.png` + `SharedAssets/b/bg.png` |
| Case-sensitive | `plastik` != `Plastik` |
| Binding-ассеты | Файл для binding-слоя **не нужен и не проверяется** (подставляется в рантайме). Поле `p` ассета может ссылаться на несуществующий файл — это не ошибка. Прочие image-ассеты — файл обязателен. |

Скрипт компиляции автоматически копирует `images/` из SceneSources в Resources/Scenes через rsync.

---

## Шаг 4. Скомпилировать сцену

### Все сцены разом

```bash
./Scripts/compile_scenes.sh
```

Скрипт находит все папки с `scene.json` в `SceneSources/`, компилирует каждую, копирует изображения и кладёт `compiled.tve` в `AnimiApp/Resources/Scenes/<scene_id>/`.

```bash
./Scripts/compile_scenes.sh --clean    # Удалить старые compiled.tve перед компиляцией
./Scripts/compile_scenes.sh --verify   # Только проверить что compiled.tve существуют и images синхронизированы
```

### Одна сцена вручную

```bash
cd TVECore
swift run TVETemplateCompiler \
  --input ../SceneSources/<scene_id> \
  --output ../AnimiApp/Resources/Scenes/<scene_id> \
  --shared ../SharedAssets
```

**Важно:** при ручном запуске компилятор **не копирует** `images/` в output — это делает только `compile_scenes.sh` (через rsync). После ручной компиляции скопируйте папку сами:

```bash
mkdir -p ../AnimiApp/Resources/Scenes/<scene_id>/images
cp ../SceneSources/<scene_id>/images/*.png ../AnimiApp/Resources/Scenes/<scene_id>/images/
```

Затем сверьте синхронизацию: `./Scripts/compile_scenes.sh --verify` (строка `images/ in sync`). Если декоративных изображений у сцены нет — шаг копирования не нужен.

### Этапы компиляции (6 шагов)

1. Загрузка `scene.json` → `ScenePackage`
2. Загрузка всех Lottie-файлов из вариантов
3. Валидация `scene.json` (структура, диапазоны, уникальность)
4. Валидация Lottie (binding-слои, mediaInput, ассеты, слои)
5. Компиляция в IR (AnimIR, PathRegistry, MergedAssets)
6. Запись `compiled.tve` (бинарный формат: magic bytes TVE\0 + JSON payload)

При ошибках компилятор выводит коды ошибок. Полный список — в `SceneValidationCode.swift` и `AnimValidationCode.swift`.

### Частые ошибки компиляции

| Код / симптом | Причина | Решение |
|---------------|---------|---------|
| `MEDIA_INPUT_MISSING` | Слой mediaInput не найден — чаще всего неверный регистр (`mediainput` вместо `mediaInput`) или его нет в `no-anim` | Переименовать слой строго в `mediaInput`; убедиться, что он есть в edit-варианте |
| `MEDIA_INPUT_NOT_SHAPE` | mediaInput не `ty:4` | Сделать слой shape |
| `MEDIA_INPUT_NO_PATH` | В mediaInput нет ровно одного shape path | Оставить ровно один path, без Trim/Merge/Repeater |
| `mediaInputNotInSameComp` | mediaInput и binding в разных композициях | Поместить оба в одну comp (оба root или оба в одном precomp) |
| `bindingLayerNotFound` | Нет слоя с именем = `bindingKey` (регистр!) | Имя binding-слоя должно точно (с учётом регистра) совпадать с `bindingKey` |
| `bindingLayerNotImage` | binding-слой не `ty:2` | Сделать binding image-слоем |
| `ASSET_MISSING` | Декоративный image-ассет не найден по basename | Положить файл в `images/` или `SharedAssets/`. (Binding-ассеты этой ошибки не дают — они пропускаются) |
| `VARIANTS_EMPTY` | Пустой массив `variants` у блока | Добавить хотя бы один variant (минимум `no-anim`) |
| Сцена не появляется в приложении | `id` в `library.json` не совпадает с именем папки в `Resources/Scenes/`, или `sceneTypeIds` в manifest ссылается на несуществующий id | Сверить id; несоответствие приводит к **молчаливому** пропуску, без ошибки |

---

## Шаг 5. Зарегистрировать сцену в library.json

Добавить запись в `AnimiApp/Resources/Scenes/library.json`:

```json
{
  "id": "<scene_id>",
  "order": 3,
  "title": "My Scene",
  "baseDurationUs": 5000000,
  "usage": "catalog"
}
```

| Поле | Тип | Обяз. | Описание |
|------|-----|-------|----------|
| `id` | String | да | Должен совпадать с именем папки в `Scenes/`. Если папка не найдена — сцена молча пропускается при загрузке. |
| `order` | Int | да | Порядок в списке сцен |
| `title` | String | да | Отображаемое название |
| `baseDurationUs` | Int64 | да | Длительность в микросекундах. `durationFrames / fps * 1_000_000`. Примеры: 5 сек = 5000000, 10 сек = 10000000 |
| `usage` | String | нет | `"catalog"` (видна в каталоге шаблонов) или `"starterOnly"` (только как пустой стартер). По умолчанию `"catalog"`. Модель: `SceneUsage` в `SceneLibraryModels.swift`. |

Глобальные `fps` и `canvas` задаются на верхнем уровне library.json и применяются ко всем сценам.

---

## Шаг 6. Добавить шаблон в каталог

Добавить запись в `AnimiApp/Resources/Templates/Catalog/manifest.json`:

```json
{
  "id": "<template_id>",
  "categoryId": "featured",
  "order": 1,
  "title": "My Template",
  "titleKey": "template_my_template",
  "sceneTypeIds": ["<scene_id>"],
  "openBehavior": "directToEditor"
}
```

| Поле | Тип | Обяз. | Описание |
|------|-----|-------|----------|
| `id` | String | да | Уникальный ID шаблона |
| `categoryId` | String | да | ID категории из массива `categories` |
| `order` | Int | да | Порядок внутри категории |
| `title` | String | да | Отображаемое название |
| `titleKey` | String | нет | Ключ локализации (подготовлен, но пока не используется) |
| `sceneTypeIds` | Array | да | Массив `id` сцен из `library.json`. Не может быть пустым (шаблон будет молча пропущен). Порядок определяет порядок сцен в таймлайне. |
| `openBehavior` | String | да | `"previewFirst"` — сначала полноэкранное превью, потом редактор. `"directToEditor"` — сразу в редактор. |
| `previewAsset` | String | нет | Имя файла превью в `Templates/Previews/` (с расширением, напр. `"preview.mp4"`). Если файл не найден — показывается placeholder. Формат: любое видео поддерживаемое AVPlayer (.mp4, .mov). |

### Многосценный шаблон

Если `sceneTypeIds` содержит несколько ID, при создании проекта на таймлайне появятся сцены **в указанном порядке**. Один и тот же `scene_id` может повторяться — каждый экземпляр будет независимым.

```json
"sceneTypeIds": ["intro_scene", "main_scene", "main_scene", "outro_scene"]
```

Результат: таймлайн из 4 сцен, где 2-я и 3-я — независимые экземпляры одного типа.

### Новая категория

Добавить объект в массив `categories` в том же `manifest.json`:

```json
{
  "id": "my_category",
  "title": "My Category",
  "titleKey": "category_my_category",
  "order": 2
}
```

---

## Шаг 7. Собрать и проверить в Xcode

Папка `AnimiApp/Resources/Scenes/` добавлена в Xcode как folder reference — новые подпапки подхватываются автоматически. Собрать проект и проверить что шаблон появился в каталоге.

### Два разных verify-скрипта — не путать

| Скрипт | Что проверяет | Когда |
|--------|---------------|-------|
| `./Scripts/compile_scenes.sh --verify` | Наличие `compiled.tve` для всех сцен из `SceneSources/` и синхронность `images/`. Работает с исходниками, **аргументы не нужны**. | После компиляции, до сборки Xcode |
| `./Scripts/verify_release_bundle.sh <path/to/AnimiApp.app>` | Целостность собранного production-бандла: наличие `compiled.tve`, **отсутствие** исходников (`scene.json`, `anim-*.json`), наличие превью-ассетов. **Требует путь к уже собранному `.app`** — без него только печатает usage. | После Release-сборки |

Для проверки на этапе добавления шаблона (до сборки приложения) используйте `compile_scenes.sh --verify`. `verify_release_bundle.sh` без собранного `.app` запускать бессмысленно.

---

## Чеклист

### Lottie-файлы
- [ ] `no-anim.json` на каждый блок (edit-вариант). `anim-*.json` — опциональны на уровне компилятора (требуется лишь непустой `variants`), но нужны для анимации в плеере
- [ ] Canvas: 1080x1920, fps: 30, длительность совпадает с `durationFrames` в `scene.json`
- [ ] Binding-слой: `ty: 2`, имя = `bindingKey`, ровно один на блок
- [ ] mediaInput: `ty: 4`, имя = `"mediaInput"` (**проверить регистр — не `mediainput`!**), `hd: true`, ровно один path, в той же композиции что и binding
- [ ] Нет запрещённых возможностей (3D, auto-orient, time stretch, blend modes, skew)
- [ ] Используются только поддерживаемые типы слоёв (0, 2, 3, 4)
- [ ] Toggle-слои (если есть): имена `toggle:<id>`, одинаковый набор id во всех вариантах

### scene.json
- [ ] `sceneId` совпадает с именем папки
- [ ] `canvas.fps` совпадает с fps в Lottie
- [ ] `timing.endFrame` <= `canvas.durationFrames`
- [ ] `blockId` уникальны
- [ ] `bindingKey` не пустой, совпадает с именем слоя в Lottie (регистрозависимо)
- [ ] `allowedMedia` не пустой, без дубликатов
- [ ] `rect` блока согласован с Lottie root-слоём: `rect.x = p.x − a.x`, `rect.y = p.y − a.y` (см. «Связь rect блока и Lottie-координат»)
- [ ] Нет лишнего поля `input.rect` (его нет в модели `MediaInput`)
- [ ] `layerToggles[].id` совпадают с `toggle:<id>` слоями в Lottie

### Изображения
- [ ] Декоративные изображения в `images/` или `SharedAssets/`
- [ ] Basename уникален в пределах индекса
- [ ] Формат: `.png`, `.jpg`, `.jpeg`, `.webp`
- [ ] Файл для binding-ассета не нужен (валидатор его пропускает); для прочих image-ассетов — файл обязателен

### Компиляция и регистрация
- [ ] `compiled.tve` сгенерирован без ошибок и предупреждений
- [ ] При ручной компиляции: `images/` скопирован в output вручную
- [ ] `./Scripts/compile_scenes.sh --verify` → `compiled.tve exists` + `images/ in sync`
- [ ] Запись в `library.json` (id = имя папки, baseDurationUs корректен)
- [ ] Запись в `manifest.json` (sceneTypeIds ссылается на id из library.json, не пустой)
- [ ] Превью-видео в `Templates/Previews/` (опционально)
