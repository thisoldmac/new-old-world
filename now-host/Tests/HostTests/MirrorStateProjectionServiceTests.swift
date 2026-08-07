import XCTest
import MirrorKit
import NOWAgentIntegration
@testable import Host

@MainActor
final class MirrorStateProjectionServiceTests: XCTestCase {
    private let key = GuestKey.synthetic("mirror-projection")

    private func scene(seq: Int, title: String = "Macintosh HD") throws
        -> Scene {
        let document = #"""
        {
          "version":2,"seq":\#(seq),"capturedAt":\#(seq),"source":"peek",
          "screen":{"w":640,"h":480},
          "apps":[{"psn":"0.3","name":"Finder","front":true,
                   "incarnation":"process-finder"}],
          "processes":[{"psn":"0.3","name":"Finder","front":true,
                         "signature":"MACS",
                         "incarnation":"process-finder"}],
          "menubar":{"app":"Finder","menus":[
            {"title":"","apple":true,"left":0,"id":256,"items":[
              {"title":"Apple System Profiler","index":1,
               "separator":false,"enabled":true,"mark":false,"cmd":""}
            ]},
            {"title":"File","apple":false,"left":28,"id":129,
             "items":[]}
          ]},
          "windows":[{
            "id":"0.3/\#(title)#0","app":"Finder","psn":"0.3",
            "title":"\#(title)",
            "rect":{"l":10,"t":20,"r":300,"b":240},
            "front":true,"z":0,"visible":true,"controls":[],
            "ref":"window-ref",
            "incarnation":"process-finder/window-disk"
          }],
          "meta":{"errors":[],"coverage":[
            {"scope":"processes","status":"complete"},
            {"scope":"menubar","owner":"process-finder",
             "status":"complete"},
            {"scope":"windows","owner":"process-finder",
             "status":"complete"}
          ]}
        }
        """#
        return try JSONDecoder().decode(Scene.self, from: Data(document.utf8))
    }

    private func service(_ registry: MirrorStateEngineRegistry)
        -> MirrorStateProjectionService {
        MirrorStateProjectionService(engines: registry,
                                     currentGuest: { self.key })
    }

    func testStatusAndSnapshotCarryTheEnginesExactIdentity() async throws {
        let registry = MirrorStateEngineRegistry()
        let engine = registry.engine(for: key)
        _ = engine.accept(try scene(seq: 7))
        let published = try XCTUnwrap(engine.snapshot)
        let originalEntries = engine.store.entries.count

        let status = await service(registry).read(.init(intention: .status))
        let snapshot = await service(registry).read(
            .init(intention: .snapshot))

        XCTAssertEqual(status.value?.current?.snapshotID, published.id)
        XCTAssertEqual(status.value?.current?.digest, published.digest)
        XCTAssertEqual(snapshot.value?.snapshot?.metadata,
                       status.value?.current)
        XCTAssertEqual(snapshot.value?.snapshot?.entities.map(\.id), [
            "process:process-finder",
            "window:process-finder:process-finder/window-disk",
        ])
        XCTAssertEqual(snapshot.value?.snapshot?.menus.map(\.id), [256, 129])
        XCTAssertEqual(snapshot.value?.snapshot?.menus.first?.items.first?.title,
                       "Apple System Profiler")
        XCTAssertEqual(engine.store.entries.count, originalEntries,
                       "a projection read must publish no second snapshot")
    }

    func testFindUsesStableEngineEntitiesWithoutAnotherObserver() async throws {
        let registry = MirrorStateEngineRegistry()
        let engine = registry.engine(for: key)
        _ = engine.accept(try scene(seq: 1))

        let result = await service(registry).read(.init(
            intention: .find, query: "macintosh"))

        XCTAssertEqual(result.value?.matches?.count, 1)
        XCTAssertEqual(result.value?.matches?.first?.id,
                       "window:process-finder:process-finder/window-disk")
        XCTAssertEqual(result.value?.matches?.first?.freshness, "fresh")
        XCTAssertEqual(engine.store.entries.count, 1)
    }

    func testProcessVisibilityIsUnknownUntilGuestCensusAndThenProjected()
        async throws {
        let registry = MirrorStateEngineRegistry()
        let engine = registry.engine(for: key)
        _ = engine.accept(try scene(seq: 1))

        let unknown = await service(registry).read(.init(intention: .snapshot))
        XCTAssertNil(unknown.value?.snapshot?.entities.first {
            $0.kind == .process
        }?.visible, "a process roster does not imply that it is shown")

        XCTAssertTrue(engine.enrichVisibility(
            ["Finder": false], complete: true, sequence: 1))
        let observed = await service(registry).read(
            .init(intention: .snapshot))
        XCTAssertEqual(observed.value?.snapshot?.entities.first {
            $0.kind == .process
        }?.visible, false)
    }

    func testWaitReturnsTheNextSnapshotFromTheSameEngine() async throws {
        let registry = MirrorStateEngineRegistry()
        let engine = registry.engine(for: key)
        _ = engine.accept(try scene(seq: 1))
        let firstID = try XCTUnwrap(engine.snapshot?.id)
        let projection = service(registry)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 35_000_000)
            _ = engine.accept(try! self.scene(seq: 2, title: "System Folder"))
        }
        let result = await projection.read(.init(
            intention: .wait, afterSnapshotID: firstID, timeoutMs: 500))

        XCTAssertFalse(result.value?.timedOut ?? true)
        XCTAssertEqual(result.value?.current?.sequence, 2)
        XCTAssertEqual(result.value?.snapshot?.metadata.snapshotID,
                       engine.snapshot?.id)
        XCTAssertEqual(engine.store.entries.count, 2,
                       "only the test's authoritative observation publishes")
    }

    func testUnavailableEngineAndBoundedTimeoutAreExplicit() async throws {
        let registry = MirrorStateEngineRegistry()
        let absent = await service(registry).read(.init(intention: .status))
        XCTAssertEqual(absent.unavailable?.code,
                       "now-mirror-snapshot-unavailable")

        let engine = registry.engine(for: key)
        _ = engine.accept(try scene(seq: 1))
        let currentID = try XCTUnwrap(engine.snapshot?.id)
        let timedOut = await service(registry).read(.init(
            intention: .wait, afterSnapshotID: currentID, timeoutMs: 1))
        XCTAssertTrue(timedOut.value?.timedOut == true)
        XCTAssertEqual(timedOut.value?.current?.snapshotID, currentID)
        XCTAssertEqual(engine.store.entries.count, 1)
    }

    // MARK: - surfaces: what the renderer draws, for the client that doesn't

    func testSnapshotCarriesGeometryAndTheControlKindThatDecidesTheDrawing()
        async throws {
        let document = #"""
        {
          "version":2,"seq":3,"capturedAt":3,"source":"peek",
          "screen":{"w":640,"h":480},
          "apps":[{"psn":"0.9","name":"Date & Time","front":true,
                   "incarnation":"process-dt"}],
          "processes":[{"psn":"0.9","name":"Date & Time","front":true,
                        "signature":"dtcp","incarnation":"process-dt"}],
          "menubar":{"app":"Date & Time","menus":[]},
          "windows":[{
            "id":"0.9/Date & Time#0","app":"Date & Time","psn":"0.9",
            "title":"Date & Time",
            "rect":{"l":40,"t":60,"r":440,"b":400},
            "front":true,"z":0,"visible":true,
            "ref":"window-dt",
            "controls":[
              {"ref":"ctl-1","role":"control","title":"On",
               "rect":{"l":10,"t":10,"r":60,"b":26},
               "enabled":true,"visible":true,"value":1,"checked":true,
               "semantic":{"knowledge":"known","kind":"radioButton",
                           "state":"on","value":"On"}},
              {"ref":"","role":"control","title":"Region",
               "rect":{"l":10,"t":40,"r":160,"b":60},
               "enabled":true,"visible":true,
               "semantic":{"knowledge":"known","kind":"popupButton",
                           "value":"U.S."}}
            ],
            "dialogItems":[
              {"number":4,"title":"Separator",
               "rect":{"l":10,"t":80,"r":120,"b":96},
               "enabled":true,"visible":true,
               "semantic":{"knowledge":"known","kind":"editText",
                           "value":"/"}}
            ],
            "incarnation":"process-dt/window-dt"
          }],
          "meta":{"errors":[],"coverage":[]}
        }
        """#
        let registry = MirrorStateEngineRegistry()
        let engine = registry.engine(for: key)
        _ = engine.accept(try JSONDecoder().decode(
            Scene.self, from: Data(document.utf8)))

        let result = await service(registry).read(.init(intention: .snapshot))
        let snapshot = try XCTUnwrap(result.value?.snapshot)

        XCTAssertEqual(snapshot.screen?.w, 640)
        let surface = try XCTUnwrap(snapshot.surfaces.first)
        XCTAssertEqual(surface.rect, .init(l: 40, t: 60, r: 440, b: 400))
        XCTAssertEqual(surface.z, 0)
        XCTAssertEqual(surface.itemTotal, 3)

        /* The three readings no entity-level projection could give, and
           each one is a red row from the 2026-08-03 sweep: what KIND a
           control is drawn as, what a popup's chosen value is, and what
           text a field is holding. */
        let radio = try XCTUnwrap(surface.items.first { $0.title == "On" })
        XCTAssertEqual(radio.kind, "radioButton")
        XCTAssertEqual(radio.state, "on")
        XCTAssertEqual(radio.checked, true)

        let popup = try XCTUnwrap(surface.items.first {
            $0.title == "Region"
        })
        XCTAssertEqual(popup.kind, "popupButton")
        XCTAssertEqual(popup.text, "U.S.")
        /* NOW's producer emits "" for a control ref. Carried as absent
           rather than as an empty string, so a caller can see that this
           control cannot be addressed — the drift the mutation slice has
           to close, made visible rather than papered over. */
        XCTAssertNil(popup.ref)

        let field = try XCTUnwrap(surface.items.first {
            $0.source == "dialogItem"
        })
        XCTAssertEqual(field.number, 4)
        XCTAssertEqual(field.kind, "editText")
        XCTAssertEqual(field.text, "/")
    }

    /// **One coordinate space, and a box a click can land in.**
    ///
    /// Sweep A, 2026-08-07: the desktop's icons arrived as points at SCREEN
    /// positions while every other rect in the same array was content-local
    /// — two conventions in one snapshot, the degenerate one impossible to
    /// hit-test. Both are producer-side and both are fixed in the producer.
    ///
    /// The backdrop is given a non-zero origin on purpose: with the origin
    /// at {0,0} the conversion is arithmetically invisible, which is
    /// exactly how it stayed unwritten for a month.
    func testFinderItemRectsAreWindowLocalBoxesOrHonestlyAbsent()
        async throws {
        let document = #"""
        {
          "version":2,"seq":9,"capturedAt":9,"source":"peek",
          "screen":{"w":800,"h":600},
          "apps":[{"psn":"0.3","name":"Finder","front":true,
                   "incarnation":"process-finder"}],
          "processes":[{"psn":"0.3","name":"Finder","front":true,
                        "signature":"MACS",
                        "incarnation":"process-finder"}],
          "menubar":{"app":"Finder","menus":[]},
          "windows":[{
            "id":"0.3/Desktop#0","app":"Finder","psn":"0.3",
            "title":"Desktop",
            "rect":{"l":0,"t":20,"r":800,"b":600},
            "front":true,"z":0,"visible":true,"controls":[],
            "ref":"desktop-ref",
            "incarnation":"process-finder/window-desktop"
          }],
          "desktopItems":[
            {"name":"Macintosh HD","kind":"folder","type":null,
             "creator":null,"x":700,"y":60,"placed":true,
             "alias":false,"invisible":false},
            {"name":"Nowhere","kind":"document","type":null,
             "creator":null,"x":0,"y":0,"placed":false,
             "alias":false,"invisible":false}
          ],
          "meta":{"errors":[],"coverage":[]}
        }
        """#
        let registry = MirrorStateEngineRegistry()
        _ = registry.engine(for: key).accept(try JSONDecoder().decode(
            Scene.self, from: Data(document.utf8)))

        let result = await service(registry).read(.init(intention: .snapshot))
        let surface = try XCTUnwrap(result.value?.snapshot?.surfaces.first)

        let disk = try XCTUnwrap(surface.items.first {
            $0.title == "Macintosh HD"
        })
        let rect = try XCTUnwrap(disk.rect)
        /* Local to the window that carries it: the backdrop's own origin
           subtracted, and NOT `FinderItems.contentOrigin`, which would add
           a title bar the desktop does not have. */
        XCTAssertEqual(rect.l, 700)
        XCTAssertEqual(rect.t, 40)
        /* The 32x32 icon plus the name beneath it — the box the Finder was
           measured with, and the box HitTester already compares against. A
           point is not a smaller version of that; it is a rect nothing can
           ever hit. */
        XCTAssertEqual(rect.r, 700 + 32)
        XCTAssertEqual(rect.b, 40 + 32 + 12)

        let unplaced = try XCTUnwrap(surface.items.first {
            $0.title == "Nowhere"
        })
        /* An honest gap. The Finder never placed it, so there is no
           position to report and none is invented; `state` says why. */
        XCTAssertNil(unplaced.rect)
        XCTAssertEqual(unplaced.state, "unplaced")
    }

    /// **A list row is 16x16 at a 19-px pitch, and a 32x44 box spans three of
    /// them.** Lane B made every item's rect a real 32x32 target; this is the
    /// half it named and did not ship — the size is the Finder's own, so a
    /// window drawing rows stops being projected as icons on a grid.
    ///
    /// The numbers are the ones the Finder answered for Macintosh HD in
    /// `name` view on 2026-08-07 (mac99 / OS 9.1), beside a screendump.
    func testAListViewsRowsProjectAsRowsAndNotAsIconBoxes() async throws {
        let document = #"""
        {
          "version":2,"seq":11,"capturedAt":11,"source":"peek",
          "screen":{"w":800,"h":600},
          "apps":[{"psn":"0.3","name":"Finder","front":true,
                   "incarnation":"process-finder"}],
          "processes":[{"psn":"0.3","name":"Finder","front":true,
                        "signature":"MACS",
                        "incarnation":"process-finder"}],
          "menubar":{"app":"Finder","menus":[]},
          "windows":[{
            "id":"0.3/Macintosh HD#0","app":"Finder","psn":"0.3",
            "title":"Macintosh HD",
            "rect":{"l":48,"t":83,"r":452,"b":321},
            "front":true,"z":0,"visible":true,"controls":[],
            "ref":"hd-ref",
            "incarnation":"process-finder/window-hd",
            "items":[
              {"name":"Applications (Mac OS 9)","kind":"folder","type":null,
               "creator":null,"x":22,"y":43,"w":16,"h":16,"placed":true,
               "alias":false,"invisible":false},
              {"name":"Documents","kind":"folder","type":null,
               "creator":null,"x":22,"y":62,"w":16,"h":16,"placed":true,
               "alias":false,"invisible":false}
            ]
          }],
          "meta":{"errors":[],"coverage":[]}
        }
        """#
        let registry = MirrorStateEngineRegistry()
        _ = registry.engine(for: key).accept(try JSONDecoder().decode(
            Scene.self, from: Data(document.utf8)))

        let result = await service(registry).read(.init(intention: .snapshot))
        let surface = try XCTUnwrap(result.value?.snapshot?.surfaces.first)
        let first = try XCTUnwrap(surface.items.first {
            $0.title == "Applications (Mac OS 9)"
        })
        let rect = try XCTUnwrap(first.rect)
        XCTAssertEqual(rect.l, 22)
        XCTAssertEqual(rect.t, 43)
        XCTAssertEqual(rect.r, 38, "the Finder's own right edge")
        XCTAssertEqual(rect.b, 59, "and its bottom — not 43 + 32 + 12")

        let second = try XCTUnwrap(surface.items.first {
            $0.title == "Documents"
        })
        XCTAssertLessThanOrEqual(rect.b, try XCTUnwrap(second.rect).t,
                                 "two rows that overlap are one click that "
                                 + "can select either file")
    }

    func testDesktopIconsAreCarriedAndNotReportedAsAnEmptyWindow()
        async throws {
        let document = #"""
        {
          "version":2,"seq":4,"capturedAt":4,"source":"peek",
          "screen":{"w":800,"h":600},
          "apps":[{"psn":"0.3","name":"Finder","front":true,
                   "incarnation":"process-finder"}],
          "processes":[{"psn":"0.3","name":"Finder","front":true,
                        "signature":"MACS",
                        "incarnation":"process-finder"}],
          "menubar":{"app":"Finder","menus":[]},
          "windows":[{
            "id":"0.3/Desktop#0","app":"Finder","psn":"0.3",
            "title":"Desktop",
            "rect":{"l":0,"t":0,"r":800,"b":600},
            "front":true,"z":0,"visible":true,"controls":[],
            "ref":"desktop-ref",
            "items":[
              {"name":"Macintosh HD","kind":"folder","type":null,
               "creator":null,"x":700,"y":40,"placed":true,
               "alias":false,"invisible":false},
              {"name":"Trash","kind":"folder","type":null,"creator":null,
               "x":700,"y":520,"placed":true,"alias":false,
               "invisible":false}
            ],
            "incarnation":"process-finder/window-desktop"
          }],
          "meta":{"errors":[],"coverage":[]}
        }
        """#
        let registry = MirrorStateEngineRegistry()
        let engine = registry.engine(for: key)
        _ = engine.accept(try JSONDecoder().decode(
            Scene.self, from: Data(document.utf8)))

        let result = await service(registry).read(.init(intention: .snapshot))
        let surface = try XCTUnwrap(result.value?.snapshot?.surfaces.first)

        /* Reported 0/0 while the machine drew seventeen icons, because the
           projection carried controls and dialog items and nothing else.
           A Finder item is neither: it is a file the Finder draws. */
        XCTAssertEqual(surface.itemTotal, 2)
        let disk = try XCTUnwrap(surface.items.first {
            $0.title == "Macintosh HD"
        })
        XCTAssertEqual(disk.source, "finderItem")
        XCTAssertEqual(disk.kind, "folder")
        /* Addressed by NAME — a Finder icon has no reference, which is why
           `finderOpen` takes one. Absent rather than an empty string, so a
           caller sees it cannot be addressed by ref. */
        XCTAssertNil(disk.ref)
    }

    func testAWholeSceneOfWindowsStaysInsideOneMessage() async throws {
        /* The per-window cap alone let several open panels plus a desktop
           of icons exceed the protocol's 64 KB ceiling, past which the
           writer throws and the connection closes with NO reply — so
           `snapshot` stopped answering while `status` still did, which
           reads as a broken host rather than an oversized payload. */
        var windows: [String] = []
        for w in 0..<12 {
            var controls: [String] = []
            for c in 0..<80 {
                controls.append("""
                {"ref":"r\(w)-\(c)","role":"control","title":"Item \(c)",
                 "rect":{"l":1,"t":1,"r":2,"b":2},"enabled":true,
                 "visible":true,
                 "semantic":{"knowledge":"known","kind":"pushButton",
                             "value":"a value long enough to matter"}}
                """)
            }
            windows.append("""
            {"id":"0.9/W\(w)#0","app":"Many","psn":"0.9","title":"W\(w)",
             "rect":{"l":0,"t":0,"r":300,"b":200},"front":\(w == 0),
             "z":\(w),"visible":true,"ref":"win\(w)",
             "controls":[\(controls.joined(separator: ","))],
             "incarnation":"process-many/window-\(w)"}
            """)
        }
        let document = """
        {"version":2,"seq":9,"capturedAt":9,"source":"peek",
         "screen":{"w":800,"h":600},
         "apps":[{"psn":"0.9","name":"Many","front":true,
                  "incarnation":"process-many"}],
         "processes":[{"psn":"0.9","name":"Many","front":true,
                       "signature":"many","incarnation":"process-many"}],
         "menubar":{"app":"Many","menus":[]},
         "windows":[\(windows.joined(separator: ","))],
         "meta":{"errors":[],"coverage":[]}}
        """
        let registry = MirrorStateEngineRegistry()
        let engine = registry.engine(for: key)
        _ = engine.accept(try JSONDecoder().decode(
            Scene.self, from: Data(document.utf8)))

        let result = await service(registry).read(.init(intention: .snapshot))
        let snapshot = try XCTUnwrap(result.value?.snapshot)
        let encoded = try JSONEncoder().encode(snapshot)
        XCTAssertLessThan(encoded.count, 64 * 1024,
                          "a whole scene must fit one protocol message")

        /* Truncation is stated, never silent: every window reports its
           TRUE total even when it returned nothing, so a caller can see
           what it did not get and ask for that window alone. */
        XCTAssertEqual(snapshot.surfaces.count, 12)
        for surface in snapshot.surfaces {
            XCTAssertEqual(surface.itemTotal, 80)
        }
        XCTAssertTrue(snapshot.surfaces.contains { $0.items.isEmpty },
                      "a window past the budget returns no items")
        XCTAssertFalse(snapshot.surfaces[0].items.isEmpty,
                       "the front window is served first and is not starved")
    }

    // MARK: - display: the drawing, for the face that draws nothing

    /// A window whose content plane was traced, and one that was not.
    private func drawnScene(ops: String,
                            second: String = "") throws -> Scene {
        let document = """
        {
          "version":2,"seq":5,"capturedAt":5,"source":"peek",
          "screen":{"w":640,"h":480},
          "apps":[{"psn":"0.9","name":"SimpleText","front":true,
                   "incarnation":"process-st"}],
          "processes":[{"psn":"0.9","name":"SimpleText","front":true,
                        "signature":"ttxt","incarnation":"process-st"}],
          "menubar":{"app":"SimpleText","menus":[]},
          "windows":[{
            "id":"0.9/Drawn#0","app":"SimpleText","psn":"0.9",
            "title":"Drawn","kind":8,
            "rect":{"l":40,"t":60,"r":440,"b":400},
            "front":true,"z":0,"visible":true,"controls":[],
            "ref":"win-drawn","incarnation":"process-st/window-drawn",
            "display":[\(ops)]
          },{
            "id":"0.9/Untraced#0","app":"SimpleText","psn":"0.9",
            "title":"Untraced","kind":8,
            "rect":{"l":0,"t":0,"r":100,"b":100},
            "front":false,"z":1,"visible":true,"controls":[],
            "ref":"win-untraced",
            "incarnation":"process-st/window-untraced"\(second)
          }],
          "meta":{"errors":[],"coverage":[]}
        }
        """
        return try JSONDecoder().decode(Scene.self, from: Data(document.utf8))
    }

    private func projected(_ scene: Scene) async throws
        -> AgentIntegrationMirrorSnapshot {
        let registry = MirrorStateEngineRegistry()
        _ = registry.engine(for: key).accept(scene)
        let result = await service(registry).read(.init(intention: .snapshot))
        return try XCTUnwrap(result.value?.snapshot)
    }

    func testTheDrawingIsCarriedVerbatimSoItCanBeReplayed() async throws {
        /* Slice 6's rule is: to render a custom control, do not classify
           it — replay its ops. That is only possible for a face that can
           SEE the ops, and until now the Mirror window could and MCP
           could not, so an agent could not do the render half at all. */
        let snapshot = try await projected(try drawnScene(ops: """
            {"op":"state","ticks":10,"kind":"origin","origin":[0,0]},
            {"op":"rect","ticks":11,"verb":2,"rect":[0,0,400,340]},
            {"op":"text","ticks":12,"text":"Save changes?","pen":[20,40],
             "font":3,"size":9,"face":1},
            {"op":"bits","ticks":13,"src":[0,0,32,32],"dst":[8,8,40,40]}
            """))
        let drawn = try XCTUnwrap(snapshot.surfaces.first {
            $0.title == "Drawn"
        })
        let ops = try XCTUnwrap(drawn.display)

        XCTAssertEqual(drawn.displayTotal, 4)
        XCTAssertEqual(ops.count, 4)
        /* Order is the contract: later ops paint over earlier, so a
           replay that reorders them draws a different window. */
        XCTAssertEqual(ops.map(\.op), ["state", "rect", "text", "bits"])

        /* The op vocabulary reaches the caller untranslated. A projection
           that reshaped these into named types would have to decide what
           each coordinate array means, and every such decision is a place
           for a replay to become a classification. */
        let text = try XCTUnwrap(ops.first { $0.op == "text" })
        XCTAssertEqual(text.text, "Save changes?")
        XCTAssertEqual(text.pen, [20, 40])
        XCTAssertEqual(text.font, 3)
        XCTAssertEqual(text.face, 1)
        let erase = try XCTUnwrap(ops.first { $0.op == "rect" })
        XCTAssertEqual(erase.verb, 2)
        XCTAssertEqual(erase.rect, [0, 0, 400, 340])
        let blit = try XCTUnwrap(ops.first { $0.op == "bits" })
        XCTAssertEqual(blit.src, [0, 0, 32, 32])
        XCTAssertEqual(blit.dst, [8, 8, 40, 40])
    }

    func testAnUntracedWindowIsNotReportedAsOneThatDrewNothing()
        async throws {
        /* Today only the front window is traced at all, so collapsing
           "not traced" into "traced and empty" would report every
           background window as a window that draws nothing — a plausible
           lie about the machine, and the exact distinction the IR keeps
           by making `display` optional. */
        let untraced = try await projected(try drawnScene(
            ops: #"{"op":"line","ticks":1,"from":[0,0],"to":[9,9]}"#))
        let quiet = try XCTUnwrap(untraced.surfaces.first {
            $0.title == "Untraced"
        })
        XCTAssertNil(quiet.display)
        XCTAssertNil(quiet.displayTotal)

        let empty = try await projected(try drawnScene(
            ops: #"{"op":"line","ticks":1,"from":[0,0],"to":[9,9]}"#,
            second: #","display":[]"#))
        let proven = try XCTUnwrap(empty.surfaces.first {
            $0.title == "Untraced"
        })
        XCTAssertEqual(proven.display, [])
        XCTAssertEqual(proven.displayTotal, 0)
    }

    func testALongDrawingIsBoundedAndSaysHowMuchItDropped() async throws {
        /* The producer caps its own accumulator at 600 ops and a `text`
           op carries an arbitrary DrawString, so the honest worst case is
           600 long strings — which no per-op COUNT can bound inside a
           64 KB message. */
        let ops = (0..<600).map { index in
            """
            {"op":"text","ticks":\(index),
             "text":"\(String(repeating: "M", count: 200)) \(index)",
             "pen":[10,\(index)],"font":3,"size":9,"face":0}
            """
        }.joined(separator: ",")
        let snapshot = try await projected(try drawnScene(ops: ops))
        let drawn = try XCTUnwrap(snapshot.surfaces.first {
            $0.title == "Drawn"
        })
        let carried = try XCTUnwrap(drawn.display)

        /* Bounded, and the true count is stated beside it — a tail that
           did not say so reads as the whole drawing, which is worse than
           no drawing because it looks complete. */
        XCTAssertEqual(drawn.displayTotal, 600)
        XCTAssertLessThan(carried.count, 600)
        XCTAssertGreaterThan(carried.count, 0)

        /* The NEWEST ops survive, which is both the producer's own rule
           when its accumulator overflows and the one that replays: later
           ops paint over earlier, so a tail reaches the state the window
           is in where a head stops partway through a redraw. */
        XCTAssertEqual(carried.last?.ticks, 599)
        XCTAssertEqual(carried.map(\.ticks),
                       Array((600 - carried.count)..<600))

        let encoded = try JSONEncoder().encode(snapshot)
        XCTAssertLessThan(encoded.count, 64 * 1024,
                          "a traced window must fit one protocol message")
    }

    func testAWholeSceneOfItemsAndDrawOpsStillFitsOneMessage() async throws {
        /* The two budgets are independent, so neither one alone proves
           the ceiling holds. Adding Finder items to the snapshot is what
           broke it last time: the writer throws past 64 KB and the
           connection closes with NO reply, so `snapshot` stops answering
           while `status` still does — which reads as a broken host rather
           than an oversized payload (open-issues, 2026-08-05). */
        var windows: [String] = []
        for w in 0..<12 {
            let controls = (0..<80).map { c in
                """
                {"ref":"r\(w)-\(c)","role":"control","title":"Item \(c)",
                 "rect":{"l":1,"t":1,"r":2,"b":2},"enabled":true,
                 "visible":true,
                 "semantic":{"knowledge":"known","kind":"pushButton",
                             "value":"a value long enough to matter"}}
                """
            }.joined(separator: ",")
            let ops = (0..<600).map { index in
                """
                {"op":"text","ticks":\(index),
                 "text":"\(String(repeating: "W", count: 200))",
                 "pen":[1,\(index)],"font":3,"size":9,"face":0}
                """
            }.joined(separator: ",")
            windows.append("""
            {"id":"0.9/W\(w)#0","app":"Many","psn":"0.9","title":"W\(w)",
             "rect":{"l":0,"t":0,"r":300,"b":200},"front":\(w == 0),
             "z":\(w),"visible":true,"ref":"win\(w)",
             "text":{"content":"\(String(repeating: "T", count: 9000))",
                     "active":true},
             "controls":[\(controls)],"display":[\(ops)],
             "incarnation":"process-many/window-\(w)"}
            """)
        }
        let document = """
        {"version":2,"seq":9,"capturedAt":9,"source":"peek",
         "screen":{"w":800,"h":600},
         "apps":[{"psn":"0.9","name":"Many","front":true,
                  "incarnation":"process-many"}],
         "processes":[{"psn":"0.9","name":"Many","front":true,
                       "signature":"many","incarnation":"process-many"}],
         "menubar":{"app":"Many","menus":[]},
         "windows":[\(windows.joined(separator: ","))],
         "meta":{"errors":[],"coverage":[]}}
        """
        let snapshot = try await projected(
            try JSONDecoder().decode(Scene.self, from: Data(document.utf8)))
        let encoded = try JSONEncoder().encode(snapshot)
        XCTAssertLessThan(encoded.count, 64 * 1024,
                          "items and draw ops share one message ceiling")

        /* Every window still reports its TRUE totals even when it got
           nothing of that family, so a caller can see exactly what it did
           not get and ask for that window alone. */
        XCTAssertEqual(snapshot.surfaces.count, 12)
        for surface in snapshot.surfaces {
            XCTAssertEqual(surface.itemTotal, 80)
            XCTAssertEqual(surface.displayTotal, 600)
            XCTAssertEqual(surface.text?.contentTotal, 9000)
            XCTAssertLessThanOrEqual(surface.text?.content.count ?? 0, 2048)
        }
        XCTAssertFalse(snapshot.surfaces[0].items.isEmpty,
                       "the front window is served first and is not starved")
        XCTAssertFalse(snapshot.surfaces[0].display?.isEmpty ?? true,
                       "the front window's drawing is served first too")
        XCTAssertTrue(snapshot.surfaces.contains { $0.items.isEmpty },
                      "a window past the item budget returns no items")
        XCTAssertTrue(snapshot.surfaces.contains {
            $0.display?.isEmpty == true
        }, "a window past the content budget returns no ops")

        /* The two budgets are separate on purpose: a shared pool would let
           whichever family is served first starve the rest, and the
           measured item worst case (54.6 KB before any of this existed)
           would have starved everything. */
        XCTAssertFalse(snapshot.surfaces.allSatisfy {
            $0.items.isEmpty || ($0.display?.isEmpty ?? true)
        }, "one window must receive both families, not one at the other's cost")
    }

    /// **The ceiling, measured on the WHOLE reply and on a scene that has
    /// the parts the budgets do not govern.**
    ///
    /// The row above pins the two family budgets and passed throughout,
    /// while `mirror_read --intention snapshot` was closing the connection
    /// on a live OS 9 session (sweep C, 2026-08-07, 3/3). It could pass
    /// because its fixture has two entities, no menubar and no coverage
    /// rows — none of which the item and content budgets bound — and
    /// because it measured the SNAPSHOT rather than the message the
    /// snapshot travels in.
    ///
    /// So this one adds the ungoverned families back: a full menubar, a
    /// desktop's worth of processes and windows, coverage rows, and the
    /// envelope. It is the shape that actually overflowed.
    func testAMenuHeavyDesktopFitsTheWHOLEMessageNotJustTheSnapshot()
        async throws {
        var apps: [String] = []
        var processes: [String] = []
        var windows: [String] = []
        for p in 0..<12 {
            apps.append("""
            {"psn":"0.\(p)","name":"Application Number \(p)",
             "front":\(p == 0),"incarnation":"process-\(p)"}
            """)
            processes.append("""
            {"psn":"0.\(p)","name":"Application Number \(p)",
             "front":\(p == 0),"signature":"ap\(p)",
             "incarnation":"process-\(p)"}
            """)
            for w in 0..<4 {
                let controls = (0..<40).map { c in
                    """
                    {"ref":"r\(p)-\(w)-\(c)","role":"control",
                     "title":"A control with a reasonably long label \(c)",
                     "rect":{"l":1,"t":1,"r":2,"b":2},"enabled":true,
                     "visible":true,
                     "semantic":{"knowledge":"known","kind":"pushButton",
                                 "value":"a value long enough to matter"}}
                    """
                }.joined(separator: ",")
                let ops = (0..<200).map { index in
                    """
                    {"op":"text","ticks":\(index),
                     "text":"\(String(repeating: "W", count: 120))",
                     "pen":[1,\(index)],"font":3,"size":9,"face":0}
                    """
                }.joined(separator: ",")
                windows.append("""
                {"id":"0.\(p)/W\(w)#0","app":"Application Number \(p)",
                 "psn":"0.\(p)","title":"A window with a long title \(w)",
                 "rect":{"l":0,"t":0,"r":300,"b":200},
                 "front":\(p == 0 && w == 0),"z":\(p * 4 + w),
                 "visible":true,"ref":"win-\(p)-\(w)",
                 "controls":[\(controls)],"display":[\(ops)],
                 "incarnation":"process-\(p)/window-\(w)"}
                """)
            }
        }
        /* A real OS 9 menubar: nine menus, and the Apple menu alone can
           carry ninety-six items. */
        let menus = (0..<9).map { m in
            let items = (0..<96).map { i in
                """
                {"title":"A menu item with a real name \(i)","index":\(i),
                 "separator":false,"enabled":true,"mark":false,"cmd":""}
                """
            }.joined(separator: ",")
            return """
            {"id":\(m),"title":"Menu \(m)","apple":\(m == 0),
             "left":\(m * 60),"items":[\(items)]}
            """
        }.joined(separator: ",")
        let coverage = (0..<12).map { c in
            """
            {"scope":"windows","owner":"Application Number \(c)",
             "status":"partial",
             "reason":"a reason long enough to be a real sentence \(c)"}
            """
        }.joined(separator: ",")
        let document = """
        {"version":2,"seq":9,"capturedAt":9,"source":"peek",
         "screen":{"w":800,"h":600},
         "apps":[\(apps.joined(separator: ","))],
         "processes":[\(processes.joined(separator: ","))],
         "menubar":{"app":"Application Number 0","menus":[\(menus)]},
         "windows":[\(windows.joined(separator: ","))],
         "meta":{"errors":[],"coverage":[\(coverage)]}}
        """
        let scene = try JSONDecoder().decode(
            Scene.self, from: Data(document.utf8))
        let registry = MirrorStateEngineRegistry()
        _ = registry.engine(for: key).accept(scene)
        let result = await service(registry).read(.init(intention: .snapshot))

        /* The MESSAGE, not the snapshot: the ceiling is on what the
           transport carries, and the envelope repeats the metadata. This
           is the assertion the old row could not make. */
        let response = AgentIntegrationLocalResponse(
            requestID: UUID(), mirrorReadResult: result)
        let encoded = try AgentIntegrationLocalCodec.encode(response)
        XCTAssertLessThanOrEqual(
            encoded.count,
            AgentIntegrationLocalProtocol.maximumMessageBytes)

        /* And it still ANSWERS. A snapshot that fits by carrying nothing
           would pass the line above and be useless — the defect this
           replaces was a caller getting no scene at all. */
        let snapshot = try XCTUnwrap(result.value?.snapshot)
        XCTAssertEqual(snapshot.surfaces.count, 48)
        XCTAssertFalse(snapshot.entities.isEmpty)
        XCTAssertFalse(snapshot.menus.isEmpty)
        XCTAssertFalse(snapshot.surfaces[0].items.isEmpty,
                       "the front window is served first and is not starved")
        for surface in snapshot.surfaces {
            XCTAssertEqual(surface.itemTotal, 40)
            XCTAssertEqual(surface.displayTotal, 200)
        }

        /* And every bound SAYS what it bounded. A caller that got a prefix
           has to be able to tell it from a Mac with fewer things on it —
           the whole reason the surfaces already carry `itemTotal`. */
        XCTAssertEqual(snapshot.entityTotal, 60)   // 12 processes, 48 windows
        for menu in snapshot.menus {
            XCTAssertEqual(menu.itemTotal, 96)
        }
        XCTAssertTrue(snapshot.menus.contains { $0.items.count < 96 },
                      "a menubar this large must be bounded somewhere")
    }

    // MARK: - the omission CLASS, not one more instance of it

    func testEveryWindowFieldIsCarriedOrConsciouslyDeclined() async throws {
        /* Three times in slice 2 the projection carried what a reader
           REMEMBERED rather than what the model holds: `window.items` for
           desktop icons, `window.items` again for Finder rows, and
           `window.display`. Each shipped invisible for weeks. This walks
           `Scene.Window`'s own stored properties and fails on any one the
           roster below has not disposed of — so the NEXT field added to
           the IR turns this red instead of shipping silently. */
        let scene = try Self.rosterScene()
        let window = try XCTUnwrap(scene.windows.first)
        let declared = Set(IRSchema.declaredProperties(of: window)
            .filter { $0.hasPrefix("Scene.Window.") }
            .map { String($0.dropFirst("Scene.Window.".count)) })

        XCTAssertFalse(declared.isEmpty,
                       "reflection must see the window's own fields")
        XCTAssertEqual(
            declared.subtracting(Self.windowFieldRoster.keys).sorted(), [],
            """
            A field was added to Scene.Window and the MCP projection has \
            not been told about it. Carry it in \
            MirrorStateProjectionService.surfaces(_:), or add it to \
            windowFieldRoster as .declined with the reason — but do not \
            let it ship invisible, which is what happened three times.
            """)
        XCTAssertEqual(
            Set(Self.windowFieldRoster.keys).subtracting(declared).sorted(),
            [],
            """
            The roster names a field Scene.Window no longer has. Delete \
            the row; a roster that outlives the model stops proving \
            anything.
            """)

        /* The carried half is PROVEN against a real projection rather
           than asserted, because a roster whose entries nothing checks is
           the same kind of remembering it exists to replace. */
        let snapshot = try await projected(scene)
        for (field, disposition) in Self.windowFieldRoster {
            guard case .carried(let reaches) = disposition else { continue }
            XCTAssertTrue(reaches(snapshot),
                          "Scene.Window.\(field) is rostered as carried "
                            + "and did not reach the projection")
        }
    }

    func testTheRosterReadsContentRatherThanMerePresence() async throws {
        /* **The guard needs its own guard.** A roster check that only asks
           whether a key is there passes for a field that arrives empty,
           and then the roster reports coverage it does not have — the same
           shape as a test that passed for months by winning a race while
           asserting the opposite of what was happening.

           So: run every `.carried` check against a window whose fields are
           all PRESENT and all EMPTY. Every one must fail. A check that
           still passes here is a presence check wearing a value check's
           clothes, and this names it. */
        let snapshot = try await projected(try Self.emptiedRosterScene())
        for (field, disposition) in Self.windowFieldRoster {
            guard case .carried(let reaches) = disposition else { continue }
            XCTAssertFalse(reaches(snapshot),
                           "Scene.Window.\(field)'s roster check passes "
                             + "against a window that carries nothing, so "
                             + "it proves the key exists rather than that "
                             + "the Mac's state arrived")
        }
    }

    // MARK: - the journal: which face drove it

    func testJournalTellsAnAgentDrivenActFromAHandDrivenOne() async throws {
        let registry = MirrorStateEngineRegistry()
        let engine = registry.engine(for: key)
        _ = engine.accept(try scene(seq: 1))
        let process = MirrorProcessIdentity(
            session: MirrorGuestSession(guest: "mirror-projection",
                                        incarnation: "session"),
            incarnation: "process-finder")

        for (id, source) in [("by-hand", MirrorOperationSource.human),
                             ("by-agent", .mcp)] {
            engine.operations.append(.init(
                id: id, source: source, displayedSnapshotID: 1,
                displayedSequence: 1, target: .process(process),
                postcondition: .processFront(process),
                enqueuedAt: Date()))
        }

        let result = await service(registry).read(.init(intention: .journal))
        let journal = try XCTUnwrap(result.value?.journal)

        /* Hardcoded to `human` until 2026-08-05, so every agent-driven act
           was recorded as a person's. The paired hand-versus-MCP check the
           plan asks for is unreadable without this field. */
        XCTAssertEqual(journal.first { $0.id == "by-hand" }?.source, "human")
        XCTAssertEqual(journal.first { $0.id == "by-agent" }?.source, "mcp")
        XCTAssertEqual(engine.store.entries.count, 1,
                       "reading the journal publishes no snapshot")
    }

    // MARK: - metrics: the Mirror page's numbers, headless

    func testMetricsCarryTheSameClocksTheMirrorPageShows() async {
        let acts = MirrorActTimeline(log: { _ in })
        let cycles = MirrorCycleTimeline(log: { _ in })
        acts.depth = 3
        acts.record(.init(
            kind: .released, operationID: "op", label: "close Finder",
            outcome: .timedOut, queueDepthAtEntry: 2,
            enqueuedAt: Date(timeIntervalSince1970: 0),
            dispatchStartedAt: Date(timeIntervalSince1970: 4),
            dispatchReturnedAt: Date(timeIntervalSince1970: 6),
            settledAt: nil,
            releasedAt: Date(timeIntervalSince1970: 21)))
        cycles.record(.init(
            requestedAt: Date(timeIntervalSince1970: 0),
            deliveredAt: Date(timeIntervalSince1970: 1),
            publishedAt: Date(timeIntervalSince1970: 1.25),
            idleBefore: 0.8, semantics: true, interaction: true,
            outcome: "ok", windows: 1, elements: 54))

        let service = MirrorStateProjectionService(
            engines: MirrorStateEngineRegistry(),
            currentGuest: { nil },
            metrics: { acts.projected(cycles: cycles, running: true) })
        let result = await service.read(.init(intention: .metrics))

        XCTAssertTrue(result.available)
        XCTAssertEqual(result.value?.metrics?.laneDepth, 3)
        let act = result.value?.metrics?.acts.first
        XCTAssertEqual(act?.queueDepthAtEntry, 2)
        XCTAssertEqual(act?.waitedMs, 4000)
        XCTAssertEqual(act?.dispatchMs, 2000)
        /* The reading the whole instrument exists for: never settled is
           absent, not zero, so a headless caller cannot average a timeout
           into a healthy act. */
        XCTAssertNil(act?.settleMs)
        XCTAssertEqual(act?.totalMs, 21000)
        XCTAssertEqual(result.value?.metrics?.cycles.first?.walk, "full")
        XCTAssertEqual(result.value?.metrics?.cycles.first?.requestMs, 1000)
    }

    func testMetricsAnswerEvenWhenNoSceneHasEverArrived() async {
        let acts = MirrorActTimeline(log: { _ in })
        let cycles = MirrorCycleTimeline(log: { _ in })
        cycles.record(.init(
            requestedAt: Date(timeIntervalSince1970: 0), deliveredAt: nil,
            publishedAt: Date(timeIntervalSince1970: 30), idleBefore: nil,
            semantics: true, interaction: true, outcome: "declined",
            windows: nil, elements: nil))
        let service = MirrorStateProjectionService(
            engines: MirrorStateEngineRegistry(),
            currentGuest: { nil },
            metrics: { acts.projected(cycles: cycles, running: true) })

        /* A walk that never answered is exactly when the numbers matter
           most; refusing for want of a snapshot would hide the slowest
           cases behind the same silence a blank Mirror already gives. */
        let result = await service.read(.init(intention: .metrics))
        XCTAssertTrue(result.available)
        XCTAssertNil(result.value?.current)
        XCTAssertEqual(result.value?.metrics?.cycles.first?.outcome,
                       "declined")
        XCTAssertNil(result.value?.metrics?.cycles.first?.requestMs)
    }

    func testAQuietMirrorIsToldApartFromOneThatNeverRan() async {
        let acts = MirrorActTimeline(log: { _ in })
        let cycles = MirrorCycleTimeline(log: { _ in })

        /* Both replies are empty. Without `running` they are the same
           reply, and they call for opposite next steps — wait, versus open
           the Mirror. Found by calling this row against a live host on
           2026-08-05, which answered empty for the second reason and read
           exactly like the first. */
        let quiet = await MirrorStateProjectionService(
            engines: MirrorStateEngineRegistry(), currentGuest: { nil },
            metrics: { acts.projected(cycles: cycles, running: true) })
            .read(.init(intention: .metrics))
        let neverRan = await MirrorStateProjectionService(
            engines: MirrorStateEngineRegistry(), currentGuest: { nil },
            metrics: { acts.projected(cycles: cycles, running: false) })
            .read(.init(intention: .metrics))

        XCTAssertEqual(quiet.value?.metrics?.acts.count, 0)
        XCTAssertEqual(neverRan.value?.metrics?.acts.count, 0)
        XCTAssertEqual(quiet.value?.metrics?.running, true)
        XCTAssertEqual(neverRan.value?.metrics?.running, false)
    }

    func testMetricsAreUnavailableRatherThanEmptyWhenNothingMeasures() async {
        let service = MirrorStateProjectionService(
            engines: MirrorStateEngineRegistry(),
            currentGuest: { nil })
        let result = await service.read(.init(intention: .metrics))

        /* An empty measurement set and an absent measurer read identically
           to a caller, and they call for opposite next steps. */
        XCTAssertFalse(result.available)
        XCTAssertEqual(result.unavailable?.code,
                       "now-mirror-metrics-unavailable")
    }
}

// MARK: - the roster the omission-class guard reads

/// What the MCP surface projection does with one stored property of
/// `Scene.Window`.
private enum WindowFieldDisposition {
    /// Reaches the projection, and the closure proves it against a real
    /// snapshot rather than asserting it.
    case carried((AgentIntegrationMirrorSnapshot) -> Bool)
    /// Deliberately not carried. The reason is the whole point of the
    /// case: "not carried" with no argument is the state all three
    /// omissions were already in.
    case declined(String)
}

extension MirrorStateProjectionServiceTests {
    /* Located by POSITION, not by title. `title` is itself a rostered
       field, so a locator that matched on it could not be run against the
       emptied probe — and the emptied probe is what proves these checks
       read content rather than mere presence. */
    fileprivate static func full(_ snapshot: AgentIntegrationMirrorSnapshot)
        -> AgentIntegrationMirrorSurface? {
        snapshot.surfaces.first
    }

    fileprivate static func plain(_ snapshot: AgentIntegrationMirrorSnapshot)
        -> AgentIntegrationMirrorSurface? {
        snapshot.surfaces.dropFirst().first
    }

    /// The same two windows with every field PRESENT and EMPTY — `[]`
    /// lists, `""` strings, zeroed numbers, `false` flags.
    ///
    /// Nothing here is absent, so a roster check that passes against it is
    /// asserting that a key exists rather than that the machine's state
    /// arrived. That is the failure mode that keeps a suite green for the
    /// wrong reason, and it is invisible from the positive case alone.
    fileprivate static func emptiedRosterScene() throws -> Scene {
        let document = #"""
        {
          "version":2,"seq":7,"capturedAt":7,"source":"peek",
          "screen":{"w":640,"h":480},
          "apps":[{"psn":"0.0","name":"","front":false,
                   "incarnation":"process-empty"}],
          "processes":[{"psn":"0.0","name":"","front":false,
                        "signature":"????","incarnation":"process-empty"}],
          "menubar":{"app":"","menus":[]},
          "windows":[{
            "id":"","app":"","psn":"0.0","title":"","kind":0,
            "rect":{"l":0,"t":0,"r":0,"b":0},
            "front":false,"z":9,"visible":false,
            "ref":"","addr":0,
            "text":{"content":"","active":false},
            "controls":[],"dialogItems":[],"display":[],"items":[]
          },{
            "id":"","app":"","psn":"0.0","title":"","kind":0,
            "rect":{"l":0,"t":0,"r":0,"b":0},
            "front":false,"z":8,"visible":false,
            "ref":"","addr":0,
            "text":{"content":"","active":false},
            "controls":[],"dialogItems":[],"display":[],"items":[]
          }],
          "meta":{"errors":[],"coverage":[]}
        }
        """#
        return try JSONDecoder().decode(Scene.self, from: Data(document.utf8))
    }

    /// Two windows: one populating every decodable field of
    /// `Scene.Window`, and one with no `incarnation` — because `id` is
    /// only observable as an entity key when the durable one is absent,
    /// and a probe that cannot distinguish the two would let either
    /// field's projection rot unnoticed.
    fileprivate static func rosterScene() throws -> Scene {
        let document = #"""
        {
          "version":2,"seq":6,"capturedAt":6,"source":"peek",
          "screen":{"w":640,"h":480},
          "apps":[{"psn":"0.9","name":"SimpleText","front":true,
                   "incarnation":"process-st"}],
          "processes":[{"psn":"0.9","name":"SimpleText","front":true,
                        "signature":"ttxt","incarnation":"process-st"}],
          "menubar":{"app":"SimpleText","menus":[]},
          "windows":[{
            "id":"0.9/Save changes?#0","app":"SimpleText","psn":"0.9",
            "title":"Save changes?","kind":2,
            "rect":{"l":40,"t":60,"r":440,"b":400},
            "front":true,"z":0,"visible":true,
            "ref":"win-save","addr":1234567,
            "incarnation":"process-st/window-save",
            "text":{"content":"Untitled","active":true},
            "controls":[
              {"ref":"ctl-save","role":"control","title":"Save",
               "rect":{"l":10,"t":10,"r":60,"b":26},
               "enabled":true,"visible":true,
               "semantic":{"knowledge":"known","kind":"pushButton",
                           "value":"Save"}}
            ],
            "dialogItems":[
              {"number":3,"title":"Name",
               "rect":{"l":10,"t":40,"r":200,"b":56},
               "enabled":true,"visible":true,
               "semantic":{"knowledge":"known","kind":"editText",
                           "value":"Untitled"}}
            ],
            "display":[
              {"op":"text","ticks":7,"text":"Save changes?","pen":[8,20],
               "font":3,"size":9,"face":0}
            ]
          },{
            "id":"0.9/Plain#0","app":"SimpleText","psn":"0.9",
            "title":"Plain","kind":8,
            "rect":{"l":0,"t":0,"r":120,"b":90},
            "front":false,"z":1,"visible":true,"controls":[],
            "items":[
              {"name":"Read Me","kind":"file","type":"TEXT",
               "creator":"ttxt","x":12,"y":20,"placed":true,
               "alias":false,"invisible":false}
            ]
          }],
          "meta":{"errors":[],"coverage":[]}
        }
        """#
        return try JSONDecoder().decode(Scene.self, from: Data(document.utf8))
    }

    /// **Every stored property of `Scene.Window`, disposed of on purpose.**
    ///
    /// A field missing from here fails
    /// `testEveryWindowFieldIsCarriedOrConsciouslyDeclined`, which is the
    /// point: the three omissions this guard exists for were all silent,
    /// and the cost of each was weeks of a face that could not see
    /// something the model had been holding the whole time.
    fileprivate static var windowFieldRoster:
        [String: WindowFieldDisposition] {
        [
            "id": .carried { plain($0)?.entityID == "0.9/Plain#0" },
            "app": .carried { snapshot in
                snapshot.entities.contains {
                    $0.kind == .window && $0.name == "SimpleText"
                }
            },
            "psn": .declined("""
                The guest's Process Serial Number is a transport identity \
                that a relaunch reuses. Entities are addressed by durable \
                incarnation — a window's owner arrives as \
                `entities[].ownerID` — and publishing a psn beside it \
                would offer a second, weaker key for the same join.
                """),
            "title": .carried { full($0)?.title == "Save changes?" },
            "kind": .carried { full($0)?.kind == 2 },
            "rect": .carried {
                full($0)?.rect == .init(l: 40, t: 60, r: 440, b: 400)
            },
            "front": .carried { full($0)?.front == true },
            "z": .carried { full($0)?.z == 0 },
            "visible": .carried { full($0)?.visible == true },
            "controls": .carried { snapshot in
                full(snapshot)?.items.contains {
                    $0.source == "control" && $0.title == "Save"
                } == true
            },
            "dialogItems": .carried { snapshot in
                full(snapshot)?.items.contains {
                    $0.source == "dialogItem" && $0.number == 3
                } == true
            },
            "ref": .carried { full($0)?.ref == "win-save" },
            "addr": .declined("""
                The window record's own guest address. The IR carries it \
                so a HARNESS can say which window it is comparing against \
                the machine; nothing renders from it, and MCP addresses \
                windows by `entityID`, which stays valid across a scene \
                the pointer does not. Publishing a raw guest pointer as \
                an addressing option would invite a caller to key on it.
                """),
            "incarnation": .carried {
                full($0)?.entityID
                    == "window:process-st:process-st/window-save"
            },
            "text": .carried { full($0)?.text?.content == "Untitled" },
            "items": .carried { snapshot in
                plain(snapshot)?.items.contains {
                    $0.source == "finderItem" && $0.title == "Read Me"
                } == true
            },
            "display": .carried { snapshot in
                full(snapshot)?.display?.contains {
                    $0.op == "text" && $0.text == "Save changes?"
                } == true
            },
            "island": .declined("""
                Host-internal render state that happens to live on this \
                struct. It has never been on the wire — `Serve.sceneMethod` \
                nils every island before encoding, because island pixels \
                ride their own pager — and it is a base64 RGBA blob that \
                would exceed the protocol's whole one-message ceiling by \
                itself.
                """),
            "displayEpoch": .declined("""
                The content plane's own clock (plan 018 slice 1), and the \
                same kind of shelf as `island`: host-internal render state \
                that happens to live on this struct. Every number in it — \
                the guest's capture generation and its display epoch — \
                already reaches an agent on the drain records themselves, \
                and `stale` is this host's own conclusion about them, not a \
                fact about the machine. A projection that published it \
                would be exporting a renderer's opinion as guest evidence.
                """),
        ]
    }
}
