import CoreGraphics
import Foundation

/// The requested mirror state and whether CoreGraphics needs to change it.
struct MirroringChangeResult {
    let display: DisplayDevice
    let enabled: Bool
    let changed: Bool
}

/// Stages all mirror changes in one persistent CoreGraphics transaction.
final class MirroringService {
    func isInMirrorSet(_ display: DisplayDevice, among displays: [DisplayDevice]) -> Bool {
        let source = CGDisplayMirrorsDisplay(display.id)
        if source != kCGNullDirectDisplay { return true }
        return displays.contains { candidate in
            candidate.id != display.id && CGDisplayMirrorsDisplay(candidate.id) == display.id
        }
    }

    func set(
        enabled: Bool,
        source: DisplayDevice,
        targets: [DisplayDevice],
        dryRun: Bool
    ) throws -> [MirroringChangeResult] {
        let results = targets.map { target in
            let currentSource = CGDisplayMirrorsDisplay(target.id)
            let alreadyRequested = enabled
                ? currentSource == source.id
                : currentSource == kCGNullDirectDisplay
            return MirroringChangeResult(
                display: target,
                enabled: enabled,
                changed: !alreadyRequested
            )
        }
        let changes = results.filter(\.changed)
        guard !dryRun, !changes.isEmpty else { return results }

        // Display reconfiguration can temporarily return kCGErrorFailure while
        // another system component is updating the same display arrangement.
        let maximumAttempts = 5
        var lastFailure = ""
        for attempt in 0..<maximumAttempts {
            var configuration: CGDisplayConfigRef?
            let beginError = CGBeginDisplayConfiguration(&configuration)
            guard beginError == .success, let configuration else {
                lastFailure = "CGBeginDisplayConfiguration: \(beginError.rawValue)"
                if shouldRetry(beginError, attempt: attempt, maximumAttempts: maximumAttempts) {
                    waitBeforeRetry(attempt)
                    continue
                }
                throw DisplayCtlError.displayConfiguration(lastFailure)
            }

            var stageError: CGError?
            var stageDisplayName = ""
            for change in changes {
                let mirrorSource = enabled ? source.id : kCGNullDirectDisplay
                let error = CGConfigureDisplayMirrorOfDisplay(
                    configuration,
                    change.display.id,
                    mirrorSource
                )
                if error != .success {
                    stageError = error
                    stageDisplayName = change.display.name
                    break
                }
            }

            if let stageError {
                CGCancelDisplayConfiguration(configuration)
                lastFailure = L10n.text(
                    "CGConfigureDisplayMirrorOfDisplay для \(stageDisplayName): \(stageError.rawValue)",
                    "CGConfigureDisplayMirrorOfDisplay for \(stageDisplayName): \(stageError.rawValue)"
                )
                if shouldRetry(stageError, attempt: attempt, maximumAttempts: maximumAttempts) {
                    waitBeforeRetry(attempt)
                    continue
                }
                throw DisplayCtlError.displayConfiguration(lastFailure)
            }

            let completeError = CGCompleteDisplayConfiguration(configuration, .permanently)
            if completeError == .success { return results }

            lastFailure = "CGCompleteDisplayConfiguration: \(completeError.rawValue)"
            if shouldRetry(completeError, attempt: attempt, maximumAttempts: maximumAttempts) {
                waitBeforeRetry(attempt)
                continue
            }
            throw DisplayCtlError.displayConfiguration(lastFailure)
        }

        throw DisplayCtlError.displayConfiguration(lastFailure)
    }

    private func shouldRetry(_ error: CGError, attempt: Int, maximumAttempts: Int) -> Bool {
        error.rawValue == CGError.failure.rawValue && attempt + 1 < maximumAttempts
    }

    private func waitBeforeRetry(_ attempt: Int) {
        Thread.sleep(forTimeInterval: 0.2 * Double(attempt + 1))
    }
}
