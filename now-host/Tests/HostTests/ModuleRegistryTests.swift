import XCTest
@testable import Host

@MainActor
final class ModuleRegistryTests: XCTestCase {
    func testStandardRegistryHasScreenFirstAndSettings() {
        XCTAssertEqual(ModuleRegistry.standard.modules.map(\.id),
                       ["screen", "files", "icloud", "processes",
                        "mirror", "console", "chat",
                        "web", "development", "census", "diagnostics", "networking", "software",
                        "mcp", "logs", "settings"])
        XCTAssertEqual(ModuleRegistry.standard.module(id: "screen")?.title,
                       "Screen")
        XCTAssertEqual(ModuleRegistry.standard.module(id: "settings")?.title,
                       "Connections")
        XCTAssertEqual(ModuleRegistry.standard.module(id: "web")?.title,
                       "Web Proxy")
    }

    func testUnknownModuleIsAbsent() {
        XCTAssertNil(ModuleRegistry.standard.module(id: "missing"))
    }

    func testFooterHoldsLogsAndConnectionsInOrder() {
        /* MCP, then Logs, then Connections under the divider. MCP sits
           above Logs because part of it is the narrower reading of the same
           record — Logs is everything that happened, MCP is the part of it
           somebody else caused — and a person who wants that part should
           not have to know it is in the log. */
        XCTAssertEqual(ModuleRegistry.standard.footerModules.map(\.id),
                       ["mcp", "logs", "settings"])
        XCTAssertEqual(ModuleRegistry.standard.listModules.map(\.id),
                       ["screen", "files", "icloud", "processes",
                        "mirror", "console", "chat",
                        "web", "development", "census", "diagnostics", "networking", "software"])
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

    /// **A renamed module keeps a forwarding address.**
    ///
    /// The selection is persisted by id, so `agent` → `mcp` would otherwise
    /// silently evict whoever was last looking at that page: their saved id
    /// stops resolving and the next launch drops them on the first page. Every
    /// old name in the table has to resolve, and to something real.
    func testARenamedModuleStillResolvesFromItsOldSavedID() {
        XCTAssertEqual(ModuleRegistry.standard.resolvingRenames(id: "agent")?.id,
                       "mcp")
        // Screenshots became Screen once the page grew the live stream.
        XCTAssertEqual(
            ModuleRegistry.standard.resolvingRenames(id: "screenshots")?.id,
            "screen")
        for (old, new) in ModuleRegistry.renamedIDs {
            XCTAssertNil(ModuleRegistry.standard.module(id: old),
                         "\(old) was renamed, so nothing may still claim it.")
            XCTAssertNotNil(ModuleRegistry.standard.module(id: new),
                            "\(old) forwards to \(new), which must exist.")
        }
    }

    /// A name nobody ever used forwards nowhere: the table is a migration,
    /// not a spell-checker.
    func testAnUnknownIDIsNotForwarded() {
        XCTAssertNil(ModuleRegistry.standard.resolvingRenames(id: "missing"))
    }

    /// The root renders the selected definition; it must never regain a
    /// parallel id switch as modules migrate into their own files.
    func testEveryModuleHasADetailDefinition() throws {
        let registry = ModuleRegistry.standard
        XCTAssertEqual(registry.definitions.count, registry.modules.count)
        for definition in registry.definitions {
            XCTAssertNotNil(definition.makeView,
                            "\(definition.descriptor.id) has no detail view")
        }
        let view = try GateSource.hostSwift(
            "now-host/Sources/Host/HostRootView.swift")
        XCTAssertFalse(view.contains("switch state.selectedModuleID"))
        XCTAssertTrue(view.contains("state.moduleView("))
    }

    func testTaxonomyIsIndependentFromPlacement() {
        let tiers = Dictionary(uniqueKeysWithValues:
            ModuleRegistry.standard.modules.map { ($0.id, $0.tier) })
        XCTAssertEqual(tiers["networking"], .core)
        XCTAssertEqual(tiers["mirror"], .experimental)
        XCTAssertEqual(tiers["logs"], .debug)
        XCTAssertEqual(ModuleRegistry.standard.module(id: "mcp")?.placement,
                       .footer)
        XCTAssertEqual(tiers["mcp"], .experimental)
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
