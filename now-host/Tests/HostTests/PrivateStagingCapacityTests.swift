import XCTest
@testable import Host

final class PrivateStagingCapacityTests: XCTestCase {
    func testImportantUsageCapacityWinsWhenItIsUsable() {
        XCTAssertEqual(
            PrivateStagingCapacity.availableBytes(
                importantUsage: 900, ordinary: 700),
            900)
    }

    func testZeroImportantUsageFallsBackToOrdinaryCapacity() {
        XCTAssertEqual(
            PrivateStagingCapacity.availableBytes(
                importantUsage: 0, ordinary: 700),
            700)
    }

    func testMissingImportantUsageFallsBackToOrdinaryCapacity() {
        XCTAssertEqual(
            PrivateStagingCapacity.availableBytes(
                importantUsage: nil, ordinary: 700),
            700)
    }

    func testNegativeImportantUsageFallsBackToOrdinaryCapacity() {
        XCTAssertEqual(
            PrivateStagingCapacity.availableBytes(
                importantUsage: -1, ordinary: 700),
            700)
    }

    func testOrdinaryZeroIsAValidFullDiskAnswer() {
        XCTAssertEqual(
            PrivateStagingCapacity.availableBytes(
                importantUsage: 0, ordinary: 0),
            0)
    }

    func testNoTrustworthyCapacityIsUnknown() {
        XCTAssertNil(
            PrivateStagingCapacity.availableBytes(
                importantUsage: nil, ordinary: nil))
        XCTAssertNil(
            PrivateStagingCapacity.availableBytes(
                importantUsage: -1, ordinary: -1))
    }
}
