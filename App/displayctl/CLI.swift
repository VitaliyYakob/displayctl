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

/// Coordinates discovery, validation, system services, and text/JSON output.
final class DisplayCtlApplication {
    private struct RequestedChange {
        let display: DisplayDevice
        let profileSelection: String?
        let rateSelection: String?
        let resolutionSelection: String?
        let brightnessSelection: String?
    }

    private struct Snapshot {
        let number: Int
        let display: DisplayDevice
        let profiles: [ReferencePreset]
        let rates: [RefreshOption]
        let resolutions: [ResolutionOption]
        let metadata: FirmwareService.Metadata
        let brightnessPercent: Int?
        let autoBrightness: AutoBrightnessStatus
        let colorFeatures: ColorFeatureStatus
    }

    private struct Plan {
        let number: Int
        let display: DisplayDevice
        let profile: ReferencePreset?
        let rate: RefreshOption?
        let rateSelection: String?
        let rateUnsupported: Bool
        let resolution: ResolutionOption?
        let brightnessSelection: String?
        let brightnessPercent: Int?
        var brightnessResult: BrightnessChangeResult?
        var autoBrightnessResult: AutoBrightnessChangeResult?
    }

    private let discovery = DisplayDiscovery()
    private let presets = CoreDisplayBridge()
    private let refreshRates = RefreshRateService()
    private let brightness = BrightnessService()
    private let autoBrightness = AutoBrightnessService()
    private let layout = LayoutService()
    private let mirroring = MirroringService()
    private let firmware = FirmwareService()
    private let colorFeatures = ColorFeatureService()

    func run(arguments: [String]) throws {
        let options = try CLIOptions.parse(arguments)
        switch options.command {
        case .help:
            print(Self.help)
            return
        case .version:
            print("displayctl 1.0.1")
            return
        default:
            break
        }

        let active = try discovery.activeDisplays()
        let displays = try discovery.supportedDisplays(from: active)

        switch options.command {
        case .list:
            try printList(displays, json: options.json)
        case .info:
            let hasSelection = !options.displayNumbers.isEmpty
            let targets = hasSelection
                ? try selectedDisplays(displays, options: options)
                : displays
            try printInfo(
                targets,
                allDisplays: displays,
                detailed: options.all || hasSelection,
                json: options.json
            )
        case .profiles:
            let targets = try selectedDisplays(displays, options: options)
            try printProfiles(targets, allDisplays: displays, json: options.json)
        case .rates:
            let targets = try selectedDisplays(displays, options: options)
            try printRates(targets, allDisplays: displays, json: options.json)
        case .resolutions:
            let targets = try selectedDisplays(displays, options: options)
            try printResolutions(targets, allDisplays: displays, json: options.json)
        case .brightness:
            let targets = try selectedDisplays(displays, options: options)
            try printBrightness(targets, allDisplays: displays, json: options.json)
        case .layout:
            try handleLayout(
                options: options,
                supportedDisplays: displays,
                onlineDisplays: active
            )
        case .mirroring(let enabled):
            if let enabled {
                guard let source = active.first(where: \.isMain) else {
                    throw DisplayCtlError.displayConfiguration(L10n.text(
                        "Основной монитор не найден.",
                        "The main display was not found."
                    ))
                }
                let targets = options.all || options.displayNumbers.isEmpty
                    ? displays.filter { $0.id != source.id }
                    : try selectedDisplays(displays, options: options)
                guard !targets.isEmpty else {
                    throw DisplayCtlError.invalidArguments(L10n.text(
                        "Дополнительные Apple Studio Display не найдены.",
                        "No secondary Apple Studio Displays were found."
                    ))
                }
                guard !targets.contains(where: { $0.id == source.id || $0.isMain }) else {
                    throw DisplayCtlError.invalidArguments(L10n.text(
                        "Основной монитор является источником зеркала и не указывается после --display.",
                        "The main display is the mirroring source and must not be specified after --display."
                    ))
                }
                try applyMirroring(
                    enabled: enabled,
                    source: source,
                    targets: targets,
                    allDisplays: displays,
                    dryRun: options.dryRun,
                    json: options.json
                )
            } else {
                try printMirroringStatus(displays, json: options.json)
            }
        case .set(let profile, let rate, let resolution, let brightnessSelection):
            if options.layoutRequested {
                try handleLayout(
                    options: options,
                    supportedDisplays: displays,
                    onlineDisplays: active
                )
                break
            }
            let requests: [RequestedChange]
            if options.displaySetOptions.isEmpty {
                let targets = try selectedDisplays(displays, options: options)
                requests = targets.map {
                    RequestedChange(
                        display: $0,
                        profileSelection: profile,
                        rateSelection: rate,
                        resolutionSelection: resolution,
                        brightnessSelection: brightnessSelection
                    )
                }
            } else {
                requests = try options.displaySetOptions.map { item in
                    RequestedChange(
                        display: try discovery.select(from: displays, number: item.displayNumber),
                        profileSelection: item.profile,
                        rateSelection: item.rate,
                        resolutionSelection: item.resolution,
                        brightnessSelection: item.brightness
                    )
                }
            }
            try apply(
                requests: requests,
                allDisplays: displays,
                trueTone: options.trueTone,
                nightShift: options.nightShift,
                dryRun: options.dryRun,
                json: options.json
            )
        case .help, .version:
            break
        }
    }

