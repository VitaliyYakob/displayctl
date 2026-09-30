import XCTest
@testable import displayctl

final class RefreshRateTests: XCTestCase {
    func testMissingVRRFunctionDoesNotAdvertiseAdaptiveSync() {
        XCTAssertFalse(RefreshRateService.isAdaptive(vrrResult: nil))
    }

    func testFixedAndAdaptiveResultsRemainDistinct() {
        XCTAssertFalse(RefreshRateService.isAdaptive(vrrResult: 0))
        XCTAssertTrue(RefreshRateService.isAdaptive(vrrResult: 1))
    }
}
