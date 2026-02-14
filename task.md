Ниже — **глубокий трассинг** “от `plastik.png` в Lottie → до Metal blending” + **каноническое релизное ТЗ** на универсальный фикс, который будет корректно работать для **всех** будущих слоёв/шаблонов (Local/Shared assets + потенциально пользовательские PNG с альфой).

---

# 1) Трассинг: как `plastik.png` попадает в рендер

## 1.1. В шаблоне `polaroid_shared_demo` `plastik.png` — это обычный image-asset с альфой

Файл: `AnimiApp/Resources/Templates/polaroid_shared_demo/anim-1.json`
Якорь (фрагмент):

```json
{"id":"image_1","u":"images/","p":"plastik.png","e":0}
...
{"ty":2,"nm":"plastik.png","refId":"image_1", ... "bm":0}
```

Это означает: Lottie ожидает, что PNG из `images/` будет отрисован как обычная текстура (без специальных blend modes — `bm:0`).

## 1.2. Физически `plastik.png` лежит в SharedAssets, и резолвится по basename

Файл: `SharedAssets/decor/plastik.png` (basename = `plastik`).

Почему это важно: в проекте используется **resolver по basename** (без папок), который сканирует SharedAssets рекурсивно.

### SharedAssetsIndex индексирует все файлы в `SharedAssets/` по basename

`TVECore/Sources/TVECore/Assets/SharedAssetsIndex.swift`

```swift
let basename = (fileURL.lastPathComponent as NSString).deletingPathExtension
result[basename] = fileURL
```

### CompositeAssetResolver ищет сначала Local(images/), затем SharedAssets

`TVECore/Sources/TVECore/Assets/CompositeAssetResolver.swift`

```swift
if let url = localIndex.url(forKey: key) { return url }
if let url = sharedIndex.url(forKey: key) { return url }
throw AssetResolutionError.assetNotFound(...)
```

## 1.3. ScenePackageTextureProvider грузит текстуры **через MTKTextureLoader(URL)** без premultiply

`TVECore/Sources/TVECore/MetalRenderer/ScenePackageTextureProvider.swift` → `loadTexture(from:assetId:)`

```swift
let options: [MTKTextureLoader.Option: Any] = [
    .SRGB: false,
    .generateMipmaps: false,
    .textureUsage: MTLTextureUsage.shaderRead.rawValue,
    .textureStorageMode: MTLStorageMode.private.rawValue
]
return try loader.newTexture(URL: url, options: options)
```

> Ключевой факт: тут **нет** шага “перевести PNG в premultiplied-alpha”. Комментарий “Load with options for premultiplied alpha” — но фактически это не делает premultiply.

## 1.4. Рендер-пайплайн настроен на **premultiplied alpha blending**

`TVECore/Sources/TVECore/MetalRenderer/MetalRendererResources.swift` → `configureBlending()`

```swift
attachment.sourceRGBBlendFactor = .one
attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
attachment.sourceAlphaBlendFactor = .one
attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
```

Это формула **premultiplied “over”**:

* `out.rgb = src.rgb + dst.rgb * (1 - src.a)`
* корректно только если `src.rgb` уже **умножен на src.a**.

## 1.5. Фрагмент-шейдер quad НЕ делает premultiply

`TVECore/Sources/TVECore/MetalRenderer/Shaders/QuadShaders.metal` → `quad_fragment`

```metal
float4 color = tex.sample(samp, in.texCoord);
// Premultiplied alpha: multiply all channels by opacity
return color * in.opacity;
```

Он лишь умножает на opacity, но не делает `color.rgb *= color.a`.

---

# 2) Корневая причина (строго по коду)

**Renderer ожидает premultiplied-alpha текстуры (см. blending factors), но PNG-ассеты грузятся как straight alpha и подаются в quad_fragment без конверсии.**

Именно поэтому слой “пластик/плёнка” визуально становится “залитым” — при малой альфе RGB остаётся ярким и добавляется почти целиком из-за `.one` в `sourceRGBBlendFactor`.

---

# 3) Каноническое ТЗ на релизный универсальный фикс

## 3.1. Цель

Сделать так, чтобы **все image-текстуры с альфой**, используемые в рендеринге (Local assets + SharedAssets + потенциально пользовательские PNG), имели **одну каноническую альфа-конвенцию**: **premultiplied alpha**.

Это должно быть:

* универсально (не “фикс для plastik.png”)
* безопасно (не ломает случаи без альфы)
* предсказуемо для будущих blend modes / экспортов
* “release-quality” по производительности (особенно с `.private` текстурами и preloadAll)

## 3.2. Каноническое решение (рекомендовано)

**Переводить PNG/JPEG/WebP → premultiplied RGBA/BGRA на этапе загрузки** в едином месте (Texture Provider / Texture Factory), а не в шейдерах.

Почему:

* blending уже premult во всём движке (см. `configureBlending`)
* конверсия в шейдере рискованна: можно “double premultiply” если где-то источник уже premult
* единый CPU/Decode слой проще тестировать и гарантировать поведение

---

# 4) Конкретные задачи для программиста

## A) Добавить единый “PremultipliedTextureLoader” (новый модуль/файл в TVECore)