    private func selectedDisplays(_ displays: [DisplayDevice], options: CLIOptions) throws -> [DisplayDevice] {
        if options.all { return displays }
        if !options.displayNumbers.isEmpty {
            return try options.displayNumbers.map {
                try discovery.select(from: displays, number: $0)
            }
        }
        return [try discovery.select(from: displays, number: nil)]
    }

    private func displayNumber(_ display: DisplayDevice, in displays: [DisplayDevice]) -> Int {
        (displays.firstIndex(where: { $0.id == display.id }) ?? 0) + 1
    }

    // MARK: - List

    private func printList(_ displays: [DisplayDevice], json: Bool) throws {
        if json {
            try printJSON([
                "displays": displays.enumerated().map { offset, display in
                    ["number": offset + 1, "name": display.name]
                }
            ])
        } else {
            for (offset, display) in displays.enumerated() {
                print("[\(offset + 1)] \(display.name)")
            }
        }
    }

    private func printInfo(
        _ targets: [DisplayDevice],
        allDisplays: [DisplayDevice],
        detailed: Bool,
        json: Bool
    ) throws {
        let currentColorFeatures = colorFeatures.status()
        let snapshots = try targets.map { display in
            try snapshot(
                number: displayNumber(display, in: allDisplays),
                display: display,
                colorFeatures: currentColorFeatures
            )
        }
        if json {
            try printJSON(["displays": snapshots.map { snapshotJSON($0, detailed: detailed) }])
        } else {
            for (offset, snapshot) in snapshots.enumerated() {
                if offset > 0 { print("") }
                printSnapshot(snapshot, detailed: detailed)
            }
        }
    }

    private func snapshot(
        number: Int,
        display: DisplayDevice,
        colorFeatures: ColorFeatureStatus
    ) throws -> Snapshot {
        Snapshot(
            number: number,
            display: display,
            profiles: try presets.presets(for: display.id),
            rates: try refreshRates.options(for: display),
            // info should remain useful even if macOS temporarily withholds its
            // resolution table during display reconfiguration.
            resolutions: (try? refreshRates.resolutions(for: display)) ?? [],
            metadata: firmware.metadata(for: display),
            brightnessPercent: brightness.valuePercent(for: display),
            autoBrightness: autoBrightness.status(for: display),
            colorFeatures: colorFeatures
        )
    }

    private func printSnapshot(_ snapshot: Snapshot, detailed: Bool) {
        let display = snapshot.display
        let activeProfile = snapshot.profiles.first(where: \.isActive)
        let activeRate = snapshot.rates.first(where: \.isActive)
        let activeResolution = snapshot.resolutions.first(where: \.isActive)

        print("[\(snapshot.number)] \(display.name):")
        print("    id: \(display.id)")
        print("    Role: \(display.isMain ? L10n.text("Основной", "Main") : L10n.text("Дополнительный", "Secondary"))")
        print("    Profile: \(activeProfile.map { "[\($0.ordinal)] \($0.name)" } ?? "—")")
        print("    Rate: \(activeRate.map { "[\($0.ordinal)] \($0.label)" } ?? "—")")
        print("    Resolution: \(activeResolution.map { "[\($0.ordinal)] \($0.label)" } ?? display.resolution?.label ?? "—")")
        print("    Mirroring: \(display.isMirrored)")
        print("    serial: \(snapshot.metadata.serial ?? display.serialText)")
        print("    Firmware: \(snapshot.metadata.firmware ?? "—")")
        print("    Brightness: \(snapshot.brightnessPercent.map { "\($0)%" } ?? "—")")
        print("    AutoBrightness: \(optionalBool(snapshot.autoBrightness.enabled))")
        print("    TrueTone: \(optionalBool(snapshot.colorFeatures.trueTone))")
        print("    NightShift: \(optionalBool(snapshot.colorFeatures.nightShift))")
        if detailed {
            print("    Profiles:")
            printProfileRows(snapshot.profiles, indent: "        ")
            print("    Rates:")
            printRateRows(snapshot.rates, indent: "        ")
            print("    Resolutions:")
            printResolutionRows(snapshot.resolutions, indent: "        ")
        }
    }

