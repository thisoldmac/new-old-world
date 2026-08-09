import XCTest
@testable import MirrorKit

/// The object-first rules, pinned.
///
/// These are the spec: what a gesture on a named thing MEANS. They run
/// without a machine because the decision is pure — which is the point of
/// splitting the plan from its execution. A driver that disagrees with
/// one of these is wrong; a driver that cannot serve one says so in its
/// own words and this file has nothing to say about that.
final class InteractionPolicyTests: XCTestCase {

    // MARK: - Fixtures

    private func win(front: Bool = true, ref: String? = "now-window-1",
                     part: MirrorObject.WindowPart = .content)
        -> MirrorObject.Window {
        .init(id: "0.9/Doc#0", ref: ref, psn: "0.9", title: "Doc",
              rect: Rect(l: 20, t: 40, r: 420, b: 300), kind: 8,
              isFront: front, part: part)
    }

    private func bar(part: Scrollbar.Part?) -> MirrorObject.Control {
        .init(ref: "now-element-bar", role: "scrollbar", title: "",
              rect: Rect(l: 380, t: 0, r: 396, b: 180),
              value: 10, min: 0, max: 500, isEnabled: true,
              window: win(), part: part)
    }

    private func dialogItem(enabled: Bool = true,
                            actionable: Bool = true,
                            ref: String? = "now-element-dialog")
        -> MirrorObject.DialogItem {
        .init(number: 7, ref: ref, title: "Date Formats…",
              rect: Rect(l: 10, t: 10, r: 110, b: 30),
              isEnabled: enabled, window: win(), semanticKind: "pushButton",
              semanticAction: actionable ? "press" : nil,
              isSemanticallyActionable: actionable)
    }

    private func plan(_ o: MirrorObject, _ g: MirrorGesture) -> InteractionPlan {
        InteractionPolicy.plan(for: .init(object: o, gesture: g))
    }

    private let tap = MirrorGesture.click(count: 1, mods: 0,
                                          at: Point(x: 0, y: 0))
    private let doubleTap = MirrorGesture.click(count: 2, mods: 0,
                                                at: Point(x: 0, y: 0))

    // MARK: - The reason the object comes first

    /// A desktop icon is reached BY NAME. Gesture-first, this was a click
    /// at a coordinate — which a guest with no positional click verb
    /// could not serve at all, so the Finder's icons were unreachable.
    func testADesktopIconIsSelectedByName() {
        let icon = MirrorObject.finderItem(
            .init(name: "Macintosh HD", container: nil,
                  point: Point(x: 700, y: 60)))

        XCTAssertEqual(plan(icon, tap),
                       .finderSelect(item: "Macintosh HD", container: .desktop))
        XCTAssertEqual(plan(icon, doubleTap),
                       .finderOpen(item: "Macintosh HD", container: .desktop))
    }

    /// An icon inside a folder window names its window, because the
    /// Finder addresses the two differently.
    func testAWindowIconNamesItsWindow() {
        let icon = MirrorObject.finderItem(
            .init(name: "Extensions", container: win(),
                  point: Point(x: 100, y: 100)))
        XCTAssertEqual(plan(icon, doubleTap),
                       .finderOpen(item: "Extensions",
                                   container: .window(title: "Doc")))
    }

    /// Empty desktop is an OBJECT, so a click on it has somewhere to go.
    /// Gesture-first this was "click at 700,500" and then a refusal.
    ///
    /// And the object carries WHOSE desktop it is, because a click there
    /// brings the Finder forward - which is what a Mac does, and what
    /// this did not do. Watched 2026-08-03: with the app switcher
    /// listing only applications that have windows, and the Finder's
    /// only window being the backdrop, the mirror could not reach the
    /// Finder at all.
    func testClickingTheDesktopFrontsTheFinder() {
        let finder = MirrorObject.App(psn: "0.3", name: "Finder",
                                      isFront: false)
        XCTAssertEqual(plan(.desktop(finder), tap),
                       .activateApp(psn: "0.3"))

        // Already front: nothing left to front, so it means the other
        // half of what a desktop click means.
        let front = MirrorObject.App(psn: "0.3", name: "Finder",
                                     isFront: true)
        XCTAssertEqual(plan(.desktop(front), tap), .finderDeselect)
    }

    func testEmptyDesktopIsAnObjectAndClearsTheSelection() {
        XCTAssertEqual(plan(.desktop(nil), tap), .finderDeselect)
        // And a double-click there really is nothing — said as nothing,
        // not as a failure.
        guard case .nothing = plan(.desktop(nil), doubleTap) else {
            return XCTFail("double-clicking bare desktop is a no-op, not a "
                           + "refusal")
        }
    }

