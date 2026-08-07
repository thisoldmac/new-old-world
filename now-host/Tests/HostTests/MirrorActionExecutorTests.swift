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

    func testKeyCapsLaunchCarriesNamedProcessPostcondition() throws {
        let engine = try makeEngine()
        let menu = MirrorObject.Menu(id: 256, title: "", left: 0,
                                     isApple: true)
        let item = MirrorObject.MenuItem(
            menu: menu, index: 9, title: "Key Caps", cmd: "",
            isEnabled: true, isSeparator: false)
        let interaction = Interaction(
            object: .menuItem(item),
            gesture: .click(count: 1, mods: 0, at: .init(x: 10, y: 100)))
        let operation = try XCTUnwrap(MirrorActionExecutor.operation(
            for: interaction, plan: .openAppleMenuItem(name: "Key Caps"),
            engine: engine, id: "key-caps"))

        XCTAssertEqual(operation.postcondition,
                       .processNamedPresent("Key Caps"))
    }

    /// **The defect that made every control panel time out having
    /// worked.** A Finder-open predicted a Finder-owned window for
    /// everything; a control panel opens as its OWN application, so the
    /// postcondition could never match and the act burned its full 15 s
    /// holding the one mutation lane. `openAppleMenuItem` has always
    /// predicted `processNamedPresent` for the same event reached from the
    /// Apple menu — this case was the outlier, not the new shape.
    func testOpeningAControlPanelPredictsItsOwnProcessNotAFinderWindow() throws {
        let engine = try makeEngine()
        let finder = MirrorProcessIdentity(session: engine.session,
                                           incarnation: "finder")

        for panel in ["Date & Time", "AppleTalk"] {
            let operation = try XCTUnwrap(MirrorActionExecutor.operation(
                for: open(panel, in: "Control Panels"),
                plan: .finderOpen(item: panel,
                                  container: .window(title: "Control Panels")),
                engine: engine, id: "open-\(panel)"))
            XCTAssertEqual(operation.postcondition,
                           .processNamedPresent(panel),
                           "a cdev opens as an application named for itself")
            XCTAssertEqual(operation.target, .process(finder),
                           "the Finder is still who was asked to open it")
        }

        let app = try XCTUnwrap(MirrorActionExecutor.operation(
            for: open("SimpleText", in: "Control Panels"),
            plan: .finderOpen(item: "SimpleText",
                              container: .window(title: "Control Panels")),
            engine: engine, id: "open-app"))
        XCTAssertEqual(app.postcondition, .processNamedPresent("SimpleText"))
    }

    /// The half the old prediction was right about, and it must stay right:
    /// the Finder does own a folder's window, and a disk's.
    func testOpeningAFolderStillPredictsAFinderOwnedWindow() throws {
        let engine = try makeEngine()
        let finder = MirrorProcessIdentity(session: engine.session,
                                           incarnation: "finder")

        let folder = try XCTUnwrap(MirrorActionExecutor.operation(
            for: open("Fonts", in: "Control Panels"),
            plan: .finderOpen(item: "Fonts",
                              container: .window(title: "Control Panels")),
            engine: engine, id: "open-folder"))
        XCTAssertEqual(folder.postcondition,
                       .windowNamedPresent(owner: finder, title: "Fonts"))

        let disk = try XCTUnwrap(MirrorActionExecutor.operation(
            for: open("Macintosh HD", in: nil),
            plan: .finderOpen(item: "Macintosh HD", container: .desktop),
            engine: engine, id: "open-disk"))
        XCTAssertEqual(disk.postcondition,
                       .windowNamedPresent(owner: finder,
                                           title: "Macintosh HD"))
    }

    /// **Only a positive signal moves the prediction.** An alias reports
    /// its own kind and never its target's, a document's type says nothing
    /// about which application will claim it, and an item this scene never
    /// read cannot be classified at all. All three keep the prediction they
    /// have always had rather than acquiring a new way to be wrong.
    func testAnUnclassifiableItemKeepsTheOldPrediction() throws {
        let engine = try makeEngine()
        let finder = MirrorProcessIdentity(session: engine.session,
                                           incarnation: "finder")

        for (item, container) in [
            ("Panel Alias", InteractionPlan.FinderContainer
                .window(title: "Control Panels")),
            ("Read Me", .desktop),
            ("Never Read", .window(title: "System Folder")),
        ] {
            let operation = try XCTUnwrap(MirrorActionExecutor.operation(
                for: open(item, in: nil),
                plan: .finderOpen(item: item, container: container),
                engine: engine, id: "open-\(item)"))
            XCTAssertEqual(operation.postcondition,
                           .windowNamedPresent(owner: finder, title: item),
                           "\(item) is not classifiable from this scene")
        }
    }

    /// **The false negative sweep A priced at 18 seconds.** `open "Mail"`
    /// reported `timedOut` **having worked**: the desktop's `Mail` is an
    /// alias, an alias was unclassifiable, and unclassifiable predicted a
    /// Finder window titled `Mail` — a window no Finder ever makes,
    /// because Mail opens as its own application. Measured on the
    /// emulator 2026-08-07: the alias's original is an `APPL` named
    /// `Mail`, and opening it puts a process named `Mail` at the front.
    ///
    /// The renamed case is the load-bearing one. An alias can be called
    /// anything; the process is named after the TARGET, so a prediction
    /// built from the alias's own name is a second way to time out having
    /// worked, and it would survive a test that only ever used an alias
    /// whose name happened to match.
    func testOpeningAResolvedAliasPredictsWhatItPointsAt() throws {
        let engine = try makeEngine()
        let finder = MirrorProcessIdentity(session: engine.session,
                                           incarnation: "finder")

        for alias in ["Mail", "My Mailer"] {
            let operation = try XCTUnwrap(MirrorActionExecutor.operation(
                for: open(alias, in: nil),
                plan: .finderOpen(item: alias, container: .desktop),
                engine: engine, id: "open-\(alias)"))
            XCTAssertEqual(operation.postcondition,
                           .processNamedPresent("Mail"),
                           "\(alias) points at an application called Mail")
            XCTAssertEqual(operation.target, .process(finder))
        }

        /* An alias to a FOLDER still opens a Finder window - and the
           Finder titles it after the target, so `Docs` would never
           match either. */
        let folder = try XCTUnwrap(MirrorActionExecutor.operation(
            for: open("Docs", in: nil),
            plan: .finderOpen(item: "Docs", container: .desktop),
            engine: engine, id: "open-docs"))
        XCTAssertEqual(folder.postcondition,
                       .windowNamedPresent(owner: finder,
                                           title: "Documents"))
    }

    private func open(_ name: String, in container: String?) -> Interaction {
        let window = container.map {
            MirrorObject.Window(
                id: "0.3/\($0)#0", ref: "panels-ref", psn: "0.3", title: $0,
                rect: .init(l: 0, t: 0, r: 300, b: 200), kind: 0,
                isFront: true, part: .content)
        }
        return .init(object: .finderItem(.init(name: name,
                                               container: window,
                                               point: .init(x: 10, y: 20))),
                     gesture: .click(count: 2, mods: 0,
                                     at: .init(x: 10, y: 20)))
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
         "desktopItems":[
          {"name":"Macintosh HD","kind":"disk","x":500,"y":40,
           "placed":true,"alias":false,"invisible":false},
          {"name":"Read Me","kind":"file","type":"TEXT","creator":"ttxt",
           "x":500,"y":120,"placed":true,"alias":false,"invisible":false},
          {"name":"Mail","kind":"file","x":500,"y":200,"placed":true,
           "alias":true,"invisible":false,
           "aliasTarget":{"name":"Mail","kind":"application",
                          "type":"APPL","creator":"aplt"}},
          {"name":"My Mailer","kind":"file","x":500,"y":260,"placed":true,
           "alias":true,"invisible":false,
           "aliasTarget":{"name":"Mail","kind":"application",
                          "type":"APPL","creator":"aplt"}},
          {"name":"Docs","kind":"file","x":500,"y":320,"placed":true,
           "alias":true,"invisible":false,
           "aliasTarget":{"name":"Documents","kind":"folder"}}],
         "windows":[
          {"id":"0.3/System Folder#0","app":"Finder","psn":"0.3",
           "title":"System Folder","rect":{"l":1,"t":2,"r":200,"b":180},
           "front":false,"z":1,"visible":true,"controls":[],
           "ref":"system-ref","incarnation":"system-window"},
          {"id":"0.3/Control Panels#0","app":"Finder","psn":"0.3",
           "title":"Control Panels","rect":{"l":10,"t":40,"r":310,"b":240},
           "front":true,"z":0,"visible":true,"controls":[],
           "ref":"panels-ref","incarnation":"panels-window",
           "items":[
            {"name":"Date & Time","kind":"file","type":"cdev",
             "creator":"date","x":10,"y":10,"placed":true,"alias":false,
             "invisible":false},
            {"name":"AppleTalk","kind":"file","type":"cdev",
             "creator":"atlk","x":80,"y":10,"placed":true,"alias":false,
             "invisible":false},
            {"name":"SimpleText","kind":"application","type":"APPL",
             "creator":"ttxt","x":150,"y":10,"placed":true,"alias":false,
             "invisible":false},
            {"name":"Fonts","kind":"folder","x":10,"y":80,
             "placed":true,"alias":false,"invisible":false},
            {"name":"Panel Alias","kind":"file","x":80,"y":80,
             "placed":true,"alias":true,"invisible":false}]}],
         "meta":{"errors":[],"coverage":[
          {"scope":"processes","status":"complete"},
          {"scope":"windows","owner":"finder","status":"complete"},
          {"scope":"windows","owner":"now","status":"complete"}]}}
        """#.utf8)
        _ = engine.accept(try JSONDecoder().decode(Scene.self, from: data))
        return engine
    }
}
