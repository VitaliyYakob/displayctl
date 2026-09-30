import CoreGraphics
import Foundation

/// Parsed command-line state. Repeated `--display` options form independent
/// set blocks, while `set --layout` uses one display as a geometry target.
struct CLIOptions {
    enum LayoutPlacement {
        case position(x: Int32, y: Int32)
        case relative(RelativeLayoutPosition, referenceNumber: Int)
    }

    struct DisplaySetOptions {
        let displayNumber: Int
        var profile: String?
        var rate: String?
        var resolution: String?
        var brightness: String?
    }

    enum Command {
        case list
        case info
        case profiles
        case rates
        case resolutions
        case brightness
        case layout
        case mirroring(enabled: Bool?)
        case set(profile: String?, rate: String?, resolution: String?, brightness: String?)
        case help
        case version
    }

    var command: Command = .list
    var displayNumbers: [Int] = []
    var json = false
    var all = false
    var dryRun = false
    var trueTone: Bool?
    var nightShift: NightShiftTarget?
    var displaySetOptions: [DisplaySetOptions] = []
    var layoutRequested = false
    var layoutMainNumber: Int?
    var layoutPlacement: LayoutPlacement?

    static func parse(_ arguments: [String]) throws -> CLIOptions {
        var result = CLIOptions()
        var index = 0
        var currentSetDisplayIndex: Int?

        if let first = arguments.first, !first.hasPrefix("-") {
            index = 1
            switch first {
            case "list": result.command = .list
            case "info": result.command = .info
            case "profiles": result.command = .profiles
            case "rates": result.command = .rates
            case "res": result.command = .resolutions
            case "bright": result.command = .brightness
            case "layout": result.command = .layout
            case "mirroring":
                if index < arguments.count, !arguments[index].hasPrefix("-") {
                    result.command = .mirroring(
                        enabled: try parseToggle(arguments[index], option: "mirroring")
                    )
                    index += 1
                } else {
                    result.command = .mirroring(enabled: nil)
                }
            case "set": result.command = .set(profile: nil, rate: nil, resolution: nil, brightness: nil)
            case "set-profile":
                guard index < arguments.count else {
                    throw DisplayCtlError.invalidArguments(L10n.text(
                        "set-profile требует номер профиля или default.",
                        "set-profile requires a profile number or default."
                    ))
                }
                result.command = .set(profile: arguments[index], rate: nil, resolution: nil, brightness: nil)
                index += 1
            case "set-rate":
                guard index < arguments.count else {
                    throw DisplayCtlError.invalidArguments(L10n.text(
                        "set-rate требует номер частоты или default.",
                        "set-rate requires a refresh-rate number or default."
                    ))
                }
                result.command = .set(profile: nil, rate: arguments[index], resolution: nil, brightness: nil)
                index += 1
            case "help": result.command = .help
            case "version": result.command = .version
            default:
                throw DisplayCtlError.invalidArguments(L10n.text(
                    "Неизвестная команда «\(first)». Выполните displayctl help.",
                    "Unknown command \"\(first)\". Run displayctl help."
                ))
            }
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--display", "-d":
                index += 1
                guard index < arguments.count,
                      let number = Int(arguments[index]),
                      number > 0 else {
                    throw DisplayCtlError.invalidArguments(L10n.text(
                        "После --display нужен положительный порядковый номер из displayctl list.",
                        "--display must be followed by a positive ordinal number from displayctl list."
                    ))
                }
                if case .set = result.command, !result.layoutRequested {
                    result.displaySetOptions.append(
                        DisplaySetOptions(
                            displayNumber: number,
                            profile: nil,
                            rate: nil,
                            resolution: nil,
                            brightness: nil
                        )
                    )
                    currentSetDisplayIndex = result.displaySetOptions.count - 1
                } else {
                    result.displayNumbers.append(number)
                }
            case "--json":
                result.json = true
            case "--all":
                result.all = true
            case "--dry-run":
                result.dryRun = true
            case "--layout":
                guard case .set = result.command else {
                    throw DisplayCtlError.invalidArguments(L10n.text(
                        "--layout используется только с командой set.",
                        "--layout can only be used with the set command."
                    ))
                }
                guard !result.layoutRequested else {
                    throw DisplayCtlError.invalidArguments(L10n.text(
                        "--layout нельзя указывать более одного раза.",
                        "--layout cannot be specified more than once."
                    ))
                }
                guard result.displaySetOptions.allSatisfy({
                    $0.profile == nil && $0.rate == nil && $0.resolution == nil && $0.brightness == nil
                }) else {
                    throw DisplayCtlError.invalidArguments(L10n.text(
                        "--layout нельзя объединять с параметрами профиля, частоты, разрешения или яркости.",
                        "--layout cannot be combined with profile, refresh-rate, resolution, or brightness options."
                    ))
                }
                result.displayNumbers.append(contentsOf: result.displaySetOptions.map(\.displayNumber))
                result.displaySetOptions.removeAll()
                currentSetDisplayIndex = nil
                result.layoutRequested = true
            case "--main":
                guard case .set = result.command, result.layoutRequested else {
                    throw DisplayCtlError.invalidArguments(L10n.text(
                        "--main используется только с displayctl set --layout.",
                        "--main can only be used with displayctl set --layout."
                    ))
                }
                guard result.layoutMainNumber == nil else {
                    throw DisplayCtlError.invalidArguments(L10n.text(
                        "--main нельзя указывать более одного раза.",
                        "--main cannot be specified more than once."
                    ))
                }
                index += 1
                guard index < arguments.count,
                      let number = Int(arguments[index]),
                      number > 0 else {
                    throw DisplayCtlError.invalidArguments(L10n.text(
                        "После --main нужен положительный порядковый номер из displayctl list.",
                        "--main must be followed by a positive ordinal number from displayctl list."
                    ))
                }
                result.layoutMainNumber = number
            case "--position":
                guard case .set = result.command, result.layoutRequested else {
                    throw DisplayCtlError.invalidArguments(L10n.text(
                        "--position используется только с displayctl set --layout.",
                        "--position can only be used with displayctl set --layout."
                    ))
                }
                guard result.layoutPlacement == nil else {
                    throw DisplayCtlError.invalidArguments(L10n.text(
                        "Для одной команды layout укажите только один способ размещения.",
                        "Specify only one positioning method per layout command."
                    ))
                }
                index += 1
                guard index < arguments.count,
                      let position = parsePosition(arguments[index]) else {
                    throw DisplayCtlError.invalidArguments(L10n.text(
                        "После --position укажите целые координаты X,Y, например 2560,0.",
                        "--position must be followed by integer X,Y coordinates, for example 2560,0."
                    ))
                }
                result.layoutPlacement = .position(x: position.x, y: position.y)
            case "--left-of", "--right-of", "--above", "--below":
                guard case .set = result.command, result.layoutRequested else {
                    throw DisplayCtlError.invalidArguments(L10n.text(
                        "\(argument) используется только с displayctl set --layout.",
                        "\(argument) can only be used with displayctl set --layout."
                    ))
                }
                guard result.layoutPlacement == nil else {
                    throw DisplayCtlError.invalidArguments(L10n.text(
                        "Для одной команды layout укажите только один способ размещения.",
                        "Specify only one positioning method per layout command."
                    ))
                }
                index += 1
                guard index < arguments.count,
                      let referenceNumber = Int(arguments[index]),
                      referenceNumber > 0 else {
                    throw DisplayCtlError.invalidArguments(L10n.text(
                        "После \(argument) нужен положительный порядковый номер из displayctl list.",
                        "\(argument) must be followed by a positive ordinal number from displayctl list."
                    ))
                }
                let position: RelativeLayoutPosition
                switch argument {
                case "--left-of": position = .left
                case "--right-of": position = .right
                case "--above": position = .above
                default: position = .below
                }
                result.layoutPlacement = .relative(position, referenceNumber: referenceNumber)
            case "--profile":
                index += 1
                guard index < arguments.count else {
                    throw DisplayCtlError.invalidArguments(L10n.text(
                        "После --profile нужен номер профиля или default.",
                        "--profile must be followed by a profile number or default."
                    ))
                }
                guard case .set(_, let rate, let resolution, let brightness) = result.command else {
                    throw DisplayCtlError.invalidArguments(L10n.text(
                        "--profile используется только с командой set.",
                        "--profile can only be used with the set command."
                    ))
                }
                if let currentSetDisplayIndex {
                    result.displaySetOptions[currentSetDisplayIndex].profile = arguments[index]
                } else {
                    result.command = .set(
                        profile: arguments[index],
                        rate: rate,
                        resolution: resolution,
                        brightness: brightness
                    )
                }
            case "--rate":
                index += 1
                guard index < arguments.count else {
                    throw DisplayCtlError.invalidArguments(L10n.text(
                        "После --rate нужен номер частоты или default.",
                        "--rate must be followed by a refresh-rate number or default."
                    ))
                }
                guard case .set(let profile, _, let resolution, let brightness) = result.command else {
                    throw DisplayCtlError.invalidArguments(L10n.text(
                        "--rate используется только с командой set.",
                        "--rate can only be used with the set command."
                    ))
                }
                if let currentSetDisplayIndex {
                    result.displaySetOptions[currentSetDisplayIndex].rate = arguments[index]
                } else {
                    result.command = .set(
                        profile: profile,
                        rate: arguments[index],
                        resolution: resolution,
                        brightness: brightness
                    )
                }
            case "--res":
                index += 1
                guard index < arguments.count else {
                    throw DisplayCtlError.invalidArguments(L10n.text(
                        "После --res нужен номер разрешения или default.",
                        "--res must be followed by a resolution number or default."
                    ))
                }
                guard case .set(let profile, let rate, _, let brightness) = result.command else {
                    throw DisplayCtlError.invalidArguments(L10n.text(
                        "--res используется только с командой set.",
                        "--res can only be used with the set command."
                    ))
                }
                if let currentSetDisplayIndex {
                    result.displaySetOptions[currentSetDisplayIndex].resolution = arguments[index]
                } else {
                    result.command = .set(
                        profile: profile,
                        rate: rate,
                        resolution: arguments[index],
                        brightness: brightness
                    )
                }
            case "--bright":
                index += 1
                guard index < arguments.count else {
                    throw DisplayCtlError.invalidArguments(L10n.text(
                        "После --bright укажите целое число от 1 до 100 или auto.",
                        "--bright must be followed by an integer from 1 to 100 or auto."
                    ))
                }
                let value = arguments[index].lowercased()
                guard value == "auto" || (Int(value).map { (1...100).contains($0) } ?? false) else {
                    throw DisplayCtlError.invalidArguments(L10n.text(
                        "После --bright укажите целое число от 1 до 100 или auto.",
                        "--bright must be followed by an integer from 1 to 100 or auto."
                    ))
                }
                guard case .set(let profile, let rate, let resolution, _) = result.command else {
                    throw DisplayCtlError.invalidArguments(L10n.text(
                        "--bright используется только с командой set.",
                        "--bright can only be used with the set command."
                    ))
                }
                if let currentSetDisplayIndex {
                    result.displaySetOptions[currentSetDisplayIndex].brightness = value
                } else {
                    result.command = .set(
                        profile: profile,
                        rate: rate,
                        resolution: resolution,
                        brightness: value
                    )
                }
            case "--truetone", "--true-tone":
                index += 1
                guard index < arguments.count else {
                    throw DisplayCtlError.invalidArguments(L10n.text(
                        "После --truetone укажите on или off.",
                        "--truetone must be followed by on or off."
                    ))
                }
                guard case .set = result.command else {
                    throw DisplayCtlError.invalidArguments(L10n.text(
                        "--truetone используется только с командой set.",
                        "--truetone can only be used with the set command."
                    ))
                }
                result.trueTone = try parseToggle(arguments[index], option: "--truetone")
            case "--nightshift", "--night-shift":
                index += 1
                guard index < arguments.count else {
                    throw DisplayCtlError.invalidArguments(L10n.text(
                        "После --nightshift укажите on или off.",
                        "--nightshift must be followed by on or off."
                    ))
                }
                guard case .set = result.command else {
                    throw DisplayCtlError.invalidArguments(L10n.text(
                        "--nightshift используется только с командой set.",
                        "--nightshift can only be used with the set command."
                    ))
                }
                result.nightShift = try parseNightShift(arguments[index])
            case "--help", "-h":
                result.command = .help
            case "--version":
                result.command = .version
            default:
                throw DisplayCtlError.invalidArguments(L10n.text(
                    "Неизвестный аргумент «\(argument)». Выполните displayctl help.",
                    "Unknown argument \"\(argument)\". Run displayctl help."
                ))
            }
            index += 1
        }

