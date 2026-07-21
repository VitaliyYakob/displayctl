import CoreGraphics
import Foundation

/// Apple display families intentionally supported by this command-line tool.
enum DisplayKind: String, Codable {
    case studioDisplay = "studio-display"
    case studioDisplayXDR = "studio-display-xdr"

    var title: String {
        switch self {
        case .studioDisplay:
            return "Studio Display"
        case .studioDisplayXDR:
            return "Studio Display XDR"
        }
    }
}

/// A stable snapshot of the CoreGraphics and IOKit properties used by the CLI.
struct DisplayDevice {
    let id: CGDirectDisplayID
    let name: String
    let vendorID: UInt32
    let modelID: UInt32
    let serialNumber: UInt32
    let serialText: String
    let isMain: Bool
    let isBuiltIn: Bool
    let isMirrored: Bool
    let resolution: DisplayResolution?
    let kind: DisplayKind?

}

/// Logical desktop dimensions paired with the physical framebuffer dimensions.
struct DisplayResolution {
    let logicalWidth: Int
    let logicalHeight: Int
    let pixelWidth: Int
    let pixelHeight: Int

    init(
        logicalWidth: Int,
        logicalHeight: Int,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    init(mode: CGDisplayMode) {
        self.init(
            logicalWidth: mode.width,
            logicalHeight: mode.height,
            pixelWidth: mode.pixelWidth,
            pixelHeight: mode.pixelHeight
        )
    }

    var label: String {
        if logicalWidth == pixelWidth && logicalHeight == pixelHeight {
            return "\(pixelWidth)×\(pixelHeight)"
        }
        return "\(logicalWidth)×\(logicalHeight) (\(pixelWidth)×\(pixelHeight) px)"
    }
}

/// A user-facing Retina mode and the CoreGraphics mode required to apply it.
struct ResolutionOption {
    let ordinal: Int
    let mode: CGDisplayMode
    let logicalWidth: Int
    let logicalHeight: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let isDefault: Bool
    let isActive: Bool

    var resolution: DisplayResolution {
        DisplayResolution(
            logicalWidth: logicalWidth,
            logicalHeight: logicalHeight,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }

    var label: String { resolution.label }
}

/// A CoreDisplay reference preset with a CLI ordinal and its system index.
struct ReferencePreset {
    let ordinal: Int
    let systemIndex: UInt32
    let name: String
    let uniqueID: String?
    let isActive: Bool
}

/// A fixed or variable refresh-rate mode available for the current geometry.
struct RefreshOption {
    let ordinal: Int
    let mode: CGDisplayMode
    let modeID: Int32
    let maximumHz: Double
    let minimumHz: Double?
    let isAdaptive: Bool
    let isActive: Bool

    var label: String {
        if isAdaptive {
            if let minimumHz {
                return L10n.text(
                    "Адаптивная (\(Self.formatAdaptiveHz(minimumHz))–\(Self.formatAdaptiveHz(maximumHz)) Гц)",
                    "Adaptive (\(Self.formatAdaptiveHz(minimumHz))–\(Self.formatAdaptiveHz(maximumHz)) Hz)"
                )
            }
            return L10n.text(
                "Адаптивная (до \(Self.formatAdaptiveHz(maximumHz)) Гц)",
                "Adaptive (up to \(Self.formatAdaptiveHz(maximumHz)) Hz)"
            )
        }
        return "\(Self.formatHz(maximumHz)) \(L10n.text("Гц", "Hz"))"
    }

    static func formatHz(_ value: Double) -> String {
        let roundedInteger = value.rounded()
        if abs(value - roundedInteger) < 0.005 {
            return String(Int(roundedInteger))
        }
        let formatted = String(format: "%.2f", value)
        return L10n.isRussian ? formatted.replacingOccurrences(of: ".", with: ",") : formatted
    }

    private static func formatAdaptiveHz(_ value: Double) -> String {
        String(Int(value.rounded()))
    }
}

/// Domain errors are localized at the CLI boundary and remain stable in JSON.
enum DisplayCtlError: Error, CustomStringConvertible {
    case noDisplays
    case noSupportedDisplays
    case displayNotFound(String)
    case coreDisplayUnavailable(String)
    case noReferencePresets
    case invalidPreset(Int, valid: ClosedRange<Int>?)
    case noRefreshRates
    case invalidRefreshRate(String)
    case noResolutions
    case invalidResolution(String)
    case displayConfiguration(String)
    case brightnessUnavailable(String)
    case colorFeatureUnavailable(String)
    case invalidArguments(String)

    var description: String {
        switch self {
        case .noDisplays:
            return L10n.text("Apple Studio Display не найден", "Apple Studio Display not found")
        case .noSupportedDisplays:
            return L10n.text("Apple Studio Display не найден", "Apple Studio Display not found")
        case .displayNotFound(let selector):
            return L10n.text(
                "Монитор №\(selector) не найден. Выполните displayctl list, чтобы увидеть порядковые номера.",
                "Display #\(selector) was not found. Run displayctl list to see ordinal numbers."
            )
        case .coreDisplayUnavailable(let details):
            return L10n.text(
                "Системный интерфейс референсных режимов недоступен: \(details)",
                "The system reference-mode interface is unavailable: \(details)"
            )
        case .noReferencePresets:
            return L10n.text(
                "Для выбранного монитора macOS не вернула ни одного референсного режима.",
                "macOS did not return any reference modes for the selected display."
            )
        case .invalidPreset(let ordinal, let valid):
            if let valid {
                return L10n.text(
                    "Профиль №\(ordinal) отсутствует. Допустимый диапазон: \(valid.lowerBound)...\(valid.upperBound).",
                    "Profile #\(ordinal) does not exist. Valid range: \(valid.lowerBound)...\(valid.upperBound)."
                )
            }
            return L10n.text(
                "Профиль №\(ordinal) отсутствует.",
                "Profile #\(ordinal) does not exist."
            )
        case .noRefreshRates:
            return L10n.text(
                "Для текущего разрешения и масштаба macOS не вернула варианты частоты обновления.",
                "macOS did not return refresh-rate options for the current resolution and scaling."
            )
        case .invalidRefreshRate(let value):
            return L10n.text(
                "Частота «\(value)» не найдена. Укажите порядковый номер из displayctl rates или default.",
                "Refresh rate \"\(value)\" was not found. Specify an ordinal from displayctl rates or default."
            )
        case .noResolutions:
            return L10n.text(
                "macOS не вернула доступные разрешения экрана.",
                "macOS did not return any available display resolutions."
            )
        case .invalidResolution(let value):
            return L10n.text(
                "Разрешение «\(value)» не найдено. Укажите порядковый номер из displayctl res или default.",
                "Resolution \"\(value)\" was not found. Specify an ordinal from displayctl res or default."
            )
        case .displayConfiguration(let details):
            return L10n.text(
                "Не удалось изменить конфигурацию монитора: \(details)",
                "Could not change the display configuration: \(details)"
            )
        case .brightnessUnavailable(let details):
            return L10n.text(
                "Не удалось изменить яркость: \(details)",
                "Could not change the brightness: \(details)"
            )
        case .colorFeatureUnavailable(let details):
            return L10n.text(
                "Не удалось изменить цветовую функцию: \(details)",
                "Could not change the color feature: \(details)"
            )
        case .invalidArguments(let details):
            return details
        }
    }
}
