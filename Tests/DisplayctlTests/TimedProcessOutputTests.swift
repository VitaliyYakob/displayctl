import Foundation
import XCTest
@testable import displayctl

final class TimedProcessOutputTests: XCTestCase {
    private func run(_ script: String, timeout: TimeInterval = 2) -> Data? {
        TimedProcessOutput.read(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            timeout: timeout
        )
    }

    func testCapturesSuccessfulOutput() {
        XCTAssertEqual(run("printf 'metadata'"), Data("metadata".utf8))
    }

    func testVerboseStderrCannotBlockSuccessfulOutput() {
        XCTAssertEqual(
            run("printf '%100000s' '' >&2; printf 'metadata'"),
            Data("metadata".utf8)
        )
    }

    func testFailedProcessDoesNotSupplyMetadata() {
        XCTAssertNil(run("printf 'incomplete'; exit 1"))
    }

    func testHungProcessIsTerminatedWithinDeadline() {
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertNil(run("exec /bin/sleep 10", timeout: 0.05))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1.5)
    }

    func testProcessIgnoringTerminationIsStillBounded() {
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertNil(run("trap '' TERM; exec /bin/sleep 10", timeout: 0.05))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1.5)
    }

    func testOversizedOutputIsNotParsed() {
        XCTAssertNil(run("printf '%4194305s' ''"))
    }

    func testMissingExecutableRemainsOptional() {
        XCTAssertNil(TimedProcessOutput.read(
            executableURL: URL(fileURLWithPath: "/displayctl-missing-executable"),
            arguments: []
        ))
    }
}
