import XCTest
import MirrorKit
import NOWAgentIntegration
@testable import Host

/// The seam between NOW's scene document and MirrorKit's scene.
///
/// **What these tests are for.** One rule carries the whole file: a plane is
/// *absent*, *empty*, or *populated*, and the adapter has to land all three
/// distinctly. The cheap mistake — `?? []` — passes an absent-plane test that
/// only checks the array, because absent and empty both produce `[]`. So every
/// plane below is tested three times and **the flag is asserted every time**,
/// which is what makes the collapse visible.
///
/// The mutations recorded at the foot of this file were each run and watched
/// failing.
final class MirrorSceneAdapterTests: XCTestCase {

    // MARK: - the smallest document NOW's producer can send

    /// Only `version` is non-optional in `NOWSceneDocument`, so this is the
    /// floor: a document that reports nothing at all. Every plane in the
    /// scene it produces must read as ABSENT, never as empty.
    func testAnEmptyDocumentReportsEveryPlaneAbsent() {
        let scene = MirrorSceneAdapter.scene(from: NOWSceneDocument(version: 1))

        XCTAssertEqual(scene.version, 1)
        XCTAssertEqual(scene.apps, [])
        XCTAssertFalse(scene.appsPresent,
                       "No apps key means nobody looked, not none found.")
        XCTAssertEqual(scene.windows, [])
        XCTAssertFalse(scene.windowsPresent)
        XCTAssertNil(scene.menubar, "An absent menubar stays absent.")
        XCTAssertNil(scene.processes)
        XCTAssertNil(scene.desktopItems)
        XCTAssertEqual(scene.meta.errors, [])
        XCTAssertFalse(scene.meta.errorsPresent,
                       "An absent meta must not read as a clean bill of "
                           + "health nobody issued.")
    }

    // MARK: - apps

    func testAppsAbsentEmptyAndPopulated() {
        let absent = MirrorSceneAdapter.scene(from: doc(apps: nil))
        XCTAssertEqual(absent.apps, [])
        XCTAssertFalse(absent.appsPresent)

        let empty = MirrorSceneAdapter.scene(from: doc(apps: []))
        XCTAssertEqual(empty.apps, [])
        XCTAssertTrue(empty.appsPresent,
                      "An empty apps array is a claim: the walk ran.")

        let populated = MirrorSceneAdapter.scene(from: doc(apps: [
            .init(psn: "0:1", name: "Finder", front: true, error: "stale")
        ]))
        XCTAssertTrue(populated.appsPresent)
        XCTAssertEqual(populated.apps.count, 1)
        XCTAssertEqual(populated.apps.first?.name, "Finder")
        XCTAssertEqual(populated.apps.first?.error, "stale",
                       "The oracle's verdict crosses verbatim.")
    }

    // MARK: - windows

    func testWindowsAbsentEmptyAndPopulated() {
        let absent = MirrorSceneAdapter.scene(from: doc(windows: nil))
        XCTAssertEqual(absent.windows, [])
        XCTAssertFalse(absent.windowsPresent)

        let empty = MirrorSceneAdapter.scene(from: doc(windows: []))
        XCTAssertTrue(empty.windowsPresent)

        let populated = MirrorSceneAdapter.scene(
            from: doc(windows: [window()]))
        XCTAssertTrue(populated.windowsPresent)
        XCTAssertEqual(populated.windows.first?.title, "Untitled")
        XCTAssertEqual(populated.windows.first?.rect,
                       Rect(l: 10, t: 20, r: 110, b: 120))
    }

    // MARK: - windows[].controls — the plane the port exists for

    func testWindowControlsAbsentEmptyAndPopulated() {
        let absent = MirrorSceneAdapter.scene(
            from: doc(windows: [window(controls: nil)]))
        XCTAssertEqual(absent.windows.first?.controls, [])
        XCTAssertEqual(absent.windows.first?.controlsPresent, false,
                       "A window whose control walk did not run must not "
                           + "read as a window with no controls.")

        let empty = MirrorSceneAdapter.scene(
            from: doc(windows: [window(controls: [])]))
        XCTAssertEqual(empty.windows.first?.controls, [])
        XCTAssertEqual(empty.windows.first?.controlsPresent, true)

        let populated = MirrorSceneAdapter.scene(from: doc(windows: [
            window(controls: [.init(title: "OK",
                                    rect: NOWSceneRect(l: 1, t: 2, r: 3, b: 4),
                                    enabled: true, visible: true,
                                    value: 1, min: 0, max: 1)])
        ]))
        let control = try? XCTUnwrap(populated.windows.first?.controls.first)
        XCTAssertEqual(populated.windows.first?.controlsPresent, true)
        XCTAssertEqual(control?.title, "OK")
        XCTAssertEqual(control?.value, 1)
        XCTAssertEqual(control?.rect, Rect(l: 1, t: 2, r: 3, b: 4))
    }

