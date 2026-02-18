Ниже — **финальное каноническое ТЗ** на “Главную” и “Внутреннюю страницу шаблона”, **строго опираясь на реальный snapshot-код** и на **утверждённые нами решения** (manifest в bundle, IDs строковые, mp4 previews, autoplay только видимых, loop, звук off, openBehavior per-template, See all grid 2 колонки, details full-screen + Close + Use template).

---

# Техническое задание PR: Templates Home + Template Details (UIKit, bundle catalog)

## 0) Scope (что делаем в этом PR)

### Нужно сделать

1. **Главная страница TemplatesHome**:

   * Категории (вертикальный список секций)
   * В каждой секции: заголовок категории + кнопка **See all** справа
   * Под заголовком: **горизонтальный слайдер** карточек шаблонов, где на экране **видно ровно 2 карточки**; остальные уходят вправо (20+ шт. ок)
   * Карточка = **только preview.mp4** (без title на home v1), **1080×1920 пропорции**, видео **loop + autoplay**, **звук off**
   * Autoplay **только для видимых** карточек, стоп на скролле/уходе с экрана
   * Экран поддерживает состояния: `loading / empty / error / content`

2. **Экран Category “See all”**:

   * Показывает все шаблоны категории в **grid 2 колонки**
   * Карточка = preview.mp4 (loop+autoplay, звук off) + те же правила “только видимые”
   * Состояния: `loading / empty / error / content` (empty — если в категории 0; но пустые категории на Home не показываем)

3. **Экран Template Details (full-screen preview)**:

   * Full-screen preview видео (тот же preview.mp4) **loop + autoplay**, звук off
   * Кнопка **Close**: возвращает на главную (поп/close)
   * Кнопка **Use template**: открывает редактор (TemplateEditor flow)
   * Экран поддерживает состояния: `loading / error` (контент появится после загрузки template descriptor)

4. **Навигация UIKit**

   * Root приложения должен стать `UINavigationController`
   * Стартовый экран: TemplatesHomeViewController
   * Переходы:

     * Home → See all
     * Home/See all → Details (или напрямую в Editor, если openBehavior=directToEditor)
     * Details → Use template → Editor

### Не делаем в этом PR

* Стили/дизайн-система (в конце проекта подключим отдельно)
* Фильтры/поиск (только архитектурная готовность)
* Remote catalog (только архитектурная готовность)
* Реальный рендер шаблонов для превью (используем готовые `preview.mp4`)

---

## 1) Обоснование по реальному коду snapshot (code anchors)

### 1.1 Текущий app entrypoint — UIKit root VC

Сейчас root задаётся напрямую `PlayerViewController()` без навигации:

**`AnimiApp/Sources/App/SceneDelegate.swift`**

```swift
let window = UIWindow(windowScene: windowScene)
let playerViewController = PlayerViewController()
window.rootViewController = playerViewController
window.makeKeyAndVisible()
```

➡️ Требуемое изменение: вместо `PlayerViewController()` поставить `UINavigationController(rootViewController: TemplatesHomeViewController())`.

---

### 1.2 Реальный шаблонный контент сейчас лежит в bundle subdirectory "Templates"

Загрузка compiled templates уже реализована через `Bundle.main.url(..., subdirectory: "Templates")`:

**`AnimiApp/Sources/Player/PlayerViewController.swift` (loadCompiledTemplateFromBundle)**

```swift
guard let templateURL = Bundle.main.url(
  forResource: templateName, withExtension: nil, subdirectory: "Templates"
) else { ... }
let compiledLoader = CompiledScenePackageLoader(engineVersion: TVECore.version)
let compiledPackage = try compiledLoader.load(from: templateURL)
```

➡️ Это задаёт каноничный подход для **bundle-based каталога**: и compiled.tve, и preview.mp4 должны быть доступны по предсказуемым относительным путям из bundle.

---

### 1.3 Редактор уже существует и ожидает ScenePlayer/CanvasSize

Контроллер редактора уже в проекте (UIKit/TVECore), и его контракт зафиксирован:

**`AnimiApp/Sources/Editor/TemplateEditorController.swift`**

```swift
@MainActor final class TemplateEditorController {
  func setPlayer(_ player: ScenePlayer) { ... }
  var canvasSize: SizeD = .zero
  func currentRenderCommands() -> [RenderCommand]? { ... }
}
```

