import CoreGraphics
import Darwin
import Foundation
import ObjectiveC.runtime

struct AutoBrightnessStatus {
    let supported: Bool
    let enabled: Bool?
}

enum AutoBrightnessChangeResult {
    case changed
    case unchanged
    case unsupported(String)

    var changed: Bool {
        switch self {
        case .changed: return true
        case .unchanged, .unsupported: return false
        }
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

/// DisplayServices is the system component used by Displays Settings for
/// ambient-light compensation. The symbols are private, so every entry point
/// is resolved at runtime and absence is reported as an unsupported feature.
final class AutoBrightnessService {
    private typealias HasAmbientLightCompensation = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias AmbientLightCompensationEnabled = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias EnableAmbientLightCompensation = @convention(c) (CGDirectDisplayID, Bool) -> Int32

    private let handle: UnsafeMutableRawPointer?
    private let coreBrightnessHandle: UnsafeMutableRawPointer?
    private let displayServicesClient: NSObject?
    private let hasAmbientLightCompensation: HasAmbientLightCompensation?
    private let ambientLightCompensationEnabled: AmbientLightCompensationEnabled?
    private let enableAmbientLightCompensation: EnableAmbientLightCompensation?

    init() {
        let opened = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_NOW | RTLD_LOCAL
        )
        handle = opened
        coreBrightnessHandle = dlopen(
            "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
            RTLD_NOW | RTLD_LOCAL
        )
        displayServicesClient = Self.makeClient(named: "DisplayServicesClient")
        hasAmbientLightCompensation = Self.function(
            opened,
            "DisplayServicesHasAmbientLightCompensation",
            as: HasAmbientLightCompensation.self
        )
        ambientLightCompensationEnabled = Self.function(
            opened,
            "DisplayServicesAmbientLightCompensationEnabled",
            as: AmbientLightCompensationEnabled.self
        )
        enableAmbientLightCompensation = Self.function(
            opened,
            "DisplayServicesEnableAmbientLightCompensation",
            as: EnableAmbientLightCompensation.self
        )
    }

    deinit {
        if let handle { dlclose(handle) }
    }

    func status(for display: DisplayDevice) -> AutoBrightnessStatus {
        // Displays Settings uses DisplayServicesClient on current macOS. Its
        // Available property also reflects restrictions of a reference preset.
        if let available = propertyBool("CBAutoBrightnessAvailable", for: display) {
            return AutoBrightnessStatus(
                supported: available,
                enabled: available
                    ? propertyBool("CBAutoBrightnessEnabled", for: display)
                    : nil
            )
        }

        guard handle != nil,
              let hasAmbientLightCompensation,
              let ambientLightCompensationEnabled else {
            return AutoBrightnessStatus(supported: false, enabled: nil)
        }
        let supported = hasAmbientLightCompensation(display.id)
        return AutoBrightnessStatus(
            supported: supported,
            enabled: supported ? ambientLightCompensationEnabled(display.id) : nil
        )
    }

    func preview(enabled: Bool, for display: DisplayDevice) -> AutoBrightnessChangeResult {
        let current = status(for: display)
        guard current.supported, let currentEnabled = current.enabled else {
            return .unsupported(Self.unsupportedMessage)
        }
        return currentEnabled == enabled ? .unchanged : .changed
    }

    func set(enabled: Bool, for display: DisplayDevice) throws -> AutoBrightnessChangeResult {
        let current = status(for: display)
        guard current.supported, let currentEnabled = current.enabled else {
            return .unsupported(Self.unsupportedMessage)
        }
        if currentEnabled == enabled { return .unchanged }

        if propertyBool("CBAutoBrightnessAvailable", for: display) != nil {
            guard setPropertyBool(
                enabled,
                key: "CBAutoBrightnessEnabled",
                for: display
            ) else {
                if !status(for: display).supported { return .unsupported(Self.unsupportedMessage) }
                throw DisplayCtlError.brightnessUnavailable(L10n.text(
                    "CoreBrightness отклонил изменение автоматической яркости для \(display.name)",
                    "CoreBrightness rejected the automatic-brightness change for \(display.name)"
                ))
            }
        } else {
            guard let enableAmbientLightCompensation else {
                return .unsupported(Self.unsupportedMessage)
            }
            let result = enableAmbientLightCompensation(display.id, enabled)
            guard result == 0 else {
                if !status(for: display).supported { return .unsupported(Self.unsupportedMessage) }
                throw DisplayCtlError.brightnessUnavailable(L10n.text(
                    "DisplayServicesEnableAmbientLightCompensation для \(display.name): \(result)",
                    "DisplayServicesEnableAmbientLightCompensation for \(display.name): \(result)"
                ))
            }
        }

        // The setting is asynchronous. A short bounded confirmation prevents a
        // successful return for a reference preset that silently rejects ALC.
        for attempt in 0..<5 {
            Thread.sleep(forTimeInterval: attempt == 0 ? 0.2 : 0.1)
            let confirmed = status(for: display)
            if !confirmed.supported { return .unsupported(Self.unsupportedMessage) }
            if confirmed.enabled == enabled { return .changed }
        }
        return .unsupported(Self.unsupportedMessage)
    }

    private static var unsupportedMessage: String {
        L10n.text(
            "изменение не поддерживается дисплеем или активным профилем",
            "changes are not supported by the display or active profile"
        )
    }

    private func propertyBool(_ key: String, for display: DisplayDevice) -> Bool? {
        guard coreBrightnessHandle != nil, let displayServicesClient else { return nil }
        let selector = NSSelectorFromString("copyPropertyForKey:andDisplay:")
        guard let method = class_getInstanceMethod(type(of: displayServicesClient), selector) else {
            return nil
        }
        typealias Getter = @convention(c) (
            AnyObject,
            Selector,
            NSString,
            UInt64
        ) -> Unmanaged<AnyObject>?
        let call = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        guard let value = call(
            displayServicesClient,
            selector,
            key as NSString,
            UInt64(display.id)
        )?.takeRetainedValue() as? NSNumber else {
            return nil
        }
        return value.boolValue
    }

    private func setPropertyBool(
        _ value: Bool,
        key: String,
        for display: DisplayDevice
    ) -> Bool {
        guard coreBrightnessHandle != nil, let displayServicesClient else { return false }
        let selector = NSSelectorFromString("setProperty:withKey:andDisplay:")
        guard let method = class_getInstanceMethod(type(of: displayServicesClient), selector) else {
            return false
        }
        typealias Setter = @convention(c) (
            AnyObject,
            Selector,
            NSNumber,
            NSString,
            UInt64
        ) -> Bool
        let call = unsafeBitCast(method_getImplementation(method), to: Setter.self)
        return call(
            displayServicesClient,
            selector,
            NSNumber(value: value),
            key as NSString,
            UInt64(display.id)
        )
    }

    private static func makeClient(named className: String) -> NSObject? {
        guard let type = NSClassFromString(className) as? NSObject.Type else { return nil }
        return type.init()
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
