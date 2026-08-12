import XCTest
@testable import MirrorKit

final class AppleMenuProfileTests: XCTestCase {
    func testMacOS86JoinsKnownIconsWithoutChangingGuestRows() {
        let menu = Scene.Menu(title: "", apple: true, left: 10, id: 256,
                              items: [
            .init(title: "\0\0Apple System Profiler", index: 3),
            .init(title: "Control Panels", index: 4, submenu: true),
            .init(title: "Third Party Thing", index: 5),
        ])

        let projected = AppleMenuProfile.macOS86(menu)

        XCTAssertEqual(projected.items.map(\.title), menu.items.map(\.title))
        XCTAssertEqual(projected.items[0].icon?.creator, "prfc")
        XCTAssertEqual(projected.items[0].icon?.type, "APPD")
        XCTAssertEqual(projected.items[1].icon?.generic, "folder")
        XCTAssertNil(projected.items[2].icon)
        XCTAssertEqual(projected.items[1].submenu, true)
    }

    func testProfileDoesNotDecorateOrdinaryMenus() {
        let menu = Scene.Menu(title: "File", apple: false, left: 43, id: 257,
                              items: [.init(title: "Calculator", index: 1)])
        XCTAssertEqual(AppleMenuProfile.macOS86(menu), menu)
    }
}