➡️ Наши новые экраны должны **не ломать** существующий editor flow: “Use template” будет создавать/открывать editor, который дальше использует `ScenePlayer` и compiled template.

---

## 2) Bundle Catalog: структура ресурсов (канонично)

### 2.1 Новая структура ресурсов в bundle

Добавить в `AnimiApp/Resources`:

```
Resources/Templates/
  Catalog/
    manifest.json
  Items/
    <templateId>/
      compiled.tve
      preview.mp4
      (опционально) meta.json
```

> Примечание: сейчас в snapshot уже есть `Resources/Templates/<templateId>/compiled.tve` и scene.json и т.п.
> В этом PR допускается:
>
> * либо **переложить** в `Templates/Items/<id>/...`
> * либо оставить существующие папки, но manifest должен указывать корректные relative paths.
>   (предпочтительно привести к `Catalog/` + `Items/` ради релизной структуры)

---

## 3) Manifest contract (расширяемый)

### 3.1 JSON schema (v1)

`manifest.json` содержит:

* массив категорий (контролируемый порядок)
* массив шаблонов (контролируемый порядок, привязка к категории)

Обязательные поля:

**Category**

* `id: String` (CategoryID)
* `title: String` (fallback для v1)
* `titleKey: String?` (для будущей локализации)
* `order: Int`

**Template**

* `id: String` (TemplateID, напр. `"polaroid_shared_demo"`)
* `categoryId: String`
* `order: Int`
* `title: String` (храним на будущее, не показываем на home v1)
* `titleKey: String?` (будущая локализация)
* `compiledPath: String` (relative path, напр. `"Templates/Items/polaroid_shared_demo/compiled.tve"`)
* `previewVideoPath: String` (relative path, напр. `"Templates/Items/polaroid_shared_demo/preview.mp4"`)
* `openBehavior: String` enum

  * `"previewFirst"` (тап открывает Details)
  * `"directToEditor"` (тап сразу открывает Editor)

### 3.2 Правила расширения

* Новые поля добавляем **без ломания** существующих (JSON decoding с default)
* Нельзя менять семантику `id/categoryId/order/paths` без миграции (в будущем, если будет remote)

---

## 4) Data layer: TemplateCatalog (единый источник правды)

### 4.1 Новые файлы (AnimiApp/Sources/TemplatesCatalog/*)

Создать модульный слой (без лишних абстракций, но релизно):

**Models**

* `TemplateID = String`
* `CategoryID = String`
* `TemplateOpenBehavior` enum
* `TemplateDescriptor`
* `TemplateCategory`
* `TemplateCatalogSnapshot` (categories + templates)

**Loader**

* `BundleTemplateCatalogLoader`

  * `func loadManifest() throws -> TemplateCatalogSnapshot`
  * грузит `Bundle.main.url(forResource: "manifest", withExtension: "json", subdirectory: "Templates/Catalog")`
  * резолвит `compiledURL`/`previewURL` через `Bundle.main.url(forResource:..., subdirectory: ...)` либо через `bundle.url(forResource:)` + `URL(fileURLWithPath:)` (на выбор исполнителя), но результатом должны быть **валидные URL на файлы в bundle**

**Repository (внутренний)**

* `TemplateCatalog`

  * хранит in-memory snapshot
  * API:

    * `load() async` (возвращает snapshot)
    * `categoriesInOrder()`
    * `templatesForCategory(_:)`
    * `template(by id: TemplateID)`

### 4.2 Состояния загрузки

Слой UI должен иметь state-машину:

`enum LoadState<T> { case loading, content(T), empty, error(String) }`

Правила:

* `empty` только если после фильтрации/валидации итоговый список категорий пуст
* Пустые категории **не включать** в content для Home

---

## 5) UI: экраны и поведение

## 5.1 TemplatesHomeViewController

**Секция категории**

* Заголовок (UILabel) + кнопка `See all`
* Ниже: горизонтальный collection view (или embedded collection внутри table/collection секций)

**Карточка шаблона (Home)**

* Только video preview
* Aspect ratio 1080:1920, **вписать** (не растягивать)
* Автоплей/луп/звук off

**Навигация**

* Tap по карточке:

  * если template.openBehavior == `directToEditor` → open editor
  * если `previewFirst` → push TemplateDetailsViewController(templateId)

**Состояния**

* loading: системный индикатор/плейсхолдер
* error: заглушка + кнопка Retry (опционально)
* empty: заглушка “No templates”

---

## 5.2 CategoryTemplatesViewController (See all)

