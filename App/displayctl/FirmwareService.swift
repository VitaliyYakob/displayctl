import Foundation

/// Firmware is not part of Quartz Display Services. `system_profiler` is the
/// system-supported source shown by System Information, so detailed output
/// queries it lazily and caches the result for the lifetime of the process.
final class FirmwareService {
    struct Metadata {
        let serial: String?
        let firmware: String?
    }

    private struct Record {
        let name: String?
        let serial: String?
        let displayID: String?
        let firmware: String
    }

    private let loadData: () -> Data?
    private lazy var records: [Record] = loadRecords()

    init(loadData: @escaping () -> Data? = {
        TimedProcessOutput.read(
            executableURL: URL(fileURLWithPath: "/usr/sbin/system_profiler"),
            arguments: ["SPDisplaysDataType", "-json", "-detailLevel", "full"]
        )
    }) {
        self.loadData = loadData
    }

    func metadata(for display: DisplayDevice, among displays: [DisplayDevice]) -> Metadata {
        guard let record = record(for: display, among: displays) else {
            return Metadata(serial: nil, firmware: nil)
        }
        return Metadata(serial: record.serial, firmware: record.firmware)
    }

    private func record(for display: DisplayDevice, among displays: [DisplayDevice]) -> Record? {
        let validSerial = display.serialText != "0" && !display.serialText.isEmpty
        if validSerial {
            let matches = records.filter {
                $0.serial?.caseInsensitiveCompare(display.serialText) == .orderedSame
            }
            let displaysWithSerial = displays.filter {
                $0.serialText.caseInsensitiveCompare(display.serialText) == .orderedSame
            }
            if matches.count == 1 && displaysWithSerial.count == 1 { return matches[0] }
        }

        let idText = String(display.id)
        let idMatches = records.filter { record in
            guard let candidate = record.displayID else { return false }
            return candidate == idText || candidate.lowercased() == String(format: "0x%x", display.id)
        }
        if idMatches.count == 1 { return idMatches[0] }

        let normalizedName = normalize(display.name)
        // Names can identify a record only when both the connected-display
        // list and the metadata list contain exactly one such display.
        guard displays.filter({ normalize($0.name) == normalizedName }).count == 1 else {
            return nil
        }
        let nameMatches = records.filter { record in
            record.name.map(normalize) == normalizedName
        }
        if nameMatches.count == 1 { return nameMatches[0] }
        return nil
    }

    private func loadRecords() -> [Record] {
        do {
            guard let data = loadData(),
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return []
            }
            var result: [Record] = []
            collectRecords(in: root, into: &result)
            return result
        } catch {
            return []
        }
    }

    private func collectRecords(in value: Any, into result: inout [Record]) {
        if let dictionary = value as? [String: Any] {
            if let firmware = firmwareValue(in: dictionary) {
                result.append(Record(
                    name: scalarString(dictionary["_name"]),
                    serial: serialValue(in: dictionary),
                    displayID: firstScalar(in: dictionary, matching: { $0.lowercased().contains("displayid") }),
                    firmware: firmware
                ))
            }
            for nested in dictionary.values {
                collectRecords(in: nested, into: &result)
            }
        } else if let array = value as? [Any] {
            for nested in array {
                collectRecords(in: nested, into: &result)
            }
        }
    }

    private func firmwareValue(in dictionary: [String: Any]) -> String? {
        let preferredKeys = [
            "spdisplays_display-fw-version",
            "spdisplays_display_firmware_version",
            "DisplayFirmwareVersion",
            "FirmwareVersion",
            "firmware-version"
        ]
        for key in preferredKeys {
            if let value = scalarString(dictionary[key]) { return value }
        }
        return firstScalar(in: dictionary) { key in
            let lowered = key.lowercased()
            return lowered.contains("firmware") && lowered.contains("version")
        }
    }

    private func serialValue(in dictionary: [String: Any]) -> String? {
        // The underscored fields are internal EDID values. In particular,
        // _spdisplays_display-serial-number2 may contain a hexadecimal value,
        // while System Information displays the non-underscored enclosure
        // serial. Prefer the same field that users see in System Information.
        let preferredKeys = [
            "spdisplays_display-serial-number",
            "DisplaySerialNumber",
            "DisplaySerialString"
        ]
        for key in preferredKeys {
            if let value = scalarString(dictionary[key]) { return value }
        }

        return dictionary
            .filter { key, _ in
                let lowered = key.lowercased()
                return lowered.contains("serial") && !lowered.hasPrefix("_spdisplays")
            }
            .compactMap { scalarString($0.value) }
            .first
    }

    private func firstScalar(in dictionary: [String: Any], matching predicate: (String) -> Bool) -> String? {
        for (key, value) in dictionary where predicate(key) {
            if let result = scalarString(value) { return result }
        }
        return nil
    }

    private func scalarString(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