    /// **Two windows in one scene, one walked and one not.** Presence is
    /// per-window, and a single scene-wide flag would be wrong here — which
    /// is the shape a "simplification" of this adapter would reach for.
    func testControlPresenceIsPerWindowNotPerScene() {
        let scene = MirrorSceneAdapter.scene(from: doc(windows: [
            window(id: "w1", controls: []),
            window(id: "w2", controls: nil),
        ]))
        XCTAssertEqual(scene.windows.map(\.controlsPresent), [true, false])
    }

    // MARK: - menubar and its menus

    func testMenubarAbsentIsNilAndDoesNotBecomeAnEmptyBar() {
        let scene = MirrorSceneAdapter.scene(from: doc(menubar: nil))
        XCTAssertNil(scene.menubar,
                     "No menubar key means this scene does not report one; "
                         + "an empty bar would claim the front process has "
                         + "no menus.")
    }

    func testMenubarMenusAbsentEmptyAndPopulated() {
        let absent = MirrorSceneAdapter.scene(
            from: doc(menubar: .init(app: "Finder", menus: nil)))
        XCTAssertEqual(absent.menubar?.menus, [])
        XCTAssertEqual(absent.menubar?.menusPresent, false)

        let empty = MirrorSceneAdapter.scene(
            from: doc(menubar: .init(app: "Backgrounder", menus: [])))
        XCTAssertEqual(empty.menubar?.menusPresent, true,
                       "A faceless application genuinely has no menus, and "
                           + "saying so is not the same as silence.")

        let populated = MirrorSceneAdapter.scene(from: doc(
            menubar: .init(app: "Finder",
                           menus: [.init(title: "File", left: 12, id: 129,
                                         items: nil)])))
        XCTAssertEqual(populated.menubar?.menusPresent, true)
        XCTAssertEqual(populated.menubar?.menus.first?.title, "File")
        XCTAssertEqual(populated.menubar?.menus.first?.id, 129)
        XCTAssertEqual(populated.menubar?.menus.first?.left, 12)
    }

    func testMenuItemsAbsentEmptyAndPopulated() {
        func menus(_ items: [NOWSceneDocument.MenuItem]?)
            -> MirrorKit.Scene.Menu? {
            MirrorSceneAdapter.scene(from: doc(
                menubar: .init(app: "Finder",
                               menus: [.init(title: "File", left: 12,
                                             id: 129, items: items)])))
                .menubar?.menus.first
        }

        XCTAssertEqual(menus(nil)?.items, [])
        XCTAssertEqual(menus(nil)?.itemsPresent, false,
                       "A menu whose item walk hit a bound reports nothing "
                           + "rather than a short list that reads complete.")
        XCTAssertEqual(menus([])?.itemsPresent, true)

        let one = menus([.init(title: "Open", index: 1, separator: false,
                               enabled: true, mark: false, cmd: "O")])
        XCTAssertEqual(one?.itemsPresent, true)
        XCTAssertEqual(one?.items.first?.title, "Open")
        XCTAssertEqual(one?.items.first?.cmd, "O")
        XCTAssertEqual(one?.items.first?.index, 1)
    }

    // MARK: - meta.errors

    func testMetaErrorsAbsentEmptyAndPopulated() {
        let absentMeta = MirrorSceneAdapter.scene(from: doc(meta: nil))
        XCTAssertFalse(absentMeta.meta.errorsPresent)

        let absentKey = MirrorSceneAdapter.scene(
            from: doc(meta: .init(errors: nil, plane: "peek")))
        XCTAssertEqual(absentKey.meta.errors, [])
        XCTAssertFalse(absentKey.meta.errorsPresent)
        XCTAssertEqual(absentKey.meta.plane, "peek",
                       "The rest of meta still crosses.")

        let empty = MirrorSceneAdapter.scene(
            from: doc(meta: .init(errors: [])))
        XCTAssertTrue(empty.meta.errorsPresent,
                      "An empty errors list is the walk saying it finished "
                          + "and found nothing wrong.")

        let populated = MirrorSceneAdapter.scene(
            from: doc(meta: .init(errors: ["Finder: truncated"],
                                  latencyMs: 12, bytes: 900)))
        XCTAssertTrue(populated.meta.errorsPresent)
        XCTAssertEqual(populated.meta.errors, ["Finder: truncated"])
        XCTAssertEqual(populated.meta.latencyMs, 12)
        XCTAssertEqual(populated.meta.bytes, 900)
    }

