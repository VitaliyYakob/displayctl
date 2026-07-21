import Foundation

enum L10n {
    static var isRussian: Bool {
        guard let primaryLanguage = Locale.preferredLanguages.first else { return false }
        let normalized = primaryLanguage.replacingOccurrences(of: "_", with: "-").lowercased()
        return normalized == "ru" || normalized.hasPrefix("ru-")
    }

    static func text(_ russian: String, _ english: String) -> String {
        isRussian ? russian : english
    }

    /// CoreDisplay and IOKit often return dictionaries containing several
    /// localizations. Keep their values consistent with the CLI language:
    /// Russian for a Russian primary language, English for every other one.
    static func value(from localized: [String: String]) -> String? {
        let candidates = isRussian
            ? ["ru", "ru_RU", "ru-RU"]
            : ["en", "en_US", "en-US", "en_GB", "en-GB"]
        for candidate in candidates {
            if let value = localized[candidate] { return value }
        }

        let prefix = isRussian ? "ru" : "en"
        return localized.first { key, _ in
            let normalized = key.replacingOccurrences(of: "_", with: "-").lowercased()
            return normalized == prefix || normalized.hasPrefix("\(prefix)-")
        }?.value
    }
}