    // MARK: - Profiles and rates

    private func printProfiles(_ targets: [DisplayDevice], allDisplays: [DisplayDevice], json: Bool) throws {
        let output = try targets.map { display in
            (
                number: displayNumber(display, in: allDisplays),
                display: display,
                values: try presets.presets(for: display.id)
            )
        }

        if json {
            try printJSON([
                "displays": output.map { item in
                    [
                        "number": item.number,
                        "name": item.display.name,
                        "main": item.display.isMain,
                        "profiles": item.values.map(profileJSON)
                    ]
                }
            ])
        } else {
            for (offset, item) in output.enumerated() {
                if offset > 0 { print("") }
                print(displayHeader(number: item.number, display: item.display))
                printProfileRows(item.values, indent: "    ")
            }
        }
    }

    private func printRates(
        _ targets: [DisplayDevice],
        allDisplays: [DisplayDevice],
        json: Bool
    ) throws {
        let output = try targets.map { display in
            (
                number: displayNumber(display, in: allDisplays),
                display: display,
                values: try refreshRates.options(for: display)
            )
        }

        if json {
            try printJSON([
                "displays": output.map { item in
                    [
                        "number": item.number,
                        "name": item.display.name,
                        "main": item.display.isMain,
                        "rates": item.values.map { rateJSON($0) }
                    ]
                }
            ])
        } else {
            for (offset, item) in output.enumerated() {
                if offset > 0 { print("") }
                print(displayHeader(number: item.number, display: item.display))
                printRateRows(item.values, indent: "    ")
            }
        }
    }

    private func printResolutions(_ targets: [DisplayDevice], allDisplays: [DisplayDevice], json: Bool) throws {
        let output = try targets.map { display in
            (
                number: displayNumber(display, in: allDisplays),
                display: display,
                values: try refreshRates.resolutions(for: display)
            )
        }

        if json {
            try printJSON([
                "displays": output.map { item in
                    [
                        "number": item.number,
                        "name": item.display.name,
                        "main": item.display.isMain,
                        "resolutions": item.values.map(resolutionOptionJSON)
                    ]
                }
            ])
        } else {
            for (offset, item) in output.enumerated() {
                if offset > 0 { print("") }
                print(displayHeader(number: item.number, display: item.display))
                printResolutionRows(item.values, indent: "    ")
            }
        }
    }

    private func printBrightness(_ targets: [DisplayDevice], allDisplays: [DisplayDevice], json: Bool) throws {
        let output = targets.map { display in
            (
                number: displayNumber(display, in: allDisplays),
                display: display,
                value: brightness.valuePercent(for: display),
                automatic: autoBrightness.status(for: display).enabled
            )
        }

        if json {
            try printJSON([
                "displays": output.map { item in
                    [
                        "number": item.number,
                        "name": item.display.name,
                        "main": item.display.isMain,
                        "brightnessPercent": item.value ?? NSNull(),
                        "autoBrightness": item.automatic ?? NSNull()
                    ]
                }
            ])
        } else {
            for (offset, item) in output.enumerated() {
                if offset > 0 { print("") }
                print(displayHeader(number: item.number, display: item.display))
                let suffix = item.automatic == true ? L10n.text(" (авто)", " (auto)") : ""
                print("    Brightness: \(item.value.map { "\($0)%" } ?? "—")\(suffix)")
            }
        }
    }

