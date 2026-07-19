import XCTest
@testable import Host

@MainActor
final class ScreenshotModelTests: XCTestCase {
    func testSupportedDepthsMatchGuestContract() {
        XCTAssertEqual(CaptureDepth.allCases.map(\.rawValue), [1, 8, 16, 32])
    }

    func testCaptureRequiresARealConnection() {
        let model = ScreenshotModuleModel()
        XCTAssertFalse(model.canCapture)

        model.connection = .connecting
        XCTAssertFalse(model.canCapture)

        model.connection = .connected(name: "Power Mac")
        XCTAssertTrue(model.canCapture)
    }

    func testNewestCaptureAppearsFirst() {
        let model = ScreenshotModuleModel()
        let older = ScreenshotRecord(id: UUID(), capturedAt: .distantPast,
                                     width: 640, height: 480,
                                     depth: .indexed)
        let newer = ScreenshotRecord(id: UUID(), capturedAt: .now,
                                     width: 800, height: 600,
                                     depth: .millions)

        model.receive(older)
        model.receive(newer)

        XCTAssertEqual(model.history.map(\.id), [newer.id, older.id])
    }
}

