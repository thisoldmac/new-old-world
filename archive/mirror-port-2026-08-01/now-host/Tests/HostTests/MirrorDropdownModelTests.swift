import XCTest
@testable import Host
import MirrorKit
import NOWAgentIntegration

/// **The pane's own menu-bar tracking, end to end** — `MirrorModuleModel`
/// opening its dropdown on a menu-title press, asking `menugeom` for real
/// geometry, aiming a selection at the right item, and falling back
/// honestly when the guest has nothing to answer with. `DropdownGeometryTests`
/// (`MirrorKitUITests`) covers the pure drawing/hit-test math in isolation;
/// this file is the model that drives it with a real (fake) wire.
@MainActor
final class MirrorDropdownModelTests: XCTestCase {
    /// One menubar, two menus: `File` (with a real separator, to prove a
    /// click on it never selects anything) and `Edit` — so the
    /// slide-between-titles behaviour has a second menu to slide to.
    private static func document() -> Data {
        Data("""
            {"version":1,"seq":1,"capturedAt":1750000000.0,"source":"peek",\
            "screen":{"w":640,"h":480},\
            "apps":[{"psn":"0.8192","name":"SimpleText","front":true}],\
            "menubar":{"app":"SimpleText","menus":[\
            {"title":"File","apple":false,"left":38,"id":129,"items":[\
            {"title":"New","index":1,"separator":false,"enabled":true,\
            "mark":false,"cmd":"n"},\
            {"title":"","index":2,"separator":true,"enabled":false,\
            "mark":false,"cmd":""},\
            {"title":"Quit","index":3,"separator":false,"enabled":true,\
            "mark":false,"cmd":"q"}]},\
            {"title":"Edit","apple":false,"left":98,"id":130,"items":[\
            {"title":"Undo","index":1,"separator":false,"enabled":true,\
            "mark":false,"cmd":""}]}]},\
            "windows":[],"meta":{"plane":"peek anchors"}}
            """.utf8)
    }

    private func model(listener: GuestListener? = nil,
                       actions: MirrorActionDriver? = nil) -> MirrorModuleModel {
        let model = MirrorModuleModel(listener: listener, actions: actions,
                                      watch: .manual)
        model.connection = .connected(named: "PowerBook 1400")
        model.show(document: Self.document(), irVersion: 1,
                  provenance: .fixture(name: "test.json"))
        return model
    }

    // MARK: - open / close, no wire at all

    /// A press on a menu title opens the mirror's own dropdown — UI state,
    /// no act sent — and with no driver behind the page, it stays on the
    /// fallback geometry rather than crashing trying to fetch one.
    func testPressingATitleOpensTheDropdownWithNoActSent() {
        let model = model()
        model.click(x: 50, y: 8)          // inside File's title span
        XCTAssertEqual(model.openMenu, 0)
        XCTAssertNil(model.openMenuGeometry)
        XCTAssertNil(model.lastAction, "opening a menu is not an act")
    }

    /// Re-pressing the SAME title closes it — the classic Mac's own
    /// click-open/click-close toggle, not a click-away dismiss.
    func testPressingTheSameTitleAgainCloses() {
        let model = model()
        model.click(x: 50, y: 8)
        XCTAssertEqual(model.openMenu, 0)
        model.click(x: 50, y: 8)
        XCTAssertNil(model.openMenu)
    }

    /// Pressing a DIFFERENT title while tracking slides to it instead of
    /// requiring a second click to dismiss first.
    func testPressingAnotherTitleWhileTrackingSlidesToIt() {
        let model = model()
        model.click(x: 50, y: 8)          // File
        XCTAssertEqual(model.openMenu, 0)
        model.click(x: 105, y: 8)         // Edit's title, y still in the bar
        XCTAssertEqual(model.openMenu, 1)
    }