        if result.all && (!result.displayNumbers.isEmpty || !result.displaySetOptions.isEmpty) {
            throw DisplayCtlError.invalidArguments(L10n.text(
                "--all и --display нельзя использовать одновременно.",
                "--all and --display cannot be used together."
            ))
        }
        if (result.all || !result.displayNumbers.isEmpty), case .list = result.command {
            throw DisplayCtlError.invalidArguments(L10n.text(
                "Команда list не принимает ключей; используйте displayctl info для получения информации о подключенных мониторах.",
                "The list command does not accept options; use displayctl info to get information about connected displays."
            ))
        }
        let readDisplayNumbers = result.displayNumbers
        if Set(readDisplayNumbers).count != readDisplayNumbers.count {
            throw DisplayCtlError.invalidArguments(L10n.text(
                "Один и тот же --display нельзя указывать более одного раза.",
                "The same --display cannot be specified more than once."
            ))
        }
        if case .mirroring(let enabled) = result.command {
            if enabled == nil {
                guard !result.all, result.displayNumbers.isEmpty, !result.dryRun else {
                    throw DisplayCtlError.invalidArguments(L10n.text(
                        "Для просмотра статуса используйте displayctl mirroring без --all, --display и --dry-run.",
                        "To view status, use displayctl mirroring without --all, --display, or --dry-run."
                    ))
                }
            }
        }
        if case .layout = result.command {
            if result.dryRun {
                throw DisplayCtlError.invalidArguments(L10n.text(
                    "Для просмотра раскладки не нужен --dry-run.",
                    "--dry-run is not needed when viewing the layout."
                ))
            }
        }
        if case .set(let profile, let rate, let resolution, let brightness) = result.command {
            if result.layoutRequested {
                guard profile == nil, rate == nil, resolution == nil, brightness == nil,
                      result.displaySetOptions.isEmpty,
                      result.trueTone == nil, result.nightShift == nil else {
                    throw DisplayCtlError.invalidArguments(L10n.text(
                        "--layout нельзя объединять с другими изменениями команды set.",
                        "--layout cannot be combined with other set-command changes."
                    ))
                }
                guard !result.all else {
                    throw DisplayCtlError.invalidArguments(L10n.text(
                        "--all не используется с set --layout.",
                        "--all cannot be used with set --layout."
                    ))
                }

                let changesMain = result.layoutMainNumber != nil
                let changesPosition = result.layoutPlacement != nil
                guard changesMain != changesPosition else {
                    throw DisplayCtlError.invalidArguments(L10n.text(
                        "После set --layout укажите --main либо один способ размещения монитора.",
                        "After set --layout, specify --main or one display-positioning method."
                    ))
                }
                if changesMain {
                    guard result.displayNumbers.isEmpty else {
                        throw DisplayCtlError.invalidArguments(L10n.text(
                            "С --main не используется --display.",
                            "--display cannot be used with --main."
                        ))
                    }
                } else {
                    guard result.displayNumbers.count == 1 else {
                        throw DisplayCtlError.invalidArguments(L10n.text(
                            "Для изменения положения укажите ровно один --display NUMBER.",
                            "Specify exactly one --display NUMBER to change a display position."
                        ))
                    }
                }
                return result
            }

            if !result.displaySetOptions.isEmpty,
               profile != nil || rate != nil || resolution != nil || brightness != nil {
                guard result.displaySetOptions.count == 1 else {
                    throw DisplayCtlError.invalidArguments(
                        L10n.text(
                            "При нескольких --display указывайте --profile, --rate, --res и --bright после соответствующего --display.",
                            "With multiple --display blocks, place --profile, --rate, --res, and --bright after the corresponding --display."
                        )
                    )
                }
                if result.displaySetOptions[0].profile == nil {
                    result.displaySetOptions[0].profile = profile
                }
                if result.displaySetOptions[0].rate == nil {
                    result.displaySetOptions[0].rate = rate
                }
                if result.displaySetOptions[0].resolution == nil {
                    result.displaySetOptions[0].resolution = resolution
                }
                if result.displaySetOptions[0].brightness == nil {
                    result.displaySetOptions[0].brightness = brightness
                }
                result.command = .set(profile: nil, rate: nil, resolution: nil, brightness: nil)
            }

            let hasDisplayChanges = result.displaySetOptions.contains {
                $0.profile != nil || $0.rate != nil || $0.resolution != nil || $0.brightness != nil
            }
            guard profile != nil || rate != nil || resolution != nil || brightness != nil || hasDisplayChanges
                    || result.trueTone != nil || result.nightShift != nil else {
                throw DisplayCtlError.invalidArguments(
                    L10n.text(
                        "Для set укажите --profile, --rate, --res, --bright, --truetone или --nightshift.",
                        "Specify --profile, --rate, --res, --bright, --truetone, or --nightshift for set."
                    )
                )
            }
            if let profile { try validateProfileSelection(profile) }
            if let rate { try validateRateSelection(rate) }
            if let resolution { try validateResolutionSelection(resolution) }
            for item in result.displaySetOptions {
                if let profile = item.profile { try validateProfileSelection(profile) }
                if let rate = item.rate { try validateRateSelection(rate) }
                if let resolution = item.resolution { try validateResolutionSelection(resolution) }
            }

            let displayNumbers = result.displaySetOptions.map(\.displayNumber)
            guard Set(displayNumbers).count == displayNumbers.count else {
                throw DisplayCtlError.invalidArguments(
                    L10n.text(
                        "Один и тот же --display нельзя указывать более одного раза в команде set.",
                        "The same --display cannot be specified more than once in a set command."
                    )
                )
            }
        }
        return result
    }

    private static func parseToggle(_ value: String, option: String) throws -> Bool {
        switch value.lowercased() {
        case "on", "true", "1": return true
        case "off", "false", "0": return false
        default:
            throw DisplayCtlError.invalidArguments(L10n.text(
                "\(option) принимает on или off.",
                "\(option) accepts on or off."
            ))
        }
    }

    private static func parsePosition(_ value: String) -> (x: Int32, y: Int32)? {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let xValue = Int64(parts[0]),
              let yValue = Int64(parts[1]),
              xValue >= Int64(Int32.min), xValue <= Int64(Int32.max),
              yValue >= Int64(Int32.min), yValue <= Int64(Int32.max) else {
            return nil
        }
        return (Int32(xValue), Int32(yValue))
    }

    private static func parseNightShift(_ value: String) throws -> NightShiftTarget {
        switch value.lowercased() {
        case "on", "true", "1": return .on
        case "off", "false", "0": return .off
        default:
            throw DisplayCtlError.invalidArguments(L10n.text(
                "--nightshift принимает on или off.",
                "--nightshift accepts on or off."
            ))
        }
    }

    private static func validateProfileSelection(_ value: String) throws {
        if value.lowercased() == "default" { return }
        guard let number = Int(value), number > 0 else {
            throw DisplayCtlError.invalidArguments(L10n.text(
                "Профиль должен быть положительным порядковым номером или default.",
                "The profile must be a positive ordinal number or default."
            ))
        }
    }

    private static func validateRateSelection(_ value: String) throws {
        if value.lowercased() == "default" { return }
        guard let number = Int(value), number > 0 else {
            throw DisplayCtlError.invalidArguments(
                L10n.text(
                    "Частота должна быть положительным порядковым номером или default.",
                    "The refresh rate must be a positive ordinal number or default."
                )
            )
        }
    }

    private static func validateResolutionSelection(_ value: String) throws {
        if value.lowercased() == "default" { return }
        guard let number = Int(value), number > 0 else {
            throw DisplayCtlError.invalidArguments(
                L10n.text(
                    "Разрешение должно быть положительным порядковым номером или default.",
                    "The resolution must be a positive ordinal number or default."
                )
            )
        }
    }
}
