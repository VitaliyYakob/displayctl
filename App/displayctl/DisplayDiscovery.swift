import AppKit
import CoreGraphics
import Darwin
import Foundation

/// Enumerates online displays and keeps only supported Apple Studio Display models.
final class DisplayDiscovery {
    private let appleVendorID: UInt32 = 0x0610
    private let studioDisplayXDRModelIDs: Set<UInt32> = [0xae42, 0xae43]
    private let studioDisplayModelIDs: Set<UInt32> = [
        0x9d02, // Studio Display (2022)
        0xae3a, 0xae3b, 0xae3e, 0xae3f, 0xae46, 0xae47 // Studio Display (2026)
    ]
    private let infoLoader = DisplayInfoLoader()

    func activeDisplays() throws -> [DisplayDevice] {
        var count: UInt32 = 0
        // Mirrored follower displays disappear from CGGetActiveDisplayList but
        // remain connected and addressable. The online list keeps their IDs and
        // therefore preserves displayctl ordinals while mirroring is enabled.
        var result = CGGetOnlineDisplayList(0, nil, &count)
        guard result == .success else {
            throw DisplayCtlError.displayConfiguration(L10n.text(
                "CGGetOnlineDisplayList вернул код \(result.rawValue)",
                "CGGetOnlineDisplayList returned code \(result.rawValue)"
            ))
        }
        guard count > 0 else { throw DisplayCtlError.noDisplays }

        var ids = Array(repeating: CGDirectDisplayID(), count: Int(count))
        result = CGGetOnlineDisplayList(count, &ids, &count)
        guard result == .success else {
            throw DisplayCtlError.displayConfiguration(L10n.text(
                "CGGetOnlineDisplayList вернул код \(result.rawValue)",
                "CGGetOnlineDisplayList returned code \(result.rawValue)"
            ))
        }

        let screenNames = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, String)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return (number.uint32Value, screen.localizedName)
        })

        let activeIDs = Array(ids.prefix(Int(count)))
        return activeIDs.map { id in
            let ioInfo = displayInfo(for: id)
            let name = screenNames[id]
                ?? localizedProductName(from: ioInfo)
                ?? "Display \(id)"
            let vendorID = CGDisplayVendorNumber(id)
            let modelID = CGDisplayModelNumber(id)
            let numericSerial = CGDisplaySerialNumber(id)
            let ioSerial = uint32Value(ioInfo?["DisplaySerialNumber"])
            let serial = ioSerial ?? numericSerial
            let serialText = serialString(from: ioInfo) ?? String(serial)
            let mirrorTarget = CGDisplayMirrorsDisplay(id)
            let isMirrored = mirrorTarget != kCGNullDirectDisplay
                || activeIDs.contains { otherID in
                    otherID != id && CGDisplayMirrorsDisplay(otherID) == id
                }
            let resolution = CGDisplayCopyDisplayMode(id).map { mode in
                DisplayResolution(
                    logicalWidth: mode.width,
                    logicalHeight: mode.height,
                    pixelWidth: mode.pixelWidth,
                    pixelHeight: mode.pixelHeight
                )
            }

            return DisplayDevice(
                id: id,
                name: name,
                vendorID: vendorID,
                modelID: modelID,
                serialNumber: serial,
                serialText: serialText,
                isMain: CGDisplayIsMain(id) != 0,
                isBuiltIn: CGDisplayIsBuiltin(id) != 0,
                isMirrored: isMirrored,
                resolution: resolution,
                kind: displayKind(name: name, vendorID: vendorID, modelID: modelID)
            )
        }
    }

    func supportedDisplays(from displays: [DisplayDevice]) throws -> [DisplayDevice] {
        let supported = displays
            .filter { $0.kind != nil }
            .sorted { lhs, rhs in
                if lhs.isMain != rhs.isMain { return lhs.isMain }
                return lhs.id < rhs.id
            }
        guard !supported.isEmpty else { throw DisplayCtlError.noSupportedDisplays }
        return supported
    }

    func select(from supported: [DisplayDevice], number: Int?) throws -> DisplayDevice {
        if let number {
            guard number > 0, number <= supported.count else {
                throw DisplayCtlError.displayNotFound(String(number))
            }
            return supported[number - 1]
        }

        if let main = supported.first(where: \.isMain) {
            return main
        }
        return supported[0]
    }

    private func displayKind(name: String, vendorID: UInt32, modelID: UInt32) -> DisplayKind? {
        guard vendorID == appleVendorID else { return nil }
        if studioDisplayXDRModelIDs.contains(modelID) {
            return .studioDisplayXDR
        }
        if studioDisplayModelIDs.contains(modelID) {
            return .studioDisplay
        }

        let normalized = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
        if normalized.contains("studio display xdr") {
            return .studioDisplayXDR
        }
        if normalized.contains("studio display") {
            return .studioDisplay
        }
        return nil
    }

    private func displayInfo(for id: CGDirectDisplayID) -> [String: Any]? {
        infoLoader.info(for: id)
    }

    private func localizedProductName(from info: [String: Any]?) -> String? {
        if let name = info?["DisplayProductName"] as? String, !name.isEmpty {
            return name
        }
        guard let names = info?["DisplayProductName"] as? [String: String] else { return nil }
        return L10n.value(from: names) ?? names.values.first
    }

    private func uint32Value(_ value: Any?) -> UInt32? {
        if let number = value as? NSNumber { return number.uint32Value }
        return nil
    }

    private func serialString(from info: [String: Any]?) -> String? {
        let possibleKeys = ["DisplaySerialString", "SerialNumber", "serial-number", "USB Serial Number"]
        for key in possibleKeys {
            if let value = info?[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

private final class DisplayInfoLoader {
    private typealias CreateInfoDictionary = @convention(c) (UInt32) -> UnsafeRawPointer?

    private let handle: UnsafeMutableRawPointer?
    private let createInfoDictionary: CreateInfoDictionary?

    init() {
        let paths = [
            "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
            "/System/Library/PrivateFrameworks/CoreDisplay.framework/CoreDisplay"
        ]
        var opened: UnsafeMutableRawPointer?
        for path in paths {
            if let candidate = dlopen(path, RTLD_NOW | RTLD_LOCAL) {
                opened = candidate
                break
            }
        }
        handle = opened
        if let opened, let symbol = dlsym(opened, "CoreDisplay_DisplayCreateInfoDictionary") {
            createInfoDictionary = unsafeBitCast(symbol, to: CreateInfoDictionary.self)
        } else {
            createInfoDictionary = nil
        }
    }

    deinit {
        if let handle { dlclose(handle) }
    }

    func info(for displayID: CGDirectDisplayID) -> [String: Any]? {
        guard let raw = createInfoDictionary?(displayID) else { return nil }
        return Unmanaged<CFDictionary>.fromOpaque(raw).takeRetainedValue() as? [String: Any]
    }
}