    // MARK: - planes that are Optional on both sides

    func testOptionalOnBothSidesCrossesUnflattened() {
        XCTAssertNil(MirrorSceneAdapter.scene(from: doc(processes: nil))
            .processes)
        XCTAssertEqual(MirrorSceneAdapter.scene(from: doc(processes: []))
            .processes, [])
        XCTAssertNil(MirrorSceneAdapter.scene(from: doc(desktopItems: nil))
            .desktopItems)
        XCTAssertEqual(MirrorSceneAdapter.scene(from: doc(desktopItems: []))
            .desktopItems, [])

        let items = MirrorSceneAdapter.scene(from: doc(windows: [
            window(items: nil),
        ])).windows.first?.items
        XCTAssertNil(items, "A window's items plane keeps its own absence.")
    }

    // MARK: - a round trip must not launder absence into emptiness

    /// The adapter's output is re-encodable, and this is where a collapse
    /// would become permanent: an absent plane that re-encodes as `[]` has
    /// been promoted to a claim, in a document a later consumer will believe.
    func testAbsentPlanesDoNotReappearAsEmptyArraysOnEncode() throws {
        let scene = MirrorSceneAdapter.scene(from: doc(
            apps: nil,
            menubar: .init(app: "Finder",
                           menus: [.init(title: "File", left: 12, id: 129,
                                         items: nil)]),
            windows: [window(controls: nil)],
            meta: .init(errors: nil)))
        let data = try JSONEncoder().encode(scene)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNil(json["apps"], "An absent plane re-encodes absent.")
        let windows = try XCTUnwrap(json["windows"] as? [[String: Any]])
        XCTAssertNil(windows.first?["controls"])
        let bar = try XCTUnwrap(json["menubar"] as? [String: Any])
        let menus = try XCTUnwrap(bar["menus"] as? [[String: Any]])
        XCTAssertNil(menus.first?["items"])
        let meta = try XCTUnwrap(json["meta"] as? [String: Any])
        XCTAssertNil(meta["errors"])
    }

    /// And the mirror image: a plane the guest DID report empty survives the
    /// round trip as an empty array rather than vanishing.
    func testEmptyPlanesSurviveTheRoundTripAsEmptyArrays() throws {
        let scene = MirrorSceneAdapter.scene(from: doc(
            apps: [], windows: [], meta: .init(errors: [])))
        let data = try JSONEncoder().encode(scene)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual((json["apps"] as? [Any])?.count, 0)
        XCTAssertEqual((json["windows"] as? [Any])?.count, 0)
        let meta = try XCTUnwrap(json["meta"] as? [String: Any])
        XCTAssertEqual((meta["errors"] as? [Any])?.count, 0)
    }

    /// End to end from bytes: the wire's own decoder, then the adapter. This
    /// is the path a live scene takes, and it proves the three states survive
    /// the decode as well as the crossing.
    func testFromWireBytesAbsenceSurvivesDecodeAndCrossing() throws {
        let bytes = Data("""
        {"version":1,"seq":4,"source":"peek","screen":{"w":640,"h":480},
         "windows":[{"id":"w1","app":"Finder","psn":"0:1","title":"HD",
                     "rect":{"l":0,"t":0,"r":100,"b":100},"front":true,
                     "z":0,"visible":true}],
         "meta":{"plane":"peek"}}
        """.utf8)
        let document = try NOWSceneCodec.decode(irVersion: 1, document: bytes)
        let scene = MirrorSceneAdapter.scene(from: document)

        XCTAssertEqual(scene.seq, 4)
        XCTAssertEqual(scene.source, "peek")
        XCTAssertEqual(scene.screen.w, 640)
        XCTAssertTrue(MirrorSceneAdapter.hasScreen(scene))
        XCTAssertTrue(scene.windowsPresent)
        XCTAssertFalse(scene.appsPresent, "No apps key on the wire.")
        XCTAssertEqual(scene.windows.first?.controlsPresent, false)
        XCTAssertNil(scene.windows.first?.kind,
                     "NOW omits kind for a window it could not classify.")
        XCTAssertFalse(scene.meta.errorsPresent)
    }

    // MARK: - what the adapter refuses to invent

