import XCTest
@testable import MirrorKit

/// What a drag picks up, what it can be dropped on, and — the half that
/// matters most — what it refuses.
///
/// Each guard names the mutation it was watched failing under.
final class DragTargetingTests: XCTestCase {

    // MARK: - Fixtures

    private static func item(_ name: String, _ x: Int, _ y: Int,
                             kind: String = "file",
                             origin: Scene.PositionOrigin? = .drawn,
                             w: Int = 32, h: Int = 32) -> Scene.DesktopItem {
        .init(name: name, kind: kind, type: nil, creator: nil, x: x, y: y,
              placed: true, alias: false, invisible: false,
              w: w, h: h, origin: origin)
    }

    private static func window(id: String, app: String, title: String,
                               rect: Rect,
                               items: [Scene.DesktopItem]? = nil,
                               controls: [Scene.Control] = [])
        -> Scene.Window {
        .init(id: id, app: app, psn: "1.\(id)", title: title, kind: 20,
              rect: rect, front: true, z: 0, visible: true,
              controls: controls, text: nil, items: items, display: nil,
              island: nil)
    }

    private static func scene(windows: [Scene.Window] = [],
                              desktop: [Scene.DesktopItem] = [])
        -> Scene {
        Scene(version: 2, seq: 1, source: "fixture", capturedAt: 0,
              screen: .init(w: 800, h: 600), apps: [], processes: nil,
              menubar: nil, windows: windows,
              desktopItems: desktop.isEmpty ? nil : desktop,
              meta: .init(errors: []))
    }

    /// A desktop with a document at (40,60), an application at (200,60), a
    /// folder at (300,60), and a disk at (700,40) whose position the host
    /// INVENTED.
    private static func desktopScene() -> Scene {
        scene(desktop: [
            item("Read Me", 40, 60),
            item("SimpleText", 200, 60, kind: "application"),
            item("Projects", 300, 60, kind: "folder"),
            item("Untitled", 700, 40, kind: "disk", origin: .unknown),
        ])
    }

    private static func centre(_ i: Scene.DesktopItem) -> (x: Int, y: Int) {
        (i.x + 16, i.y + 16)
    }

    // MARK: - Subject

    func testADrawnDesktopItemCanBePickedUp() throws {
        let s = Self.desktopScene()
        let subject = try Self.unwrapSuccess(
            DragTargeting.subject(s, x: 56, y: 76))
        XCTAssertEqual(subject.name, "Read Me")
        XCTAssertEqual(subject.container, .desktop)
        /* 32 wide, 44 tall: the icon plus the label under it. `home` is the
           box the mirror will put back, and the Finder drags a name with its
           icon — a ghost that shed the label on pickup would visibly change
           shape at the moment of grabbing it. */
        XCTAssertEqual(DragTargeting.home(of: subject, in: s),
                       Rect(l: 40, t: 60, r: 72, b: 104))
    }

    /// **The blocker, as a test.** Mutation: drop the `homeIsTrustworthy`
    /// guard from `subject`. The invented disk position becomes draggable and
    /// the snap-back promises to return it to a place nobody measured.
    func testAnItemWithNoTrustworthyHomeIsRefused() {
        let s = Self.desktopScene()
        switch DragTargeting.subject(s, x: 716, y: 56) {
        case .success:
            XCTFail("a position this side invented is not a home")
        case .failure(let refusal):
            XCTAssertEqual(refusal, .homeUnknown(name: "Untitled",
                                                 origin: .unknown))
            XCTAssertTrue(refusal.message.contains("put back"),
                          "the refusal must say why: \(refusal.message)")
            XCTAssertTrue(refusal.message.contains("ours, not the guest's"))
        }
    }

    /// The saved grid is close enough to draw from and not to aim with.
    func testASavedGridPositionIsAlsoRefused() {
        let s = Self.scene(desktop: [Self.item("Filed", 40, 60,
                                               origin: .saved)])
        switch DragTargeting.subject(s, x: 56, y: 76) {
        case .success: XCTFail("the saved grid is not the drawn box")
        case .failure(let r):
            XCTAssertEqual(r, .homeUnknown(name: "Filed", origin: .saved))
        }
    }

