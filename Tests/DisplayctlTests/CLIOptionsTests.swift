import XCTest
@testable import displayctl

final class CLIOptionsTests: XCTestCase {
    func testIndependentSetBlocksPreserveTheirValuesAndDryRun() throws {
        let options = try CLIOptions.parse([
            "set", "--display", "1", "--profile", "4", "--bright", "auto",
            "--display", "2", "--profile", "2", "--bright", "50", "--dry-run", "--json"
        ])
        XCTAssertTrue(options.dryRun)
        XCTAssertTrue(options.json)
        XCTAssertEqual(options.displaySetOptions.map(\.displayNumber), [1, 2])
        XCTAssertEqual(options.displaySetOptions.map(\.profile), ["4", "2"])
        XCTAssertEqual(options.displaySetOptions.map(\.brightness), ["auto", "50"])
    }

    func testSingleDisplayAcceptsLeadingSetValues() throws {
        let options = try CLIOptions.parse(["set", "--profile", "4", "--display", "2", "--dry-run"])
        XCTAssertEqual(options.displaySetOptions.first?.profile, "4")
        XCTAssertEqual(options.displaySetOptions.first?.displayNumber, 2)
        XCTAssertTrue(options.dryRun)
    }

    func testReadSelectorsAndJSONArePreserved() throws {
        let options = try CLIOptions.parse(["info", "--display", "2", "--display", "3", "--json"])
        XCTAssertEqual(options.displayNumbers, [2, 3])
        XCTAssertTrue(options.json)
    }

    func testLayoutAndMirroringPreserveDryRun() throws {
        let layout = try CLIOptions.parse(["set", "--layout", "--main", "2", "--dry-run"])
        XCTAssertEqual(layout.layoutMainNumber, 2)
        XCTAssertTrue(layout.dryRun)
        let mirror = try CLIOptions.parse(["mirroring", "on", "--display", "2", "--dry-run"])
        XCTAssertTrue(mirror.dryRun)
        guard case .mirroring(enabled: true) = mirror.command else {
            return XCTFail("Expected an enabled mirroring command")
        }
    }

    func testBrightnessAcceptsBoundariesAndAutomaticMode() throws {
        for value in ["1", "100", "auto", "AUTO"] {
            XCTAssertNoThrow(try CLIOptions.parse(["set", "--bright", value]))
        }
        for value in ["0", "101", "50.5", "invalid"] {
            XCTAssertThrowsError(try CLIOptions.parse(["set", "--bright", value]))
        }
    }

    func testConflictingAndRepeatedSelectorsAreRejected() {
        let invalid = [
            ["set", "--all", "--display", "1", "--bright", "50"],
            ["set", "--display", "1", "--bright", "50", "--display", "1", "--bright", "60"],
            ["info", "--display", "1", "--display", "1"],
            ["list", "--display", "1"]
        ]
        for arguments in invalid { XCTAssertThrowsError(try CLIOptions.parse(arguments)) }
    }

    func testLayoutCannotMixSettingsOrOverflowCoordinates() {
        let invalid = [
            ["set", "--layout", "--main", "1", "--bright", "50"],
            ["set", "--layout", "--display", "2", "--position", "2147483648,0"],
            ["set", "--layout", "--display", "2", "--position", "0,-2147483649"],
            ["set", "--layout", "--display", "2", "--left-of", "1", "--right-of", "1"]
        ]
        for arguments in invalid { XCTAssertThrowsError(try CLIOptions.parse(arguments)) }
    }

    func testRequiredArgumentsAndUnsupportedCommandsAreRejected() {
        let invalid = [
            ["set"], ["set", "--bright"], ["set", "--profile", "0"],
            ["set", "--rate", "invalid"], ["mirroring", "--dry-run"],
            ["sleep"], ["wake"], ["disconnect"]
        ]
        for arguments in invalid { XCTAssertThrowsError(try CLIOptions.parse(arguments)) }
    }
}
