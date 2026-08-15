import XCTest
@testable import Host

@MainActor
final class NavigationLayoutTests: XCTestCase {
    func testStandardLayoutMatchesTheAcceptedShelvesAndZones() throws {
        let layout = NavigationLayout.standard(for: .standard)

        XCTAssertEqual(layout.upper.map(\.id),
            [NavigationShelfID.machine.rawValue,
             NavigationShelfID.screen.rawValue,
             NavigationShelfID.files.rawValue,
             "module.chat", "module.projects"])
        XCTAssertEqual(layout.lower.map(\.id),
            [NavigationShelfID.debug.rawValue,
             NavigationShelfID.network.rawValue])
        XCTAssertEqual(layout.shelf(id: .debug)?.moduleIDs,
                       ["console", "logs"])
        /* Networking is a fact about the driven machine, so it sits with the
           other three; the Connections shelf keeps only this Mac's own link
           and the surfaces that ride it. */
        XCTAssertEqual(layout.shelf(id: .machine)?.moduleIDs,
                       ["census", "software", "processes", "networking",
                        "diagnostics"])
        XCTAssertEqual(layout.shelf(id: .network)?.moduleIDs,
                       ["settings", "mcp", "web"])
        XCTAssertEqual(layout.shelf(id: .machine)?.hero, .overview)
        XCTAssertEqual(layout.shelf(id: .network)?.hero, .module("settings"))
        XCTAssertTrue(layout.drawer.isEmpty)
        assertTotalPartition(layout, registry: .standard)
    }

    func testStandardLayoutContainsOnlyModulesFromAReducedRegistry() {
        let registry = ModuleRegistry(modules: ModuleRegistry.standard.modules
            .filter { $0.id != "console" && $0.id != "logs" })

        let layout = NavigationLayout.standard(for: registry)

        assertTotalPartition(layout, registry: registry)
        XCTAssertFalse(layout.allModuleIDs.contains("console"))
        XCTAssertFalse(layout.allModuleIDs.contains("logs"))
    }

    func testSanitisingRepairsDuplicatesUnknownsRenamesAndMissingModules() {
        let corrupt = NavigationLayout(
            version: 99,
            upper: [
                .module("screenshots"),
                .module("screen"),
                .module("gone"),
                .shelf(NavigationShelf(id: .machine,
                    moduleIDs: ["census", "census"])),
            ],
            lower: [.module("chat")],
            drawer: [.shelf(NavigationShelf(id: .machine,
                moduleIDs: ["software"]))])

        let repaired = corrupt.sanitised(for: .standard)

        XCTAssertEqual(repaired.version, NavigationLayout.currentVersion)
        XCTAssertEqual(repaired.allModuleIDs.filter { $0 == "screen" }.count, 1)
        XCTAssertFalse(repaired.allModuleIDs.contains("screenshots"))
        XCTAssertFalse(repaired.allModuleIDs.contains("gone"))
        XCTAssertEqual(repaired.zone(of: .machine), .upper)
        assertTotalPartition(repaired, registry: .standard)
    }

    func testMachineCannotEnterDrawerAndNetworkCan() {
        let stored = NavigationLayout(
            upper: [.module("chat")],
            lower: [],
            drawer: [
                .shelf(NavigationShelf(id: .machine,
                    moduleIDs: ["census"])),
                .shelf(NavigationShelf(id: .network,
                    moduleIDs: ["settings"])),
            ])

        let repaired = stored.sanitised(for: .standard)

        XCTAssertEqual(repaired.zone(of: .machine), .upper)
        XCTAssertEqual(repaired.zone(of: .network), .drawer)
        assertTotalPartition(repaired, registry: .standard)
    }