    /// Chrome is not a subject, and the refusal names the KIND of thing
    /// rather than an identifier nobody can read.
    func testChromeIsNotASubject() {
        let s = Self.scene(windows: [
            Self.window(id: "w1", app: "SimpleText", title: "Untitled",
                        rect: Rect(l: 100, t: 100, r: 400, b: 300)),
        ])
        switch DragTargeting.subject(s, x: 200, y: 105) {
        case .success: XCTFail("a title bar is not an item")
        case .failure(let r):
            XCTAssertEqual(r, .notAnItem(what: "a title bar"))
        }
    }

    /// A window item's home is content-local and must arrive in the same
    /// global space as every destination point.
    ///
    /// Mutation: return the content-local box from `home(of:)`. The ghost
    /// then starts at the top-left of the screen and snaps back there.
    func testAWindowItemsHomeIsGlobal() throws {
        let win = Self.window(
            id: "w1", app: "Finder", title: "Projects",
            rect: Rect(l: 100, t: 100, r: 400, b: 300),
            items: [Self.item("Notes", 10, 20, w: 16, h: 16)])
        let s = Self.scene(windows: [win])
        let origin = FinderItems.contentOrigin(win)
        let subject = try Self.unwrapSuccess(DragTargeting.subject(
            s, x: origin.x + 14, y: origin.y + 24))
        XCTAssertEqual(subject.container, .window("w1"))
        XCTAssertEqual(
            DragTargeting.home(of: subject, in: s),
            Rect(l: origin.x + 10, t: origin.y + 20,
                 r: origin.x + 26, b: origin.y + 36),
            "a 16x16 list row keeps its own box, not a 32x32 assumption")
    }

    // MARK: - Destination and intent

    func testDesktopToDesktopIsARearrangement() throws {
        let s = Self.desktopScene()
        let plan = try Self.unwrapSuccess(
            DragTargeting.plan(s, from: (56, 76), to: (500, 400)))
        XCTAssertEqual(plan.intent, .rearrange,
                       "dragging on the desktop moves the icon; it is not a "
                       + "no-op")
        XCTAssertEqual(plan.destination, .desktop(x: 500, y: 400))
        XCTAssertEqual(plan.home, Rect(l: 40, t: 60, r: 72, b: 104))
    }

    /// Mutation: return `.move` for every destination. A same-window drag
    /// then reads as a file move, which is a different promise.
    func testWithinOneFinderWindowIsARearrangement() throws {
        let win = Self.window(
            id: "w1", app: "Finder", title: "Projects",
            rect: Rect(l: 100, t: 100, r: 400, b: 300),
            items: [Self.item("Notes", 10, 20)])
        let s = Self.scene(windows: [win])
        let o = FinderItems.contentOrigin(win)
        let plan = try Self.unwrapSuccess(DragTargeting.plan(
            s, from: (o.x + 26, o.y + 36), to: (o.x + 150, o.y + 120)))
        XCTAssertEqual(plan.intent, .rearrange)
        XCTAssertEqual(plan.destination,
                       .finderWindow(windowID: "w1", path: "Projects",
                                     x: o.x + 150, y: o.y + 120))
    }

    func testDesktopIntoAFinderWindowIsAMove() throws {
        let win = Self.window(id: "w1", app: "Finder", title: "Projects",
                              rect: Rect(l: 100, t: 100, r: 400, b: 300),
                              items: [])
        let s = Self.scene(windows: [win],
                           desktop: [Self.item("Read Me", 500, 400)])
        let o = FinderItems.contentOrigin(win)
        let plan = try Self.unwrapSuccess(DragTargeting.plan(
            s, from: (516, 416), to: (o.x + 50, o.y + 50)))
        XCTAssertEqual(plan.intent, .move)
    }

    /// Mutation: fold `.applicationIcon` into `.container`. "Open this with
    /// that" becomes "file this inside an application", which is a different
    /// act and one the Finder would refuse.
    func testDroppingOnAnApplicationIconOpensWith() throws {
        let s = Self.desktopScene()
        let app = Self.centre(Self.item("SimpleText", 200, 60))
        let plan = try Self.unwrapSuccess(
            DragTargeting.plan(s, from: (56, 76), to: (app.x, app.y)))
        XCTAssertEqual(plan.intent, .openWith)
        guard case .applicationIcon(let name, let x, let y)
                = plan.destination else {
            return XCTFail("expected an application icon, got "
                           + "\(plan.destination)")
        }
        XCTAssertEqual(name, "SimpleText")
        XCTAssertEqual([x, y], [216, 76],
                       "the drop point is the ICON's centre, not the "
                       + "pointer's — the same discipline a click follows")
    }

