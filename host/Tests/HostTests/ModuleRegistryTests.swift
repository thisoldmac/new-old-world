import XCTest
@testable import Host

final class ModuleRegistryTests: XCTestCase {
    func testStandardRegistryHasScreenshotsFirstAndSettings() {
        XCTAssertEqual(ModuleRegistry.standard.modules.map(\.id),
                       ["screenshots", "settings"])
        XCTAssertEqual(ModuleRegistry.standard.module(id: "screenshots")?.title,
                       "Screenshots")
        XCTAssertEqual(ModuleRegistry.standard.module(id: "settings")?.title,
                       "Connection")
    }

    func testUnknownModuleIsAbsent() {
        XCTAssertNil(ModuleRegistry.standard.module(id: "missing"))
    }
}