    // MARK: - The point is metadata the object interprets

    func testAScrollArrowUsesThePartResolvedWithTheObject() {
        XCTAssertEqual(plan(.control(bar(part: .lineDown)), tap),
                       .controlPart(ref: "now-element-bar", part: 21, mods: 0))
        XCTAssertEqual(plan(.control(bar(part: .lineUp)), tap),
                       .controlPart(ref: "now-element-bar", part: 20, mods: 0))
        XCTAssertEqual(plan(.control(bar(part: .pageDown)), tap),
                       .controlPart(ref: "now-element-bar", part: 23, mods: 0))
    }

    /// A control that is not a scroll bar has no parts, and a click on
    /// one is the button part.
    func testAPlainControlIsTheButtonPart() {
        var button = bar(part: nil)
        button.role = "control"
        XCTAssertEqual(plan(.control(button), tap),
                       .controlPart(ref: "now-element-bar", part: 10, mods: 0))
    }

    func testADialogButtonUsesTheDialogManagerPath() {
        XCTAssertEqual(plan(.dialogItem(dialogItem()), tap),
                       .dialogItem(ref: "now-element-dialog", item: 7))
    }

    func testDisabledAndUnknownDialogItemsDoNotBecomeGenericClicks() {
        guard case .nothing = plan(.dialogItem(dialogItem(enabled: false)),
                                   tap) else {
            return XCTFail("a disabled DITL item is inert")
        }
        guard case .unsupported = plan(
            .dialogItem(dialogItem(actionable: false)), tap) else {
            return XCTFail("unknown DITL semantics must refuse")
        }
        guard case .unsupported = plan(
            .dialogItem(dialogItem(ref: nil)), tap) else {
            return XCTFail("an unaddressable DITL item must refuse")
        }
    }

    func testTheWheelUsesIncrementalLineParts() {
        XCTAssertEqual(
            plan(.control(bar(part: nil)),
                 .scroll(notches: 3, at: Point(x: 0, y: 0))),
            .controlPart(ref: "now-element-bar", part: 21, mods: 0))
        XCTAssertEqual(
            plan(.control(bar(part: nil)),
                 .scroll(notches: -3, at: Point(x: 0, y: 0))),
            .controlPart(ref: "now-element-bar", part: 20, mods: 0))
    }

    // MARK: - Windows

    func testDraggingChromeMovesAndSizesTheWindow() {
        let top = 40 + SceneBuilder.titleBarHeight

        XCTAssertEqual(
            plan(.window(win(part: .titleBar)),
                 .drag(from: Point(x: 100, y: 50),
                       to: Point(x: 160, y: 90), mods: 0)),
            .windowAct(ref: "now-window-1",
                       act: .move(left: 20 + 60, top: top + 40)))

        XCTAssertEqual(
            plan(.window(win(part: .growBox)),
                 .drag(from: Point(x: 415, y: 295),
                       to: Point(x: 500, y: 400), mods: 0)),
            .windowAct(ref: "now-window-1",
                       act: .resize(width: 500 - 20, height: 400 - top)))
    }

    func testTheBoxesAreWindowActs() {
        XCTAssertEqual(plan(.window(win(part: .closeBox)), tap),
                       .windowAct(ref: "now-window-1", act: .close))
        XCTAssertEqual(plan(.window(win(part: .zoomBox)), tap),
                       .windowAct(ref: "now-window-1", act: .zoom(out: true)))
    }

    /// Clicking a background window activates its application and selects
    /// that exact window. The latter is essential when Finder owns several.
    func testClickingABackgroundWindowSelectsThatExactWindow() {
        XCTAssertEqual(plan(.window(win(front: false)), tap),
                       .activateWindow(psn: "0.9", ref: "now-window-1"))
        guard case .nothing = plan(.window(win(front: true)), tap) else {
            return XCTFail("the front window is already front")
        }
    }

    /// A window with no reference cannot be acted on, and the refusal
    /// says which half is missing rather than blaming the machine.
    func testAWindowWithNoReferenceRefusesByName() {
        guard case .unsupported(let why) =
            plan(.window(win(ref: nil, part: .closeBox)), tap) else {
            return XCTFail("expected a named refusal")
        }
        XCTAssertTrue(why.contains("reference"), why)
    }

    // MARK: - Menus

