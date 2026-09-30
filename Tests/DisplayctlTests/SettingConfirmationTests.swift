import XCTest
@testable import displayctl

final class SettingConfirmationTests: XCTestCase {
    private struct State {
        let value: Int
        let supported: Bool
    }

    private func confirm(_ values: [State?]) -> (state: State?, delays: [TimeInterval]) {
        var index = 0
        var delays: [TimeInterval] = []
        let state = SettingConfirmation.wait(
            read: {
                defer { index += 1 }
                return index < values.count ? values[index] : nil
            },
            isSupported: { $0.supported },
            matches: { $0.value == 50 },
            sleep: { delays.append($0) }
        )
        return (state, delays)
    }

    func testStableTargetFinishesBeforeDeadline() {
        let result = confirm([
            State(value: 50, supported: true),
            State(value: 50, supported: true)
        ])
        XCTAssertEqual(result.state?.value, 50)
        XCTAssertEqual(result.delays.count, 2)
        XCTAssertEqual(result.delays.reduce(0, +), 0.3, accuracy: 0.0001)
    }

    func testTransientTargetIsNotAccepted() {
        let result = confirm([
            State(value: 50, supported: true),
            State(value: 20, supported: true),
            State(value: 20, supported: true),
            State(value: 20, supported: true),
            State(value: 20, supported: true)
        ])
        XCTAssertNil(result.state)
        XCTAssertEqual(result.delays.reduce(0, +), 0.6, accuracy: 0.0001)
    }

    func testMissingReadingInterruptsConfirmation() {
        let result = confirm([
            State(value: 50, supported: true),
            nil,
            State(value: 50, supported: true),
            State(value: 50, supported: true)
        ])
        XCTAssertEqual(result.state?.value, 50)
        XCTAssertEqual(result.delays.count, 4)
    }

    func testProfileRestrictionStopsConfirmation() {
        let result = confirm([
            State(value: 50, supported: true),
            State(value: 50, supported: false)
        ])
        XCTAssertEqual(result.state?.supported, false)
        XCTAssertEqual(result.delays.count, 2)
    }

    func testOneMatchingReadingAtDeadlineIsNotEnough() {
        let result = confirm([
            nil, nil, nil, nil, State(value: 50, supported: true)
        ])
        XCTAssertNil(result.state)
        XCTAssertEqual(result.delays.count, 5)
    }
}
