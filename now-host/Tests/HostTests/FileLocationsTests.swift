import XCTest
@testable import Host

/// The Places sidebar: what it can honestly claim to have found, what it
/// must leave out, and what a person's rearranging of it survives.
///
/// The rules worth pinning are the ones whose failure is invisible. A
/// location resolved from the wrong half of a path still exists, so the
/// sidebar looks fine and takes you somewhere else. A discovery kept in a
/// file looks right until the folder is deleted. And a sweep that treats a
/// dropped connection as "none of these folders are there" writes an empty
/// sidebar and then persists the person's confusion.
@MainActor
final class FileLocationsTests: XCTestCase {
    /// Every bench opens a listening socket; they are closed together
    /// rather than in a `deinit`, which cannot touch main-actor state.
    private var benches: [Bench] = []

    override func tearDown() async throws {
        for bench in benches { bench.listener.stop() }
        benches = []
    }

    private func makeBench() async throws -> Bench {
        let bench = try await Bench()
        benches.append(bench)
        return bench
    }

    // MARK: - Turning what a machine said into a path we can ask for

    func testAPathInsideTheShareBecomesRelativeToIt() {
        XCTAssertEqual(
            FileLocationResolver.relative(
                "Macintosh HD:System Folder:Extensions:Foo",
                under: "Macintosh HD:"),
            "System Folder:Extensions:Foo")
    }

    func testTheShareRootIsAcceptedWithOrWithoutItsTrailingColon() {
        // The guest spells it "Macintosh HD:"; nothing stops a person's
        // preference from arriving without the colon, and the two name one
        // disk.
        XCTAssertEqual(
            FileLocationResolver.relative("Macintosh HD:System Folder",
                                          under: "Macintosh HD"),
            "System Folder")
    }

    func testComparisonIsCaseInsensitiveBecauseHFSIs() {
        XCTAssertEqual(
            FileLocationResolver.relative("MACINTOSH HD:System Folder",
                                          under: "Macintosh HD:"),
            "System Folder")
    }

    /// The case that decides whether this feature is honest: a machine
    /// sharing one project folder has a System Folder, and it is not
    /// reachable from here. Nothing on this wire can express it.
    func testAPathOutsideTheShareIsNotALocation() {
        XCTAssertNil(FileLocationResolver.relative(
            "Macintosh HD:System Folder:Extensions:Foo",
            under: "Macintosh HD:Lab:"))
    }

    func testTheShareRootItselfIsNotALocationInsideItself() {
        XCTAssertNil(FileLocationResolver.relative("Macintosh HD:",
                                                   under: "Macintosh HD:"))
    }

    func testWithNoShareRootNothingResolves() {
        XCTAssertNil(FileLocationResolver.relative("Macintosh HD:System Folder",
                                                   under: nil))
        XCTAssertNil(FileLocationResolver.relative("Macintosh HD:System Folder",
                                                   under: ""))
    }

    func testTheParentOfARootLevelFolderIsNothingRatherThanEmptyString() {
        XCTAssertEqual(FileLocationResolver.parent(of: "System Folder:Fonts"),
                       "System Folder")
        XCTAssertNil(FileLocationResolver.parent(of: "System Folder"))
    }

    /// An empty segment is a `bad-path` refusal by contract, so joining
    /// onto the root must not produce a leading colon.
    func testJoiningOntoTheRootAddsNoLeadingColon() {
        XCTAssertEqual(FileLocationResolver.join("", "System Folder"),
                       "System Folder")
        XCTAssertEqual(FileLocationResolver.join("System Folder", "Fonts"),
                       "System Folder:Fonts")
    }

    // MARK: - The Folder Manager, read through software.list

    func testTheFolderAnEntryLivesInIsTheFolderManagersAnswer() {
        let entries = [software("Foo", "Macintosh HD:System Folder:Extensions:Foo")]
        XCTAssertEqual(
            FileLocationResolver.folder(fromSoftware: entries,
                                        shareRoot: "Macintosh HD:"),
            "System Folder:Extensions")
    }