    func testDroppingOnAFolderIconFilesItInside() throws {
        let s = Self.desktopScene()
        let folder = Self.centre(Self.item("Projects", 300, 60))
        let plan = try Self.unwrapSuccess(DragTargeting.plan(
            s, from: (56, 76), to: (folder.x, folder.y)))
        XCTAssertEqual(plan.intent, .move)
        XCTAssertEqual(plan.destination,
                       .container(name: "Projects", kind: "folder",
                                  x: 316, y: 76))
    }

    func testDroppingOnAnotherApplicationsWindow() throws {
        let win = Self.window(id: "w1", app: "SimpleText", title: "Untitled",
                              rect: Rect(l: 100, t: 100, r: 400, b: 300))
        let s = Self.scene(windows: [win],
                           desktop: [Self.item("Read Me", 500, 400)])
        let plan = try Self.unwrapSuccess(
            DragTargeting.plan(s, from: (516, 416), to: (250, 200)))
        XCTAssertEqual(plan.intent, .move)
        guard case .applicationWindow(_, _, let app, _, _)
                = plan.destination else {
            return XCTFail("expected an application window")
        }
        XCTAssertEqual(app, "SimpleText")
    }

    /// Mutation: let the `default:` branch of `destination` fall through to
    /// `.desktop`. Every scroll bar and menu becomes a silent drop target,
    /// and a drag onto one lands the file somewhere nobody aimed.
    func testChromeIsNotADropTarget() {
        let scrollbar = Scene.Control(
            ref: "c1", role: "scrollbar", title: "", rect: Rect(
                l: 280, t: 0, r: 296, b: 180),
            enabled: true, visible: true, value: 0, min: 0, max: 100,
            checked: false)
        let win = Self.window(id: "w1", app: "Finder", title: "Projects",
                              rect: Rect(l: 100, t: 100, r: 400, b: 300),
                              items: [], controls: [scrollbar])
        let s = Self.scene(windows: [win],
                           desktop: [Self.item("Read Me", 500, 400)])
        let o = FinderItems.contentOrigin(win)
        switch DragTargeting.plan(s, from: (516, 416),
                                  to: (o.x + 288, o.y + 90)) {
        case .success(let plan):
            XCTFail("a scroll bar took a drop: \(plan.destination)")
        case .failure(let r):
            XCTAssertEqual(r, .notADropTarget(what: "a scroll bar"))
        }
    }

    /// Mutation: drop the self-drop guard. An item dropped on itself resolves
    /// to a container destination named after itself, which the Finder would
    /// answer by doing nothing while the mirror said it had moved a file.
    func testAnItemDroppedOnItselfIsRefused() {
        let s = Self.desktopScene()
        switch DragTargeting.plan(s, from: (56, 76), to: (58, 78)) {
        case .success: XCTFail("dropping a thing on itself is not a move")
        case .failure(let r):
            XCTAssertEqual(r, .droppedOnItself(name: "Read Me"))
        }
    }

    /// The same NAME in a different container is a different item, and
    /// dropping one on the other is a real move.
    func testSameNameInAnotherContainerIsNotItself() throws {
        let win = Self.window(id: "w1", app: "Finder", title: "Projects",
                              rect: Rect(l: 100, t: 100, r: 400, b: 300),
                              items: [Self.item("Read Me", 10, 20)])
        let s = Self.scene(windows: [win],
                           desktop: [Self.item("Read Me", 500, 400)])
        let o = FinderItems.contentOrigin(win)
        let plan = try Self.unwrapSuccess(DragTargeting.plan(
            s, from: (516, 416), to: (o.x + 26, o.y + 36)))
        XCTAssertEqual(plan.intent, .move)
    }

    // MARK: -

    private static func unwrapSuccess<T>(
        _ outcome: Result<T, DragTargeting.Refusal>,
        file: StaticString = #filePath, line: UInt = #line) throws -> T {
        switch outcome {
        case .success(let v): return v
        case .failure(let r):
            XCTFail("refused: \(r.message)", file: file, line: line)
            throw r
        }
    }
}
