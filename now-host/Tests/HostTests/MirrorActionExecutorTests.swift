import XCTest
import MirrorKit
@testable import Host

@MainActor
final class MirrorActionExecutorTests: XCTestCase {
    func testIdentityBoundPlansCannotFallThroughToLegacyDispatch() {
        let window = InteractionPlan.activateWindow(psn: "0.1", ref: "w")
        let workshop = InteractionPlan.menuCommand(menuID: 140,
                                                   itemIndex: 1,
                                                   titleLeft: 117)
        let windowObject = MirrorObject.Window(
            id: "0.1/Disk#0", ref: "w", psn: "0.1", title: "Disk",
            rect: .init(l: 0, t: 0, r: 100, b: 100), kind: 0,
            isFront: false, part: .titleBar)
        let windowClick = Interaction(
            object: .window(windowObject),
            gesture: .click(count: 1, mods: 0, at: .init(x: 10, y: 10)))
        func menuClick(_ title: String, index: Int) -> Interaction {
            let item = MirrorObject.MenuItem(
                menu: .init(id: 140, title: "Window", left: 117,
                            isApple: false),
                index: index, title: title, cmd: "", isEnabled: true,
                isSeparator: false)
            return .init(object: .menuItem(item),
                         gesture: .click(count: 1, mods: 0,
                                         at: .init(x: 130, y: 80)))
        }
        XCTAssertTrue(MirrorActionExecutor.requiresTypedSettlement(
            for: windowClick,
            plan: window))
        XCTAssertTrue(MirrorActionExecutor.requiresTypedSettlement(
            for: menuClick("Workshop", index: 1),
            plan: workshop))
        XCTAssertFalse(MirrorActionExecutor.requiresTypedSettlement(
            for: menuClick("About", index: 2),
            plan: workshop))
        XCTAssertTrue(MirrorActionExecutor.requiresTypedSettlement(
            for: windowClick,
            plan: .applicationVisibility(.showAll)))
    }

    func testSameAppWindowClickTargetsExactIncarnation() throws {
        let engine = try makeEngine()
        let object = MirrorObject.Window(
            id: "0.3/System Folder#0", ref: "system-ref", psn: "0.3",
            title: "System Folder", rect: .init(l: 1, t: 2, r: 200, b: 180),
            kind: 0, isFront: false, part: .titleBar)
        let interaction = Interaction(
            object: .window(object),
            gesture: .click(count: 1, mods: 0, at: .init(x: 20, y: 10)))
        let operation = try XCTUnwrap(MirrorActionExecutor.operation(
            for: interaction,
            plan: .activateWindow(psn: "0.3", ref: "system-ref"),
            engine: engine, id: "exact"))
        let finder = MirrorProcessIdentity(session: engine.session,
                                           incarnation: "finder")
        let system = MirrorWindowIdentity(process: finder,
                                          incarnation: "system-window")

        XCTAssertEqual(operation.target, .window(system))
        XCTAssertEqual(operation.postcondition, .windowFront(system))
        XCTAssertEqual(operation.displayedSnapshotID, engine.snapshot?.id)
    }

    func testWorkshopReopenStartsFromClosedWindowAndTargetsNOWProcess() throws {
        let engine = try makeEngine()
        let item = MirrorObject.MenuItem(
            menu: .init(id: 140, title: "Window", left: 100,
                        isApple: false),
            index: 1, title: "Workshop", cmd: "", isEnabled: true,
            isSeparator: false)
        let interaction = Interaction(
            object: .menuItem(item),
            gesture: .click(count: 1, mods: 0, at: .init(x: 130, y: 80)))
        let operation = try XCTUnwrap(MirrorActionExecutor.operation(
            for: interaction,
            plan: .menuCommand(menuID: 140, itemIndex: 1, titleLeft: 100),
            engine: engine, id: "workshop"))
        let now = MirrorProcessIdentity(session: engine.session,
                                        incarnation: "now")

        XCTAssertEqual(operation.target, .process(now))
        XCTAssertEqual(operation.postcondition,
                       .windowNamedPresent(owner: now,
                                           title: "New Old World"))
    }

    func testVisibilityPlansCarryExactProcessPostconditions() throws {
        let engine = try makeEngine()
        let menu = MirrorObject.Menu(
            id: ObjectResolver.applicationMenuID, title: "", left: 600,
            isApple: false)
        let app = MirrorObject.App(
            psn: "0.4", name: "New Old World", isFront: true,
            incarnation: "now")
        let object = MirrorObject.ApplicationMenuAction(
            title: "Hide Others", isEnabled: true,
            kind: .hideOthers(except: app), menu: menu, index: 2)
        let interaction = Interaction(
            object: .applicationMenuAction(object),
            gesture: .click(count: 1, mods: 0, at: .init(x: 610, y: 50)))
        let finder = MirrorProcessIdentity(session: engine.session,
                                           incarnation: "finder")
        let now = MirrorProcessIdentity(session: engine.session,
                                        incarnation: "now")

        let hideOthers = try XCTUnwrap(MirrorActionExecutor.operation(
            for: interaction,
            plan: .applicationVisibility(.hideOthers(
                exceptPSN: "0.4", incarnation: "now",
                name: "New Old World", menuID: menu.id,
                itemIndex: 2, titleLeft: menu.left)),
            engine: engine, id: "hide-others"))
        XCTAssertEqual(hideOthers.postcondition,
                       .processVisibility([finder: false, now: true]))

        let showAll = try XCTUnwrap(MirrorActionExecutor.operation(
            for: interaction, plan: .applicationVisibility(.showAll),
            engine: engine, id: "show-all"))
        XCTAssertEqual(showAll.postcondition,
                       .processVisibility([finder: true, now: true]))
    }

    private func makeEngine() throws -> MirrorStateEngine {
        let engine = MirrorStateEngine(guestKey: .synthetic("maxbook"))
        let data = Data(#"""
        {"version":2,"seq":1,"capturedAt":1,"source":"peek",
         "screen":{"w":640,"h":480},
         "apps":[
          {"psn":"0.3","name":"Finder","front":false,
           "incarnation":"finder"},
          {"psn":"0.4","name":"New Old World","front":true,
           "incarnation":"now"}],
         "processes":[
          {"psn":"0.3","name":"Finder","front":false,
           "signature":"MACS","incarnation":"finder"},
          {"psn":"0.4","name":"New Old World","front":true,
           "signature":"NOWo","incarnation":"now"}],
         "windows":[
          {"id":"0.3/System Folder#0","app":"Finder","psn":"0.3",
           "title":"System Folder","rect":{"l":1,"t":2,"r":200,"b":180},
           "front":false,"z":1,"visible":true,"controls":[],
           "ref":"system-ref","incarnation":"system-window"}],
         "meta":{"errors":[],"coverage":[
          {"scope":"processes","status":"complete"},
          {"scope":"windows","owner":"finder","status":"complete"},
          {"scope":"windows","owner":"now","status":"complete"}]}}
        """#.utf8)
        _ = engine.accept(try JSONDecoder().decode(Scene.self, from: data))
        return engine
    }
}