    /// Those domains enumerate the Extensions Manager's disabled siblings
    /// too. Taking the parent of one of those names a folder that exists —
    /// the wrong one — which is worse than naming none.
    func testADisabledSiblingNeverNamesTheFolder() {
        let entries = [
            software("Off", "Macintosh HD:System Folder:Extensions (Disabled):Off",
                     off: true),
            software("On", "Macintosh HD:System Folder:Extensions:On"),
        ]
        XCTAssertEqual(
            FileLocationResolver.folder(fromSoftware: entries,
                                        shareRoot: "Macintosh HD:"),
            "System Folder:Extensions")
    }

    /// An empty path is the guest saying it could not walk the parent
    /// chain. A truncated path is not a shorter path.
    func testAnEntryWithNoPathContributesNothing() {
        let entries = [software("Nameless", "")]
        XCTAssertNil(FileLocationResolver.folder(fromSoftware: entries,
                                                 shareRoot: "Macintosh HD:"))
    }

    func testAFolderOutsideTheShareIsNotOffered() {
        let entries = [software("Foo", "Macintosh HD:System Folder:Extensions:Foo")]
        XCTAssertNil(FileLocationResolver.folder(fromSoftware: entries,
                                                 shareRoot: "Macintosh HD:Lab:"))
    }

    // MARK: - What a person did to the list, and what it survives

    func testAThrownOutLocationDoesNotComeBackOnTheNextSweep() {
        let discovered = [location("System Folder"), location("Applications")]
        var stored = FileLocationsStore.Stored()
        stored.hidden = ["System Folder"]
        XCTAssertEqual(
            FileLocationsStore.merge(discovered: discovered, stored: stored)
                .map(\.path),
            ["Applications"])
    }

    func testAPinnedLocationSitsBesideTheDiscoveredOnes() {
        let stored = FileLocationsStore.Stored(
            pinned: [location("Lab:Projects", origin: .pinned)])
        XCTAssertEqual(
            FileLocationsStore.merge(discovered: [location("System Folder")],
                                     stored: stored).map(\.path),
            ["System Folder", "Lab:Projects"])
    }

