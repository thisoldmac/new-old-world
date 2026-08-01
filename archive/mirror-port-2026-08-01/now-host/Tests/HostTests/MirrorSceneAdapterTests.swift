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

        // `window()`'s own rect is (10,20)-(110,120), so content-local
        // origin is (10, 40) — this control's crossed rect is the wire's
        // (1,2)-(3,4) minus that origin, not the wire value itself (see
        // testControlRectCrossesIntoContentLocal for the fixture-driven
        // version of this same rule).
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
        XCTAssertEqual(control?.rect, Rect(l: -9, t: -38, r: -7, b: -36))
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

    // MARK: - controls[].rect crosses into content-local, and role is inferred

    /// `window()`'s own rect is (10,20)-(110,120): content-local origin
    /// (10,40), content size 100×80. Every control below is built in the
    /// wire's GLOBAL coordinates (what `now_scene_walk.c` actually reports —
    /// see the header) and every assertion is in content-local, what
    /// `HitTester`/`FinderItems`/`SceneRenderer` actually read.
    func testControlRectCrossesIntoContentLocal() throws {
        let scene = MirrorSceneAdapter.scene(from: doc(windows: [
            window(controls: [.init(
                title: "", rect: NOWSceneRect(l: 94, t: 44, r: 110, b: 140),
                enabled: true, visible: true, value: 5, min: 0, max: 50)])
        ]))
        let control = try XCTUnwrap(scene.windows.first?.controls.first)
        XCTAssertEqual(control.rect, Rect(l: 84, t: 4, r: 100, b: 100),
                       "global (94,44)-(110,140) minus the content origin "
                           + "(10,40) — not the wire value unchanged.")
    }

    /// Long, thin, hugging the window's own right edge, carrying a real
    /// range: everything Mirror's own `Scrollbar.isLive` later asks for.
    /// This is the shape `SceneRenderer.drawControl` requires to draw a
    /// thumb at all.
    func testLiveVerticalScrollbarIsInferredFromShapeAndEdge() throws {
        let scene = MirrorSceneAdapter.scene(from: doc(windows: [
            window(controls: [.init(
                title: "", rect: NOWSceneRect(l: 94, t: 44, r: 110, b: 140),
                enabled: true, visible: true, value: 5, min: 0, max: 50)])
        ]))
        let control = try XCTUnwrap(scene.windows.first?.controls.first)
        XCTAssertEqual(control.role, "scrollbar")
        XCTAssertTrue(Scrollbar.isLive(control), "max > min, so it scrolls.")
    }

    /// A scrollbar whose content happens to fit reports a degenerate range
    /// (`min == max`) but is still shaped and positioned like a bar — still
    /// `"scrollbar"`, just not `isLive`. Collapsing this to `"control"` would
    /// hide the distinction from every consumer that checks role before
    /// asking `isLive` (see the doc comment on `inferredRole`).
    func testDegenerateRangeScrollbarIsStillCalledAScrollbar() throws {
        let scene = MirrorSceneAdapter.scene(from: doc(windows: [
            window(controls: [.init(
                title: "", rect: NOWSceneRect(l: 94, t: 44, r: 110, b: 140),
                enabled: true, visible: true, value: -4, min: -4, max: -4)])
        ]))
        let control = try XCTUnwrap(scene.windows.first?.controls.first)
        XCTAssertEqual(control.role, "scrollbar")
        XCTAssertFalse(Scrollbar.isLive(control), "min == max: nothing to scroll.")
    }

    /// The horizontal twin of the test above — every existing shape test in
    /// this file (including the one above) builds a TALL strip, so the
    /// `h > w` branch of `inferredRole`'s edge check was never exercised by
    /// this suite before. Numbers are the ones measured on a real Finder
    /// folder window's horizontal bar (`docs/open-issues.md`): min -52,
    /// max -52, value -52, a bottom-hugging strip. `max >= min` (not `>`)
    /// is what keeps this "scrollbar" rather than the honest-default
    /// "control" a stricter guard would fall back to.
    func testDegenerateRangeHorizontalScrollbarIsStillCalledAScrollbar() throws {
        let scene = MirrorSceneAdapter.scene(from: doc(windows: [
            window(controls: [.init(
                title: "", rect: NOWSceneRect(l: 14, t: 104, r: 100, b: 120),
                enabled: true, visible: true,
                value: -52, min: -52, max: -52)])
        ]))
        let control = try XCTUnwrap(scene.windows.first?.controls.first)
        XCTAssertEqual(control.role, "scrollbar",
                       "long, thin, hugging the window's own BOTTOM edge — "
                           + "a degenerate range must not hide the shape.")
        XCTAssertFalse(Scrollbar.isLive(control), "min == max: nothing to scroll.")
    }

    /// Square, not a bar — the real fixture's own 16×16 hidden control
    /// (`min:0/max:1`) is this exact shape. A range alone must not be enough.
    func testSquareControlWithARangeIsNotInferredAsAScrollbar() throws {
        let scene = MirrorSceneAdapter.scene(from: doc(windows: [
            window(controls: [.init(
                title: "", rect: NOWSceneRect(l: 20, t: 20, r: 36, b: 36),
                enabled: true, visible: false, value: 0, min: 0, max: 1)])
        ]))
        let control = try XCTUnwrap(scene.windows.first?.controls.first)
        XCTAssertEqual(control.role, "control")
    }

    /// Long and thin, but nowhere near an edge — a real scrollbar never
    /// floats in the middle of a window's content. Mutation-watched: delete
    /// the edge test from `inferredRole` (keep only the shape test) and this
    /// goes from a "control" this suite expects to a "scrollbar" it does not.
    func testLongThinControlAwayFromTheEdgeIsNotInferredAsAScrollbar() throws {
        let scene = MirrorSceneAdapter.scene(from: doc(windows: [
            window(controls: [.init(
                title: "", rect: NOWSceneRect(l: 40, t: 44, r: 56, b: 140),
                enabled: true, visible: true, value: 5, min: 0, max: 50)])
        ]))
        let control = try XCTUnwrap(scene.windows.first?.controls.first)
        XCTAssertEqual(control.role, "control",
                       "Same shape as the live-scrollbar test above, "
                           + "translated 54px left of the window's right "
                           + "edge — a scrollbar does not float mid-content.")
    }

    /// A `role` NOW's wire actually sent (should it ever) always wins over
    /// the inference — this file's own three-state rule applies here too:
    /// inference is a fallback for an ABSENT field, not an override.
    func testAnExplicitRoleIsNeverOverriddenByInference() throws {
        let scene = MirrorSceneAdapter.scene(from: doc(windows: [
            window(controls: [.init(
                role: "checkbox", title: "",
                rect: NOWSceneRect(l: 20, t: 20, r: 36, b: 36),
                enabled: true, visible: true, value: 0, min: 0, max: 1)])
        ]))
        XCTAssertEqual(scene.windows.first?.controls.first?.role, "checkbox")
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

    // MARK: - desktopItems: content, and the one field this adapter computes

    /// The plain crossing: name/kind/type/creator/position/alias/invisible
    /// all cross verbatim, the same way every other field in this file does.
    func testDesktopItemContentCrossesVerbatim() throws {
        let scene = MirrorSceneAdapter.scene(from: doc(desktopItems: [
            .init(name: "ReadMe", kind: "file", type: "TEXT", creator: "ttxt",
                  x: 40, y: 60, placed: true, alias: false, invisible: false)
        ]))
        let item = try XCTUnwrap(scene.desktopItems?.first)
        XCTAssertEqual(item.name, "ReadMe")
        XCTAssertEqual(item.kind, "file")
        XCTAssertEqual(item.type, "TEXT")
        XCTAssertEqual(item.creator, "ttxt")
        XCTAssertEqual(item.x, 40)
        XCTAssertEqual(item.y, 60)
        XCTAssertTrue(item.placed)
    }

    /// A `kind == "disk"` row the guest reported `placed:false` is the ONE
    /// case this adapter computes a position for — everything else (here, a
    /// Desktop Folder item at a real, guest-reported position) must not be
    /// touched by the same pass.
    func testUnplacedVolumesAreLaidOutTopRightAndEverythingElsePassesThrough() {
        let scene = MirrorSceneAdapter.scene(from: doc(
            screen: .init(w: 640, h: 480),
            desktopItems: [
                .init(name: "Lab", kind: "folder", x: 20, y: 40,
                      placed: true, alias: false, invisible: false),
                .init(name: "Macintosh HD", kind: "disk", x: 0, y: 0,
                      placed: false, alias: false, invisible: false),
            ]))
        let items = scene.desktopItems ?? []
        XCTAssertEqual(items.count, 2)

        let folder = items.first { $0.kind == "folder" }
        XCTAssertEqual(folder?.x, 20, "an already-placed item is untouched")
        XCTAssertEqual(folder?.y, 40)
        XCTAssertEqual(folder?.placed, true)

        let disk = items.first { $0.kind == "disk" }
        XCTAssertEqual(disk?.placed, true,
                       "the adapter placed it — the guest never does")
        XCTAssertEqual(disk?.x, 640 - 76,
                       "SceneGeometry.placeVolumes' own inset from the "
                           + "right edge, at the scene's own screen width")
        XCTAssertEqual(disk?.y, 12, "the first (only) disk's row")
    }

    /// A disk the guest DID report placed (should that ever happen) is left
    /// alone — a real position always outranks this adapter's fallback.
    func testAnAlreadyPlacedVolumeIsNotRelaidOut() {
        let scene = MirrorSceneAdapter.scene(from: doc(
            screen: .init(w: 640, h: 480),
            desktopItems: [
                .init(name: "Macintosh HD", kind: "disk", x: 5, y: 5,
                      placed: true, alias: false, invisible: false),
            ]))
        let disk = scene.desktopItems?.first
        XCTAssertEqual(disk?.x, 5, "the real position wins outright")
        XCTAssertEqual(disk?.y, 5)
    }

    /// Absence and emptiness still cross unflattened once placement is in
    /// the mix — the new pass must not turn a nil into `[]` or vice versa.
    func testDesktopItemsPlaneStillCrossesUnflattenedWithPlacementInPlay() {
        XCTAssertNil(MirrorSceneAdapter.scene(from: doc(desktopItems: nil))
            .desktopItems)
        XCTAssertEqual(MirrorSceneAdapter.scene(from: doc(desktopItems: []))
            .desktopItems, [])
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
                       "No rect at all, so there is no shape to read a "
                           + "scrollbar out of — see ScrollbarRoleInference* "
                           + "for the control that DOES carry one.")
        XCTAssertEqual(control?.checked, false)
        XCTAssertNil(scene.windows.first?.display,
                     "The scene DOCUMENT carries no display plane, which is "
                         + "all nil claims here. NOW does model one — "
                         + "`qdtrace` — but it arrives as a separate control "
                         + "answer, not as a key on the scene, so this "
                         + "adapter cannot produce it. MirrorContentJoin is "
                         + "where the two meet.")
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

 Counts as run (15 tests in the class before the role/rect-crossing tests
 below were added):
   1 -> 10 tests red, 2 -> 2, 3 -> 2, 4 -> 1. Restored: 15/15 green.

 5. `inferredRole`'s edge check deleted (`onEdge` hardcoded `true`, keeping
    only the shape test). RED in
    testLongThinControlAwayFromTheEdgeIsNotInferredAsAScrollbar — a
    mid-content control the same shape as a real scrollbar now reads
    "scrollbar" too:

      XCTAssertEqual failed: ("scrollbar") is not equal to ("control") -
      Same shape as the live-scrollbar test above, translated 54px left of
      the window's right edge — a scrollbar does not float mid-content.

    Restored (edge test put back): green.
*/