    /// A ⌘ item takes the keystroke route only where a keystroke can
    /// carry the ⌘ — which NOW's Carbon guest cannot.
    ///
    /// MEASURED 2026-08-02, and it refuses rather than lying: "an event's
    /// modifiers live on the Event Manager's queue element, and the only
    /// call that hands that element back, PPostEvent, is not in
    /// CarbonLib… posting the keystroke without the modifier would type a
    /// bare character and report success, so it is refused instead."
    ///
    /// The policy assumed keystrokes worked, which would have failed
    /// every single shortcut on that guest while looking correct here.
    func testACommandItemRoutesByWhatTheGuestCanPost() {
        let menu = MirrorObject.Menu(id: 257, title: "File", left: 38,
                                     isApple: false)
        let withCmd = Interaction(
            object: .menuItem(.init(menu: menu, index: 4, title: "Close",
                                    cmd: "W", isEnabled: true,
                                    isSeparator: false)),
            gesture: tap)

        // A guest that CAN post a modified key: the shortcut is the
        // cheapest, most deterministic route.
        guard case .keystroke(let code, _, let mods) =
            InteractionPolicy.plan(for: withCmd, planes: .deviceDriven) else {
            return XCTFail("a ⌘ item is a keystroke where ⌘ can be posted")
        }
        XCTAssertEqual(mods, ActionModel.cmdKey)
        XCTAssertEqual(code, ActionModel.keycodes["w"],
                       "MenuEvent matches the CODE, not the character")

        // NOW's guest: same command, by identity, through the act plane.
        XCTAssertEqual(
            InteractionPolicy.plan(for: withCmd, planes: .residentActPlane),
            .menuCommand(menuID: 257, itemIndex: 4, titleLeft: 38),
            "a guest that cannot post ⌘ must take the MenuSelect route, "
            + "which needs no modifier at all")
    }

    /// **The wire's silence about a menu's position survives as silence.**
    ///
    /// This is the line the rest of it rests on. `normalizeMenus` used to
    /// end `?? 0`, and every guard below is unreachable while it does:
    /// nothing downstream can refuse an absence it never receives. The
    /// menu still enters the scene — a person should see it — and what it
    /// carries is "no position", which is a different fact from x = 0.
    func testAWireMenuWithNoLeftArrivesUnplacedRatherThanAtZero() {
        let menus = SceneBuilder.normalizeMenus([
            ["title": "File", "id": 257, "left": 38, "items": []],
            ["title": "Edit", "id": 258, "items": []],
            ["title": "Odd", "id": 259, "left": 0, "items": []],
        ])

        XCTAssertEqual(menus.map(\.title), ["File", "Edit", "Odd"],
                       "an unplaced menu is still a menu a person can see")
        XCTAssertEqual(menus[0].left, 38)
        XCTAssertNil(menus[1].left,
                     "a menu the wire did not place must not arrive at 0 — "
                         + "0 is four pixels from the Apple menu's title, "
                         + "and a menu act arms its press there")
        XCTAssertEqual(menus[2].left, 0,
                       "and a menu the wire really did place at 0 is a "
                           + "reading, not an absence")
    }

    /// **A menu the scene never placed is refused, not pressed at zero.**
    ///
    /// `titleLeft` is not a parameter of a menu act, it is its identity
    /// check: the resident answers a `MenuSelect` at ONE armed point, so
    /// that a press anywhere else — the person's, at the machine — passes
    /// through untouched. An act surface guarded by anything weaker rode
    /// a real user's press 18 times in 20.
    ///
    /// Until 2026-08-07 `SceneBuilder` defaulted an unreported `left` to
    /// **0**, and this policy could not see the difference. Zero is not
    /// "unknown": the act arms four pixels right of it, which is the
    /// Apple menu's title. So the number reaching here is optional now,
    /// and its absence is refused WITH THE REASON rather than served with
    /// a substitute — a silent drop would read to a person as a mirror
    /// that has stopped working.
    func testAMenuTheSceneNeverPlacedIsRefusedRatherThanPressedAtZero() {
        let placed = MirrorObject.Menu(id: 257, title: "File", left: 38,
                                       isApple: false)
        let unplaced = MirrorObject.Menu(id: 257, title: "File", left: nil,
                                         isApple: false)
        func item(_ menu: MirrorObject.Menu) -> Interaction {
            Interaction(
                object: .menuItem(.init(menu: menu, index: 1,
                                        title: "New Folder", cmd: "",
                                        isEnabled: true,
                                        isSeparator: false)),
                gesture: .click(count: 1, mods: 0, at: .init(x: 40, y: 8)))
        }

        XCTAssertEqual(
            InteractionPolicy.plan(for: item(placed),
                                   planes: .residentActPlane),
            .menuCommand(menuID: 257, itemIndex: 1, titleLeft: 38),
            "a placed menu still goes by identity")

        guard case .unsupported(let why) = InteractionPolicy.plan(
            for: item(unplaced), planes: .residentActPlane) else {
            return XCTFail("an unplaced menu must not produce a press: "
                + "\(InteractionPolicy.plan(for: item(unplaced), planes: .residentActPlane))")
        }
        XCTAssertTrue(why.contains("menu bar"),
                      "the refusal has to name what is missing: \(why)")
    }