**Новый файл:** `TVECore/Sources/TVECore/Assets/PremultipliedTextureLoader.swift` (или `MetalRenderer/` — на ваше усмотрение, но лучше рядом с Assets/Texture loading)

### Требования к API

* Вход: `URL`, `device`, `commandQueue`
* Выход: `MTLTexture` **в premultiplied BGRA/RGBA** (канонично: `.bgra8Unorm`)
* Должен поддерживать:

  * PNG с альфой (главный кейс)
  * PNG без альфы (просто работает)
  * JPG (альфы нет)
  * WebP (если iOS декодер отдаёт CGImage — ок; если нет, то fallback на MTKTextureLoader как сейчас)

### Алгоритм (канонический)

1. Декодировать `CGImage` через `CGImageSourceCreateWithURL`
2. Создать `CGContext` с:

   * `CGColorSpaceCreateDeviceRGB()`
   * `bitmapInfo = byteOrder32Little + premultipliedFirst` (это BGRA premult)
3. Нарисовать CGImage в этот контекст (тем самым получить **premultiplied** пиксели)
4. Создать **staging buffer** (`MTLBuffer`, `.storageModeShared`) и залить туда bytes
5. Создать итоговую `MTLTexture` **storageMode `.private`**, usage `.shaderRead`
6. Blit-copy из buffer → private texture через `commandQueue.makeCommandBuffer() + blitEncoder.copy(...)`
7. `commandBuffer.commit()` + `waitUntilCompleted()` (preload синхронный — контракт уже такой)

**Важно:** это сохранит текущий perf-интент `.private` из `ScenePackageTextureProvider`.

---

## B) Внедрить этот loader в `ScenePackageTextureProvider`

Файл: `TVECore/Sources/TVECore/MetalRenderer/ScenePackageTextureProvider.swift`

### Изменения

1. В `init` добавить зависимость `commandQueue: MTLCommandQueue` (или передавать его в `preloadAll(commandQueue:)` — второй вариант лучше, если не хотите хранить queue в провайдере)

2. Заменить:

```swift
return try loader.newTexture(URL: url, options: options)
```

на:

* попытку загрузить через новый premult-loader
* fallback на MTKTextureLoader только если CGImageSource не смог (например webp/неподдерживаемые случаи)

### Почему нужен commandQueue именно здесь

Потому что сейчас вы создаёте `.private` текстуры. В `.private` нельзя безопасно `replaceRegion` с CPU, поэтому нужен staging+blit.

---

## C) (Рекомендовано) Привести `UserMediaTextureFactory` к той же конвенции для PNG с альфой

Файл: `AnimiApp/Sources/UserMedia/UserMediaTextureFactory.swift`

Сейчас `makeTexture(from image: UIImage)` делает:

```swift
return try textureLoader.newTexture(cgImage: cgImage, options: options)
```

Это может быть “иногда норм”, но для универсальности (стикеры/PNG-оверлеи пользователя с альфой) лучше:

* прогонять `cgImage` через тот же premult контекст
* заливать в `.private` (или оставить `.shared`, если UI-слой требует CPU-доступ, но тогда это нужно явно задокументировать)

Видео (`CVPixelBuffer`) — обычно без альфы, можно оставить как есть.

---

# 5) Acceptance Criteria (обязательные проверки)

## 5.1. Функциональные

1. `polaroid_shared_demo` слой `plastik.png` в edit/preview отображается **полупрозрачным**, как в исходном дизайне.
2. Любой PNG с альфой в **SharedAssets** и **Local images/** ведёт себя корректно.
3. Никакие PNG без альфы / JPG не ломаются.

## 5.2. Технические/архитектурные

1. Весь рендер остаётся на **premultiplied blending** (не менять `configureBlending`).
2. Конверсия straight→premult происходит **один раз** на этапе загрузки.
3. Все ассеты в `ScenePackageTextureProvider.preloadAll()` после фикса по-прежнему грузятся в `.private` (как сейчас).
4. В runtime `texture(for:)` остаётся IO-free cache lookup (не меняем контракт).

## 5.3. Тест (очень желательно, чтобы это было “релизно”)

Добавить простой тест/смоук:

* грузим PNG с альфа-градиентом
* рендерим на фоне (шахматка или цвет)
* проверяем, что пиксели соответствуют ожидаемому premult поведению (хотя бы 2–3 sample точки)

---

# 6) Минимальный план изменений по файлам

1. **NEW** `TVECore/Sources/TVECore/Assets/PremultipliedTextureLoader.swift`
2. **MOD** `TVECore/Sources/TVECore/MetalRenderer/ScenePackageTextureProvider.swift`

   * добавить commandQueue dependency
   * заменить внутренний loadTexture
3. **MOD (желательно)** `AnimiApp/Sources/UserMedia/UserMediaTextureFactory.swift`

   * унифицировать поведение для PNG с альфой

---

Если хочешь, я могу прямо следующим сообщением оформить это как **готовый PR-документ** для программиста (в стиле вашего проекта: “контракт/инварианты/код-якоря/риски/план миграции/чеклист”), чтобы его можно было без редактирования закинуть в GitHub как описание задачи.