    private func handleLayout(
        options: CLIOptions,
        supportedDisplays: [DisplayDevice],
        onlineDisplays: [DisplayDevice]
    ) throws {
        if let mainNumber = options.layoutMainNumber {
            let target = try discovery.select(from: supportedDisplays, number: mainNumber)
            let supportedIDs = Set(supportedDisplays.map(\.id))
            let items = try layout.setMain(
                target,
                among: onlineDisplays,
                dryRun: options.dryRun
            ).filter { supportedIDs.contains($0.display.id) }
            try printLayout(
                items,
                allDisplays: supportedDisplays,
                changed: true,
                dryRun: options.dryRun,
                json: options.json
            )
            return
        }

        if let placement = options.layoutPlacement {
            guard let targetNumber = options.displayNumbers.first else {
                throw DisplayCtlError.invalidArguments(L10n.text(
                    "Для изменения положения укажите --display NUMBER.",
                    "Specify --display NUMBER to change a display position."
                ))
            }
            let target = try discovery.select(from: supportedDisplays, number: targetNumber)
            let item: DisplayLayoutItem
            switch placement {
            case .position(let x, let y):
                item = try layout.setPosition(
                    of: target,
                    x: x,
                    y: y,
                    dryRun: options.dryRun
                )
            case .relative(let position, let referenceNumber):
                let reference = try discovery.select(
                    from: supportedDisplays,
                    number: referenceNumber
                )
                item = try layout.setRelativePosition(
                    of: target,
                    relativeTo: reference,
                    position: position,
                    dryRun: options.dryRun
                )
            }
            try printLayout(
                [item],
                allDisplays: supportedDisplays,
                changed: true,
                dryRun: options.dryRun,
                json: options.json
            )
            return
        }

        let targets: [DisplayDevice]
        if options.all || options.displayNumbers.isEmpty {
            targets = supportedDisplays
        } else {
            targets = try options.displayNumbers.map {
                try discovery.select(from: supportedDisplays, number: $0)
            }
        }
        try printLayout(
            targets.map { layout.item(for: $0) },
            allDisplays: supportedDisplays,
            changed: false,
            dryRun: false,
            json: options.json
        )
    }

    private func printLayout(
        _ items: [DisplayLayoutItem],
        allDisplays: [DisplayDevice],
        changed: Bool,
        dryRun: Bool,
        json: Bool
    ) throws {
        if json {
            var result: [String: Any] = [
                "displays": items.map { item in
                    layoutJSON(item, number: displayNumber(item.display, in: allDisplays))
                }
            ]
            if changed {
                result["ok"] = true
                result["dryRun"] = dryRun
            }
            try printJSON(result)
            return
        }

        if changed {
            print("\(dryRun ? L10n.text("Проверка", "Dry run") : L10n.text("Готово", "Done")): \(L10n.text("Раскладка", "Layout"))")
        }
        for (offset, item) in items.enumerated() {
            if offset > 0 || changed { print("") }
            let number = displayNumber(item.display, in: allDisplays)
            let role = item.isMain
                ? L10n.text("Основной", "Main")
                : L10n.text("Дополнительный", "Secondary")
            print("[\(number)] \(item.display.name) (\(role)):")
            print("    Position: \(item.x),\(item.y)")
            print("    Size: \(item.width)×\(item.height)")
            print("    Rotation: \(formatRotation(item.rotation))°")
            print("    Main: \(item.isMain)")
        }
    }

    private func layoutJSON(_ item: DisplayLayoutItem, number: Int) -> [String: Any] {
        [
            "number": number,
            "name": item.display.name,
            "id": item.display.id,
            "x": item.x,
            "y": item.y,
            "width": item.width,
            "height": item.height,
            "rotation": item.rotation,
            "main": item.isMain,
            "changed": item.changed
        ]
    }

    private func formatRotation(_ value: Double) -> String {
        let rounded = value.rounded()
        return abs(value - rounded) < 0.005 ? String(Int(rounded)) : String(format: "%.2f", value)
    }

    private func printMirroringStatus(_ displays: [DisplayDevice], json: Bool) throws {
        let output = displays.enumerated().map { offset, display in
            (
                number: offset + 1,
                display: display,
                enabled: mirroring.isInMirrorSet(display, among: displays)
            )
        }
        if json {
            try printJSON([
                "displays": output.map { item in
                    [
                        "number": item.number,
                        "name": item.display.name,
                        "main": item.display.isMain,
                        "mirroring": item.enabled
                    ]
                }
            ])
        } else {
            for (offset, item) in output.enumerated() {
                if offset > 0 { print("") }
                print(displayHeader(number: item.number, display: item.display))
                print("    Mirroring: \(item.enabled ? "on" : "off")")
            }
        }
    }