    /// One folder is one row. If the Folder Manager later names a folder a
    /// person had already pinned by hand, the discovered row wins: its
    /// name came from the machine, the pin's came from a drag.
    func testAPinNeverDuplicatesOrMasksADiscoveryOfTheSameFolder() {
        let stored = FileLocationsStore.Stored(
            pinned: [FileLocation(path: "System Folder:Extensions",
                                  name: "Extensions",
                                  symbol: "folder", origin: .pinned)])
        let merged = FileLocationsStore.merge(
            discovered: [FileLocation(path: "System Folder:Extensions",
                                      name: "Systemerweiterungen",
                                      symbol: "puzzlepiece.extension",
                                      origin: .folderManager)],
            stored: stored)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.name, "Systemerweiterungen")
        XCTAssertEqual(merged.first?.origin, .folderManager)
    }

    func testTheArrangementIsHonouredAndNewFindingsLandAtTheFoot() {
        var stored = FileLocationsStore.Stored()
        // Saved before "Applications" was ever found, and naming one
        // location that has since gone.
        stored.order = ["System Folder", "Gone", ""]
        let merged = FileLocationsStore.merge(
            discovered: [location(""), location("System Folder"),
                         location("Applications")],
            stored: stored)
        XCTAssertEqual(merged.map(\.path),
                       ["System Folder", "", "Applications"],
                       "a location nobody arranged goes to the end rather "
                       + "than invalidating the arrangement")
    }

    // MARK: - Persistence, per machine

    func testCustomisationSurvivesAndIsNotSharedBetweenMachines() throws {
        let defaults = try suite()
        let store = FileLocationsStore(defaults: defaults)
        let one = GuestID("pb1400c")!
        let two = GuestID("q800")!

        var stored = FileLocationsStore.Stored()
        stored.pinned = [location("Lab", origin: .pinned)]
        stored.hidden = ["Trash"]
        store.save(stored, for: one)

        // A fresh store object: this is the restart.
        let reopened = FileLocationsStore(defaults: defaults)
        XCTAssertEqual(reopened.load(for: one), stored)
        XCTAssertEqual(reopened.load(for: two), FileLocationsStore.Stored(),
                       "one Mac's sidebar is not another's")
        XCTAssertEqual(reopened.load(for: nil), FileLocationsStore.Stored(),
                       "with nothing connected there is nothing to read")
    }

    // MARK: - The sweep itself, against a machine that answers

    func testOnlyTheFoldersThatAnsweredAreShown() async throws {
        let bench = try await makeBench()
        bench.exists = ["System Folder", "System Folder:Preferences",
                        "Applications"]
        bench.software = [
            "extensions": [software(
                "AppleShare",
                "Macintosh HD:System Folder:Extensions:AppleShare")],
        ]
        bench.model.discoverLocations()
        try await bench.waitForSweep()

        let paths = bench.model.locations.map(\.path)
        XCTAssertEqual(paths.first, "", "the share root is always the top")
        XCTAssertTrue(paths.contains("System Folder:Extensions"))
        XCTAssertTrue(paths.contains("System Folder"))
        XCTAssertTrue(paths.contains("System Folder:Preferences"))
        XCTAssertTrue(paths.contains("Applications"))
        // Everything else refused, and refusing is not an error.
        XCTAssertFalse(paths.contains("Documents"))
        XCTAssertFalse(paths.contains("Trash"))
        XCTAssertFalse(paths.contains("System Folder:Fonts"))
        XCTAssertNil(bench.model.lastError)
    }

    /// The Folder Manager route is the only one that survives a machine
    /// whose folders are not called what we would have guessed.
    func testALocalisedSystemFolderIsFoundByTheFolderManagerNotByGuessing()
        async throws {
        let bench = try await makeBench()
        bench.exists = []                  // every guessed name refuses
        bench.software = [
            "extensions": [software(
                "Foo", "Macintosh HD:Systemordner:Systemerweiterungen:Foo")],
        ]
        bench.model.discoverLocations()
        try await bench.waitForSweep()

        let byPath = Dictionary(
            uniqueKeysWithValues: bench.model.locations.map { ($0.path, $0) })
        XCTAssertEqual(byPath["Systemordner"]?.origin, .folderManager)
        XCTAssertEqual(byPath["Systemordner"]?.name, "Systemordner")
        XCTAssertEqual(byPath["Systemordner:Systemerweiterungen"]?.name,
                       "Systemerweiterungen",
                       "the machine's own name for it, not ours")
    }

    /// A folder inside the System Folder cannot be probed when the System
    /// Folder was never found: joining onto nothing would probe the share
    /// root's children under the same names, which is a different folder
    /// that may well exist.
    func testSystemFolderChildrenAreNotProbedAtTheRootInstead() async throws {
        let bench = try await makeBench()
        // "Preferences" exists at the ROOT of this share, and there is no
        // System Folder at all.
        bench.exists = ["Preferences", "Fonts"]
        bench.software = [:]
        bench.model.discoverLocations()
        try await bench.waitForSweep()

        let paths = bench.model.locations.map(\.path)
        XCTAssertFalse(paths.contains("Preferences"))
        XCTAssertFalse(paths.contains("Fonts"))
    }

    /// The guard that matters most: a sweep that carried on through a
    /// disconnect would record every folder it had not yet asked about as
    /// missing, on the strength of the wire having gone away.
    func testADroppedWireAbandonsTheSweepRatherThanEmptyingTheSidebar()
        async throws {
        let bench = try await makeBench()
        let before = bench.model.locations
        bench.exists = ["System Folder"]
        bench.refuseCode = "disconnected"
        bench.model.discoverLocations()
        try await bench.waitUntil("sweep settled") {
            !bench.model.isDiscoveringLocations
        }

        XCTAssertEqual(bench.model.locations, before,
                       "a failed rescan must preserve what was already known")
        let notice = try XCTUnwrap(bench.model.lastNotice)
        XCTAssertTrue(notice.contains("Could not finish"), notice)
    }

    func testASweepHappensOncePerConnectionUnlessAskedAgain() async throws {
        let bench = try await makeBench()
        bench.exists = []
        bench.model.discoverLocationsIfNeeded()
        try await bench.waitForSweep()
        let first = bench.listCount

        bench.model.discoverLocationsIfNeeded()
        XCTAssertEqual(bench.listCount, first,
                       "showing the page twice is not two sweeps")

        bench.model.discoverLocations()
        try await bench.waitForSweep()
        XCTAssertGreaterThan(bench.listCount, first,
                             "but a person may always ask again")
    }

    // MARK: - Dragging a folder in

    func testOnlyAFolderThisBrowserCanSeeMayBePinned() async throws {
        let bench = try await makeBench()
        bench.rootEntries = [folderEntry("Lab"), fileEntry("Read Me")]
        try await bench.browseRoot()

        XCTAssertTrue(bench.model.pinLocation(path: "Lab"))
        XCTAssertFalse(bench.model.pinLocation(path: "Read Me"),
                       "a file is not a place")
        XCTAssertFalse(bench.model.pinLocation(path: "/etc/passwd"),
                       "a dragged string is not evidence of anything")
        XCTAssertFalse(bench.model.pinLocation(path: ""),
                       "the root is already there")
        XCTAssertEqual(bench.model.locations.map(\.path), ["", "Lab"])
    }

    func testRemovingAPinForgetsItAndRemovingADiscoveryRemembersIt()
        async throws {
        let bench = try await makeBench()
        bench.exists = ["System Folder"]
        bench.rootEntries = [folderEntry("Lab")]
        bench.model.discoverLocations()
        try await bench.waitForSweep()
        try await bench.browseRoot()
        bench.model.pinLocation(path: "Lab")

        let system = try XCTUnwrap(
            bench.model.locations.first { $0.path == "System Folder" })
        let pin = try XCTUnwrap(
            bench.model.locations.first { $0.path == "Lab" })
        bench.model.removeLocation(system)
        bench.model.removeLocation(pin)
        XCTAssertEqual(bench.model.locations.map(\.path), [""])

        // The sweep runs again: the discovered one must stay out, which is
        // the whole reason removal is remembered rather than just applied.
        bench.model.discoverLocations()
        try await bench.waitForSweep()
        XCTAssertEqual(bench.model.locations.map(\.path), [""])
    }

    func testDraggingBackWhatWasThrownOutUndoesTheThrowingOut()
        async throws {
        let bench = try await makeBench()
        bench.exists = ["System Folder"]
        bench.model.discoverLocations()
        try await bench.waitForSweep()
        let system = try XCTUnwrap(
            bench.model.locations.first { $0.path == "System Folder" })
        bench.model.removeLocation(system)

        bench.rootEntries = [folderEntry("System Folder")]
        try await bench.browseRoot()
        XCTAssertTrue(bench.model.pinLocation(path: "System Folder"))
        XCTAssertTrue(bench.model.locations.contains { $0.path == "System Folder" })

        bench.model.discoverLocations()
        try await bench.waitForSweep()
        XCTAssertTrue(bench.model.locations.contains { $0.path == "System Folder" },
                      "otherwise the next sweep silently undoes the drag")
    }

    // MARK: - Harness

    private func location(_ path: String,
                          origin: FileLocation.Origin = .probed)
        -> FileLocation {
        FileLocation(path: path,
                     name: ClassicLocations.leafName(of: path),
                     symbol: "folder", origin: origin)
    }

    private func folderEntry(_ name: String) -> FileEntry {
        FileEntry(name: name, kind: "folder", fileType: nil, creator: nil,
                  dataBytes: nil, rsrcBytes: nil, modified: nil)
    }

    private func fileEntry(_ name: String) -> FileEntry {
        FileEntry(name: name, kind: "file", fileType: "TEXT",
                  creator: "ttxt", dataBytes: 3, rsrcBytes: 0, modified: nil)
    }

    private func software(_ name: String, _ path: String,
                          off: Bool? = nil) -> SoftwareEntry {
        SoftwareEntry(name: name, path: path, type: nil, creator: nil,
                      sizeK: nil, off: off, running: nil, version: nil)
    }

    private func suite() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "files.loc.\(UUID().uuidString)"))
    }

    /// A connected machine that answers `file.list` for a fixed set of
    /// folders and refuses the rest, which is exactly the shape discovery
    /// is written against.
    @MainActor
    private final class Bench {
        let listener: GuestListener
        let model: FilesModuleModel
        let guest: FakeGuest
        var exists: Set<String> = []
        var software: [String: [SoftwareEntry]] = [:]
        /// What the share root lists, for the tests that need the browser
        /// to have actually SEEN a folder before it may be pinned.
        var rootEntries: [FileEntry] = []
        var root = "Macintosh HD:"
        /// What a refusal is called. `disconnected` is the one that must
        /// abandon the sweep rather than record absences.
        var refuseCode = "no-such-folder"
        private(set) var listCount = 0

        init() async throws {
            // Held locally as well: `self` may not escape into a closure
            // until every member is initialized, and the wait below is a
            // closure.
            let listener = GuestListener(
                identity: .init(version: "0.1-test", name: "Test Host"),
                timing: .init(idleTimeout: 60))
            self.listener = listener
            listener.start(port: 0)
            try await Self.until("listening") {
                if case .listening = listener.state { return true }
                return false
            }
            model = FilesModuleModel(
                listener: listener,
                defaults: try XCTUnwrap(UserDefaults(
                    suiteName: "files.loc.\(UUID().uuidString)")))
            guest = FakeGuest(port: listener.boundPort ?? 0)
            guest.start()
            try guest.send(.hello(Hello(
                contract: Contract.revision, side: "guest", version: "0.1.0",
                name: "PowerBook 1400", os: "9.1", chunk: 8192)))
            try await Self.until("connected") {
                if case .connected = self.listener.state { return true }
                return false
            }
            guest.onMessage = { [weak self] message in
                guard let self else { return }
                self.answer(message)
            }
            model.connection = .connected(named: "PowerBook 1400")
            try await Self.until("initial connection sweep") {
                !self.model.isDiscoveringLocations
                    && !self.model.locations.isEmpty
            }
        }

        /// Lists the share root for real, so `pinLocation` is judged
        /// against rows that came off the wire rather than rows a test
        /// poked in — the check it performs is "can this browser see that
        /// this is a folder", and a poked row would not be evidence of it.
        func browseRoot() async throws {
            model.refresh()
            try await Self.until("root listed") { !self.model.rows.isEmpty }
        }

        private func answer(_ message: ControlMessage) {
            switch message {
            case .fileList(let request):
                listCount += 1
                // The root always lists — it is the share.
                guard request.path.isEmpty || exists.contains(request.path)
                else {
                    try? guest.send(.fileRefuse(FileRefuse(
                        id: request.id, code: refuseCode,
                        reason: "no such folder")))
                    return
                }
                try? guest.send(.fileListing(FileListing(
                    id: request.id, path: request.path,
                    entries: request.path.isEmpty ? rootEntries : [],
                    more: false, cursor: nil, root: root)))
            case .softwareList(let request):
                try? guest.send(.softwareListing(SoftwareListing(
                    id: request.id, domain: request.domain,
                    entries: software[request.domain] ?? [], more: false,
                    cursor: nil, note: nil)))
            default:
                break
            }
        }

        func waitForSweep() async throws {
            // Started, then settled: asserting only on "not sweeping"
            // would pass before the first request left.
            try await Self.until("sweep settled") {
                !self.model.isDiscoveringLocations
                    && (!self.model.locations.isEmpty
                        || self.model.lastNotice != nil)
            }
        }

        func waitUntil(_ what: String,
                       _ condition: @escaping () -> Bool) async throws {
            try await Self.until(what, condition)
        }

        static func until(_ what: String, timeout: TimeInterval = 5,
                          _ condition: @escaping () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() {
                guard Date() < deadline else {
                    XCTFail("timed out waiting for \(what)")
                    return
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
    }
}