    /// The same absence, one layer down, where the coordinate is actually
    /// chosen. `ActionModel.menuSelect` sends nothing at all rather than
    /// a `menuInvoke` aimed at a guess.
    func testMenuSelectSendsNothingForAMenuWithNoPosition() {
        let items = [Scene.MenuItem(title: "New Folder", index: 1,
                                    separator: false, enabled: true,
                                    mark: false, cmd: "")]
        let placed = Scene.Menu(title: "File", apple: false, left: 38,
                                id: 257, items: items)
        let unplaced = Scene.Menu(title: "File", apple: false, left: nil,
                                  id: 257, items: items)

        XCTAssertEqual(
            ActionModel.menuSelect(menu: placed, item: items[0]),
            [.menuInvoke(menuID: 257, itemIndex: 1, titleLeft: 38)])
        XCTAssertEqual(
            ActionModel.menuSelect(menu: unplaced, item: items[0]), [],
            "no position, no press — never a press at 0, which is the "
                + "Apple menu's title")
    }

    /// And an unplaced menu claims no span in the mirror's own menu bar.
    ///
    /// The 0 default did not only mis-aim acts. A menu that arrived at 0
    /// took the span from 0 to the next title — which is the strip the
    /// APPLE MENU's own title is drawn in — so a person clicking the
    /// apple in the mirror got the unplaced menu instead. The same
    /// substitution, one layer up, and visible rather than silent: the
    /// pixel it steals (x = 4) is the pixel the act used to arm at.
    func testAnUnplacedMenuClaimsNoSpanInTheMenuBar() {
        let items = [Scene.MenuItem(title: "About", index: 1,
                                    separator: false, enabled: true,
                                    mark: false, cmd: "")]
        func scene(fileLeft: Int?) -> Scene {
            Scene(version: IR.version, seq: 1, source: "mock", capturedAt: 0,
                  screen: .init(w: 800, h: 600), apps: [], processes: nil,
                  menubar: .init(app: "Finder", menus: [
                      // Ordered as the wire orders them, and the unplaced
                      // one is FIRST — which is what lets it take a span
                      // that starts before the Apple menu's.
                      Scene.Menu(title: "File", apple: false,
                                 left: fileLeft, id: 257, items: items),
                      Scene.Menu(title: "", apple: true, left: 10, id: 256,
                                 items: items),
                  ]),
                  windows: [], desktopItems: nil, meta: .init(errors: []))
        }

        // x = 4: inside the Apple menu's title, and four pixels is exactly
        // the offset a menu act adds to titleLeft when it arms.
        XCTAssertEqual(HitTester.hitTest(scene(fileLeft: nil), x: 4, y: 8),
                       .menubarBackground,
                       "a menu with no position owns no pixels")
        XCTAssertEqual(HitTester.hitTest(scene(fileLeft: 0), x: 4, y: 8),
                       .menuTitle(index: 0),
                       "a menu really placed at 0 does own them — which is "
                           + "why the absence had to stop arriving as 0")
    }

