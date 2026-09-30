import CoreGraphics
import Foundation

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
        let warnings: [String]
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

    private lazy var discovery = DisplayDiscovery()
    private lazy var presets = CoreDisplayBridge()
    private lazy var refreshRates = RefreshRateService()
    private lazy var brightness = BrightnessService()
    private lazy var autoBrightness = AutoBrightnessService()
    private lazy var layout = LayoutService()
    private lazy var mirroring = MirroringService()
    private lazy var firmware = FirmwareService()
    private lazy var colorFeatures = ColorFeatureService()

    func run(arguments: [String]) throws {
        let options = try CLIOptions.parse(arguments)
        switch options.command {
        case .help:
            print(Self.help)
            return
        case .version:
            print("displayctl 1.0.2")
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
        let snapshots = targets.map { display in
            snapshot(
                number: displayNumber(display, in: allDisplays),
                display: display,
                allDisplays: allDisplays,
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
        allDisplays: [DisplayDevice],
        colorFeatures: ColorFeatureStatus
    ) -> Snapshot {
        let lists = DisplayInfoLists(
            profiles: { try self.presets.presets(for: display.id) },
            rates: { try self.refreshRates.options(for: display) },
            resolutions: { try self.refreshRates.resolutions(for: display) }
        )
        return Snapshot(
            number: number,
            display: display,
            profiles: lists.profiles,
            rates: lists.rates,
            resolutions: lists.resolutions,
            metadata: firmware.metadata(for: display, among: allDisplays),
            brightnessPercent: brightness.valuePercent(for: display),
            autoBrightness: autoBrightness.status(for: display),
            colorFeatures: colorFeatures,
            warnings: lists.warnings
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
        for warning in snapshot.warnings {
            print("    \(L10n.text("Предупреждение", "Warning")): \(warning)")
        }
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

        let initialColorFeatures = trueTone != nil || nightShift != nil
            ? colorFeatures.status()
            : ColorFeatureStatus(trueTone: nil, nightShift: nil)
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
        if !snapshot.warnings.isEmpty {
            result["warnings"] = snapshot.warnings
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

}