    private func applyMirroring(
        enabled: Bool,
        source: DisplayDevice,
        targets: [DisplayDevice],
        allDisplays: [DisplayDevice],
        dryRun: Bool,
        json: Bool
    ) throws {
        let results = try mirroring.set(
            enabled: enabled,
            source: source,
            targets: targets,
            dryRun: dryRun
        )
        if json {
            try printJSON([
                "ok": true,
                "dryRun": dryRun,
                "source": [
                    "id": source.id,
                    "name": source.name
                ],
                "displays": results.map { result in
                    [
                        "number": displayNumber(result.display, in: allDisplays),
                        "name": result.display.name,
                        "id": result.display.id,
                        "mirroring": result.enabled,
                        "changed": result.changed
                    ]
                }
            ])
        } else {
            let status = dryRun ? L10n.text("Проверка", "Dry run") : L10n.text("Готово", "Done")
            let unchanged = L10n.text(" (без изменений)", " (unchanged)")
            for (offset, result) in results.enumerated() {
                if offset > 0 { print("") }
                let number = displayNumber(result.display, in: allDisplays)
                print("\(status): \(displayLabel(number: number, display: result.display))")
                print("    Mirroring: \(result.enabled ? "on" : "off")\(result.changed ? "" : unchanged)")
            }
        }
    }

    // MARK: - Set

    private func apply(
        requests: [RequestedChange],
        allDisplays: [DisplayDevice],
        trueTone: Bool?,
        nightShift: NightShiftTarget?,
        dryRun: Bool,
        json: Bool
    ) throws {
        // Resolve every value before changing anything. This prevents a partial
        // --all operation caused by an invalid ordinal on a later display.
        var plans = try requests.map { request -> Plan in
            let display = request.display
            let profileList = request.profileSelection == nil ? [] : try presets.presets(for: display.id)
            let rateResolution = try resolveRate(request.rateSelection, for: display)
            let resolutionList = request.resolutionSelection == nil
                ? []
                : try refreshRates.resolutions(for: display)
            let brightnessPercent = request.brightnessSelection.flatMap(Int.init)
            let automaticBrightnessTarget = request.brightnessSelection.map { $0 == "auto" }
            return Plan(
                number: displayNumber(display, in: allDisplays),
                display: display,
                profile: try request.profileSelection.map {
                    try selectProfile($0, display: display, from: profileList)
                },
                rate: rateResolution.option,
                rateSelection: request.rateSelection,
                rateUnsupported: rateResolution.unsupported,
                resolution: try request.resolutionSelection.map {
                    try selectResolution($0, from: resolutionList)
                },
                brightnessSelection: request.brightnessSelection,
                brightnessPercent: brightnessPercent,
                brightnessResult: try brightnessPercent.map {
                    try brightness.preview(percent: $0, for: display)
                },
                autoBrightnessResult: automaticBrightnessTarget.map {
                    autoBrightness.preview(enabled: $0, for: display)
                }
            )
        }

        let initialColorFeatures = colorFeatures.status()
        var trueToneResult = trueTone.map {
            previewColorChange(current: initialColorFeatures.trueTone, requested: $0)
        }
        var nightShiftResult = nightShift.map {
            previewColorChange(current: initialColorFeatures.nightShift, requested: $0.enabledValue)
        }

        if !dryRun {
            // CoreDisplay presets are synchronous and have no CGDisplayConfigRef
            // variant. Resolutions and rates, including requests for multiple
            // displays, are staged and committed in one CoreGraphics transaction.
            for plan in plans {
                if let profile = plan.profile, !profile.isActive {
                    try presets.setPreset(profile, for: plan.display.id)
                }
            }

            // Presets and video modes use separate system APIs and are applied in
            // that order. The service resolves a live combined resolution/rate
            // mode after the preset and retries while reconfiguration is in flight.
            let modeChanges = plans.compactMap { plan -> DisplayModeRequest? in
                let rate = plan.rateUnsupported ? nil : plan.rate
                guard plan.resolution != nil || rate != nil else { return nil }
                return DisplayModeRequest(
                    display: plan.display,
                    resolution: plan.resolution,
                    rate: rate
                )
            }
            let unavailableRateDisplays = try refreshRates.set(modeChanges)
            if !unavailableRateDisplays.isEmpty {
                plans = plans.map { plan in
                    guard unavailableRateDisplays.contains(plan.display.id) else { return plan }
                    return Plan(
                        number: plan.number,
                        display: plan.display,
                        profile: plan.profile,
                        rate: nil,
                        rateSelection: plan.rateSelection,
                        rateUnsupported: true,
                        resolution: plan.resolution,
                        brightnessSelection: plan.brightnessSelection,
                        brightnessPercent: plan.brightnessPercent,
                        brightnessResult: plan.brightnessResult,
                        autoBrightnessResult: plan.autoBrightnessResult
                    )
                }
            }

            for index in plans.indices {
                guard let selection = plans[index].brightnessSelection else { continue }
                let automatic = selection == "auto"
                // A numeric value is an explicit manual request, so automatic
                // brightness is disabled before the percentage is applied.
                plans[index].autoBrightnessResult = try autoBrightness.set(
                    enabled: automatic,
                    for: plans[index].display
                )
                if let percent = plans[index].brightnessPercent {
                    plans[index].brightnessResult = try brightness.set(
                        percent: percent,
                        for: plans[index].display
                    )
                }
            }

            if let trueTone {
                trueToneResult = try colorFeatures.setTrueTone(enabled: trueTone)
            }
            if let nightShift {
                nightShiftResult = try colorFeatures.setNightShift(nightShift)
            }
        }

        let displayPlans = plans.filter {
            $0.profile != nil || $0.rate != nil || $0.rateUnsupported
                || $0.resolution != nil || $0.brightnessSelection != nil
        }

        if json {
            var result: [String: Any] = [
                "ok": true,
                "dryRun": dryRun,
                "displays": displayPlans.map(planJSON)
            ]
            if let trueTone, let trueToneResult {
                result["trueTone"] = colorFeatureJSON(
                    requested: trueTone,
                    result: trueToneResult
                )
            }
            if let nightShift, let nightShiftResult {
                result["nightShift"] = colorFeatureJSON(
                    requested: nightShift.outputValue,
                    result: nightShiftResult
                )
            }
            try printJSON(result)
        } else {
            let status = dryRun ? L10n.text("Проверка", "Dry run") : L10n.text("Готово", "Done")
            let unchanged = L10n.text(" (без изменений)", " (unchanged)")

            for (offset, plan) in displayPlans.enumerated() {
                if offset > 0 { print("") }
                print("\(status): [\(plan.number)] \(plan.display.name)")
                if let profile = plan.profile {
                    print("    Profile: [\(profile.ordinal)] \(profile.name)\(profile.isActive ? unchanged : "")")
                }
                if let rate = plan.rate {
                    print("    Rate: [\(rate.ordinal)] \(rate.label)\(rate.isActive ? unchanged : "")")
                } else if plan.rateUnsupported {
                    let unsupportedMessage = L10n.text(
                        "изменение частоты обновления не поддерживается",
                        "refresh-rate changes are not supported"
                    )
                    print("    Rate: \(unsupportedMessage)")
                }
                if let resolution = plan.resolution {
                    print("    Resolution: [\(resolution.ordinal)] \(resolution.label)\(resolution.isActive ? unchanged : "")")
                }
                if plan.brightnessSelection == "auto",
                   let result = plan.autoBrightnessResult {
                    if let message = result.message {
                        print("    Brightness: \(message)")
                    } else {
                        print("    Brightness: auto\(result.changed ? "" : unchanged)")
                    }
                } else if let percent = plan.brightnessPercent,
                          let result = plan.brightnessResult {
                    if let message = result.message {
                        print("    Brightness: \(message)")
                    } else {
                        print("    Brightness: \(percent)%\(result.changed ? "" : unchanged)")
                    }
                }
            }

            if trueTone != nil || nightShift != nil {
                if !displayPlans.isEmpty { print("") }
                print("\(status): \(L10n.text("Глобально", "Global"))")
                if let trueTone, let trueToneResult {
                    printColorFeature(
                        name: "TrueTone",
                        requested: String(trueTone),
                        result: trueToneResult,
                        unchangedSuffix: unchanged
                    )
                }
                if let nightShift, let nightShiftResult {
                    printColorFeature(
                        name: "NightShift",
                        requested: String(nightShift.enabledValue),
                        result: nightShiftResult,
                        unchangedSuffix: unchanged
                    )
                }
            }
        }
    }

