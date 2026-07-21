# displayctl

[English version](README.md)

`displayctl` — консольная утилита на Swift для просмотра и управления Apple
Studio Display и Apple Studio Display XDR в macOS.

Она обращается напрямую к CoreGraphics и динамически загружаемым системным
фреймворкам дисплеев. Утилита не открывает System Settings и не эмулирует
нажатия мышью.

Приложение создано с помощью OpenAI Codex под руководством автора проекта,
который определял требования и проверял работу утилиты на реальных дисплеях
Apple.

## Возможности

- Находит подключённые поддерживаемые дисплеи и присваивает им порядковые
  номера.
- Показывает роль дисплея, CoreGraphics ID, серийный номер, прошивку,
  зеркалирование, активный референсный профиль, частоту, Retina-разрешение,
  яркость, автоматическую яркость, True Tone и Night Shift.
- Показывает и меняет референсные профили, частоты обновления и пять штатных
  Retina-масштабов Studio Display.
- Поддерживает ручную яркость (`1...100`) и автоматическую яркость (`auto`).
- Позволяет по-разному изменить несколько дисплеев одной командой.
- Показывает и меняет раскладку дисплеев, основной монитор и относительные или
  абсолютные координаты.
- Включает и выключает зеркалирование, используя основной монитор как источник.
- Поддерживает JSON и безопасную проверку изменений через `--dry-run`.
- Выводит текст на русском, если русский является основным языком macOS; для
  остальных языков используется английский.

## Требования

- macOS 13 или новее.
- Xcode Command Line Tools со Swift 5.9 или новее.
- Apple Studio Display или Apple Studio Display XDR.