    func testPermanentShelvesPreserveTheirChosenVisibleZone() {
        let stored = NavigationLayout(
            upper: [.module("chat")],
            lower: [
                .shelf(NavigationShelf(id: .machine,
                    moduleIDs: ["census"])),
                .shelf(NavigationShelf(id: .network,
                    moduleIDs: ["settings", "networking", "mcp", "web"])),
                .module("console"),
                .module("logs"),
            ],
            drawer: [])

        let repaired = stored.sanitised(for: .standard)

        XCTAssertEqual(repaired.zone(of: .machine), .lower)
        XCTAssertEqual(repaired.zone(of: .network), .lower)
        XCTAssertEqual(repaired.lower.map(\.id),
                       [NavigationShelfID.machine.rawValue,
                        NavigationShelfID.network.rawValue,
                        "module.console", "module.logs"])
        assertTotalPartition(repaired, registry: .standard)
    }

    func testOneMemberUserShelfDecomposesToItsModule() {
        let userID = UUID(uuidString: "16186E4B-5F6D-42F6-BAE6-C62C7405E492")!
        let stored = NavigationLayout(
            upper: [.shelf(NavigationShelf(id: .user(userID), title: "Work",
                                           moduleIDs: ["chat"]))],
            lower: [], drawer: [])

        let repaired = stored.sanitised(for: .standard)

        XCTAssertTrue(repaired.upper.contains(.module("chat")))
        XCTAssertNil(repaired.shelf(id: .user(userID)))
        assertTotalPartition(repaired, registry: .standard)
    }

    func testMovingNetworkHeroBackToNetworkCanDecomposeAUserShelf() {
        let userID = UUID(uuidString: "16186E4B-5F6D-42F6-BAE6-C62C7405E492")!
        let stored = NavigationLayout(
            upper: [.shelf(NavigationShelf(id: .user(userID), title: "Online",
                moduleIDs: ["settings", "chat"]))],
            lower: [.shelf(NavigationShelf(id: .network, moduleIDs: ["web"]))],
            drawer: [])

        let repaired = stored.sanitised(for: .standard)

        XCTAssertEqual(repaired.shelf(id: .network)?.moduleIDs.first, "settings")
        XCTAssertNil(repaired.shelf(id: .user(userID)))
        XCTAssertTrue(repaired.upper.contains(.module("chat")))
        assertTotalPartition(repaired, registry: .standard)
    }

    /* This test used to MANUFACTURE a continuity module and add it to the
       standard registry, anticipating the Mirror/Continuity split. The
       module is real now and lives in the standard registry, so the
       anticipation half is gone; what stays pinned is the adoption rule it
       was written for - a stored layout from before the split, where the
       screen shelf never heard of continuity, adopts it into that shelf on
       sanitise rather than dropping or duplicating it. */
    func testARegistryContinuityModuleIsAdoptedByTheScreenShelf() {
        var stored = NavigationLayout.standard(for: .standard)
        stored.upper.removeAll { $0.id == NavigationShelfID.screen.rawValue }
        stored.upper.insert(.module("screen"), at: 0)

        let repaired = stored.sanitised(for: .standard)

        XCTAssertEqual(repaired.shelf(id: .screen)?.moduleIDs.first, "screen")
        XCTAssertTrue(repaired.shelf(id: .screen)?.moduleIDs.contains("continuity") == true)
        assertTotalPartition(repaired, registry: .standard)
    }

    func testAnUnknownNewRegistryModuleIsAdoptedExactlyOnce() {
        let extra = ModuleDescriptor(id: "notes", title: "Notes",
            symbol: "note.text", summary: "Notes")
        let registry = ModuleRegistry(modules: ModuleRegistry.standard.modules + [extra])

        let repaired = NavigationLayout.standard(for: .standard)
            .sanitised(for: registry)

        XCTAssertEqual(repaired.allModuleIDs.filter { $0 == "notes" }.count, 1)
        assertTotalPartition(repaired, registry: registry)
    }

