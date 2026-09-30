import Foundation

/// Confirms an asynchronous setting with two consecutive matching readings.
/// Keep the existing settling delay and deadline, but finish as soon as the
/// requested value is stable. Missing readings interrupt that confirmation.
enum SettingConfirmation {
    static func wait<State>(
        read: () -> State?,
        isSupported: (State) -> Bool,
        matches: (State) -> Bool,
        sleep: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:)
    ) -> State? {
        var consecutiveMatches = 0
        for attempt in 0..<5 {
            sleep(attempt == 0 ? 0.2 : 0.1)
            guard let state = read() else {
                consecutiveMatches = 0
                continue
            }
            guard isSupported(state) else { return state }
            consecutiveMatches = matches(state) ? consecutiveMatches + 1 : 0
            if consecutiveMatches == 2 { return state }
        }
        return nil
    }
}
