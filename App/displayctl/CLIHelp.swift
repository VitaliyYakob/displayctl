import Foundation

extension DisplayCtlApplication {
    static var help: String {
        L10n.isRussian ? helpRussian : helpEnglish
    }

    private static let helpRussian = """
    displayctl — управление Apple Studio Display и Apple Studio Display XDR.

    ИСПОЛЬЗОВАНИЕ

      displayctl
      displayctl --version

      displayctl list [--json]

      displayctl info [--all | --display NUMBER ...] [--json]
      displayctl profiles [--all | --display NUMBER ...] [--json]
      displayctl rates [--all | --display NUMBER ...] [--json]
      displayctl res [--all | --display NUMBER ...] [--json]
      displayctl bright [--all | --display NUMBER ...] [--json]

      displayctl layout [--all | --display NUMBER ...] [--json]

      displayctl mirroring [--json]
      displayctl mirroring on|off
          [--all | --display NUMBER ...]
          [--dry-run] [--json]

      displayctl set
          [--profile NUMBER|default]
          [--rate NUMBER|default]
          [--res NUMBER|default]
          [--bright 1...100|auto]
          [--all]
          [--truetone on|off]
          [--nightshift on|off]
          [--dry-run] [--json]

      displayctl set
          --display NUMBER
              [--profile NUMBER|default]
              [--rate NUMBER|default]
              [--res NUMBER|default]
              [--bright 1...100|auto]
          [--display NUMBER ...]
          [--truetone on|off]
          [--nightshift on|off]
          [--dry-run] [--json]

      displayctl set --layout --main NUMBER [--dry-run] [--json]
      displayctl set --layout --display NUMBER
          [--position X,Y | --left-of NUMBER | --right-of NUMBER |
           --above NUMBER | --below NUMBER]
          [--dry-run] [--json]

    ОПИСАНИЕ

    Без аргументов отображается краткий список подключённых мониторов.
    Команда list выводит тот же список.

    Каждому монитору присваивается порядковый номер. Этот номер используется
    в параметре --display.

    ОБЩИЕ ПРАВИЛА

      --display NUMBER
          Выбрать один или несколько мониторов.

          Можно повторять:

              --display 2 --display 3

      --all
          Выбрать все мониторы.

          Нельзя использовать одновременно с --display.

    Команды info, profiles, rates, res и bright без --display и --all работают
    с основным монитором.

    Команда info без селектора выводит краткую информацию обо всех мониторах.
    Параметр --all дополнительно показывает полный список профилей, частот и
    разрешений каждого дисплея.

    КОМАНДА SET

    set изменяет параметры мониторов.

    Если --display не указан, изменения применяются к основному монитору.

    Если указан --all, параметры применяются ко всем мониторам.

    Если требуется изменить несколько мониторов по-разному, повторяются блоки
    --display.

    Каждый параметр относится к ближайшему предыдущему --display.

    Например:

        --display 1 --profile 4 --rate 2
        --display 2 --profile 2

    означает

        монитор 1:
            профиль 4
            частота 2

        монитор 2:
            профиль 2

    Параметры:

      --profile NUMBER|default
          Цветовой профиль.

      --rate NUMBER|default
          Частота обновления.

      --res NUMBER|default
          Разрешение.

      --bright 1...100|auto
          Ручная яркость в процентах или автоматическая яркость.

      --truetone on|off
          True Tone.

      --nightshift on|off
          Night Shift.

    True Tone и Night Shift являются глобальными параметрами графического сеанса.
    Они не зависят от выбранного монитора.

    Числовое значение --bright отключает автоматическую яркость и устанавливает
    ручную яркость в процентах. --bright auto включает автоматическую яркость.
    Команда bright показывает текущий процент и помечает автоматический режим.

    КОМАНДА LAYOUT

    Без аргументов показывает координаты, размер, поворот и роль всех мониторов.

    set --layout --main NUMBER назначает выбранный монитор основным, сохраняя
    взаимное расположение активных дисплеев.

    set --layout --display NUMBER с --position X,Y задаёт абсолютные координаты.
    --left-of, --right-of, --above и --below располагают выбранный монитор
    относительно монитора с указанным порядковым номером.

    Изменения раскладки сохраняются одной транзакцией CoreGraphics. Во время
    зеркалирования изменение раскладки недоступно. --layout не объединяется с
    другими изменениями команды set.

    КОМАНДА MIRRORING

    Без аргументов отображает текущее состояние зеркалирования.

    mirroring on включает зеркалирование.

    mirroring off отключает зеркалирование.

    Если не указан --display, изменение применяется ко всем
    дополнительным мониторам.

    Основной монитор всегда используется как источник изображения и после
    --display не указывается.

    Все изменения выполняются одной транзакцией CoreGraphics.

    ПРИМЕРЫ

    Просмотреть подключённые мониторы

        displayctl

    Подробная информация

        displayctl info

    Информация о двух мониторах

        displayctl info --display 2 --display 3

    Показать доступные профили

        displayctl profiles --display 2

    Включить автоматическую яркость

        displayctl set --bright auto

    Сделать монитор 2 основным

        displayctl set --layout --main 2

    Расположить монитор 2 справа от монитора 1

        displayctl set --layout --display 2 --right-of 1

    Задать координаты монитора 2

        displayctl set --layout --display 2 --position 2560,0

    Изменить профиль и частоту основного монитора

        displayctl set --profile 14 --rate 3

    Изменить яркость

        displayctl set --bright 50

    Изменить параметры двух мониторов

        displayctl set \\
            --display 1 --profile 4 --rate 2 \\
            --display 2 --profile 2

    Установить параметры по умолчанию всем мониторам

        displayctl set \\
            --all \\
            --profile default \\
            --rate default

    Включить True Tone

        displayctl set --truetone on

    Включить зеркалирование

        displayctl mirroring on

    Зеркалировать только мониторы 2 и 3

        displayctl mirroring on --display 2 --display 3

    ПРИМЕЧАНИЯ

    Studio Display XDR

      default для частоты соответствует Adaptive Sync.

    Studio Display

      Поддерживается только одна штатная частота — 60 Гц.
      Параметр --rate игнорируется с информационным сообщением.

    Команда res показывает штатные Retina-масштабы.

    default для разрешения соответствует рекомендуемому режиму macOS.

    Если текущий профиль не поддерживает яркость, автоматическую яркость,
    True Tone или Night Shift, соответствующее изменение пропускается.
    """