    /// A layout stored before the move carries Networking on the Connections
    /// shelf; version 4 lifts it across without disturbing anything else.
    func testVersionThreeLayoutMovesNetworkingToTheMachineShelf() {
        var stored = NavigationLayout.standard(for: .standard)
        stored.version = 3
        stored.setItems(stored.upper.map { item in
            guard case .shelf(var shelf) = item, shelf.id == .machine
            else { return item }
            shelf.moduleIDs.removeAll { $0 == "networking" }
            return .shelf(shelf)
        }, in: .upper)
        stored.setItems(stored.lower.map { item in
            guard case .shelf(var shelf) = item, shelf.id == .network
            else { return item }
            shelf.moduleIDs.insert("networking", at: 1)
            return .shelf(shelf)
        }, in: .lower)

        let migrated = stored.migratedToCurrentVersion()

        XCTAssertEqual(migrated.version, NavigationLayout.currentVersion)
        XCTAssertEqual(migrated.shelf(id: .machine)?.moduleIDs.last,
                       "networking")
        XCTAssertEqual(migrated.shelf(id: .network)?.moduleIDs,
                       ["settings", "mcp", "web"])
        assertTotalPartition(migrated, registry: .standard)
    }

    /// The migration updates a DEFAULT, never an arrangement. Networking
    /// parked somewhere on purpose is left exactly where it was put.
    func testVersionThreeMigrationLeavesADeliberatelyPlacedNetworkingAlone() {
        var stored = NavigationLayout.standard(for: .standard)
        stored.version = 3
        stored.setItems(stored.upper.map { item in
            guard case .shelf(var shelf) = item, shelf.id == .machine
            else { return item }
            shelf.moduleIDs.removeAll { $0 == "networking" }
            return .shelf(shelf)
        }, in: .upper)
        stored.drawer.append(.module("networking"))

        let migrated = stored.migratedToCurrentVersion()

        XCTAssertEqual(migrated.zone(containing: "networking"), .drawer)
        XCTAssertFalse(
            migrated.shelf(id: .machine)?.moduleIDs.contains("networking")
                == true)
    }

    private func assertTotalPartition(_ layout: NavigationLayout,
                                      registry: ModuleRegistry,
                                      file: StaticString = #filePath,
                                      line: UInt = #line) {
        XCTAssertEqual(layout.allModuleIDs.count, registry.modules.count,
                       file: file, line: line)
        XCTAssertEqual(Set(layout.allModuleIDs), Set(registry.modules.map(\.id)),
                       file: file, line: line)
    }
}

@MainActor
final class NavigationLayoutStoreTests: XCTestCase {
    private let known = ["screen", "files", "console", "chat"]

    private func defaults() throws -> UserDefaults {
        let suite = "NavigationLayoutStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testLegacyOrderMigratesAndWritesVersionedData() throws {
        let defaults = try defaults()
        defaults.set(["chat", "screen", "files"], forKey: "sidebarOrder")

        let layout = NavigationLayoutStore(defaults: defaults,
            registry: .standard).load()

        XCTAssertEqual(layout.upper.first, .module("chat"))
        let data = try XCTUnwrap(defaults.data(forKey: "navigationLayout"))
        let decoded = try JSONDecoder().decode(NavigationLayout.self, from: data)
        XCTAssertEqual(decoded.version, NavigationLayout.currentVersion)
    }

    func testLegacyOrderNormalizationKeepsKnownOrderAndAppendsNewModules() {
        XCTAssertEqual(
            LegacySidebarOrder.normalised(
                ["chat", "screen", "files"], against: known),
            ["chat", "screen", "files", "console"])
    }

    func testLegacyOrderNormalizationDropsUnknownsAndDuplicates() {
        XCTAssertEqual(
            LegacySidebarOrder.normalised(
                ["chat", "gone", "chat", "screen"], against: known),
            ["chat", "screen", "files", "console"])
    }

    func testLegacyOrderNormalizationPreservesRenamedModulePosition() {
        XCTAssertEqual(
            LegacySidebarOrder.normalised(
                ["screenshots", "chat", "screen", "files"], against: known),
            ["screen", "chat", "files", "console"])
    }

    func testCorruptDataRepairsToTheAcceptedDefault() throws {
        let defaults = try defaults()
        defaults.set(Data("not-json".utf8), forKey: "navigationLayout")

        let layout = NavigationLayoutStore(defaults: defaults,
            registry: .standard).load()

        XCTAssertEqual(layout, NavigationLayout.standard(for: .standard))
    }

