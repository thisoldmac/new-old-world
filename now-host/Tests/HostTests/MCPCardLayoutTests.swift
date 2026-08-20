import XCTest
@testable import Host

/// The MCP page's card arrangement: schema, sanitisation, and the store's
/// refusal to destroy what a newer build wrote. These pin the persistence
/// contract before any view draws it.
@MainActor
final class MCPCardLayoutTests: XCTestCase {
    func testStandardLayoutPutsHistoryAloneOnTheRightAllOpen() {
        let layout = MCPCardLayout.standard
        XCTAssertEqual(layout.right, ["activity"])
        XCTAssertEqual(layout.left, ["transport.stdio", "transport.http",
                                     "presence", "held-lane", "consent"])
        XCTAssertTrue(layout.collapsed.isEmpty)
        XCTAssertTrue(layout.openLogTails.isEmpty)
    }

    func testSanitiseDropsUnknownsDedupesAndSeatsMissingCards() {
        let messy = MCPCardLayout(
            version: 1,
            left: ["presence", "from-the-future", "presence", "activity"],
            right: ["transport.http", "presence"],
            collapsed: ["from-the-future", "consent"],
            openLogTails: ["transport.http", "consent", "gone"])
        let clean = messy.sanitised()

        XCTAssertEqual(clean.left, ["presence", "activity",
                                    "transport.stdio", "held-lane",
                                    "consent"])
        XCTAssertEqual(clean.right, ["transport.http"])
        XCTAssertEqual(clean.collapsed, ["consent"])
        /* Only transports may hold a tail. */
        XCTAssertEqual(clean.openLogTails, ["transport.http"])
    }

    func testStoreRoundTripsAndRepairsCorruptData() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = MCPCardLayoutStore(defaults: defaults)

        XCTAssertEqual(store.load(), .standard)
        var layout = MCPCardLayout.standard
        layout.collapsed = ["presence"]
        store.save(layout)
        XCTAssertEqual(store.load().collapsed, ["presence"])

        defaults.set(Data("not json".utf8),
                     forKey: MCPCardLayoutStore.layoutKey)
        XCTAssertEqual(store.load(), .standard)
    }

    func testNewerVersionBlobIsUsedSafelyAndNeverOverwritten() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = MCPCardLayoutStore(defaults: defaults)

        var future = MCPCardLayout.standard
        future.version = MCPCardLayout.currentVersion + 1
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let futureData = try encoder.encode(future)
        defaults.set(futureData, forKey: MCPCardLayoutStore.layoutKey)

        XCTAssertEqual(store.load(), .standard)
        var attempted = MCPCardLayout.standard
        attempted.collapsed = ["presence"]
        store.save(attempted)
        XCTAssertEqual(defaults.data(forKey: MCPCardLayoutStore.layoutKey),
                       futureData)
    }

    func testUnchangedSaveWritesNoNewBytes() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = MCPCardLayoutStore(defaults: defaults)

        _ = store.load()
        let first = defaults.data(forKey: MCPCardLayoutStore.layoutKey)
        store.save(store.load())
        XCTAssertEqual(defaults.data(forKey: MCPCardLayoutStore.layoutKey),
                       first)
    }

    func testModelIntentsMutateAndPersist() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let model = MCPCardLayoutModel(defaults: defaults)

        model.toggleCollapsed(.presence)
        model.toggleLogTail(.transportHTTP)
        model.toggleLogTail(.consent)
        model.move(.activity, to: .left, before: .presence)
        model.move(.transportStdio, to: .right)

        XCTAssertTrue(model.layout.isCollapsed(.presence))
        XCTAssertTrue(model.layout.isLogTailOpen(.transportHTTP))
        XCTAssertFalse(model.layout.isLogTailOpen(.consent))
        XCTAssertEqual(model.layout.cards(in: .right), [.transportStdio])
        XCTAssertEqual(model.layout.left.firstIndex(of: "activity"),
                       model.layout.left.firstIndex(of: "presence")! - 1)

        /* The same defaults reload into the same arrangement. */
        let reloaded = MCPCardLayoutModel(defaults: defaults)
        XCTAssertEqual(reloaded.layout, model.layout)
    }

    func testNudgeStepsWithinTheColumnAndStopsAtTheEdges() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let model = MCPCardLayoutModel(defaults: defaults)

        model.nudge(.transportStdio, forward: true)
        XCTAssertEqual(model.layout.left.prefix(2),
                       ["transport.http", "transport.stdio"])
        model.nudge(.transportHTTP, forward: false)
        XCTAssertEqual(model.layout.left.first, "transport.http")
        model.nudge(.activity, forward: true)
        XCTAssertEqual(model.layout.right, ["activity"])
    }

    private func suite() throws -> (UserDefaults, String) {
        let name = "mcp-card-layout-tests-\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }
}
