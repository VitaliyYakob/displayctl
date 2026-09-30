import XCTest
@testable import displayctl

final class DisplayInfoTests: XCTestCase {
    func testMissingProfilesDoNotPreventOtherTablesFromBeingRead() {
        var ratesRead = false
        var resolutionsRead = false
        let lists = DisplayInfoLists(
            profiles: { throw DisplayCtlError.coreDisplayUnavailable("missing symbol") },
            rates: { ratesRead = true; return [] },
            resolutions: { resolutionsRead = true; return [] }
        )
        XCTAssertTrue(ratesRead)
        XCTAssertTrue(resolutionsRead)
        XCTAssertTrue(lists.profiles.isEmpty)
        XCTAssertEqual(lists.warnings.count, 1)
        XCTAssertTrue(lists.warnings[0].hasPrefix("profiles:"))
        XCTAssertTrue(lists.warnings[0].contains("missing symbol"))
    }

    func testMultipleFailuresKeepTheirReasonsAndSuccessfulData() {
        let profile = ReferencePreset(
            ordinal: 1, systemIndex: 0, name: "Available", uniqueID: nil, isActive: true
        )
        let lists = DisplayInfoLists(
            profiles: { [profile] },
            rates: { throw DisplayCtlError.noRefreshRates },
            resolutions: { throw DisplayCtlError.noResolutions }
        )
        XCTAssertEqual(lists.profiles.first?.name, "Available")
        XCTAssertEqual(lists.warnings.count, 2)
        XCTAssertTrue(lists.warnings[0].hasPrefix("rates:"))
        XCTAssertTrue(lists.warnings[1].hasPrefix("resolutions:"))
    }

    func testSuccessfulTablesDoNotProduceWarnings() {
        let lists = DisplayInfoLists(profiles: { [] }, rates: { [] }, resolutions: { [] })
        XCTAssertTrue(lists.warnings.isEmpty)
    }
}
