import XCTest
@testable import Host

final class ModuleRegistryTests: XCTestCase {
    func testStandardRegistryHasScreenshotsFirstAndSettings() {
        XCTAssertEqual(ModuleRegistry.standard.modules.map(\.id),
                       ["screenshots", "files", "processes", "console",
                        "census", "diagnostics", "software", "agent",
                        "logs", "settings"])
        XCTAssertEqual(ModuleRegistry.standard.module(id: "screenshots")?.title,
                       "Screenshots")
        XCTAssertEqual(ModuleRegistry.standard.module(id: "settings")?.title,
                       "Connection")
    }

    func testUnknownModuleIsAbsent() {
        XCTAssertNil(ModuleRegistry.standard.module(id: "missing"))
    }

    func testFooterHoldsLogsAndConnectionInOrder() {
        /* Agent, then Logs, then Connection under the divider. Agent sits
           above Logs because it is the narrower reading of the same record
           — Logs is everything that happened, Agent is the part of it
           somebody else caused — and a person who wants that part should
           not have to know it is in the log. */
        XCTAssertEqual(ModuleRegistry.standard.footerModules.map(\.id),
                       ["agent", "logs", "settings"])
        XCTAssertEqual(ModuleRegistry.standard.listModules.map(\.id),
                       ["screenshots", "files", "processes", "console",
                        "census", "diagnostics", "software"])
    }

    func testOnlyConnectionShowsLinkStatusInTheFooter() {
        XCTAssertEqual(
            ModuleRegistry.standard.module(id: "settings")?.showsLinkStatus,
            true)
        XCTAssertEqual(
            ModuleRegistry.standard.module(id: "logs")?.showsLinkStatus,
            false)
    }

    /// The halves are a view of one array: together they are all of it, in
    /// order, and nothing lands in both.
    func testPlacementPartitionsTheModules() {
        let registry = ModuleRegistry.standard
        let halves = registry.listModules + registry.footerModules
        XCTAssertEqual(halves.count, registry.modules.count)
        XCTAssertEqual(Set(halves.map(\.id)), Set(registry.modules.map(\.id)))
    }

    /// A footer module is still a module, so a saved selection pointing at
    /// one still resolves on the next launch.
    func testFooterModuleResolvesByID() {
        XCTAssertEqual(ModuleRegistry.standard.module(id: "settings")?.placement,
                       .footer)
        XCTAssertEqual(ModuleRegistry.standard.module(id: "files")?.placement,
                       .list)
    }
}
