import XCTest
@testable import Host

@MainActor
final class SidebarPreferencesTests: XCTestCase {
    private func makePreferences() throws -> (SidebarPreferences, UserDefaults) {
        let suite = "SidebarPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (SidebarPreferences(defaults: defaults,
                                   registry: .standard), defaults)
    }

    func testDefaultsUseTheStandardLayout() throws {
        let (prefs, _) = try makePreferences()
        XCTAssertFalse(prefs.compact)
        XCTAssertFalse(prefs.collapsed)
        XCTAssertEqual(prefs.layout, .standard(for: .standard))
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
        let first = SidebarPreferences(defaults: defaults, registry: .standard)
        first.compact = true
        first.collapsed = true
        var layout = first.layout
        layout.upper.swapAt(3, 4)
        first.replaceLayout(layout)

        let reopened = SidebarPreferences(defaults: defaults, registry: .standard)
        XCTAssertTrue(reopened.compact)
        XCTAssertTrue(reopened.collapsed)
        XCTAssertEqual(reopened.layout, layout)
    }

    func testLegacyOrderIsMigratedToAVersionedNavigationLayout() throws {
        let suite = "SidebarPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["chat", "screen", "files"], forKey: "sidebarOrder")

        _ = SidebarPreferences(defaults: defaults, registry: .standard)

        XCTAssertNotNil(defaults.data(forKey: "navigationLayout"))
    }

    func testCreatingAUserShelfRequestsInlineRenameAndPersistsItsTitle() throws {
        let (prefs, _) = try makePreferences()
        let id = UUID(uuidString: "16186E4B-5F6D-42F6-BAE6-C62C7405E492")!
        var changed = prefs.layout
        changed.upper.removeAll {
            $0 == .module("chat") || $0 == .module("development")
        }
        changed.upper.append(.shelf(NavigationShelf(
            id: .user(id), title: "New Shelf",
            moduleIDs: ["chat", "development"])))

        prefs.replaceLayout(changed)
        XCTAssertEqual(prefs.shelfBeingRenamed, .user(id))

        prefs.renameShelf(id: .user(id), title: "Work")
        XCTAssertEqual(prefs.layout.shelf(id: .user(id))?.title, "Work")
        XCTAssertNil(prefs.shelfBeingRenamed)
    }

    func testCancellingNewShelfRenameRestoresTheExactPreviousLayout() throws {
        let (prefs, _) = try makePreferences()
        let previous = prefs.layout
        let id = UUID(uuidString: "16186E4B-5F6D-42F6-BAE6-C62C7405E492")!
        var changed = previous
        changed.upper.removeAll {
            $0 == .module("chat") || $0 == .module("development")
        }
        changed.upper.append(.shelf(NavigationShelf(
            id: .user(id), title: "New Shelf",
            moduleIDs: ["chat", "development"])))

        prefs.replaceLayout(changed)
        prefs.cancelShelfCreation(id: .user(id))

        XCTAssertEqual(prefs.layout, previous)
        XCTAssertNil(prefs.shelfBeingRenamed)
        XCTAssertNil(prefs.layout.shelf(id: .user(id)))
    }

    func testCancellingAnOldShelfRenameDoesNotRewindTheLayout() throws {
        let (prefs, _) = try makePreferences()
        let unchanged = prefs.layout

        prefs.cancelShelfCreation(id: .screen)

        XCTAssertEqual(prefs.layout, unchanged)
        XCTAssertNil(prefs.shelfBeingRenamed)
    }
}
