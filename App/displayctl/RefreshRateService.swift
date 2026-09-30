import AppKit
import CoreGraphics
import Darwin
import Foundation

/// A combined geometry/rate request applied as one CoreGraphics mode change.
struct DisplayModeRequest {
    let display: DisplayDevice
    let resolution: ResolutionOption?
    let rate: RefreshOption?
}

/// Builds user-facing mode lists and applies compatible modes transactionally.
final class RefreshRateService {
    private typealias IsDisplayModeVRR = @convention(c) (UInt32, Int32) -> Int32
    private typealias GetDisplayModeMinRefreshRate = @convention(c) (UInt32, Int32, UnsafeMutablePointer<Float>) -> Int32

    private let skyLightHandle: UnsafeMutableRawPointer?
    private let isDisplayModeVRR: IsDisplayModeVRR?
    private let getDisplayModeMinRefreshRate: GetDisplayModeMinRefreshRate?

    init() {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL)
        skyLightHandle = handle
        isDisplayModeVRR = Self.function(handle, "SLSIsDisplayModeVRR", as: IsDisplayModeVRR.self)
        getDisplayModeMinRefreshRate = Self.function(handle, "SLSGetDisplayModeMinRefreshRate", as: GetDisplayModeMinRefreshRate.self)
    }

    deinit {
        if let skyLightHandle { dlclose(skyLightHandle) }
    }

    func resolutions(for display: DisplayDevice) throws -> [ResolutionOption] {
        guard let current = CGDisplayCopyDisplayMode(display.id) else {
            throw DisplayCtlError.noResolutions
        }

        // On recent macOS versions the Studio Display 2× Retina modes are only
        // present in the expanded CoreGraphics table. Read that table, then
        // strictly keep the five user-facing Studio Display Retina scales.
        let allModes = try copyAllModes(
            for: display.id,
            includeDuplicateLowResolutionModes: true,
            emptyError: .noResolutions
        )
        var collected: [(
            mode: CGDisplayMode,
            logicalWidth: Int,
            logicalHeight: Int,
            pixelWidth: Int,
            pixelHeight: Int,
            isDefault: Bool,
            isActive: Bool
        )] = []
        var indexesByGeometry: [String: Int] = [:]

        for mode in allModes where isStandardStudioRetinaResolution(mode) {
            let key = geometryKey(mode)
            let active = sameGeometry(mode, current)
            let isDefault = isDefaultMode(mode)
            if let index = indexesByGeometry[key] {
                collected[index].isDefault = collected[index].isDefault || isDefault
                collected[index].isActive = collected[index].isActive || active
                if active || (isDefault && !isDefaultMode(collected[index].mode)) {
                    collected[index].mode = mode
                }
                continue
            }
            indexesByGeometry[key] = collected.count
            collected.append((
                mode: mode,
                logicalWidth: mode.width,
                logicalHeight: mode.height,
                pixelWidth: mode.pixelWidth,
                pixelHeight: mode.pixelHeight,
                isDefault: isDefault,
                isActive: active
            ))
        }

        collected.sort { lhs, rhs in
            let lhsArea = lhs.logicalWidth * lhs.logicalHeight
            let rhsArea = rhs.logicalWidth * rhs.logicalHeight
            if lhsArea != rhsArea { return lhsArea > rhsArea }
            if lhs.logicalWidth != rhs.logicalWidth { return lhs.logicalWidth > rhs.logicalWidth }
            let lhsPixels = lhs.pixelWidth * lhs.pixelHeight
            let rhsPixels = rhs.pixelWidth * rhs.pixelHeight
            return lhsPixels > rhsPixels
        }

        guard !collected.isEmpty else { throw DisplayCtlError.noResolutions }
        return collected.enumerated().map { offset, item in
            ResolutionOption(
                ordinal: offset + 1,
                mode: item.mode,
                logicalWidth: item.logicalWidth,
                logicalHeight: item.logicalHeight,
                pixelWidth: item.pixelWidth,
                pixelHeight: item.pixelHeight,
                isDefault: item.isDefault,
                isActive: item.isActive
            )
        }
    }

    func options(for display: DisplayDevice) throws -> [RefreshOption] {
        guard let current = CGDisplayCopyDisplayMode(display.id) else {
            throw DisplayCtlError.noRefreshRates
        }

        let allModes = try copyAllModes(for: display.id, emptyError: .noRefreshRates)

        let compatibleModes = allModes.filter { mode in
            mode.width == current.width
                && mode.height == current.height
                && mode.pixelWidth == current.pixelWidth
                && mode.pixelHeight == current.pixelHeight
                && mode.isUsableForDesktopGUI()
        }

        var collected: [(
            mode: CGDisplayMode,
            modeID: Int32,
            maxHz: Double,
            minHz: Double?,
            adaptive: Bool,
            active: Bool
        )] = []
        var indexesByKey: [String: Int] = [:]

        for mode in compatibleModes {
            let modeID = mode.ioDisplayModeID
            let maxHz = mode.refreshRate
            let adaptive = isAdaptiveMode(displayID: display.id, modeID: modeID)
            let minHz = adaptive ? minimumRefreshRate(displayID: display.id, modeID: modeID) : nil
            let normalizedMax = maxHz > 0 ? maxHz : Double(NSScreenMaximumFPS.value(for: display.id) ?? 0)
            guard normalizedMax > 0 else { continue }

            let dedupeKey = adaptive
                ? "adaptive:\(Int((minHz ?? 0) * 100)):\(Int(normalizedMax * 100))"
                : "fixed:\(Int((normalizedMax * 100).rounded()))"
            let item = (
                mode: mode,
                modeID: modeID,
                maxHz: normalizedMax,
                minHz: minHz,
                adaptive: adaptive,
                active: CFEqual(mode, current) || mode.ioDisplayModeID == current.ioDisplayModeID
            )
            if let existingIndex = indexesByKey[dedupeKey] {
                if item.active && !collected[existingIndex].active {
                    collected[existingIndex] = item
                }
                continue
            }
            indexesByKey[dedupeKey] = collected.count
            collected.append(item)
        }

        // The XDR mode table contains an internal fixed entry whose raw rate
        // equals the VRR ceiling (for example 120.04 Hz). Displays Settings does
        // not expose that entry: it exposes the canonical fixed 120 Hz mode.
        // Hide only this VRR-ceiling duplicate, while preserving broadcast
        // pairs that the UI really shows (59.94/60 and 47.95/48).
        let adaptiveMaximums = collected.filter(\.adaptive).map(\.maxHz)
        let canonicalFixedRates = collected
            .filter { !$0.adaptive && abs($0.maxHz - $0.maxHz.rounded()) < 0.005 }
            .map(\.maxHz)
        collected.removeAll { item in
            guard !item.adaptive else { return false }
            return adaptiveMaximums.contains(where: { abs($0 - item.maxHz) < 0.01 })
                && canonicalFixedRates.contains(where: { abs($0 - item.maxHz.rounded()) < 0.01 })
        }

        collected.sort { lhs, rhs in
            if lhs.adaptive != rhs.adaptive { return lhs.adaptive }
            return lhs.maxHz > rhs.maxHz
        }

        guard !collected.isEmpty else { throw DisplayCtlError.noRefreshRates }
        return collected.enumerated().map { offset, item in
            RefreshOption(
                ordinal: offset + 1,
                mode: item.mode,
                modeID: item.modeID,
                maximumHz: item.maxHz,
                minimumHz: item.minHz,
                isAdaptive: item.adaptive,
                isActive: item.active
            )
        }
    }

    func set(_ requestedChanges: [DisplayModeRequest]) throws -> Set<CGDirectDisplayID> {
        guard !requestedChanges.isEmpty else { return [] }

        let maximumAttempts = 5
        var lastFailure = ""
        for attempt in 0..<maximumAttempts {
            // Profiles and display reconfiguration can invalidate a previously
            // returned CGDisplayMode. Always map the requested value to a live
            // mode object immediately before starting the transaction.
            let live: (
                changes: [(display: DisplayDevice, mode: CGDisplayMode)],
                unavailableDisplayIDs: Set<CGDirectDisplayID>
            )
            do {
                live = try liveChanges(for: requestedChanges)
            } catch let error as DisplayCtlError {
                lastFailure = error.description
                if attempt + 1 < maximumAttempts {
                    waitBeforeRetry(attempt)
                    continue
                }
                throw error
            }
            if !live.unavailableDisplayIDs.isEmpty, attempt + 1 < maximumAttempts {
                waitBeforeRetry(attempt)
                continue
            }
            let changes = live.changes
            guard !changes.isEmpty else { return live.unavailableDisplayIDs }

            var configuration: CGDisplayConfigRef?
            let beginError = CGBeginDisplayConfiguration(&configuration)
            guard beginError == .success, let configuration else {
                lastFailure = "CGBeginDisplayConfiguration: \(beginError.rawValue)"
                if shouldRetry(beginError, attempt: attempt, maximumAttempts: maximumAttempts) {
                    waitBeforeRetry(attempt)
                    continue
                }
                throw DisplayCtlError.displayConfiguration(lastFailure)
            }

            var stageError: CGError?
            var stageDisplayName = ""
            for change in changes {
                let error = CGConfigureDisplayWithDisplayMode(
                    configuration,
                    change.display.id,
                    change.mode,
                    nil
                )
                if error != .success {
                    stageError = error
                    stageDisplayName = change.display.name
                    break
                }
            }

            if let stageError {
                CGCancelDisplayConfiguration(configuration)
                lastFailure = L10n.text(
                    "CGConfigureDisplayWithDisplayMode для \(stageDisplayName): \(stageError.rawValue)",
                    "CGConfigureDisplayWithDisplayMode for \(stageDisplayName): \(stageError.rawValue)"
                )
                if shouldRetry(stageError, attempt: attempt, maximumAttempts: maximumAttempts) {
                    waitBeforeRetry(attempt)
                    continue
                }
                throw DisplayCtlError.displayConfiguration(lastFailure)
            }

            let completeError = CGCompleteDisplayConfiguration(configuration, .permanently)
            if completeError == .success { return live.unavailableDisplayIDs }

            lastFailure = "CGCompleteDisplayConfiguration: \(completeError.rawValue)"
            if shouldRetry(completeError, attempt: attempt, maximumAttempts: maximumAttempts) {
                waitBeforeRetry(attempt)
                continue
            }
            throw DisplayCtlError.displayConfiguration(lastFailure)
        }

        throw DisplayCtlError.displayConfiguration(lastFailure)
    }

    func defaultOption(from available: [RefreshOption]) throws -> RefreshOption {
        guard !available.isEmpty else { throw DisplayCtlError.noRefreshRates }
        return available.first(where: \.isAdaptive) ?? available[0]
    }

    func defaultResolution(from available: [ResolutionOption]) throws -> ResolutionOption {
        guard !available.isEmpty else { throw DisplayCtlError.noResolutions }

        // The driver flag is the primary source of truth. On a Retina table,
        // prefer its 2× logical representation if the flag appears on several
        // entries that share the native panel timing.
        let flagged = available.filter(\.isDefault)
        if let retinaDefault = flagged.first(where: isRetinaTwoTimes) {
            return retinaDefault
        }
        if let driverDefault = flagged.first {
            return driverDefault
        }

        // Defensive fallback for a mode table without the driver flag. Both
        // supported Studio Display families use 2560×1440 at 2× by default.
        if let studioDefault = available.first(where: {
            $0.logicalWidth == 2560
                && $0.logicalHeight == 1440
                && $0.pixelWidth == 5120
                && $0.pixelHeight == 2880
        }) {
            return studioDefault
        }
        return available.first(where: \.isActive) ?? available[0]
    }

    private func minimumRefreshRate(displayID: CGDirectDisplayID, modeID: Int32) -> Double? {
        guard let getDisplayModeMinRefreshRate else { return nil }
        var value: Float = 0
        guard getDisplayModeMinRefreshRate(displayID, modeID, &value) == 0, value > 0 else { return nil }
        return Double(value)
    }

    private func liveChanges(
        for requestedChanges: [DisplayModeRequest]
    ) throws -> (
        changes: [(display: DisplayDevice, mode: CGDisplayMode)],
        unavailableDisplayIDs: Set<CGDirectDisplayID>
    ) {
        var changes: [(display: DisplayDevice, mode: CGDisplayMode)] = []
        var unavailableDisplayIDs: Set<CGDirectDisplayID> = []

        for request in requestedChanges {
            guard let current = CGDisplayCopyDisplayMode(request.display.id) else {
                throw DisplayCtlError.displayConfiguration(L10n.text(
                    "Не удалось получить текущий видеорежим для \(request.display.name).",
                    "Could not obtain the current display mode for \(request.display.name)."
                ))
            }
            let allModes: [CGDisplayMode]
            do {
                allModes = try copyAllModes(
                    for: request.display.id,
                    emptyError: request.resolution == nil ? .noRefreshRates : .noResolutions
                )
            } catch DisplayCtlError.noRefreshRates {
                unavailableDisplayIDs.insert(request.display.id)
                continue
            }
            let targetGeometry = request.resolution?.mode ?? current
            let compatible = allModes.filter {
                sameGeometry($0, targetGeometry) && $0.isUsableForDesktopGUI()
            }
            guard !compatible.isEmpty else {
                throw DisplayCtlError.displayConfiguration(L10n.text(
                    "Разрешение \(request.resolution?.label ?? DisplayResolution(mode: current).label) больше недоступно для \(request.display.name).",
                    "Resolution \(request.resolution?.label ?? DisplayResolution(mode: current).label) is no longer available for \(request.display.name)."
                ))
            }

            var selected: CGDisplayMode?
            if let requestedRate = request.rate {
                selected = matchingMode(
                    for: requestedRate,
                    in: compatible,
                    current: current,
                    displayID: request.display.id
                )
                if selected == nil {
                    unavailableDisplayIDs.insert(request.display.id)
                    // A requested resolution remains independently actionable
                    // when that resolution does not offer the requested rate.
                    guard request.resolution != nil else { continue }
                }
            }
            if selected == nil {
                selected = sameGeometry(current, targetGeometry)
                    ? current
                    : preferredMode(
                        in: compatible,
                        preserving: current,
                        displayID: request.display.id
                    )
            }

            guard let selected else { continue }
            if !CFEqual(selected, current) && selected.ioDisplayModeID != current.ioDisplayModeID {
                changes.append((request.display, selected))
            }
        }

        return (changes, unavailableDisplayIDs)
    }

    private func copyAllModes(
        for displayID: CGDirectDisplayID,
        includeDuplicateLowResolutionModes: Bool = true,
        emptyError: DisplayCtlError
    ) throws -> [CGDisplayMode] {
        let options: CFDictionary?
        if includeDuplicateLowResolutionModes {
            let optionKey = kCGDisplayShowDuplicateLowResolutionModes as String
            options = [optionKey: true] as CFDictionary
        } else {
            options = nil
        }
        guard let allModes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode],
              !allModes.isEmpty else {
            throw emptyError
        }
        return allModes
    }

    private func matchingMode(
        for requested: RefreshOption,
        in modes: [CGDisplayMode],
        current: CGDisplayMode,
        displayID: CGDirectDisplayID
    ) -> CGDisplayMode? {
        if requested.isAdaptive {
            if modes.contains(where: { $0.ioDisplayModeID == current.ioDisplayModeID }),
               isAdaptiveMode(displayID: displayID, modeID: current.ioDisplayModeID) {
                return current
            }
            return modes
                .filter { isAdaptiveMode(displayID: displayID, modeID: $0.ioDisplayModeID) }
                .min {
                    abs(normalizedRefreshRate($0, displayID: displayID) - requested.maximumHz)
                        < abs(normalizedRefreshRate($1, displayID: displayID) - requested.maximumHz)
                }
        }

        if modes.contains(where: { $0.ioDisplayModeID == current.ioDisplayModeID }),
           !isAdaptiveMode(displayID: displayID, modeID: current.ioDisplayModeID),
           abs(normalizedRefreshRate(current, displayID: displayID) - requested.maximumHz) <= 0.05 {
            return current
        }
        let closest = modes
            .filter { !isAdaptiveMode(displayID: displayID, modeID: $0.ioDisplayModeID) }
            .min {
                abs(normalizedRefreshRate($0, displayID: displayID) - requested.maximumHz)
                    < abs(normalizedRefreshRate($1, displayID: displayID) - requested.maximumHz)
            }
        return closest.flatMap {
            abs(normalizedRefreshRate($0, displayID: displayID) - requested.maximumHz) <= 0.05 ? $0 : nil
        }
    }

    private func preferredMode(
        in modes: [CGDisplayMode],
        preserving current: CGDisplayMode,
        displayID: CGDirectDisplayID
    ) -> CGDisplayMode? {
        let currentIsAdaptive = isAdaptiveMode(displayID: displayID, modeID: current.ioDisplayModeID)
        let sameKind = modes.filter {
            isAdaptiveMode(displayID: displayID, modeID: $0.ioDisplayModeID) == currentIsAdaptive
        }
        let currentHz = normalizedRefreshRate(current, displayID: displayID)
        if let closest = sameKind.min(by: {
            abs(normalizedRefreshRate($0, displayID: displayID) - currentHz)
                < abs(normalizedRefreshRate($1, displayID: displayID) - currentHz)
        }) {
            return closest
        }
        return modes.first(where: isDefaultMode) ?? modes.first
    }

    private func isAdaptiveMode(displayID: CGDirectDisplayID, modeID: Int32) -> Bool {
        Self.isAdaptive(vrrResult: isDisplayModeVRR?(displayID, modeID))
    }

    static func isAdaptive(vrrResult: Int32?) -> Bool {
        // Optional comparison would incorrectly classify nil as nonzero.
        // A missing private API must never advertise Adaptive Sync support.
        (vrrResult ?? 0) != 0
    }

    private func normalizedRefreshRate(_ mode: CGDisplayMode, displayID: CGDirectDisplayID) -> Double {
        mode.refreshRate > 0
            ? mode.refreshRate
            : Double(NSScreenMaximumFPS.value(for: displayID) ?? 0)
    }

    private func geometryKey(_ mode: CGDisplayMode) -> String {
        "\(mode.width):\(mode.height):\(mode.pixelWidth):\(mode.pixelHeight)"
    }

    private func sameGeometry(_ lhs: CGDisplayMode, _ rhs: CGDisplayMode) -> Bool {
        lhs.width == rhs.width
            && lhs.height == rhs.height
            && lhs.pixelWidth == rhs.pixelWidth
            && lhs.pixelHeight == rhs.pixelHeight
    }

    private func isDefaultMode(_ mode: CGDisplayMode) -> Bool {
        // kDisplayModeDefaultFlag from IOGraphicsTypes.h.
        mode.ioFlags & 0x00000004 != 0
    }

    private func isRetinaTwoTimes(_ option: ResolutionOption) -> Bool {
        option.logicalWidth * 2 == option.pixelWidth
            && option.logicalHeight * 2 == option.pixelHeight
    }

    private func isStandardStudioRetinaResolution(_ mode: CGDisplayMode) -> Bool {
        guard mode.isUsableForDesktopGUI(),
              mode.width * 2 == mode.pixelWidth,
              mode.height * 2 == mode.pixelHeight else {
            return false
        }
        return Self.standardStudioLogicalResolutions.contains(
            "\(mode.width)x\(mode.height)"
        )
    }

    private static let standardStudioLogicalResolutions: Set<String> = [
        "1600x900",
        "2048x1152",
        "2560x1440",
        "2880x1620",
        "3200x1800"
    ]

    private func shouldRetry(_ error: CGError, attempt: Int, maximumAttempts: Int) -> Bool {
        error.rawValue == CGError.failure.rawValue && attempt + 1 < maximumAttempts
    }

    private func waitBeforeRetry(_ attempt: Int) {
        Thread.sleep(forTimeInterval: 0.2 * Double(attempt + 1))
    }

    private static func function<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as type: T.Type) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }
}

private enum NSScreenMaximumFPS {
    static func value(for displayID: CGDirectDisplayID) -> Int? {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  number.uint32Value == displayID else { continue }
            return screen.maximumFramesPerSecond
        }
        return nil
    }
}
