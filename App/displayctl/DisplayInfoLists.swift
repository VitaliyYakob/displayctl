import Foundation

/// Optional mode tables must not prevent info from reporting the remaining
/// display properties. Preserve each failed field's reason for text and JSON.
struct DisplayInfoLists {
    let profiles: [ReferencePreset]
    let rates: [RefreshOption]
    let resolutions: [ResolutionOption]
    let warnings: [String]

    init(
        profiles: () throws -> [ReferencePreset],
        rates: () throws -> [RefreshOption],
        resolutions: () throws -> [ResolutionOption]
    ) {
        var warnings: [String] = []
        self.profiles = Self.read("profiles", operation: profiles, warnings: &warnings)
        self.rates = Self.read("rates", operation: rates, warnings: &warnings)
        self.resolutions = Self.read("resolutions", operation: resolutions, warnings: &warnings)
        self.warnings = warnings
    }

    private static func read<Value>(
        _ field: String,
        operation: () throws -> [Value],
        warnings: inout [String]
    ) -> [Value] {
        do {
            return try operation()
        } catch {
            warnings.append("\(field): \(error)")
            return []
        }
    }
}
