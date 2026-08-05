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
