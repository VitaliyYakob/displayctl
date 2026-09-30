import Foundation
import XCTest
@testable import displayctl

final class FirmwareTests: XCTestCase {
    private func service(_ records: [[String: Any]]) -> FirmwareService {
        FirmwareService(loadData: {
            try? JSONSerialization.data(withJSONObject: ["SPDisplaysDataType": records])
        })
    }

    func testUnrelatedSingletonRecordIsNotAssigned() {
        let display = makeDisplay()
        let metadata = service([
            ["_name": "Other Monitor", "FirmwareVersion": "other"]
        ]).metadata(for: display, among: [display])
        XCTAssertNil(metadata.serial)
        XCTAssertNil(metadata.firmware)
    }

    func testTwoIdenticalNamesCannotShareOneRecord() {
        let displays = [makeDisplay(id: 1), makeDisplay(id: 2)]
        let service = service([
            ["_name": "Studio Display", "FirmwareVersion": "one"]
        ])
        for display in displays {
            XCTAssertNil(service.metadata(for: display, among: displays).firmware)
        }
    }

    func testUniqueNameRemainsAValidFallback() {
        let displays = [makeDisplay(), makeDisplay(id: 2, name: "Studio Display XDR")]
        let metadata = service([
            ["_name": "studio display", "FirmwareVersion": "17.0"]
        ]).metadata(for: displays[0], among: displays)
        XCTAssertEqual(metadata.firmware, "17.0")
    }

    func testSerialMatchesCaseInsensitively() {
        let displays = [makeDisplay(serial: "ABC123"), makeDisplay(id: 2, serial: "DEF456")]
        let service = service([
            ["_name": "Studio Display", "spdisplays_display-serial-number": "abc123", "FirmwareVersion": "first"],
            ["_name": "Studio Display", "spdisplays_display-serial-number": "def456", "FirmwareVersion": "second"]
        ])
        XCTAssertEqual(service.metadata(for: displays[0], among: displays).firmware, "first")
        XCTAssertEqual(service.metadata(for: displays[1], among: displays).firmware, "second")
    }

    func testDecimalAndHexadecimalDisplayIDsDisambiguateNames() {
        let displays = [makeDisplay(id: 12), makeDisplay(id: 13)]
        let service = service([
            ["_name": "Studio Display", "displayID": "12", "FirmwareVersion": "first"],
            ["_name": "Studio Display", "displayID": "0xD", "FirmwareVersion": "second"]
        ])
        XCTAssertEqual(service.metadata(for: displays[0], among: displays).firmware, "first")
        XCTAssertEqual(service.metadata(for: displays[1], among: displays).firmware, "second")
    }

    func testDuplicateSerialNumbersNeedAnotherIdentifier() {
        let displays = [makeDisplay(serial: "same"), makeDisplay(id: 2, serial: "same")]
        let service = service([
            ["_name": "Studio Display", "spdisplays_display-serial-number": "same", "FirmwareVersion": "ambiguous"]
        ])
        for display in displays {
            XCTAssertNil(service.metadata(for: display, among: displays).firmware)
        }
    }

    func testDuplicateMetadataRecordsAreNotSelectedArbitrarily() {
        let display = makeDisplay(serial: "same")
        let metadata = service([
            ["_name": "Studio Display", "spdisplays_display-serial-number": "same", "FirmwareVersion": "first"],
            ["_name": "Studio Display", "spdisplays_display-serial-number": "same", "FirmwareVersion": "second"]
        ]).metadata(for: display, among: [display])
        XCTAssertNil(metadata.firmware)
    }

    func testMissingAndMalformedMetadataRemainOptional() {
        let display = makeDisplay()
        for data in [nil, Data("not JSON".utf8)] {
            let metadata = FirmwareService(loadData: { data }).metadata(for: display, among: [display])
            XCTAssertNil(metadata.serial)
            XCTAssertNil(metadata.firmware)
        }
    }

    func testMetadataIsLoadedOnlyOncePerInvocation() {
        var loads = 0
        let displays = [makeDisplay(), makeDisplay(id: 2)]
        let service = FirmwareService(loadData: {
            loads += 1
            return Data("{}".utf8)
        })
        for display in displays {
            _ = service.metadata(for: display, among: displays)
        }
        XCTAssertEqual(loads, 1)
    }
}
