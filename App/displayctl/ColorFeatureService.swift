import Darwin
import Foundation
import ObjectiveC.runtime

struct ColorFeatureStatus {
    let trueTone: Bool?
    let nightShift: Bool?
}

enum ColorFeatureChangeResult {
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

enum NightShiftTarget: Equatable {
    case on
    case off

    var enabledValue: Bool { self == .on }

    var outputValue: String {
        switch self {
        case .on: return "on"
        case .off: return "off"
        }
    }
}

/// True Tone and Night Shift are user-session settings. CoreBrightness exposes
/// them globally rather than per CGDirectDisplayID, so these values are shown
/// for every compatible display but are changed only once per command.
final class ColorFeatureService {
    private struct BlueLightStatus {
        let enabled: Bool
        let available: Bool
    }

    private let frameworkHandle: UnsafeMutableRawPointer?
    private let trueToneClient: NSObject?
    private let blueLightClient: NSObject?

    init() {
        frameworkHandle = dlopen(
            "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
            RTLD_NOW | RTLD_LOCAL
        )
        trueToneClient = Self.makeClient(named: "CBTrueToneClient")
        blueLightClient = Self.makeClient(named: "CBBlueLightClient")
    }

    func status() -> ColorFeatureStatus {
        let nightShiftStatus = blueLightStatus()
        return ColorFeatureStatus(
            trueTone: trueToneState(),
            nightShift: nightShiftStatus.flatMap { $0.available ? $0.enabled : nil }
        )
    }

    func setTrueTone(enabled: Bool) throws -> ColorFeatureChangeResult {
        guard frameworkHandle != nil, let trueToneClient else {
            throw DisplayCtlError.colorFeatureUnavailable(L10n.text(
                "CoreBrightness/CBTrueToneClient недоступен",
                "CoreBrightness/CBTrueToneClient is unavailable"
            ))
        }
        guard boolValue("supported", on: trueToneClient) == true else {
            return .unsupported(L10n.text(
                "изменение не поддерживается текущей конфигурацией дисплеев",
                "changes are not supported by the current display configuration"
            ))
        }
        guard boolValue("available", on: trueToneClient) == true else {
            return .unsupported(L10n.text(
                "изменение не поддерживается активным профилем",
                "changes are not supported by the active profile"
            ))
        }
        if boolValue("enabled", on: trueToneClient) == enabled { return .unchanged }
        guard callBoolSetter("setEnabled:", value: enabled, on: trueToneClient) == true else {
            throw DisplayCtlError.colorFeatureUnavailable(L10n.text(
                "CoreBrightness отклонил изменение True Tone",
                "CoreBrightness rejected the True Tone change"
            ))
        }
        return .changed
    }

    func setNightShift(_ target: NightShiftTarget) throws -> ColorFeatureChangeResult {
        guard frameworkHandle != nil, let blueLightClient else {
            throw DisplayCtlError.colorFeatureUnavailable(L10n.text(
                "CoreBrightness/CBBlueLightClient недоступен",
                "CoreBrightness/CBBlueLightClient is unavailable"
            ))
        }
        guard boolValue("supported", on: blueLightClient) == true,
              let current = blueLightStatus() else {
            return .unsupported(L10n.text(
                "изменение не поддерживается текущей конфигурацией дисплеев",
                "changes are not supported by the current display configuration"
            ))
        }
        guard current.available else {
            return .unsupported(L10n.text(
                "изменение не поддерживается активным профилем",
                "changes are not supported by the active profile"
            ))
        }

        let requestedValue = target.enabledValue
        if current.enabled == requestedValue {
            guard let confirmed = settledBlueLightStatus(enabled: requestedValue),
                  confirmed.available,
                  confirmed.enabled == requestedValue else {
                return .unsupported(L10n.text(
                    "изменение не поддерживается активным профилем",
                    "changes are not supported by the active profile"
                ))
            }
            return .unchanged
        }

        switch target {
        case .on:
            guard setNightShiftEnabled(true, client: blueLightClient) else {
                return .unsupported(L10n.text(
                    "изменение не поддерживается активным профилем",
                    "changes are not supported by the active profile"
                ))
            }
        case .off:
            guard setNightShiftEnabled(false, client: blueLightClient) else {
                return .unsupported(L10n.text(
                    "изменение не поддерживается активным профилем",
                    "changes are not supported by the active profile"
                ))
            }
        }

        guard let confirmed = settledBlueLightStatus(enabled: requestedValue),
              confirmed.available,
              confirmed.enabled == requestedValue else {
            return .unsupported(L10n.text(
                "изменение не поддерживается активным профилем",
                "changes are not supported by the active profile"
            ))
        }
        return .changed
    }

    private func trueToneState() -> Bool? {
        guard frameworkHandle != nil, let trueToneClient,
              boolValue("supported", on: trueToneClient) == true,
              boolValue("available", on: trueToneClient) == true else {
            return nil
        }
        return boolValue("enabled", on: trueToneClient)
    }

    private func blueLightStatus() -> BlueLightStatus? {
        guard frameworkHandle != nil, let blueLightClient,
              boolValue("supported", on: blueLightClient) == true else {
            return nil
        }

        let selector = NSSelectorFromString("getBlueLightStatus:")
        guard let method = class_getInstanceMethod(type(of: blueLightClient), selector) else { return nil }
        typealias GetStatus = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
        let call = unsafeBitCast(method_getImplementation(method), to: GetStatus.self)

        // CBBlueLightStatus is private. CoreBrightness parses its dictionary as:
        // autoEnabled at byte 0, enabled at byte 1, scheduleAllowed at byte 2,
        // mode/schedule/disableFlags, and BlueReductionAvailable at byte 32.
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 40, alignment: 8)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 40)
        guard call(blueLightClient, selector, buffer) else { return nil }

        return BlueLightStatus(
            enabled: buffer.load(fromByteOffset: 1, as: UInt8.self) != 0,
            available: buffer.load(fromByteOffset: 32, as: UInt8.self) != 0
        )
    }

    private func settledBlueLightStatus(enabled: Bool) -> BlueLightStatus? {
        SettingConfirmation.wait(
            read: { self.blueLightStatus() },
            isSupported: { $0.available },
            matches: { $0.enabled == enabled }
        )
    }

    private func setNightShiftEnabled(_ enabled: Bool, client: NSObject) -> Bool {
        callBoolSetter("setEnabled:", value: enabled, on: client) == true
    }

    private func boolValue(_ selectorName: String, on object: NSObject) -> Bool? {
        let selector = NSSelectorFromString(selectorName)
        guard let method = class_getInstanceMethod(type(of: object), selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let call = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        return call(object, selector)
    }

    private func callBoolSetter(_ selectorName: String, value: Bool, on object: NSObject) -> Bool? {
        let selector = NSSelectorFromString(selectorName)
        guard let method = class_getInstanceMethod(type(of: object), selector) else { return nil }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Bool
        let call = unsafeBitCast(method_getImplementation(method), to: Setter.self)
        return call(object, selector, value)
    }

    private static func makeClient(named className: String) -> NSObject? {
        guard let type = NSClassFromString(className) as? NSObject.Type else { return nil }
        return type.init()
    }
}