    private static let helpEnglish = """
    displayctl — control Apple Studio Display and Apple Studio Display XDR.

    USAGE

      displayctl
      displayctl --version

      displayctl list [--json]

      displayctl info [--all | --display NUMBER ...] [--json]
      displayctl profiles [--all | --display NUMBER ...] [--json]
      displayctl rates [--all | --display NUMBER ...] [--json]
      displayctl res [--all | --display NUMBER ...] [--json]
      displayctl bright [--all | --display NUMBER ...] [--json]

      displayctl layout [--all | --display NUMBER ...] [--json]

      displayctl mirroring [--json]
      displayctl mirroring on|off
          [--all | --display NUMBER ...]
          [--dry-run] [--json]

      displayctl set
          [--profile NUMBER|default]
          [--rate NUMBER|default]
          [--res NUMBER|default]
          [--bright 1...100|auto]
          [--all]
          [--truetone on|off]
          [--nightshift on|off]
          [--dry-run] [--json]

      displayctl set
          --display NUMBER
              [--profile NUMBER|default]
              [--rate NUMBER|default]
              [--res NUMBER|default]
              [--bright 1...100|auto]
          [--display NUMBER ...]
          [--truetone on|off]
          [--nightshift on|off]
          [--dry-run] [--json]

      displayctl set --layout --main NUMBER [--dry-run] [--json]
      displayctl set --layout --display NUMBER
          [--position X,Y | --left-of NUMBER | --right-of NUMBER |
           --above NUMBER | --below NUMBER]
          [--dry-run] [--json]

    DESCRIPTION

    With no arguments, displayctl prints a short list of connected displays.
    The list command prints the same list.

    Each display is assigned an ordinal number. This number is used with
    the --display option.

    GENERAL RULES

      --display NUMBER
          Select one or more displays.

          It can be repeated:

              --display 2 --display 3

      --all
          Select all displays.

          It cannot be used together with --display.

    The info, profiles, rates, res, and bright commands operate on the main
    display when neither --display nor --all is specified.

    The info command without a selector prints a short summary for all displays.
    --all additionally includes the complete profile, refresh-rate, and
    resolution lists for every display.

    SET COMMAND

    set changes display parameters.

    If --display is omitted, changes apply to the main display.

    If --all is specified, the parameters apply to all displays.

    To change several displays differently, repeat --display blocks.

    Each parameter applies to the nearest preceding --display.

    For example:

        --display 1 --profile 4 --rate 2
        --display 2 --profile 2

    means

        display 1:
            profile 4
            refresh rate 2

        display 2:
            profile 2

    Options:

      --profile NUMBER|default
          Color profile.

      --rate NUMBER|default
          Refresh rate.

      --res NUMBER|default
          Resolution.

      --bright 1...100|auto
          Manual brightness in percent or automatic brightness.

      --truetone on|off
          True Tone.

      --nightshift on|off
          Night Shift.

    True Tone and Night Shift are global graphical-session settings.
    They do not depend on the selected display.

    A numeric --bright value disables automatic brightness and sets manual
    brightness in percent. --bright auto enables automatic brightness. The
    bright command shows the current percentage and marks automatic mode.

    LAYOUT COMMAND

    With no arguments, it shows the coordinates, size, rotation, and role of
    every display.

    set --layout --main NUMBER makes the selected display main while preserving
    the relative arrangement of active displays.

    set --layout --display NUMBER with --position X,Y sets absolute coordinates.
    --left-of, --right-of, --above, and --below position the selected display
    relative to the display with the specified ordinal number.

    Layout changes are saved in one CoreGraphics transaction. Layout changes
    are unavailable while mirroring is active. --layout cannot be combined with
    other changes of the set command.

    MIRRORING COMMAND

    With no arguments, it displays the current mirroring status.

    mirroring on enables mirroring.

    mirroring off disables mirroring.

    If --display is not specified, the change applies to all
    secondary displays.

    The main display is always used as the image source and must not be specified
    after --display.

    All changes are performed in one CoreGraphics transaction.

    EXAMPLES

    View connected displays

        displayctl

    Detailed information

        displayctl info

    Information about two displays

        displayctl info --display 2 --display 3

    Show available profiles

        displayctl profiles --display 2

    Enable automatic brightness

        displayctl set --bright auto

    Make display 2 the main display

        displayctl set --layout --main 2

    Place display 2 to the right of display 1

        displayctl set --layout --display 2 --right-of 1

    Set coordinates for display 2

        displayctl set --layout --display 2 --position 2560,0

    Change the main display profile and refresh rate

        displayctl set --profile 14 --rate 3

    Change brightness

        displayctl set --bright 50

    Change parameters for two displays

        displayctl set \\
            --display 1 --profile 4 --rate 2 \\
            --display 2 --profile 2

    Apply the default parameters to all displays

        displayctl set \\
            --all \\
            --profile default \\
            --rate default

    Enable True Tone

        displayctl set --truetone on

    Enable mirroring

        displayctl mirroring on

    Mirror only displays 2 and 3

        displayctl mirroring on --display 2 --display 3

    NOTES

    Studio Display XDR

      default for the refresh rate corresponds to Adaptive Sync.

    Studio Display

      Only one native refresh rate, 60 Hz, is supported.
      --rate is ignored with an informational message.

    The res command shows the standard Retina scales.

    default for resolution corresponds to the macOS recommended mode.

    If the current profile does not support brightness, automatic brightness,
    True Tone, or Night Shift, the corresponding change is skipped.
    """
}
