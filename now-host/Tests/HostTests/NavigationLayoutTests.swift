import XCTest
@testable import Host

final class NavigationLayoutTests: XCTestCase {
    func testStandardLayoutMatchesTheAcceptedShelvesAndZones() throws {
        let layout = NavigationLayout.standard(for: .standard)

        XCTAssertEqual(layout.upper.map(\.id),
            [NavigationShelfID.machine.rawValue,
             NavigationShelfID.screen.rawValue,
             NavigationShelfID.files.rawValue,
             "module.chat", "module.development"])
        XCTAssertEqual(layout.lower.map(\.id),
            [NavigationShelfID.network.rawValue,
             "module.console", "module.logs"])
        XCTAssertEqual(layout.shelf(id: .machine)?.hero, .overview)
        XCTAssertEqual(layout.shelf(id: .network)?.hero, .module("settings"))
        XCTAssertTrue(layout.drawer.isEmpty)
        assertTotalPartition(layout, registry: .standard)
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

    func testARegistryContinuityModuleIsAdoptedByTheScreenShelf() {
        let continuity = ModuleDescriptor(id: "continuity", title: "Continuity",
            symbol: "display.2", summary: "Continue on another Mac")
        let registry = ModuleRegistry(modules:
            ModuleRegistry.standard.modules + [continuity])
        var stored = NavigationLayout.standard(for: .standard)
        stored.upper.removeAll { $0.id == NavigationShelfID.screen.rawValue }
        stored.upper.insert(.module("screen"), at: 0)

        let repaired = stored.sanitised(for: registry)

        XCTAssertEqual(repaired.shelf(id: .screen)?.moduleIDs.first, "screen")
        XCTAssertTrue(repaired.shelf(id: .screen)?.moduleIDs.contains("continuity") == true)
        assertTotalPartition(repaired, registry: registry)
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

        let layout = NavigationLayoutStore(defaults: defaults,
            registry: .standard).load()

        XCTAssertEqual(layout, NavigationLayout.standard(for: .standard))
        XCTAssertEqual(defaults.data(forKey: NavigationLayoutStore.layoutKey),
                       data)
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
            || $0 == .module("development") }
        layout.upper.append(.shelf(NavigationShelf(id: .user(id), title: "Work",
            moduleIDs: ["chat", "development"])))
        store.save(layout)

        let reopened = NavigationLayoutStore(defaults: defaults,
            registry: .standard).load()
        XCTAssertEqual(reopened.shelf(id: .user(id))?.title, "Work")
        XCTAssertEqual(reopened.shelf(id: .user(id))?.moduleIDs,
                       ["chat", "development"])
    }
}