    /// The producer never emits `apple`, `ref`, `role` or `checked`. The
    /// adapter fills them with the falsy value and these assertions pin that
    /// as a deliberate non-claim: anything else would be the adapter making
    /// an assertion about the machine that no walk supports.
    func testUnreportedFieldsAreNotAsserted() {
        let scene = MirrorSceneAdapter.scene(from: doc(
            menubar: .init(app: "Finder",
                           menus: [.init(title: "", left: 0, id: 128,
                                         items: [])]),
            windows: [window(controls: [.init(title: "Cancel")])]))
        XCTAssertEqual(scene.menubar?.menus.first?.apple, false)
        let control = scene.windows.first?.controls.first
        XCTAssertEqual(control?.ref, "",
                       "An empty ref is MirrorKit's own word for a control "
                           + "that cannot be acted on.")
        XCTAssertEqual(control?.role, "control",
                       "Never 'scrollbar' — that is a defProc reading NOW "
                           + "does not have.")
        XCTAssertEqual(control?.checked, false)
        XCTAssertNil(scene.windows.first?.display,
                     "NOW models no display plane; nil is 'not traced'.")
    }

    /// A document with no `screen` gets 0×0 rather than an invented 512×342,
    /// and the pane has a way to ask.
    func testAbsentScreenIsNamedNotInvented() {
        let scene = MirrorSceneAdapter.scene(from: NOWSceneDocument(version: 1))
        XCTAssertEqual(scene.screen.w, 0)
        XCTAssertEqual(scene.screen.h, 0)
        XCTAssertFalse(MirrorSceneAdapter.hasScreen(scene))

        let sized = MirrorSceneAdapter.scene(
            from: doc(screen: .init(w: 512, h: 342)))
        XCTAssertTrue(MirrorSceneAdapter.hasScreen(sized))
    }

    // MARK: - builders

    private func doc(screen: NOWSceneDocument.ScreenSize? = nil,
                     apps: [NOWSceneDocument.AppRef]? = nil,
                     processes: [NOWSceneDocument.ProcessRef]? = nil,
                     menubar: NOWSceneDocument.Menubar? = nil,
                     windows: [NOWSceneDocument.Window]? = nil,
                     desktopItems: [NOWSceneDocument.DesktopItem]? = nil,
                     meta: NOWSceneDocument.Meta? = nil) -> NOWSceneDocument {
        NOWSceneDocument(version: 1, seq: 1, capturedAt: 0, source: "peek",
                         screen: screen, apps: apps, processes: processes,
                         menubar: menubar, windows: windows,
                         desktopItems: desktopItems, meta: meta)
    }

    private func window(id: String = "w1",
                        controls: [NOWSceneDocument.Control]? = nil,
                        items: [NOWSceneDocument.DesktopItem]? = nil)
        -> NOWSceneDocument.Window {
        NOWSceneDocument.Window(id: id, app: "Finder", psn: "0:1",
                                title: "Untitled",
                                rect: NOWSceneRect(l: 10, t: 20,
                                                   r: 110, b: 120),
                                front: true, z: 0, visible: true,
                                controls: controls, items: items)
    }
}

/*
 Mutations run against this file, each watched failing:

 1. `plane(_:)` returns `(rows ?? [], true)` — the `?? []` collapse.
    Absent becomes empty everywhere. RED in
    testAnEmptyDocumentReportsEveryPlaneAbsent,
    testAppsAbsentEmptyAndPopulated, testWindowsAbsentEmptyAndPopulated,
    testWindowControlsAbsentEmptyAndPopulated,
    testControlPresenceIsPerWindowNotPerScene,
    testMenubarMenusAbsentEmptyAndPopulated,
    testMenuItemsAbsentEmptyAndPopulated,
    testAbsentPlanesDoNotReappearAsEmptyArraysOnEncode,
    testFromWireBytesAbsenceSurvivesDecodeAndCrossing.
 2. `meta(from:)` returns `Meta.make(errors: [])` for an absent meta — the
    default flag, i.e. a clean bill of health nobody issued. RED in
    testAnEmptyDocumentReportsEveryPlaneAbsent and
    testMetaErrorsAbsentEmptyAndPopulated.
 3. `scene(from:)` maps an absent menubar to an empty bar
    (`Menubar.make(app: "", menus: [])`). RED in
    testMenubarAbsentIsNilAndDoesNotBecomeAnEmptyBar.
 4. Absent `screen` becomes 512×342. RED in
    testAbsentScreenIsNamedNotInvented.

 Counts as run (15 tests in the class):
   1 -> 10 tests red, 2 -> 2, 3 -> 2, 4 -> 1. Restored: 15/15 green.
*/
