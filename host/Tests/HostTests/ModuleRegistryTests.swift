import XCTest
@testable import Host

final class ModuleRegistryTests: XCTestCase {
    func testStandardRegistryStartsWithScreenshots() {
        XCTAssertEqual(ModuleRegistry.standard.modules.map(\.id), ["screenshots"])
        XCTAssertEqual(ModuleRegistry.standard.module(id: "screenshots")?.title,
                       "Screenshots")
    }

    func testUnknownModuleIsAbsent() {
        XCTAssertNil(ModuleRegistry.standard.module(id: "missing"))
    }
}