    private func selectProfile(
        _ selection: String,
        display: DisplayDevice,
        from available: [ReferencePreset]
    ) throws -> ReferencePreset {
        if selection.lowercased() == "default" {
            return try presets.defaultPreset(for: display.id, from: available)
        }
        guard let ordinal = Int(selection),
              let match = available.first(where: { $0.ordinal == ordinal }) else {
            let range = available.isEmpty ? nil : 1...available.count
            throw DisplayCtlError.invalidPreset(Int(selection) ?? 0, valid: range)
        }
        return match
    }

    private func selectRate(_ selection: String, from available: [RefreshOption]) throws -> RefreshOption {
        let normalized = selection.lowercased()
        if normalized == "default" {
            return try refreshRates.defaultOption(from: available)
        }
        if let ordinal = Int(selection),
           let byOrdinal = available.first(where: { $0.ordinal == ordinal }) {
            return byOrdinal
        }
        throw DisplayCtlError.invalidRefreshRate(selection)
    }

    private func selectResolution(
        _ selection: String,
        from available: [ResolutionOption]
    ) throws -> ResolutionOption {
        if selection.lowercased() == "default" {
            return try refreshRates.defaultResolution(from: available)
        }
        if let ordinal = Int(selection),
           let match = available.first(where: { $0.ordinal == ordinal }) {
            return match
        }
        throw DisplayCtlError.invalidResolution(selection)
    }

