Выбирать нужно **B**, но не в том виде, как вы его сформулировали, и точно **не C**.

**Каноническое решение**
- `clampedLocalFrame` **не открывать** из `private` в `internal`.
- Для `makeRenderContext` и `renderCommands` делать **behavior tests на реальном `SceneInstanceRuntime`**, собранном из **минимального in-memory `CompiledScene`**, а не из файловых `ScenePackages`.
- Для forwarding в `UserMediaService` делать **узкий test seam**, а не тянуть full package assets.

**Почему именно так**
- `A` слишком тяжёлый и хрупкий. Тесты на реальные `ScenePackages` и диск:
  - медленнее,
  - зависят от ассетов и структуры пакетов,
  - ближе к integration/UI regression, чем к unit/contract.
- `C` недостаточен. Это снова тестирует формулу, а не production behavior.
- `B` даёт правильный баланс:
  - тест идёт через **реальный production path** `SceneInstanceRuntime`,
  - не зависит от дисковых scene packages,
  - детерминирован,
  - быстро выполняется.

**Что делать**
1. Для `makeRenderContext` и `renderCommands`:
- собрать минимальный `CompiledScene` вручную через `TVECore` модели;
- положить его в `SceneTypeResourcesCache.Resources`;
- создать реальный `SceneInstanceRuntime` с `MTLCreateSystemDefaultDevice()` и `makeCommandQueue()`;
- проверить:
  - `makeRenderContext(localFrame: 350).localFrame == 299`
  - `renderCommands(localFrame: 299, mode: .preview) == renderCommands(localFrame: 350, mode: .preview)`

2. Для `syncVideoFrame`, `syncPlaybackTick`, `startPlayback`:
- не менять visibility helper’а;
- добавить **test-only seam для media service injection** в [SceneInstanceRuntime.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/TimelineComposition/SceneInstanceRuntime.swift)
- лучший вариант:
  - маленький internal protocol, который покрывает только нужные методы
  - `UserMediaService` ему соответствует
  - internal init для тестов принимает injected service
- дальше spy проверяет, что в сервис ушёл `299`, а не `350`

**Чего не делать**
- не делать `clampedLocalFrame` internal только ради тестов
- не тащить файловые `TestAssets/ScenePackages` в основной contract suite
- не ограничиваться pure helper tests

**Итог**
- для behavior test: **B**
- для forwarding test: **spy через injected seam**
- `C` отклонить
- `A` оставить только как optional integration test, не как основной способ закрытия acceptance gap

Если нужно, следующим сообщением я могу дать **точный final test plan по файлам и API seam**, без вариантов выбора.