    /// The Application menu's lower half lists PROCESSES, and choosing
    /// one means "bring this application forward" — which the wire says
    /// by process serial number.
    ///
    /// Watched failing twice on 2026-08-03, both as menu commands that
    /// reported a tick the machine never honoured: `Hide Finder`, and
    /// choosing `Finder` from the list while Mail stayed frontmost. The
    /// row was being addressed instead of the thing the row names.
    func testAnApplicationRowIsTheApplication() {
        let appMenu = Scene.Menu(title: "", apple: false, left: 600,
                                 id: ObjectResolver.applicationMenuID,
                                 items: [])
        let apps = [Scene.AppRef(psn: "0.3", name: "Finder", front: false,
                                 incarnation: "process-finder", error: nil),
                    Scene.AppRef(psn: "0.7", name: "Mail", front: true,
                                 incarnation: "process-mail", error: nil)]

        let row = Scene.MenuItem(title: "Finder", index: 4, separator: false,
                                 enabled: true, mark: false, cmd: "")
        let object = ObjectResolver.menuItem(row, in: appMenu, index: 4,
                                             apps: apps)
        guard case .app(let a) = object else {
            return XCTFail("a row naming a running process IS that process")
        }
        XCTAssertEqual(a.psn, "0.3")
        XCTAssertEqual(plan(object, tap), .activateApp(psn: "0.3"),
                       "and choosing it fronts that application by psn, "
                       + "not by commanding menu -16489")

        let visibilityRows: [(Scene.MenuItem,
                              InteractionPlan.ApplicationVisibility)] = [
            (.init(title: "Hide Mail", index: 1, separator: false,
                   enabled: true, mark: false, cmd: ""),
             .hide(psn: "0.7", incarnation: "process-mail", name: "Mail",
                   menuID: ObjectResolver.applicationMenuID, itemIndex: 1,
                   titleLeft: 600)),
            (.init(title: "Hide Others", index: 2, separator: false,
                   enabled: true, mark: false, cmd: ""),
             .hideOthers(exceptPSN: "0.7", incarnation: "process-mail",
                         name: "Mail",
                         menuID: ObjectResolver.applicationMenuID,
                         itemIndex: 2, titleLeft: 600)),
            (.init(title: "Show All", index: 3, separator: false,
                   enabled: true, mark: false, cmd: ""), .showAll),
        ]
        for (row, expected) in visibilityRows {
            let resolved = ObjectResolver.menuItem(row, in: appMenu,
                                                   index: row.index,
                                                   apps: apps)
            XCTAssertEqual(plan(resolved, tap),
                           .applicationVisibility(expected), row.title)
        }

        let disabledShow = Scene.MenuItem(
            title: "Show All", index: 3, separator: false, enabled: false,
            mark: false, cmd: "")
        let disabled = ObjectResolver.menuItem(disabledShow, in: appMenu,
                                               index: 3, apps: apps)
        guard case .nothing = plan(disabled, tap) else {
            return XCTFail("the guest-disabled Show All row must be inert")
        }

        // And an ordinary menu is untouched by any of this.
        let file = Scene.Menu(title: "File", apple: false, left: 38,
                              id: 257, items: [])
        let quit = Scene.MenuItem(title: "Finder", index: 1, separator: false,
                                  enabled: true, mark: false, cmd: "")
        guard case .menuItem = ObjectResolver.menuItem(quit, in: file,
                                                       index: 1, apps: apps)
        else {
            return XCTFail("only the Application menu lists processes; a "
                           + "File-menu row that happens to share a name "
                           + "must stay a command")
        }
    }

    func testShortcutlessItemsAndSeparators() {
        let menu = MirrorObject.Menu(id: 257, title: "File", left: 38,
                                     isApple: false)
        let plain = MirrorObject.menuItem(
            .init(menu: menu, index: 9, title: "Page Setup…", cmd: "",
                  isEnabled: true, isSeparator: false))
        XCTAssertEqual(plan(plain, tap),
                       .menuCommand(menuID: 257, itemIndex: 9, titleLeft: 38))

        // Neither route depends on where the row was DRAWN, which is what
        // used to make selection miss below a separator.
        let separator = MirrorObject.menuItem(
            .init(menu: menu, index: 8, title: "-", cmd: "",
                  isEnabled: true, isSeparator: true))
        guard case .nothing = plan(separator, tap) else {
            return XCTFail("a separator is not a command")
        }
    }

    /// The live Apple menu of an OS 9 machine: the About row, the
    /// separator, then the Apple Menu Items folder.
    private func appleMenu(id: Int = -16383) -> Scene.Menu {
        func row(_ i: Int, _ title: String,
                 separator: Bool = false) -> Scene.MenuItem {
            .init(title: title, index: i, separator: separator,
                  enabled: true, mark: false, cmd: "")
        }
        return .init(title: "", apple: true, left: 10, id: id, items: [
            row(1, "About This Computer"),
            row(2, "-", separator: true),
            row(3, "Apple System Profiler"),
            row(6, "Control Panels"),
            row(9, "Key Caps"),
            row(14, "Sherlock 2"),
        ])
    }

