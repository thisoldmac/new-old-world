import XCTest
@testable import Host

/// The ordering rule, which is the part with anything to get wrong. It is
/// the guest's `order_adopt` in Swift and must behave the same way: the two
/// halves offer the same arrangement and a person moving between them should
/// not find one of them forgetting.
@MainActor
final class SidebarPreferencesTests: XCTestCase {
    private let known = ["screen", "files", "console", "chat"]

    func testEmptyStoredOrderIsTheRegistryOrder() {
        // The state every existing install is in: nothing saved, so nothing
        // about the sidebar changes when this ships.
        XCTAssertEqual(SidebarPreferences.sanitised([], against: known), known)
    }

    func testSavedOrderIsKept() {
        let saved = ["chat", "screen", "files", "console"]
        XCTAssertEqual(SidebarPreferences.sanitised(saved, against: known),
                       saved)
    }

    func testModuleAddedSinceTheOrderWasSavedGoesToTheEnd() {
        /* The reason this rule exists rather than "discard anything that
           does not match": a saved arrangement must survive the next module,
           or every new page silently resets everyone's sidebar. */
        let saved = ["chat", "screen", "files"]
        XCTAssertEqual(SidebarPreferences.sanitised(saved, against: known),
                       ["chat", "screen", "files", "console"])
    }

    func testRetiredModuleIsDropped() {
        let saved = ["chat", "gone", "screen", "files", "console"]
        XCTAssertEqual(SidebarPreferences.sanitised(saved, against: known),
                       ["chat", "screen", "files", "console"])
    }

    func testDuplicateInStoredOrderIsTakenOnce() {
        // A corrupt or hand-edited value must not be able to show a row
        // twice, which would also break selection.
        let saved = ["chat", "chat", "screen", "files", "console"]
        XCTAssertEqual(SidebarPreferences.sanitised(saved, against: known),
                       ["chat", "screen", "files", "console"])
    }

    func testResultIsAlwaysAPermutationOfWhatExists() {
        // The invariant the sidebar depends on: every module appears exactly
        // once, whatever was on disk.
        for saved in [[], ["gone"], ["chat", "chat", "gone"],
                      ["console", "files", "screen", "chat"]] {
            let out = SidebarPreferences.sanitised(saved, against: known)
            XCTAssertEqual(Set(out), Set(known), "stored: \(saved)")
            XCTAssertEqual(out.count, known.count, "stored: \(saved)")
        }
    }

    /// **A saved order naming a module's OLD id keeps its position.**
    ///
    /// Screenshots became Screen. Without the rename going through the same
    /// table the saved SELECTION uses, `sanitised` would read `screenshots`
    /// as a retired module, drop it, and re-append `screen` at the end — so
    /// a person who had dragged that page to the top would find it at the
    /// bottom, with nothing to tell them why.
    func testARenamedModuleKeepsItsPlaceInASavedOrder() {
        let saved = ["screenshots", "chat", "files", "console"]
        XCTAssertEqual(SidebarPreferences.sanitised(saved, against: known),
                       ["screen", "chat", "files", "console"])
    }

    /// The rename must not be able to show the page twice — a saved order
    /// written across the rename can hold both names at once.
    func testBothNamesOfARenamedModuleCollapseToOneRow() {
        let saved = ["screenshots", "chat", "screen", "files", "console"]
        XCTAssertEqual(SidebarPreferences.sanitised(saved, against: known),
                       ["screen", "chat", "files", "console"])
    }

    // MARK: - Against the real registry and a real defaults suite

    private func makePreferences() throws -> (SidebarPreferences, UserDefaults) {
        let suite = "SidebarPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (SidebarPreferences(defaults: defaults,
                                   registry: .standard), defaults)
    }

    func testDefaultsAreTodaysSidebar() throws {
        let (prefs, _) = try makePreferences()
        XCTAssertFalse(prefs.compact)
        XCTAssertFalse(prefs.collapsed)
        XCTAssertEqual(prefs.ordered(ModuleRegistry.standard.listModules).map(\.id),
                       ModuleRegistry.standard.listModules.map(\.id))
    }

    func testMoveReordersAndPersists() throws {
        let (prefs, defaults) = try makePreferences()
        let modules = ModuleRegistry.standard.listModules
        let last = try XCTUnwrap(modules.last?.id)

        prefs.move(modules, from: IndexSet(integer: modules.count - 1), to: 0)
        XCTAssertEqual(prefs.ordered(modules).first?.id, last)
        XCTAssertEqual(defaults.stringArray(forKey: "sidebarOrder")?.first, last)
    }

    func testResetRestoresTheRegistryOrder() throws {
        let (prefs, _) = try makePreferences()
        let modules = ModuleRegistry.standard.listModules

        prefs.move(modules, from: IndexSet(integer: modules.count - 1), to: 0)
        XCTAssertNotEqual(prefs.ordered(modules).map(\.id), modules.map(\.id))
        prefs.resetOrder(modules)
        XCTAssertEqual(prefs.ordered(modules).map(\.id), modules.map(\.id))
    }

    func testCollapsedAndCompactAreIndependent() throws {
        let (prefs, _) = try makePreferences()

        /* Folding must not forget the density, which is why these are two
           stored values rather than one three-valued one. */
        prefs.compact = true
        prefs.collapsed = true
        prefs.collapsed = false
        XCTAssertTrue(prefs.compact)
    }

    func testChoicesSurviveARelaunch() throws {
        let suite = "SidebarPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let modules = ModuleRegistry.standard.listModules
        let last = try XCTUnwrap(modules.last?.id)

        let first = SidebarPreferences(defaults: defaults, registry: .standard)
        first.compact = true
        first.collapsed = true
        first.move(modules, from: IndexSet(integer: modules.count - 1), to: 0)

        let reopened = SidebarPreferences(defaults: defaults, registry: .standard)
        XCTAssertTrue(reopened.compact)
        XCTAssertTrue(reopened.collapsed)
        XCTAssertEqual(reopened.ordered(modules).first?.id, last)
    }

    func testLegacyOrderIsMigratedToAVersionedNavigationLayout() throws {
        let suite = "SidebarPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["chat", "screen", "files"], forKey: "sidebarOrder")

        _ = SidebarPreferences(defaults: defaults, registry: .standard)

        XCTAssertNotNil(defaults.data(forKey: "navigationLayout"))
    }
}
