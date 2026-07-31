import XCTest
import Network
@testable import Host

/// The Software page's sweep budget, driven over the real wire.
///
/// Enumerating a domain costs the other Mac a multi-second disk crawl it
/// does while doing nothing else, so the question every test here asks is
/// *how many times did the guest have to sweep*. That is counted at the
/// guest — the `software.list` messages a scripted `FakeGuest` actually
/// received — rather than inferred from the model's own state, because a
/// model can look cached while still having asked.
///
/// **Every negative claim here is ordered.** "The second open did not
/// enumerate" is not asserted by looking straight after it: a request that
/// had been sent would not have arrived yet, so that assertion would pass
/// whether or not the cache worked. Each one instead sends a request that
/// MUST reach the guest (a rescan) and waits for its answer; the wire is a
/// queue, so anything the earlier call sent is at the guest by then, and
/// the count is read after that barrier.
@MainActor
final class SoftwareCacheTests: XCTestCase {
    private var listener: GuestListener!
    private var model: SoftwareModel!

    override func setUp() async throws {
        listener = GuestListener(identity: .init(version: "t", name: "Host"),
                                 timing: .init(idleTimeout: 60))
        listener.start(port: 0)
        try await waitUntil("listening") {
            if case .listening = self.listener.state { return true }
            return false
        }
        model = SoftwareModel(listener: listener)
    }

    override func tearDown() async throws {
        listener.stop()
        listener = nil
        model = nil
    }

    // MARK: harness

