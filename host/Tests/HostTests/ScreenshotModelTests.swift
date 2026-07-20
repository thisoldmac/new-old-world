import XCTest
@testable import Host

@MainActor
final class ScreenshotModelTests: XCTestCase {
    private func makeModel() -> ScreenshotModuleModel {
        ScreenshotModuleModel(listener: GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host")))
    }

    func testSupportedDepthsMatchGuestContract() {
        XCTAssertEqual(CaptureDepth.allCases.map(\.rawValue),
                       [1, 2, 4, 8, 16, 32])
    }

    func testCaptureRequiresARealConnection() {
        let model = makeModel()
        XCTAssertFalse(model.canCapture)

        model.connection = .connecting
        XCTAssertFalse(model.canCapture)

        model.connection = .connected(name: "Power Mac")
        XCTAssertTrue(model.canCapture)
    }

    func testCapturingWithoutAGuestFailsHonestly() {
        let model = makeModel()
        model.connection = .connected(name: "PowerBook 1400")
        model.capture()
        // The listener holds no session, so it refuses immediately.
        XCTAssertEqual(model.lastError, "No Mac is connected")
        XCTAssertTrue(model.history.isEmpty)
    }
}
