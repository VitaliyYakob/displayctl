import CoreGraphics
import Darwin
import Foundation

/// CoreDisplay is the same system component used by Displays Settings for
/// reference presets. Apple does not publish Swift headers for these symbols,
/// so the bridge resolves them at runtime and fails cleanly when they move.
final class CoreDisplayBridge {
    private typealias GetPresetCount = @convention(c) (UInt32) -> UInt32
    private typealias GetActivePresetIndex = @convention(c) (UInt32) -> Int32
    private typealias GetFactoryDefaultPresetIndex = @convention(c) (UInt32) -> Int32
    private typealias SetActivePresetIndex = @convention(c) (UInt32, UInt32) -> Int32
    private typealias IsPresetValid = @convention(c) (UInt32, UInt32) -> Int32
    private typealias CopyPreset = @convention(c) (UInt32, UInt32) -> UnsafeRawPointer?

    private let handle: UnsafeMutableRawPointer?
    private let loadError: String?

    private let getPresetCount: GetPresetCount?
    private let getActivePresetIndex: GetActivePresetIndex?
    private let getFactoryDefaultPresetIndex: GetFactoryDefaultPresetIndex?
    private let setActivePresetIndex: SetActivePresetIndex?
    private let isPresetValid: IsPresetValid?
    private let copyPreset: CopyPreset?

    private let nameKey: String?
    private let descriptionKey: String?
    private let uniqueIDKey: String?
    private let validKey: String?

    init() {
        let paths = [
            "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
            "/System/Library/PrivateFrameworks/CoreDisplay.framework/CoreDisplay"
        ]

        var opened: UnsafeMutableRawPointer?
        var errorMessage: String?
        for path in paths {
            if let candidate = dlopen(path, RTLD_NOW | RTLD_LOCAL) {
                opened = candidate
                break
            }
            if let error = dlerror() {
                errorMessage = String(cString: error)
            }
        }
        handle = opened
        loadError = opened == nil ? (errorMessage ?? L10n.text(
            "CoreDisplay не найден",
            "CoreDisplay was not found"
        )) : nil

        getPresetCount = Self.function(opened, "CoreDisplay_Display_GetPresetCount", as: GetPresetCount.self)
        getActivePresetIndex = Self.function(opened, "CoreDisplay_Display_GetActivePresetIndex", as: GetActivePresetIndex.self)
        getFactoryDefaultPresetIndex = Self.function(opened, "CoreDisplay_Display_GetFactoryDefaultPresetIndex", as: GetFactoryDefaultPresetIndex.self)
        setActivePresetIndex = Self.function(opened, "CoreDisplay_Display_SetActivePresetIndex", as: SetActivePresetIndex.self)
        isPresetValid = Self.function(opened, "CoreDisplay_Display_IsPresetValid", as: IsPresetValid.self)
        copyPreset = Self.function(opened, "CoreDisplay_Display_CopyPreset", as: CopyPreset.self)

        nameKey = Self.cfStringConstant(opened, "kCDDisplayPresetNameKey")
        descriptionKey = Self.cfStringConstant(opened, "kCDDisplayPresetDescriptionKey")
        uniqueIDKey = Self.cfStringConstant(opened, "kCDDisplayPresetUniqueIDKey")
        validKey = Self.cfStringConstant(opened, "kCDDisplayPresetValidKey")
    }

    deinit {
        if let handle { dlclose(handle) }
    }

    func presets(for displayID: CGDirectDisplayID) throws -> [ReferencePreset] {
        guard let getPresetCount, let getActivePresetIndex, let copyPreset else {
            throw unavailableError()
        }

        let count = getPresetCount(displayID)
        let activeIndex = getActivePresetIndex(displayID)
        var result: [ReferencePreset] = []

        for index in 0..<count {
            if let isPresetValid, isPresetValid(displayID, index) == 0 {
                continue
            }
            guard let rawDictionary = copyPreset(displayID, index) else { continue }
            let dictionary = Unmanaged<CFDictionary>.fromOpaque(rawDictionary).takeRetainedValue() as NSDictionary
            if let validKey, let valid = dictionary[validKey] as? NSNumber, !valid.boolValue {
                continue
            }

            let name = stringValue(dictionary[nameKey ?? "Name"])
                ?? stringValue(dictionary[descriptionKey ?? "Description"])
                ?? "\(L10n.text("Профиль", "Profile")) \(index + 1)"
            let uniqueID = stringValue(dictionary[uniqueIDKey ?? "UniqueID"])
            result.append(ReferencePreset(
                ordinal: result.count + 1,
                systemIndex: index,
                name: name,
                uniqueID: uniqueID,
                isActive: activeIndex >= 0 && UInt32(activeIndex) == index
            ))
        }
        return result
    }

    func setPreset(_ preset: ReferencePreset, for displayID: CGDirectDisplayID) throws {
        guard !preset.isActive else { return }
        guard let setActivePresetIndex else { throw unavailableError() }
        guard setActivePresetIndex(displayID, preset.systemIndex) != 0 else {
            throw DisplayCtlError.displayConfiguration(L10n.text(
                "CoreDisplay отклонил профиль с системным индексом \(preset.systemIndex)",
                "CoreDisplay rejected the profile with system index \(preset.systemIndex)"
            ))
        }
    }

    func defaultPreset(for displayID: CGDirectDisplayID, from available: [ReferencePreset]? = nil) throws -> ReferencePreset {
        let presetList = try available ?? presets(for: displayID)
        guard !presetList.isEmpty else { throw DisplayCtlError.noReferencePresets }
        if let getFactoryDefaultPresetIndex {
            let systemIndex = getFactoryDefaultPresetIndex(displayID)
            if systemIndex >= 0,
               let match = presetList.first(where: { $0.systemIndex == UInt32(systemIndex) }) {
                return match
            }
        }
        return presetList[0]
    }

    private func unavailableError() -> DisplayCtlError {
        let missing = [
            getPresetCount == nil ? "GetPresetCount" : nil,
            getActivePresetIndex == nil ? "GetActivePresetIndex" : nil,
            setActivePresetIndex == nil ? "SetActivePresetIndex" : nil,
            copyPreset == nil ? "CopyPreset" : nil
        ].compactMap { $0 }
        let details = loadError ?? L10n.text(
            "не найдены символы: \(missing.joined(separator: ", "))",
            "missing symbols: \(missing.joined(separator: ", "))"
        )
        return .coreDisplayUnavailable(details)
    }

    private func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let localized = value as? [String: String] {
            return L10n.value(from: localized) ?? localized.values.first
        }
        return nil
    }

    private static func function<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as type: T.Type) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }

    private static func cfStringConstant(_ handle: UnsafeMutableRawPointer?, _ name: String) -> String? {
        guard let handle, let address = dlsym(handle, name) else { return nil }
        let value = address.assumingMemoryBound(to: UnsafeRawPointer?.self).pointee
        guard let value else { return nil }
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }
}