    /// A press on the SEPARATOR inside the open dropdown selects nothing
    /// and closes the menu — `ActionModel.menuSelect` answers `[]` for it,
    /// and this page must not treat a separator as an item with no act any
    /// more than a disabled control is treated as one with no act.
    func testPressingTheSeparatorSelectsNothingButStillCloses() {
        let model = model()
        model.click(x: 50, y: 8)                 // open File
        // Uniform fallback: item 0 ("New") is rows [23,39), the separator
        // (position 1) is [39,55) — see DropdownGeometryTests for the same
        // arithmetic pinned against SceneRenderer directly.
        model.click(x: 40, y: 45)                // inside the separator row
        XCTAssertNil(model.openMenu, "the menu still closes on the press")
        XCTAssertNil(model.lastAction, "a separator sends nothing to report")
    }

    /// A press anywhere else — the window underneath, the desktop, the
    /// letterbox — dismisses the menu without acting on what is under it.
    func testPressingElsewhereDismissesWithoutActingUnderneath() async throws {
        let (listener, guest) = try await connectedListener()
        defer { guest.connection.cancel(); listener.stop() }
        let asked = Box(false)
        guest.onMessage = { message in
            if case .commandRequest = message { asked.value = true }
        }
        let model = model(
            listener: listener,
            actions: MirrorActionDriver(
                adapter: AgentIntegrationHostAdapter(listener: listener)))
        model.connection = .connected(
            name: "PowerBook 1400", key: try XCTUnwrap(listener.activeKey))

        model.click(x: 50, y: 8)                 // open File
        // menugeom fires on open; give it a moment, then dismiss with a
        // click far outside the dropdown before asserting.
        try await Task.sleep(nanoseconds: 20_000_000)
        model.click(x: 600, y: 460)               // the desktop

        XCTAssertNil(model.openMenu)
        XCTAssertNil(model.lastAction,
                     "a click that dismissed a menu must not also act on "
                         + "the desktop underneath it")
    }

    // MARK: - selecting an item reaches the wire

    /// **Selecting an item dispatches `menuact` with the menu's own
    /// identity**, and closes the menu immediately — before the wire even
    /// answers, the same way a real menu's tracking loop ends on release.
    func testSelectingAnItemDispatchesMenuactAndClosesAtOnce() async throws {
        let (listener, guest) = try await connectedListener()
        defer { guest.connection.cancel(); listener.stop() }
        let seen = Box<[String: String]?>(nil)
        guest.onMessage = { message in
            switch message {
            case .commandRequest(let request) where request.name == "menugeom":
                try? guest.send(.commandResult(.init(
                    id: request.id, ok: false, output: nil,
                    error: .init(code: "act-plane-absent",
                                message: "no NOW Extension"))))
            case .commandRequest(let request) where request.name == "menuact":
                seen.value = request.args
                try? guest.send(.commandResult(.init(
                    id: request.id, ok: true,
                    output: ["menuact": [["Dispatch", "dispatched"]]],
                    error: nil)))
            default:
                break
            }
        }
        let model = model(
            listener: listener,
            actions: MirrorActionDriver(
                adapter: AgentIntegrationHostAdapter(listener: listener)))
        model.connection = .connected(
            name: "PowerBook 1400", key: try XCTUnwrap(listener.activeKey))

        model.click(x: 50, y: 8)                  // open File
        model.click(x: 40, y: 30)                 // "New" — row 0, fallback

        XCTAssertNil(model.openMenu, "closes at once, not after the wire answers")

        let deadline = Date().addingTimeInterval(5)
        while model.lastAction?.outcome == .asking, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(seen.value?["menu"], "129")
        XCTAssertEqual(seen.value?["item"], "1")
        XCTAssertEqual(seen.value?["titleLeft"], "38")
        XCTAssertEqual(model.lastAction?.outcome, .dispatched)
        XCTAssertEqual(model.lastAction?.target, "\"New\"")
    }

    // MARK: - menugeom: real geometry upgrades the aim, honest refusal doesn't break it