    private func resolveRate(
        _ selection: String?,
        for display: DisplayDevice
    ) throws -> (option: RefreshOption?, unsupported: Bool) {
        guard let selection else { return (nil, false) }

        // Studio Display exposes only its fixed panel rate. Asking Quartz to
        // reapply it is not a supported refresh-rate change and can fail for
        // some reference presets, so it is intentionally treated as a no-op.
        guard display.kind == .studioDisplayXDR else { return (nil, true) }

        do {
            let available = try refreshRates.options(for: display)
            guard available.count > 1 else { return (nil, true) }
            return (try selectRate(selection, from: available), false)
        } catch DisplayCtlError.noRefreshRates {
            return (nil, true)
        }
    }

    // MARK: - Formatting

    private func previewColorChange(current: Bool?, requested: Bool) -> ColorFeatureChangeResult {
        guard let current else {
            return .unsupported(L10n.text(
                "изменение недоступно в текущей конфигурации",
                "the change is unavailable in the current configuration"
            ))
        }
        return current == requested ? .unchanged : .changed
    }

    private func colorFeatureJSON(
        requested: Any,
        result: ColorFeatureChangeResult
    ) -> [String: Any] {
        var output: [String: Any] = [
            "requested": requested,
            "changed": result.changed,
            "supported": result.supported,
            "global": true
        ]
        if let message = result.message {
            output["message"] = message
        }
        return output
    }

    private func printColorFeature(
        name: String,
        requested: String,
        result: ColorFeatureChangeResult,
        unchangedSuffix: String
    ) {
        if let message = result.message {
            print("    \(name): \(message)")
        } else {
            print("    \(name): \(requested)\(result.changed ? "" : unchangedSuffix)")
        }
    }

    private func printProfileRows(_ profiles: [ReferencePreset], indent: String) {
        if profiles.isEmpty {
            print("\(indent)—")
            return
        }
        for profile in profiles {
            print("\(indent)[\(profile.ordinal)] \(profile.name)\(profile.isActive ? " *" : "")")
        }
    }

    private func printRateRows(_ rates: [RefreshOption], indent: String) {
        if rates.isEmpty {
            print("\(indent)—")
            return
        }
        for rate in rates {
            print("\(indent)[\(rate.ordinal)] \(rate.label)\(rate.isActive ? " *" : "")")
        }
    }

    private func printResolutionRows(_ resolutions: [ResolutionOption], indent: String) {
        if resolutions.isEmpty {
            print("\(indent)—")
            return
        }
        for resolution in resolutions {
            print("\(indent)[\(resolution.ordinal)] \(resolution.label)\(resolution.isActive ? " *" : "")")
        }
    }

    private func snapshotJSON(_ snapshot: Snapshot, detailed: Bool) -> [String: Any] {
        let display = snapshot.display
        let activeProfile = snapshot.profiles.first(where: \.isActive)
        let activeRate = snapshot.rates.first(where: \.isActive)
        let activeResolution = snapshot.resolutions.first(where: \.isActive)
        let resolutionValue: Any
        if let activeResolution {
            resolutionValue = resolutionOptionJSON(activeResolution)
        } else {
            resolutionValue = resolutionJSON(display.resolution)
        }
        var result: [String: Any] = [
            "number": snapshot.number,
            "name": display.name,
            "role": display.isMain ? "main" : "secondary",
            "main": display.isMain,
            "profile": activeProfile.map(profileJSON) ?? NSNull(),
            "rate": activeRate.map { rateJSON($0) } ?? NSNull(),
            "resolution": resolutionValue,
            "mirroring": display.isMirrored,
            "id": display.id,
            "serial": snapshot.metadata.serial ?? display.serialText,
            "firmware": snapshot.metadata.firmware ?? NSNull(),
            "brightnessPercent": snapshot.brightnessPercent ?? NSNull(),
            "autoBrightness": snapshot.autoBrightness.enabled ?? NSNull(),
            "trueTone": snapshot.colorFeatures.trueTone ?? NSNull(),
            "nightShift": snapshot.colorFeatures.nightShift ?? NSNull()
        ]
        if detailed {
            result["profiles"] = snapshot.profiles.map(profileJSON)
            result["rates"] = snapshot.rates.map { rateJSON($0) }
            result["resolutions"] = snapshot.resolutions.map(resolutionOptionJSON)
        }
        return result
    }

