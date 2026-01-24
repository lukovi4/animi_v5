* **Конфиг SwiftLint не подхватывался**, потому что запуск был из `TVECore/` — верно. Это типичная ловушка: SwiftLint ищет `.swiftlint.yml` относительно current working directory.
* `superfluous_disable_command` — логично: ты отключал правило там, где конфиг уже исключает `x/y/ip/op/st`.
* `prefer_self_in_static_references`, `empty_count`, `cyclomatic_complexity` — фиксы верные и “по стандарту”.

---

## Обязательное улучшение процесса (чтобы CI больше не падал)

### 1) Добавить “единый” командный entrypoint в репо

В корне репозитория (`animi/`) добавить один из вариантов:

**Вариант A (лучший): Makefile**

* `make lint` → запускает SwiftLint из корня
* `make test` → swift test / xcodebuild test
* `make ci` → lint + test + build

**Вариант B: Scripts**
`Scripts/lint.sh`:

* `cd "$(git rev-parse --show-toplevel)"`
* `swiftlint lint --strict TVECore/Sources TVECore/Tests AnimiApp`

Это убирает человеческий фактор “запустил не оттуда”.

### 2) Добавить это в README (коротко)

Раздел `Local checks before push`:

* `make ci` (или `./Scripts/ci.sh`)
* если без make — перечисление команд

---

## Что делать разработчику дальше (политика на будущее)

**Перед каждым пушем/PR:**

1. запуск из корня репо `swiftlint lint --strict ...`
2. `swift test` (TVECore)
3. `xcodebuild build` (AnimiApp)

И если хочется прям железно — можно поставить pre-push git hook, но это опционально.

---

Для **PR4.1** фиксируем так, чтобы это **на 100% совпадало с CI** и не ломалось от отсутствия конкретного симулятора.

## Что использовать для `make build`

### ✅ Рекомендованный вариант (стабильный)

Используем **generic destination**, как в CI:

```bash
xcodebuild build \
  -project AnimiApp/AnimiApp.xcodeproj \
  -scheme AnimiApp \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO
```

Почему:

* не зависит от “iPhone 15/16” и установленного runtime,
* повторяет твою CI-политику (мы уже так сделали в PR0/PR1),
* работает и локально, и на машинах без нужного симулятора.

### ❌ Не рекомендую фиксировать `name=iPhone 15`

Это хрупко: на машине может быть только iPhone 14 или другой runtime, и локальный `make build` начнёт падать “не найден destination”.

## Scheme

* **`-scheme AnimiApp`** — да, всегда явно указываем.
* Workspace/Package не нужен.

---

## Мини-шаблон для Makefile целей (чтобы программисту было проще)

* `lint`: запуск SwiftLint **из корня**
* `test`: `swift test` внутри `TVECore`
* `build`: `xcodebuild build ... generic`
* `ci`: последовательно `lint test build`

И в README в разделе “Local checks before push” пишем одну команду:

* `make ci`

---

Используем **generic destination** — это самый стабильный и должен совпадать с вашим CI.

✅ В `make build` фиксируем так:

```bash
xcodebuild build \
  -project AnimiApp/AnimiApp.xcodeproj \
  -scheme AnimiApp \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO
```

Почему именно так:

* `name=iPhone 16` — **хрупко** (на машине/CI может не быть такого симулятора).
* `OS=latest,name=Any iOS Simulator Device` — это не “канонический” стабильный формат и тоже может вести себя по-разному.
* `generic/platform=iOS Simulator` — **не привязан к модели** и обычно работает везде.

Если хочешь максимально “один-в-один с CI” — просто **используй ровно ту же строку**, что в `.github/workflows/ci.yml`.