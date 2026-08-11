import XCTest
@testable import Host

final class MirrorLaunchOptionsTests: XCTestCase {
    func testParsesBoundedDeterministicMirrorScale() {
        XCTAssertEqual(MirrorLaunchOptions.parse(
            ["host", "--mirror-scale", "0.9"]).scale, 0.9)
        XCTAssertNil(MirrorLaunchOptions.parse(
            ["host", "--mirror-scale", "0.2"]).scale)
        XCTAssertNil(MirrorLaunchOptions.parse(
            ["host", "--mirror-scale", "large"]).scale)
    }
}