* Заголовок = category title/titleKey
* Grid 2 колонки (UICollectionViewFlowLayout)
* Те же карточки preview.mp4
* Tap behavior: как на Home (per-template openBehavior)

---

## 5.3 TemplateDetailsViewController

* Full-screen video preview (preview.mp4)
* Loop + autoplay, звук off
* **Close**: возвращает на Home (navigationController?.popViewController или dismiss — зависит от способа показа; в v1 используем push → значит pop)
* **Use template**: открывает editor (push)

---

## 6) Video preview implementation (релизные правила)

### 6.1 Требования

* Звук всегда off
* Loop всегда on
* Autoplay только когда карточка **видима**
* Stop/pause при:

  * уходе карточки с экрана
  * уходе экрана (viewWillDisappear)
  * быстрый скролл

### 6.2 Реализация (без оверинжиниринга)

Создать `PreviewVideoView` или `PreviewVideoPlayer`:

* внутри `AVPlayer` + `AVPlayerLayer`
* методы:

  * `configure(url:)`
  * `play() / pause()`
  * `setMuted(true)`
  * loop через `NotificationCenter` (AVPlayerItemDidPlayToEndTime → seek(to: .zero) + play) **только если view still visible**

Для коллекции:

* `willDisplay cell` → play
* `didEndDisplaying cell` → pause + optionally nil out playerItem
* при `scrollViewDidEndDecelerating` / `scrollViewDidEndDragging` можно “доподжать” play для видимых

---

## 7) Навигация и интеграция с существующим кодом

### 7.1 Обязательное изменение

**`AnimiApp/Sources/App/SceneDelegate.swift`**

* заменить root на `UINavigationController`
* стартовый VC: `TemplatesHomeViewController`

Это строго следует текущей UIKit-архитектуре snapshot (см. anchor 1.1).

### 7.2 Переиспользование PlayerViewController

`PlayerViewController` сейчас — debug/engine playground и имеет свою UI-обвязку (segmented control, export, etc.).
В этом PR:

* **не использовать PlayerViewController как Home/Details**
* Editor остаётся как отдельный flow (уже есть `TemplateEditorController`)

---

## 8) Acceptance Criteria (что считается “готово”)

1. Приложение стартует в Home (TemplatesHome) внутри UINavigationController.
2. Home показывает категории в порядке `order`, пустые категории скрыты.
3. В каждой категории горизонтальный слайдер:

   * на экране видно ровно 2 карточки
   * можно скроллить вправо
4. Видео в карточках:

   * autoplay + loop
   * mute
   * играет только у видимых карточек; уехала — остановилась
5. See all открывается из кнопки и показывает grid 2 колонки для выбранной категории.
6. Tap по карточке работает per-template:

   * directToEditor → сразу editor
   * previewFirst → details
7. Details:

   * full-screen preview (loop/autoplay/mute)
   * Close возвращает на Home
   * Use template открывает editor
8. Поддержаны состояния loading/empty/error на всех 3 экранах (Home/SeeAll/Details), источником правды является Catalog load.

---

## 9) Изменения/добавления файлов (конкретно)

### Изменить

* `AnimiApp/Sources/App/SceneDelegate.swift` — root navigation + Home

### Добавить (примерная структура)

* `AnimiApp/Sources/TemplatesCatalog/TemplateModels.swift`
* `AnimiApp/Sources/TemplatesCatalog/BundleTemplateCatalogLoader.swift`
* `AnimiApp/Sources/TemplatesCatalog/TemplateCatalog.swift`
* `AnimiApp/Sources/TemplatesUI/TemplatesHomeViewController.swift`
* `AnimiApp/Sources/TemplatesUI/CategoryTemplatesViewController.swift`
* `AnimiApp/Sources/TemplatesUI/TemplateDetailsViewController.swift`
* `AnimiApp/Sources/TemplatesUI/PreviewVideoView.swift`
* `AnimiApp/Sources/TemplatesUI/Cells/TemplatePreviewCell.swift`
* `AnimiApp/Resources/Templates/Catalog/manifest.json`
* * `preview.mp4` файлы в `Resources/Templates/Items/<id>/preview.mp4`

---

Если хочешь, следующим сообщением я сразу дам **готовый `manifest.json` шаблон (пример)** + точную разметку размеров для “ровно 2 карточки на экране” (формулы для itemSize/sectionInsets/spacing), но это уже будет сверх ТЗ.
