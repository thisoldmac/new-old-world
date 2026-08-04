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

    func testTheWheelPagesRatherThanLines() {
        XCTAssertEqual(
            plan(.control(bar(part: nil)),
                 .scroll(notches: 3, at: Point(x: 0, y: 0))),
            .controlPart(ref: "now-element-bar", part: 23, mods: 0))
        XCTAssertEqual(
            plan(.control(bar(part: nil)),
                 .scroll(notches: -3, at: Point(x: 0, y: 0))),
            .controlPart(ref: "now-element-bar", part: 22, mods: 0))
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
                                 error: nil),
                    Scene.AppRef(psn: "0.7", name: "Mail", front: true,
                                 error: nil)]

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
                   enabled: true, mark: false, cmd: ""), .hide(name: "Mail")),
            (.init(title: "Hide Others", index: 2, separator: false,
                   enabled: true, mark: false, cmd: ""),
             .hideOthers(except: "Mail")),
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