    func testFutureVersionIsNotOverwrittenByAnOlderApp() throws {
        let defaults = try defaults()
        var future = NavigationLayout.standard(for: .standard)
        future.version = NavigationLayout.currentVersion + 1
        let data = try JSONEncoder().encode(future)
        defaults.set(data, forKey: NavigationLayoutStore.layoutKey)

        let store = NavigationLayoutStore(defaults: defaults,
            registry: .standard)
        var layout = store.load()
        layout.upper.swapAt(3, 4)
        _ = store.save(layout)

        XCTAssertEqual(defaults.data(forKey: NavigationLayoutStore.layoutKey),
                       data)
    }

    func testVersionOneLayoutMigratesConnectionsIntoThePinnedZone() throws {
        let defaults = try defaults()
        var versionOne = NavigationLayout.standard(for: .standard)
        versionOne.version = 1
        let networkIndex = try XCTUnwrap(versionOne.lower.firstIndex {
            $0.id == NavigationShelfID.network.rawValue
        })
        versionOne.upper.insert(versionOne.lower.remove(at: networkIndex), at: 3)
        defaults.set(try JSONEncoder().encode(versionOne),
                     forKey: NavigationLayoutStore.layoutKey)

        let loaded = NavigationLayoutStore(defaults: defaults,
            registry: .standard).load()

        XCTAssertEqual(loaded.version, NavigationLayout.currentVersion)
        XCTAssertEqual(loaded.zone(of: .network), .lower)
        XCTAssertEqual(loaded.lower.last?.id,
                       NavigationShelfID.network.rawValue)
        XCTAssertEqual(loaded.shelf(id: .debug)?.moduleIDs,
                       ["console", "logs"])
    }

    func testVersionTwoLayoutGroupsLooseDebugModulesAboveConnections() throws {
        let defaults = try defaults()
        var versionTwo = NavigationLayout.standard(for: .standard)
        versionTwo.version = 2
        versionTwo.lower = [
            .shelf(NavigationShelf(
                id: .network,
                moduleIDs: ["settings", "networking", "mcp", "web"])),
            .module("console"),
            .module("logs"),
        ]
        defaults.set(try JSONEncoder().encode(versionTwo),
                     forKey: NavigationLayoutStore.layoutKey)

        let loaded = NavigationLayoutStore(defaults: defaults,
            registry: .standard).load()

        XCTAssertEqual(loaded.lower.map(\.id),
                       [NavigationShelfID.debug.rawValue,
                        NavigationShelfID.network.rawValue])
        XCTAssertEqual(loaded.shelf(id: .debug)?.moduleIDs,
                       ["console", "logs"])
    }

    func testLayoutSurvivesRelaunch() throws {
        let defaults = try defaults()
        let store = NavigationLayoutStore(defaults: defaults, registry: .standard)
        var layout = store.load()
        layout.upper.swapAt(3, 4)
        store.save(layout)

        XCTAssertEqual(NavigationLayoutStore(defaults: defaults,
            registry: .standard).load(), layout)
    }

    func testUserShelfIdentityAndTitleSurviveRelaunch() throws {
        let defaults = try defaults()
        let store = NavigationLayoutStore(defaults: defaults, registry: .standard)
        let id = UUID(uuidString: "16186E4B-5F6D-42F6-BAE6-C62C7405E492")!
        var layout = store.load()
        layout.upper.removeAll { $0 == .module("chat")
            || $0 == .module("projects") }
        layout.upper.append(.shelf(NavigationShelf(id: .user(id), title: "Work",
            moduleIDs: ["chat", "projects"])))
        store.save(layout)

        let reopened = NavigationLayoutStore(defaults: defaults,
            registry: .standard).load()
        XCTAssertEqual(reopened.shelf(id: .user(id))?.title, "Work")
        XCTAssertEqual(reopened.shelf(id: .user(id))?.moduleIDs,
                       ["chat", "projects"])
    }
}