    private func resolutionJSON(_ resolution: DisplayResolution?) -> Any {
        guard let resolution else { return NSNull() }
        return [
            "logicalWidth": resolution.logicalWidth,
            "logicalHeight": resolution.logicalHeight,
            "pixelWidth": resolution.pixelWidth,
            "pixelHeight": resolution.pixelHeight,
            "label": resolution.label
        ]
    }

    private func profileJSON(_ profile: ReferencePreset) -> [String: Any] {
        [
            "number": profile.ordinal,
            "systemIndex": profile.systemIndex,
            "name": profile.name,
            "uniqueID": profile.uniqueID ?? NSNull(),
            "active": profile.isActive
        ]
    }

    private func rateJSON(_ rate: RefreshOption) -> [String: Any] {
        [
            "number": rate.ordinal,
            "label": rate.label,
            "adaptive": rate.isAdaptive,
            "minimumHz": rate.minimumHz ?? NSNull(),
            "maximumHz": rate.maximumHz,
            "modeID": rate.modeID,
            "active": rate.isActive
        ]
    }

    private func resolutionOptionJSON(_ resolution: ResolutionOption) -> [String: Any] {
        [
            "number": resolution.ordinal,
            "label": resolution.label,
            "logicalWidth": resolution.logicalWidth,
            "logicalHeight": resolution.logicalHeight,
            "pixelWidth": resolution.pixelWidth,
            "pixelHeight": resolution.pixelHeight,
            "default": resolution.isDefault,
            "active": resolution.isActive
        ]
    }

    private func planJSON(_ plan: Plan) -> [String: Any] {
        var result: [String: Any] = [
            "number": plan.number,
            "name": plan.display.name,
            "id": plan.display.id
        ]
        if let profile = plan.profile {
            result["profile"] = [
                "number": profile.ordinal,
                "name": profile.name,
                "changed": !profile.isActive
            ]
        }
        if plan.rateUnsupported {
            result["rate"] = [
                "requested": plan.rateSelection.map { $0 as Any } ?? NSNull(),
                "supported": false,
                "changed": false,
                "message": L10n.text(
                    "Изменение частоты обновления не поддерживается",
                    "Refresh-rate changes are not supported"
                )
            ]
        } else if let rate = plan.rate {
            result["rate"] = [
                "number": rate.ordinal,
                "label": rate.label,
                "supported": true,
                "changed": !rate.isActive
            ]
        }
        if let resolution = plan.resolution {
            result["resolution"] = [
                "number": resolution.ordinal,
                "label": resolution.label,
                "default": resolution.isDefault,
                "changed": !resolution.isActive
            ]
        }
        if plan.brightnessSelection == "auto",
           let autoBrightnessResult = plan.autoBrightnessResult {
            var brightnessJSON: [String: Any] = [
                "requested": "auto",
                "automatic": true,
                "supported": autoBrightnessResult.supported,
                "changed": autoBrightnessResult.changed
            ]
            if let message = autoBrightnessResult.message {
                brightnessJSON["message"] = message
            }
            result["brightness"] = brightnessJSON
        } else if let percent = plan.brightnessPercent,
                  let brightnessResult = plan.brightnessResult {
            var brightnessJSON: [String: Any] = [
                "requestedPercent": percent,
                "automatic": false,
                "supported": brightnessResult.supported,
                "changed": brightnessResult.changed || (plan.autoBrightnessResult?.changed ?? false)
            ]
            if let message = brightnessResult.message {
                brightnessJSON["message"] = message
            }
            result["brightness"] = brightnessJSON
        }
        return result
    }

    private func printJSON(_ object: Any) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        print(String(decoding: data, as: UTF8.self))
    }

    private func optionalBool(_ value: Bool?) -> String {
        value.map(String.init) ?? "—"
    }

    private func displayHeader(number: Int, display: DisplayDevice) -> String {
        "\(displayLabel(number: number, display: display)):"
    }

    private func displayLabel(number: Int, display: DisplayDevice) -> String {
        let role = display.isMain
            ? L10n.text("Основной", "Main")
            : L10n.text("Дополнительный", "Secondary")
        return "[\(number)] \(display.name) (\(role))"
    }

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
