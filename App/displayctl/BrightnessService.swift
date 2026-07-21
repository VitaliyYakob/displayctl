import CoreGraphics
import Darwin
import Foundation

enum BrightnessChangeResult {
    case changed
    case unchanged
    case unsupported(String)

    var changed: Bool {
        if case .changed = self { return true }
        return false
    }

    var supported: Bool {
        if case .unsupported = self { return false }
        return true
    }

    var message: String? {
        if case .unsupported(let message) = self { return message }
        return nil
    }
}

/// DisplayServices is the system component behind the brightness slider in
/// Displays Settings. Its values use the normalized slider range 0.0...1.0.
final class BrightnessService {
    private struct Status {
        let value: Float
        let canChange: Bool
    }

    private typealias CanChangeBrightness = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private let handle: UnsafeMutableRawPointer?
    private let canChangeBrightness: CanChangeBrightness?
    private let getBrightness: GetBrightness?
    private let setBrightness: SetBrightness?

    init() {
        let opened = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_NOW | RTLD_LOCAL
        )
        handle = opened
        canChangeBrightness = Self.function(
            opened,
            "DisplayServicesCanChangeBrightness",
            as: CanChangeBrightness.self
        )
        getBrightness = Self.function(
            opened,
            "DisplayServicesGetBrightness",
            as: GetBrightness.self
        )
        setBrightness = Self.function(
            opened,
            "DisplayServicesSetBrightness",
            as: SetBrightness.self
        )
    }

    deinit {
        if let handle { dlclose(handle) }
    }

    func valuePercent(for display: DisplayDevice) -> Int? {
        guard let value = value(for: display) else { return nil }
        return Self.percent(from: value)
    }

    func preview(percent: Int, for display: DisplayDevice) throws -> BrightnessChangeResult {
        guard symbolsAvailable else { throw unavailableError() }
        guard canChange(for: display) != false else {
            return .unsupported(Self.profileUnsupportedMessage)
        }
        guard let status = status(for: display) else {
            throw readError(display: display)
        }
        guard status.canChange else { return .unsupported(Self.profileUnsupportedMessage) }
        return Self.matches(status.value, percent: percent) ? .unchanged : .changed
    }

    func set(percent: Int, for display: DisplayDevice) throws -> BrightnessChangeResult {
        guard symbolsAvailable, let setBrightness else { throw unavailableError() }
        guard canChange(for: display) != false else {
            return .unsupported(Self.profileUnsupportedMessage)
        }
        guard let current = status(for: display) else {
            throw readError(display: display)
        }
        guard current.canChange else { return .unsupported(Self.profileUnsupportedMessage) }

        if Self.matches(current.value, percent: percent) {
            guard let confirmed = settledStatus(for: display), confirmed.canChange else {
                return .unsupported(Self.profileUnsupportedMessage)
            }
            return Self.matches(confirmed.value, percent: percent)
                ? .unchanged
                : .unsupported(Self.profileUnsupportedMessage)
        }

        let result = setBrightness(display.id, Float(percent) / 100.0)
        if result != 0 {
            if canChangeBrightness?(display.id) == false {
                return .unsupported(Self.profileUnsupportedMessage)
            }
            throw DisplayCtlError.brightnessUnavailable(L10n.text(
                "DisplayServicesSetBrightness для \(display.name): \(result)",
                "DisplayServicesSetBrightness for \(display.name): \(result)"
            ))
        }

        guard let confirmed = settledStatus(for: display),
              confirmed.canChange,
              Self.matches(confirmed.value, percent: percent) else {
            return .unsupported(Self.profileUnsupportedMessage)
        }
        return .changed
    }

    private var symbolsAvailable: Bool {
        handle != nil && canChangeBrightness != nil && getBrightness != nil && setBrightness != nil
    }

    private func status(for display: DisplayDevice) -> Status? {
        guard let value = value(for: display), let canChange = canChange(for: display) else {
            return nil
        }
        return Status(value: value, canChange: canChange)
    }

    private func value(for display: DisplayDevice) -> Float? {
        guard let getBrightness else { return nil }
        var value: Float = 0
        guard getBrightness(display.id, &value) == 0 else { return nil }
        return min(max(value, 0), 1)
    }

    private func canChange(for display: DisplayDevice) -> Bool? {
        canChangeBrightness?(display.id)
    }

    private func settledStatus(for display: DisplayDevice) -> Status? {
        var lastStatus: Status?
        for attempt in 0..<5 {
            Thread.sleep(forTimeInterval: attempt == 0 ? 0.2 : 0.1)
            if canChange(for: display) == false {
                return Status(value: 0, canChange: false)
            }
            guard let status = status(for: display) else { continue }
            lastStatus = status
            if !status.canChange { return status }
        }
        return lastStatus
    }

    private func unavailableError() -> DisplayCtlError {
        .brightnessUnavailable(L10n.text(
            "системный интерфейс DisplayServices недоступен",
            "the DisplayServices system interface is unavailable"
        ))
    }

    private func readError(display: DisplayDevice) -> DisplayCtlError {
        .brightnessUnavailable(L10n.text(
            "не удалось прочитать значение для \(display.name)",
            "could not read the value for \(display.name)"
        ))
    }

    private static var profileUnsupportedMessage: String {
        L10n.text(
            "изменение не поддерживается активным профилем",
            "changes are not supported by the active profile"
        )
    }

    private static func matches(_ value: Float, percent: Int) -> Bool {
        abs(value - Float(percent) / 100.0) <= 0.005
    }

    private static func percent(from value: Float) -> Int {
        Int((min(max(value, 0), 1) * 100).rounded())
    }

    private static func function<T>(
        _ handle: UnsafeMutableRawPointer?,
        _ name: String,
        as type: T.Type
    ) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }
}
