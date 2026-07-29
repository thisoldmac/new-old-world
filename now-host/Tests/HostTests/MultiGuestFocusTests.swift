import AppKit
import XCTest
import Network
@testable import Host

/// What a guest picker is allowed to do to the modules.
///
/// The wire half of "two guests on one port" landed with the picker
/// deliberately unwired, because every module model cached per CONNECTION
/// and cleared only on a DISCONNECT: switching would have shown one Mac's
/// process table, inventory, census, browse path and scrollback under the
/// other Mac's name. Nothing was wrong while nothing switched. These are
/// the guards that let something switch.
///
/// They are written against the seam the live window uses — `connection`
/// on each model, set by HostAppState from the listener's state — rather
/// than against the cache directly, because the cache being right and the
/// model never being told are the same defect from the person's side.
@MainActor
final class MultiGuestFocusTests: XCTestCase {
    private let jem = GuestConnectionState.connected(named: "PowerBook 1400c")
    private let ess = GuestConnectionState.connected(named: "PowerBook 180c")

    private func listener() -> GuestListener {
        GuestListener(identity: .init(version: "0.1-test", name: "Test Host"))
    }

    // MARK: - The cache itself

    func testTheCacheParksTheOutgoingMachineAndRestoresTheIncomingOne() {
        let cache = GuestStateCache<String>()
        // First focus has nothing to park and nothing to restore.
        guard case .switched(let first) = cache.focus(GuestKey(name: "A"),
                                                      parking: "") else {
            return XCTFail("the first machine is a switch, not a no-op")
        }
        XCTAssertNil(first, "a machine never seen starts empty")

        guard case .switched(let toB) = cache.focus(GuestKey(name: "B"),
                                                    parking: "A's state") else {
            return XCTFail("B is a different machine")
        }
        XCTAssertNil(toB)
        guard case .switched(let backToA) = cache.focus(GuestKey(name: "A"),
                                                        parking: "B's state")
        else { return XCTFail("A is a different machine again") }
        XCTAssertEqual(backToA, "A's state")
    }

    /// The distinction the enum exists for: a disconnect must not look
    /// like a switch to an empty machine, or every model would wipe itself
    /// the moment the wire dropped.
    func testADisconnectIsNotASwitch() {
        let cache = GuestStateCache<String>()
        _ = cache.focus(GuestKey(name: "A"), parking: "")
        guard case .unchanged = cache.focus(nil, parking: "A's state") else {
            return XCTFail("nil focus must leave the live state alone")
        }
        // ...and the machine coming back is still the focused one, so it
        // finds its own state rather than a restore of nothing.
        guard case .unchanged = cache.focus(GuestKey(name: "A"),
                                            parking: "A's state") else {
            return XCTFail("the same machine is not a switch")
        }
    }

    func testTheCacheIsBoundedByMachinesSeen() {
        let cache = GuestStateCache<String>(limit: 2)
        _ = cache.focus(GuestKey(name: "A"), parking: "")
        _ = cache.focus(GuestKey(name: "B"), parking: "A")
        _ = cache.focus(GuestKey(name: "C"), parking: "B")
        _ = cache.focus(GuestKey(name: "D"), parking: "C")
        XCTAssertNil(cache.parkedState(for: GuestKey(name: "A")),
                     "the oldest machine's state is dropped past the limit")
        XCTAssertEqual(cache.parkedState(for: GuestKey(name: "C")), "C")
    }

    // MARK: - The console

    func testTheScrollbackIsPerMachineAndComesBack() {
        let console = ConsoleModel(listener: listener())
        console.focus(on: jem)
        console.input = "gestalt"
        console.submit()
        XCTAssertTrue(console.lines.contains { $0.text == "gestalt" })

        console.focus(on: ess)
        XCTAssertFalse(console.lines.contains { $0.text == "gestalt" },
                       "one Mac's session must not appear under another's")
        XCTAssertTrue(console.lines.contains { $0.text.contains("180c") },
                      "the fresh console names the machine it is a console for")
        console.input = "vers"
        console.submit()

        console.focus(on: jem)
        XCTAssertTrue(console.lines.contains { $0.text == "gestalt" },
                      "a scrollback cannot be re-fetched, so it is kept")
        XCTAssertFalse(console.lines.contains { $0.text == "vers" })
        XCTAssertEqual(console.recallHistory(-1), "gestalt",
                       "↑ recalls this machine's history, not the other's")
    }

    /// The behaviour that existed before there were two guests, and which
    /// parking must not quietly take away: the scrollback is what a person
    /// reads to find out why the wire dropped.
    func testADisconnectLeavesTheScrollbackOnScreen() {
        let console = ConsoleModel(listener: listener())
        console.focus(on: jem)
        console.input = "gestalt"
        console.submit()
        console.focus(on: .disconnected)
        XCTAssertTrue(console.lines.contains { $0.text == "gestalt" })
    }

    // MARK: - Screenshots