    private func applePlan(_ title: String,
                           in menu: Scene.Menu) -> InteractionPlan {
        guard let item = menu.items.first(where: { $0.title == title }) else {
            return .nothing(why: "no such row")
        }
        return InteractionPolicy.plan(
            for: Interaction(object: ObjectResolver.menuItem(
                item, in: menu, index: item.index), gesture: tap),
            planes: .residentActPlane)
    }

    func testKeyCapsUsesGuestFinderInsteadOfCarbonDeskAccessoryAPI() {
        XCTAssertEqual(applePlan("Key Caps", in: appleMenu()),
                       .openAppleMenuItem(name: "Key Caps"))
    }

    /// **The whole Apple Menu Items folder, not one row of it.**
    ///
    /// Only Key Caps took the Finder route until 2026-08-06; every other
    /// row became a menu command that the front application answered by
    /// doing nothing, because no application's menu dispatch opens a file
    /// out of that folder. Measured in `acts.log`: those rows dispatched
    /// into NOW's own main loop in 18-50 ms and fell off the end of
    /// `handle_menu_choice`, which has no Apple-menu case at all.
    ///
    /// Mutation check: give `isAppleMenuItemsEntry` back its old
    /// Key-Caps-only meaning and all three of these become
    /// `.menuCommand(menuID: -16383, ...)` — the exact plan the log
    /// recorded for the three rows Michelle reported.
    func testEveryAppleMenuItemsRowGoesToTheFinder() {
        let menu = appleMenu()
        for title in ["Apple System Profiler", "Control Panels",
                      "Sherlock 2"] {
            XCTAssertEqual(applePlan(title, in: menu),
                           .openAppleMenuItem(name: title),
                           "\(title) must be opened as a file")
        }
    }

    /// The About row is above the separator and IS the front
    /// application's own command — it stays on the command route, and
    /// asking the Finder to open a file by that name would name nothing.
    func testAboutRowStaysAMenuCommand() {
        XCTAssertEqual(applePlan("About This Computer", in: appleMenu()),
                       .menuCommand(menuID: -16383, itemIndex: 1,
                                    titleLeft: 10))
    }

    /// No separator, no claim. A menu that does not have the OS 9 shape
    /// keeps the route it has always had rather than having a filename
    /// guessed for it.
    func testAppleMenuWithoutASeparatorKeepsTheCommandRoute() {
        var menu = appleMenu()
        menu.items = menu.items.filter { !$0.separator }
        XCTAssertEqual(applePlan("Sherlock 2", in: menu),
                       .menuCommand(menuID: -16383, itemIndex: 14,
                                    titleLeft: 10))
    }

    // MARK: - Nothing is ever a silent drop

    /// Every plan either does something, or explains itself. A case that
    /// returned an empty action list would be indistinguishable from a
    /// broken mirror to the person clicking it.
    func testEveryOutcomeSaysSomething() {
        let objects: [MirrorObject] = [
            .desktop(nil),
            .window(win(part: .collapseBox)),
            .window(win(ref: nil)),
            .control(bar(part: .thumb)),
            .dialogItem(dialogItem(actionable: false)),
            .menu(.init(id: 256, title: "", left: 10, isApple: true)),
            .app(.init(psn: "0.9", name: "Finder", isFront: true)),
        ]
        let gestures: [MirrorGesture] = [
            tap, doubleTap,
            .drag(from: Point(x: 0, y: 0), to: Point(x: 5, y: 5), mods: 0),
            .scroll(notches: 1, at: Point(x: 0, y: 0)),
        ]
        for o in objects {
            for g in gestures {
                switch InteractionPolicy.plan(for: .init(object: o,
                                                         gesture: g)) {
                case .nothing(let why), .unsupported(let why):
                    XCTAssertFalse(why.isEmpty,
                                   "\(o.describedForAPerson) + \(g) gave an "
                                   + "empty reason")
                default:
                    break                  // it does something; fine
                }
            }
        }
    }

    /// The gap that is real, stated as a gap. A thumb drag needs a verb
    /// that SETS a value; pressing a part at the control's own centre
    /// cannot position one, and paging there in a loop would overshoot.
    func testTheThumbDragGapIsNamedRatherThanApproximated() {
        guard case .unsupported(let why) =
            plan(.control(bar(part: .thumb)),
                 .drag(from: Point(x: 388, y: 60),
                       to: Point(x: 388, y: 140), mods: 0)) else {
            return XCTFail("approximating a thumb drag is worse than "
                           + "refusing it - it looks like a stutter")
        }
        XCTAssertTrue(why.contains("value"), why)
    }
}