    /// Opening a menu asks `menugeom`; a real answer changes which row a
    /// point resolves to — proven the same way `DropdownGeometryTests`
    /// proves it, by choosing a fixture where the real layout and the
    /// uniform assumption disagree, then reading the item the SELECTION
    /// actually named off the wire.
    func testARealMenugeomAnswerChangesWhichItemAPressSelects() async throws {
        let (listener, guest) = try await connectedListener()
        defer { guest.connection.cancel(); listener.stop() }
        let menuactArgs = Box<[String: String]?>(nil)
        guest.onMessage = { message in
            switch message {
            case .commandRequest(let request) where request.name == "menugeom":
                try? guest.send(.commandResult(.init(
                    id: request.id, ok: true,
                    output: ["menugeom": [
                        ["Menu", "129"], ["Items", "3"],
                        ["Width", "100"], ["Height", "42"],
                        ["Item 1", "0, 0, 16, 100"],
                        ["Item 2", "16, 0, 22, 100"],
                        // Item 3 (Quit) real rows 22..42 — taller than the
                        // uniform 16px row a fallback would give it.
                        ["Item 3", "22, 0, 42, 100"]]],
                    error: nil)))
            case .commandRequest(let request) where request.name == "menuact":
                menuactArgs.value = request.args
                try? guest.send(.commandResult(.init(
                    id: request.id, ok: true,
                    output: ["menuact": [["Dispatch", "dispatched"]]],
                    error: nil)))
            default:
                break
            }
        }
        let model = model(
            listener: listener,
            actions: MirrorActionDriver(
                adapter: AgentIntegrationHostAdapter(listener: listener)))
        model.connection = .connected(
            name: "PowerBook 1400", key: try XCTUnwrap(listener.activeKey))

        model.click(x: 50, y: 8)                  // open File
        let geomDeadline = Date().addingTimeInterval(5)
        while model.openMenuGeometry == nil, Date() < geomDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(model.openMenuGeometry,
                        "the real answer never reached the model's own state")

        // Real frame: x menu.left-1=37, y menubarHeight=20 (see
        // DropdownGeometryTests for the same math against SceneRenderer
        // directly). Item 3's real row is local 22..42 → frame y 43..63.
        model.click(x: 60, y: 51)                 // inside REAL item 3 only

        let deadline = Date().addingTimeInterval(5)
        while model.lastAction?.outcome == .asking, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(menuactArgs.value?["item"], "3",
                       "a point inside item 3's REAL rect selected something "
                           + "else — the real geometry was not consumed")
    }

    /// **Honest fallback.** No NOW Extension (`act-plane-absent`) means the
    /// dropdown still opens and a press inside it still selects — on the
    /// uniform assumption `SceneRenderer` has always had — rather than the
    /// page treating an absent extension as the menu itself being broken.
    func testAnAbsentExtensionFallsBackRatherThanBreakingTheMenu() async throws {
        let (listener, guest) = try await connectedListener()
        defer { guest.connection.cancel(); listener.stop() }
        let menuactArgs = Box<[String: String]?>(nil)
        guest.onMessage = { message in
            switch message {
            case .commandRequest(let request) where request.name == "menugeom":
                try? guest.send(.commandResult(.init(
                    id: request.id, ok: false, output: nil,
                    error: .init(code: "act-plane-absent",
                                message: "the NOW Extension is not "
                                    + "installed on this Mac"))))
            case .commandRequest(let request) where request.name == "menuact":
                menuactArgs.value = request.args
                try? guest.send(.commandResult(.init(
                    id: request.id, ok: true,
                    output: ["menuact": [["Dispatch", "dispatched"]]],
                    error: nil)))
            default:
                break
            }
        }
        let model = model(
            listener: listener,
            actions: MirrorActionDriver(
                adapter: AgentIntegrationHostAdapter(listener: listener)))
        model.connection = .connected(
            name: "PowerBook 1400", key: try XCTUnwrap(listener.activeKey))

        model.click(x: 50, y: 8)
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertNil(model.openMenuGeometry,
                    "an absent extension must not leave a stale geometry "
                        + "behind, real or invented")

        model.click(x: 40, y: 30)                 // "New" on the fallback
        let deadline = Date().addingTimeInterval(5)
        while model.lastAction?.outcome == .asking, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(menuactArgs.value?["item"], "1",
                       "the fallback assumption must still let a person "
                           + "choose the right item with no NOW Extension "
                           + "installed at all")
    }

    private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }
}