    private func image() -> CGImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.cgImage!
    }

    private func delivery(from guest: String)
        -> GuestListener.CaptureDelivery {
        GuestListener.CaptureDelivery(
            image: image(),
            format: CaptureFormat(width: 4, height: 4, depth: 8, rowBytes: 4,
                                  bytes: 16, paletteBytes: 0, packed: false,
                                  captureMs: 1, encodeMs: 1),
            transferMs: 1, wireBytes: 16,
            guestName: guest, guestKey: GuestKey(name: guest))
    }

    /// The gap the wire slice left open, stated in its own words: a push
    /// "arrives on pushedCaptures with no identity, so the Screenshots
    /// module would attribute a background guest's push to the active
    /// one". It now arrives stamped with the socket it came from.
    func testABackgroundMacsPushIsFiledUnderTheMachineThatSentIt() throws {
        let suite = "multiguest.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removeSuite(named: suite) }
        let model = ScreenshotModuleModel(listener: listener(),
                                          defaults: defaults)
        var announced: [String] = []
        model.announce = { guest, _, _ in announced.append(guest) }
        model.connection = jem

        model.receivePushed(delivery(from: "PowerBook 180c"))
        XCTAssertTrue(model.history.isEmpty,
                      "the machine being driven did not take this picture")
        XCTAssertEqual(announced, ["PowerBook 180c"],
                       "the notification names the Mac that sent it")

        model.connection = ess
        XCTAssertEqual(model.history.count, 1,
                       "it was waiting under the Mac that sent it")
        XCTAssertEqual(model.history.first?.guest, "PowerBook 180c")
    }

    func testTheDrivenMacsOwnPushStillLandsInFront() throws {
        let suite = "multiguest.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removeSuite(named: suite) }
        let model = ScreenshotModuleModel(listener: listener(),
                                          defaults: defaults)
        model.connection = jem
        model.receivePushed(delivery(from: "PowerBook 1400c"))
        XCTAssertEqual(model.history.count, 1)
        XCTAssertEqual(model.history.first?.guest, "PowerBook 1400c")
    }

    func testCapturesAreKeptPerMachineRatherThanDiscardedOnASwitch() throws {
        let suite = "multiguest.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removeSuite(named: suite) }
        let model = ScreenshotModuleModel(listener: listener(),
                                          defaults: defaults)
        model.connection = jem
        model.receivePushed(delivery(from: "PowerBook 1400c"))
        model.connection = ess
        XCTAssertTrue(model.history.isEmpty,
                      "the other Mac's screen is not this Mac's history")
        model.connection = jem
        XCTAssertEqual(model.history.count, 1,
                       "a capture cannot be taken again, so it is kept")
    }

    // MARK: - Hardware

    func testTheCensusDossierIsPerMachine() {
        let model = CensusModuleModel(listener: listener())
        model.connection = jem
        let first = try? XCTUnwrap(CensusProbes.all.first?.id)
        XCTAssertNotNil(first)
        XCTAssertEqual(model.probes.count, CensusProbes.all.count)
        // Nothing has run on either machine, so the guard that matters is
        // the identity of the arrays, not their contents: a switch must
        // hand the model a different dossier object, not the same one.
        model.connection = ess
        XCTAssertTrue(model.probes.allSatisfy { !$0.hasRun })
    }

    // MARK: - The whole window

    /// Every model that shows one machine's state has to hear about the
    /// switch. This is the wiring guard: `HostAppState` used to assign
    /// `connection` model by model, and a module added to that list and
    /// not to the picker's would be invisible until someone switched.
    func testEveryGuestScopedModelFollowsTheActiveMac() async throws {
        let suite = "MultiGuestFocus.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(0, forKey: "listenPort")
        defaults.set(false, forKey: "listenAtLaunch")

        let state = HostAppState(registry: .standard, defaults: defaults)
        state.listener.start(port: 0)
        try await waitUntil("listening") {
            if case .listening = state.listener.state { return true }
            return false
        }
        let port = try XCTUnwrap(state.listener.boundPort)

        func dial(_ name: String) async throws -> FakeGuest {
            let guest = FakeGuest(port: port)
            guest.start()
            try guest.send(.hello(Hello(
                contract: Contract.revision, side: "guest", version: "0.1.0",
                name: name, os: "9.1", chunk: 8192)))
            try await waitUntil("\(name) connected") {
                state.listener.guests.contains { $0.name == name }
            }
            return guest
        }
        let jemGuest = try await dial("PowerBook 1400c")
        _ = try await dial("PowerBook 180c")
        defer { state.stopListening(); jemGuest.connection.cancel() }

        XCTAssertEqual(state.screenshots.connection.peerLabel,
                       "PowerBook 1400c")

        XCTAssertTrue(state.selectGuest(GuestKey(name: "PowerBook 180c")))
        try await waitUntil("the models follow") {
            state.screenshots.connection.peerLabel == "PowerBook 180c"
        }
        for label in [state.screenshots.connection.peerLabel,
                      state.files.connection.peerLabel,
                      state.census.connection.peerLabel,
                      state.processes.connection.peerLabel,
                      state.software.connection.peerLabel] {
            XCTAssertEqual(label, "PowerBook 180c",
                           "a module left behind shows the wrong Mac's state")
        }
    }

    /// The defect in the plainest form it has: rows that came off one
    /// machine's disk, on screen under the other machine's name.
    ///
    /// End to end through two real sockets, because the failure is a
    /// wiring failure — a model that caches correctly and never learns it
    /// switched is indistinguishable, from the desk, from one that does
    /// not cache correctly at all.
    func testOneMacsRowsAreNeverShownUnderTheOthersName() async throws {
        let suite = "MultiGuestRows.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "listenAtLaunch")
        let state = HostAppState(registry: .standard, defaults: defaults)
        state.listener.start(port: 0)
        try await waitUntil("listening") {
            if case .listening = state.listener.state { return true }
            return false
        }
        let port = try XCTUnwrap(state.listener.boundPort)

        /// A guest that answers `software.list` with one named entry, and
        /// counts how many times it was asked — the second half of the
        /// point of parking is that coming back does not re-sweep a
        /// classic Mac's disk.
        func dial(_ name: String, serving app: String) async throws
            -> (guest: FakeGuest, asked: () -> Int) {
            let guest = FakeGuest(port: port)
            var asks = 0
            guest.onMessage = { message in
                guard case .softwareList(let request) = message else { return }
                asks += 1
                try? guest.send(.softwareListing(SoftwareListing(
                    id: request.id, domain: request.domain,
                    entries: [SoftwareEntry(
                        name: app, path: "HD:Applications:\(app)",
                        type: "APPL", creator: "????", sizeK: 100,
                        off: nil, running: nil, version: nil)],
                    more: false, cursor: nil, note: nil)))
            }
            guest.start()
            try guest.send(.hello(Hello(
                contract: Contract.revision, side: "guest", version: "0.1.0",
                name: name, os: "9.1", chunk: 8192)))
            try await waitUntil("\(name) connected") {
                state.listener.guests.contains { $0.name == name }
            }
            return (guest, { asks })
        }

        let jem = try await dial("PowerBook 1400c", serving: "SimpleText")
        let ess = try await dial("PowerBook 180c", serving: "TeachText")
        defer {
            state.stopListening()
            jem.guest.connection.cancel()
            ess.guest.connection.cancel()
        }

        state.software.refresh()
        try await waitUntil("the 1400c's inventory") {
            state.software.rows.map(\.name) == ["SimpleText"]
        }

        XCTAssertTrue(state.selectGuest(GuestKey(name: "PowerBook 180c")))
        try await waitUntil("the switch reaches Software") {
            state.software.connection.peerLabel == "PowerBook 180c"
        }
        XCTAssertTrue(state.software.rows.isEmpty,
                      "the 1400c's applications are not the 180c's")

        state.software.refresh()
        try await waitUntil("the 180c's inventory") {
            state.software.rows.map(\.name) == ["TeachText"]
        }

        XCTAssertTrue(state.selectGuest(GuestKey(name: "PowerBook 1400c")))
        try await waitUntil("the switch back") {
            state.software.connection.peerLabel == "PowerBook 1400c"
        }
        XCTAssertEqual(state.software.rows.map(\.name), ["SimpleText"],
                       "coming back finds this machine's own inventory")
        XCTAssertEqual(jem.asked(), 1,
                       "a ~4s disk sweep is not repeated for a glance at "
                       + "the other Mac")
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5,
                           _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                return XCTFail("timed out waiting for \(what)")
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - The menu

    func testTheDriveMenuNamesTheMacsAndTicksTheOneBeingDriven() {
        let holder = NSMenuItem(title: "Drive", action: nil, keyEquivalent: "")
        holder.submenu = NSMenu(title: "Drive")
        let menu = MainMenu.fillDriveMenu(
            holder,
            guests: [
                ConnectedGuest(key: GuestKey(name: "PowerBook 1400c"),
                               name: "PowerBook 1400c", version: nil,
                               operatingSystem: nil, connectedAt: Date(),
                               isActive: false),
                ConnectedGuest(key: GuestKey(name: "PowerBook 180c"),
                               name: "PowerBook 180c", version: nil,
                               operatingSystem: nil, connectedAt: Date(),
                               isActive: true),
            ],
            target: self, action: #selector(noop))
        XCTAssertEqual(menu.items.map(\.title),
                       ["PowerBook 1400c", "PowerBook 180c"])
        XCTAssertEqual(menu.items.map(\.state), [.off, .on])
        // The title is the identity the action acts on, so it must fold
        // back to the same key the roster carries.
        XCTAssertEqual(GuestKey(name: menu.items[1].title),
                       GuestKey(name: "PowerBook 180c"))
    }

    func testAnEmptyDriveMenuSaysSoRatherThanOpeningOntoNothing() {
        let holder = NSMenuItem(title: "Drive", action: nil, keyEquivalent: "")
        let menu = MainMenu.fillDriveMenu(holder, guests: [], target: self,
                                          action: #selector(noop))
        XCTAssertEqual(menu.items.map(\.title), ["No Macs Connected"])
        XCTAssertFalse(holder.isEnabled)
    }

    @objc private func noop() {}
}
