import Darwin
import Foundation

/// Captures optional system metadata without an unbounded process wait or a
/// full pipe blocking the child. Temporary output is private and always removed.
enum TimedProcessOutput {
    static func read(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval = 5
    ) -> Data? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("displayctl-metadata-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            defer { try? FileManager.default.removeItem(at: directory) }
            let outputURL = directory.appendingPathComponent("stdout")
            guard FileManager.default.createFile(
                atPath: outputURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else { return nil }
            let output = try FileHandle(forUpdating: outputURL)
            defer { try? output.close() }

            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = output
            // Firmware is optional. Discard diagnostics without creating an
            // unread stderr pipe that could deadlock system_profiler.
            process.standardError = FileHandle.nullDevice
            try process.run()

            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                process.terminate()
                let terminationDeadline = ProcessInfo.processInfo.systemUptime + 0.25
                while process.isRunning && ProcessInfo.processInfo.systemUptime < terminationDeadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                return nil
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            try output.seek(toOffset: 0)
            let maximumBytes = 4 * 1024 * 1024
            guard let data = try output.read(upToCount: maximumBytes + 1),
                  data.count <= maximumBytes else { return nil }
            return data
        } catch {
            return nil
        }
    }
}