Проект разработан и проверен на Apple silicon с актуальными системными
фреймворками macOS. Совместимость приватных интерфейсов может измениться после
крупного обновления macOS; подробнее см. в разделе
[Особенности реализации](#особенности-реализации).

## Сборка

Если Xcode Command Line Tools ещё не установлены:

```sh
xcode-select --install
```

Соберите исполняемый файл:

```sh
swift build -c release
```

Запустите его непосредственно из проекта:

```sh
./.build/release/displayctl --version
./.build/release/displayctl
```

При желании установите утилиту для всей системы:

```sh
sudo install -m 0755 .build/release/displayctl /usr/local/bin/displayctl
```

После установки откройте новое окно Terminal — команда `displayctl` будет
доступна из любого каталога.

## Быстрый старт

```sh
# Краткий список подключённых дисплеев
displayctl
displayctl list

# Информация и доступные значения
displayctl info
displayctl info --all
displayctl profiles --display 1
displayctl rates --display 1
displayctl res --display 1
displayctl bright --all
displayctl layout

# Изменить параметры основного дисплея
displayctl set --profile 14 --rate 3 --res default --bright 50

# Включить автоматическую яркость
displayctl set --bright auto

# Применить значения по умолчанию ко всем дисплеям
displayctl set --all --profile default --rate default --res default

# По-разному изменить два дисплея
displayctl set \
  --display 1 --profile 4 --rate 2 --bright auto \
  --display 2 --profile 2 --bright 50

# Сделать дисплей 2 основным
displayctl set --layout --main 2

# Расположить дисплей 2 справа от дисплея 1
displayctl set --layout --display 2 --right-of 1

# Включить зеркало на всех дополнительных дисплеях
displayctl mirroring on
```

Полная локализованная справка доступна через `displayctl help`.

## Выбор дисплея

`NUMBER` после `--display` — порядковый номер из `displayctl list`, а не
CoreGraphics ID или серийный номер. Номера остаются предсказуемыми, пока не
меняется состав подключённых дисплеев и основной монитор.

В командах чтения `--display` можно повторять:

```sh
displayctl info --display 2 --display 3
displayctl profiles --display 1 --display 2
```

Без `--display` и `--all` команды `profiles`, `rates`, `res` и `bright` работают
с основным монитором. `info` и `layout` без селектора показывают все
поддерживаемые дисплеи.

`--all` и `--display` нельзя использовать одновременно.

## Изменение параметров

Команда `set` принимает:

| Параметр | Значение | Назначение |
| --- | --- | --- |
| `--profile` | `NUMBER` или `default` | Референсный профиль |
| `--rate` | `NUMBER` или `default` | Частота обновления |
| `--res` | `NUMBER` или `default` | Retina-разрешение |
| `--bright` | `1...100` или `auto` | Ручная или автоматическая яркость |
| `--truetone` | `on` или `off` | Глобальное состояние True Tone |
| `--nightshift` | `on` или `off` | Глобальное состояние Night Shift |

Числовая яркость сначала отключает автоматический режим, затем устанавливает
значение в процентах. `--bright auto` включает автоматическую яркость. Некоторые
референсные профили отключают управление яркостью; такие изменения пропускаются
с информационным сообщением.

При нескольких блоках `--display` каждый параметр относится к ближайшему
предыдущему дисплею:

```sh
displayctl set \
  --display 1 --profile 4 --rate 2 \
  --display 2 --profile 2
```

True Tone и Night Shift являются глобальными параметрами графического сеанса,
поэтому применяются один раз независимо от выбранных дисплеев.

## Частоты и разрешения

Для Studio Display XDR значение `--rate default` выбирает Adaptive Sync, если
он доступен. Studio Display предоставляет фиксированную штатную частоту 60 Гц;
попытка её изменить пропускается и не прерывает остальные изменения команды.

`displayctl res` показывает только пять штатных Retina-масштабов 2×:

- 1600×900
- 2048×1152
- 2560×1440
- 2880×1620
- 3200×1800

`--res default` выбирает рекомендованный драйвером режим. Если драйвер не
пометил его явно, используется 2560×1440 с масштабом 2×.

## Раскладка дисплеев

`displayctl layout` только показывает раскладку. Все изменения проходят через
`set`:

```sh
displayctl set --layout --main 2
displayctl set --layout --display 2 --position 2560,0
displayctl set --layout --display 2 --left-of 1
displayctl set --layout --display 2 --right-of 1
displayctl set --layout --display 2 --above 1
displayctl set --layout --display 2 --below 1
```

Раскладка сохраняется одной транзакцией CoreGraphics. Перед изменением нужно
выключить зеркалирование. `--layout` нельзя объединять с другими изменениями
команды `set` в одном запуске.

## Зеркалирование

```sh
displayctl mirroring
displayctl mirroring on
displayctl mirroring off
displayctl mirroring on --display 2 --display 3
```

Без селекторов изменение применяется ко всем дополнительным поддерживаемым
дисплеям. Основной монитор всегда является источником и не указывается как
цель.

## JSON и dry run

Добавьте `--json` к документированной команде для стабильного структурированного
вывода:

```sh
displayctl info --all --json
displayctl set --bright auto --json
```

`--dry-run` проверяет селекторы и значения, но не применяет изменения:

```sh
displayctl set --profile 4 --rate 2 --dry-run
displayctl set --layout --main 2 --dry-run
displayctl mirroring on --dry-run
```

## Особенности реализации

Поиск дисплеев, изменение видеорежимов, раскладки и зеркалирования используют
публичный CoreGraphics. Референсные профили, метаданные Adaptive Sync, яркость,
автоматическая яркость, True Tone, Night Shift и часть данных о дисплее доступны
через CoreDisplay, SkyLight, DisplayServices и CoreBrightness, для которых Apple
не публикует Swift API.

Эти символы загружаются во время выполнения. Если интерфейс отсутствует или
активный референсный профиль запрещает функцию, утилита сообщает об ограничении,
а не завершается аварийно. После крупных обновлений macOS совместимость всё
равно следует перепроверять.

Референсные профили и видеорежимы CoreGraphics не имеют общей системной
транзакции. Поэтому при совместном изменении дисплеи могут погаснуть дважды —
так же ведут себя System Settings.

## Структура проекта

```text
App/displayctl/       Исходники Swift
Package.swift         Манифест Swift Package Manager
.github/workflows/    Проверка сборки в GitHub Actions
README.md             Английская документация
```

## Отказ от ответственности

Это независимый проект, не связанный с Apple Inc. и не одобренный ею. Apple,
macOS, Studio Display и XDR являются товарными знаками Apple Inc.
