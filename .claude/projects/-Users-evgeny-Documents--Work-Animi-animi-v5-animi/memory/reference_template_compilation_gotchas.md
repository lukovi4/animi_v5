---
name: reference-template-compilation-gotchas
description: Стабильные не-очевидные факты про компиляцию/добавление шаблонов Animi (regression-prone). Canonical doc — Docs/adding-templates.md
metadata:
  type: reference
---

Не-очевидные факты при добавлении шаблона/сцены. Подробные пошаговые инструкции — в `Docs/adding-templates.md` (canonical, читать его). Здесь только то, что часто ломается или контринтуитивно:

1. Имена `mediaInput` и `bindingKey` сравниваются **регистрозависимо** (`layer.name == ...`). `mediainput` (lowercase) → компилятор не находит слой → `MEDIA_INPUT_MISSING`. Частая ошибка экспортёров Lottie.
2. Поля `input.rect` **не существует** в Codable-модели `MediaInput.swift` — при декодировании молча игнорируется. `rect` живёт на уровне блока (`MediaBlock.rect`).
3. Rect блока и Lottie root-координаты должны быть согласованы: анимация рисуется по Lottie root-слою (эффективная позиция = `p − a`); `rect` блока задаёт только clip-прямоугольник (при `containerClip != none`) и bounds для UI/тапа. Формула: `rect.x = p.x − a.x`, `rect.y = p.y − a.y`.
4. Binding image-ассет **не требует файла** на диске (валидатор пропускает binding-ассеты, текстуру ставит юзер в рантайме; поле `p` может ссылаться на несуществующий файл). Любой **другой** image-ассет (декор) — файл обязателен, иначе `ASSET_MISSING`.
5. `library.json` поле `usage` поддерживает `catalog` / `starterOnly` (опционально, дефолт `catalog`; `SceneUsage` в `SceneLibraryModels.swift`).
6. `anim-*` вариант не обязателен на уровне компилятора (нужен лишь непустой `variants`; пустой → `VARIANTS_EMPTY`). На практике `no-anim` нужен для edit-режима, `anim-*` — для анимации в плеере.
7. Два разных verify-скрипта: `compile_scenes.sh --verify` (проверяет исходники: `compiled.tve` + синхронность `images/`, без аргументов) vs `verify_release_bundle.sh <path/to/.app>` (целостность собранного бандла, требует путь к `.app`).
8. Ручной запуск `swift run TVETemplateCompiler` **не копирует** `images/` в output — это делает только `compile_scenes.sh` (rsync). После ручной компиляции копировать `images/` вручную.