    private func waitUntil(_ what: String, timeout: TimeInterval = 5,
                           _ cond: @escaping () -> Bool) async throws {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout {
                return XCTFail("timed out waiting for \(what)")
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func connectGuest(named name: String = "PB 1400")
        async throws -> FakeGuest {
        let guest = FakeGuest(port: listener.boundPort!)
        guest.start()
        try guest.send(.hello(Hello(contract: Contract.revision, side: "guest",
            version: "0.1", name: name, os: "9.1", chunk: 8192)))
        try await waitUntil("host hello") { !guest.received.isEmpty }
        try await waitUntil("host connected") {
            if case .connected = self.listener.state { return true }
            return false
        }
        model.connection = .connected(named: name)
        return guest
    }

    /// Answers every `software.list` with one whole page, and counts what it
    /// was asked for. `fails` makes the next N requests time out at the
    /// guest — the guest simply does not answer, which is the honest shape
    /// of a Mac that went away mid-sweep.
    @MainActor
    private final class Script {
        private(set) var requests: [(domain: String, cursor: Int?)] = []
        var entries: [String: [SoftwareEntry]] = [:]
        /// Requests to swallow rather than answer, from now on.
        var silentAnswers = 0
        var note: String?

        var count: Int { requests.count }
        func count(domain: String) -> Int {
            requests.filter { $0.domain == domain }.count
        }

        func install(on guest: FakeGuest) {
            guest.onMessage = { [weak self, weak guest] msg in
                guard let self, let guest,
                      case .softwareList(let req) = msg else { return }
                self.requests.append((req.domain, req.cursor))
                if self.silentAnswers > 0 {
                    self.silentAnswers -= 1
                    // Answer the FAILURE the host can actually see quickly:
                    // an error listing rather than a 30 s watchdog wait.
                    try? guest.send(.error(ErrorMessage(
                        id: req.id, code: "sweep-failed",
                        message: "The disk went away mid-sweep")))
                    return
                }
                try? guest.send(.softwareListing(SoftwareListing(
                    id: req.id, domain: req.domain,
                    entries: self.entries[req.domain] ?? [],
                    more: false, cursor: nil, note: self.note)))
            }
        }
    }

    private func entry(_ name: String, _ path: String) -> SoftwareEntry {
        SoftwareEntry(name: name, path: path, type: "APPL", creator: "ttxt",
                      sizeK: 100, off: nil, running: nil, version: "1.0")
    }

    /// The barrier every ordered assertion below leans on: force one sweep
    /// that MUST reach the guest, and wait for its answer. Anything an
    /// earlier call put on the wire has arrived by the time this returns.
    ///
    /// The settle-and-check is not ceremony. `refresh()` declines while a
    /// sweep is in flight, so a barrier fired on a busy model is a barrier
    /// that never happened — and a count read after it would be a count of
    /// nothing, passing for either answer. Found by mutation: with the
    /// cache disabled, the version of this helper without these two lines
    /// left `testTheFirstOpenSweepsAndTheSecondDoesNot` GREEN.
    private func barrierRescan() async throws {
        try await waitUntil("the page to settle") {
            self.model.isLoading == false
        }
        let before = model.fetchedAt
        model.refresh()
        XCTAssertTrue(model.isLoading,
                      "the barrier has to actually ask, or it is not one")
        try await waitUntil("the barrier rescan landed") {
            self.model.isLoading == false && self.model.fetchedAt != before
        }
    }

    /// A call that must NOT reach the wire. `sweep()` flips `isLoading`
    /// synchronously, so this is a fact about what just happened rather
    /// than a guess about what has not happened yet — which is the whole
    /// distinction an asynchronous negative assertion gets wrong.
    private func expectNoSweep(_ what: String, _ body: () -> Void) {
        XCTAssertFalse(model.isLoading, "\(what): precondition, page idle")
        body()
        XCTAssertFalse(model.isLoading,
                       "\(what): a domain already in hand must not start a "
                           + "sweep at all")
    }

    private func openAndWait() async throws {
        model.openIfNeeded()
        try await waitUntil("the first sweep landed") {
            self.model.isLoading == false && self.model.fetchedAt != nil
        }
    }

    // MARK: the sweep budget

    func testTheFirstOpenSweepsAndTheSecondDoesNot() async throws {
        let guest = try await connectGuest()
        let script = Script()
        script.entries["apps"] = [entry("SimpleText", "HD:Apps:SimpleText")]
        script.install(on: guest)

        try await openAndWait()
        XCTAssertEqual(script.count, 1, "the page opened; the Mac swept once")
        XCTAssertEqual(model.rows.count, 1)

        // Re-opening the page, twice. Neither may even start a sweep, and
        // anything they did send is on the wire ahead of the barrier, so
        // the count read after the barrier is conclusive.
        expectNoSweep("second open") { model.openIfNeeded() }
        expectNoSweep("third open") { model.openIfNeeded() }
        try await barrierRescan()
        XCTAssertEqual(script.count, 2,
                       "two more opens cost nothing; only the rescan swept")
    }

    func testFlippingTheDomainPickerBackDoesNotSweepAgain() async throws {
        let guest = try await connectGuest()
        let script = Script()
        script.entries["apps"] = [entry("SimpleText", "HD:Apps:SimpleText")]
        script.entries["cdevs"] = [entry("Sound", "HD:System:CP:Sound")]
        script.install(on: guest)

        try await openAndWait()
        model.domain = .cdevs
        try await waitUntil("control panels landed") {
            self.model.isLoading == false && self.model.rows.count == 1
                && self.model.rows[0].name == "Sound"
        }
        XCTAssertEqual(script.count(domain: "apps"), 1)
        XCTAssertEqual(script.count(domain: "cdevs"), 1)

        // Back to a domain this Mac has already answered.
        expectNoSweep("flipping back to Applications") { model.domain = .apps }
        XCTAssertEqual(model.rows.map(\.name), ["SimpleText"],
                       "the banked listing came back without the wire")
        try await barrierRescan()
        XCTAssertEqual(script.count(domain: "apps"), 2,
                       "returning to Applications cost nothing; the "
                           + "barrier rescan is the only second sweep")
    }

    func testEachDomainIsSweptOnceOnItsOwn() async throws {
        let guest = try await connectGuest()
        let script = Script()
        script.entries["apps"] = [entry("SimpleText", "HD:a")]
        script.entries["extensions"] = [entry("AppleShare", "HD:e")]
        script.install(on: guest)

        try await openAndWait()
        model.domain = .extensions
        try await waitUntil("extensions landed") {
            self.model.isLoading == false
                && self.model.rows.first?.name == "AppleShare"
        }
        // Opening the page again on a domain already in hand.
        expectNoSweep("re-open on Extensions") { model.openIfNeeded() }
        try await barrierRescan()
        XCTAssertEqual(script.count(domain: "extensions"), 2,
                       "one sweep for the open, one for the barrier")
        XCTAssertEqual(script.count(domain: "apps"), 1,
                       "Applications was never re-asked")
    }

    // MARK: what invalidates it

    func testADisconnectDropsTheBankedSweeps() async throws {
        let guest = try await connectGuest()
        let script = Script()
        script.entries["apps"] = [entry("SimpleText", "HD:a")]
        script.install(on: guest)
        try await openAndWait()
        XCTAssertEqual(script.count, 1)

        // The session ended. The next dial may be a redeployed guest with a
        // different disk, so the listing does not survive it.
        model.connection = .disconnected
        XCTAssertTrue(model.rows.isEmpty,
                      "nothing from a session that ended stays on screen")
        XCTAssertNil(model.fetchedAt)

        model.connection = .connected(named: "PB 1400")
        try await openAndWait()
        XCTAssertEqual(script.count, 2, "the reconnect swept again")
    }

    func testAnotherMacsListingIsNeverShownUnderThisOne() async throws {
        let guest = try await connectGuest()
        let script = Script()
        script.entries["apps"] = [entry("SimpleText", "HD:a")]
        script.install(on: guest)
        try await openAndWait()

        // The window is pointed at a DIFFERENT machine. Its own key, its
        // own (absent) listing — the first Mac's inventory must not be
        // sitting there under the second one's name.
        model.connection = .connected(named: "Quadra 950")
        XCTAssertTrue(model.rows.isEmpty,
                      "a machine never swept shows nothing, not the other "
                          + "Mac's software")
        XCTAssertNil(model.fetchedAt)

        script.entries["apps"] = [entry("HyperCard", "HD:h")]
        try await openAndWait()
        XCTAssertEqual(model.rows.map(\.name), ["HyperCard"])

        // Back to the first Mac: its own listing, parked, not re-swept.
        expectNoSweep("returning to the first Mac") {
            model.connection = .connected(named: "PB 1400")
            model.openIfNeeded()
        }
        XCTAssertEqual(model.rows.map(\.name), ["SimpleText"],
                       "each Mac's listing came back under its own name")
        try await barrierRescan()
        XCTAssertEqual(script.count, 3,
                       "one sweep per machine, plus the barrier — coming "
                           + "back cost nothing")
    }

    // MARK: a rescan that fails

    func testAFailedRescanKeepsTheOldListingAndSaysSo() async throws {
        let guest = try await connectGuest()
        let script = Script()
        script.entries["apps"] = [entry("SimpleText", "HD:a")]
        script.install(on: guest)
        try await openAndWait()
        let swept = try XCTUnwrap(model.fetchedAt)

        script.silentAnswers = 1
        model.refresh()
        try await waitUntil("the rescan failed") {
            self.model.isLoading == false && self.model.lastError != nil
        }
        XCTAssertEqual(model.rows.map(\.name), ["SimpleText"],
                       "a failed rescan does not cost a good answer")
        XCTAssertEqual(model.fetchedAt, swept,
                       "and the good answer keeps its OWN timestamp — it "
                           + "must not pass for the sweep just asked for")
        XCTAssertNotNil(model.rescanFailedAt,
                        "the page has something to say out loud")
        XCTAssertNotNil(model.lastError)
    }

    func testAFailedFirstSweepLeavesNoTimestampToMisread() async throws {
        let guest = try await connectGuest()
        let script = Script()
        script.silentAnswers = 1
        script.install(on: guest)

        model.openIfNeeded()
        try await waitUntil("the first sweep failed") {
            self.model.isLoading == false && self.model.lastError != nil
        }
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertNil(model.fetchedAt, "there is no listing to be as of")
        XCTAssertNil(model.rescanFailedAt,
                     "nothing stale is on screen, so there is nothing to "
                         + "warn about — that line is for a fallback")

        // And nothing was banked, so the next open still asks.
        script.entries["apps"] = [entry("SimpleText", "HD:a")]
        try await openAndWait()
        XCTAssertEqual(script.count, 2)
        XCTAssertEqual(model.rows.count, 1)
    }

    func testASuccessfulRescanClearsTheStaleWarning() async throws {
        let guest = try await connectGuest()
        let script = Script()
        script.entries["apps"] = [entry("SimpleText", "HD:a")]
        script.install(on: guest)
        try await openAndWait()

        script.silentAnswers = 1
        model.refresh()
        try await waitUntil("the rescan failed") {
            self.model.rescanFailedAt != nil
        }
        script.entries["apps"] = [entry("SimpleText", "HD:a"),
                                  entry("HyperCard", "HD:h")]
        try await barrierRescan()
        XCTAssertNil(model.rescanFailedAt,
                     "a sweep that landed is not a stale one")
        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.rows.count, 2)
    }

    // MARK: staleness, as the footer reads it

    func testTheAgeLineStaysQuietWhileTheSweepIsFresh() {
        let now = Date()
        XCTAssertNil(SoftwareModuleView.age(of: now, now: now),
                     "a sweep taken while you watched needs no phrase; "
                         + "\"as of 14:02\" already says it is a snapshot")
        XCTAssertNil(SoftwareModuleView.age(of: now.addingTimeInterval(-30),
                                            now: now))
        let old = SoftwareModuleView.age(of: now.addingTimeInterval(-3600),
                                         now: now)
        XCTAssertNotNil(old, "an hour-old listing says how old it is")
        XCTAssertTrue(old?.contains("hour") == true, "got \(old ?? "nil")")
    }
}
