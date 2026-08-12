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
        guard case .switched(let first) = cache.focus(GuestKey.synthetic("A"),
                                                      parking: "") else {
            return XCTFail("the first machine is a switch, not a no-op")
        }
        XCTAssertNil(first, "a machine never seen starts empty")

        guard case .switched(let toB) = cache.focus(GuestKey.synthetic("B"),
                                                    parking: "A's state") else {
            return XCTFail("B is a different machine")
        }
        XCTAssertNil(toB)
        guard case .switched(let backToA) = cache.focus(GuestKey.synthetic("A"),
                                                        parking: "B's state")
        else { return XCTFail("A is a different machine again") }
        XCTAssertEqual(backToA, "A's state")
    }

    /// The distinction the enum exists for: a disconnect must not look
    /// like a switch to an empty machine, or every model would wipe itself
    /// the moment the wire dropped.
    func testADisconnectIsNotASwitch() {
        let cache = GuestStateCache<String>()
        _ = cache.focus(GuestKey.synthetic("A"), parking: "")
        guard case .unchanged = cache.focus(nil, parking: "A's state") else {
            return XCTFail("nil focus must leave the live state alone")
        }
        // ...and the machine coming back is still the focused one, so it
        // finds its own state rather than a restore of nothing.
        guard case .unchanged = cache.focus(GuestKey.synthetic("A"),
                                            parking: "A's state") else {
            return XCTFail("the same machine is not a switch")
        }
    }

    func testTheCacheIsBoundedByMachinesSeen() {
        let cache = GuestStateCache<String>(limit: 2)
        _ = cache.focus(GuestKey.synthetic("A"), parking: "")
        _ = cache.focus(GuestKey.synthetic("B"), parking: "A")
        _ = cache.focus(GuestKey.synthetic("C"), parking: "B")
        _ = cache.focus(GuestKey.synthetic("D"), parking: "C")
        XCTAssertNil(cache.parkedState(for: GuestKey.synthetic("A")),
                     "the oldest machine's state is dropped past the limit")
        XCTAssertEqual(cache.parkedState(for: GuestKey.synthetic("C")), "C")
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
            guestName: guest, guestKey: GuestKey.synthetic(guest))
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
        let essGuest = try await dial("PowerBook 180c")
        defer {
            state.stopListening()
            jemGuest.connection.cancel()
            essGuest.connection.cancel()
        }

        let screen = try XCTUnwrap(state.moduleRuntime(
            for: "screen", as: ScreenHostModuleRuntime.self))
        XCTAssertEqual(screen.model.connection.peerLabel,
                       "PowerBook 1400c")

        let outgoingMirrorKey = try liveKey(state, "PowerBook 1400c")
        state.mirrorRun.start()
        XCTAssertEqual(state.mirrorSource.pinnedGuestKey, outgoingMirrorKey)

        let incomingMirrorKey = try liveKey(state, "PowerBook 180c")
        XCTAssertTrue(state.selectGuest(incomingMirrorKey))
        try await waitUntil("the models follow") {
            screen.model.connection.peerLabel == "PowerBook 180c"
        }
        let census = try XCTUnwrap(state.moduleRuntime(
            for: "census", as: CensusHostModuleRuntime.self))
        let software = try XCTUnwrap(state.moduleRuntime(
            for: "software", as: SoftwareHostModuleRuntime.self))
        let files = try XCTUnwrap(state.moduleRuntime(
            for: "files", as: FilesHostModuleRuntime.self))
        for label in [screen.model.connection.peerLabel,
                      files.model.connection.peerLabel,
                      census.model.connection.peerLabel,
                      state.processes.connection.peerLabel,
                      software.model.connection.peerLabel] {
            XCTAssertEqual(label, "PowerBook 180c",
                           "a module left behind shows the wrong Mac's state")
        }
        XCTAssertEqual(state.mirrorSource.pinnedGuestKey, incomingMirrorKey,
                       "the Mirror must cross the same connection boundary")
        XCTAssertNil(state.mirrorEngines.existing(for: outgoingMirrorKey),
                     "the outgoing session engine must not survive a switch")
        XCTAssertNotNil(state.mirrorEngines.existing(for: incomingMirrorKey))

        essGuest.connection.cancel()
        try await waitUntil("the active disconnect promotes the remaining Mac") {
            screen.model.connection.peerLabel == "PowerBook 1400c"
        }
        XCTAssertEqual(state.mirrorSource.pinnedGuestKey, outgoingMirrorKey,
                       "an active disconnect starts a fresh session on the "
                           + "remaining Mac")
        XCTAssertNil(state.mirrorSource.scene)
        XCTAssertNil(state.mirrorEngines.existing(for: incomingMirrorKey))
        XCTAssertNotNil(state.mirrorEngines.existing(for: outgoingMirrorKey))
    }

    func testAddressedSceneRequestDoesNotFollowTheActivePicker() async throws {
        let listener = listener()
        listener.start(port: 0)
        try await waitUntil("listening") {
            if case .listening = listener.state { return true }
            return false
        }
        let port = try XCTUnwrap(listener.boundPort)
        var firstAsks = 0
        var secondAsks = 0

        func dial(_ name: String, asks: @escaping () -> Void) async throws
            -> FakeGuest {
            let guest = FakeGuest(port: port)
            guest.onMessage = { message in
                if case .sceneRequest = message { asks() }
            }
            guest.start()
            try guest.send(.hello(Hello(
                contract: Contract.revision, side: "guest", version: "test",
                name: name, os: "9.1", chunk: 8192)))
            try await waitUntil("\(name) connected") {
                listener.guests.contains { $0.name == name }
            }
            return guest
        }

        let first = try await dial("First Mac") { firstAsks += 1 }
        let second = try await dial("Second Mac") { secondAsks += 1 }
        defer {
            first.connection.cancel(); second.connection.cancel()
            listener.stop()
        }
        let firstKey = try XCTUnwrap(
            listener.guests.first { $0.name == "First Mac" }?.key)
        let secondKey = try XCTUnwrap(
            listener.guests.first { $0.name == "Second Mac" }?.key)
        XCTAssertTrue(listener.selectGuest(secondKey))

        listener.requestScene(for: firstKey) { _ in }
        var duplicateFailure: String?
        listener.requestScene(for: firstKey) { result in
            if case .failure(let failure) = result {
                duplicateFailure = failure.message
            }
        }
        try await waitUntil("the pinned guest receives the scene request") {
            firstAsks == 1
        }
        XCTAssertEqual(secondAsks, 0,
                       "the active picker must not retarget a pinned Mirror")
        XCTAssertEqual(firstAsks, 1,
                       "a second caller must not orphan the first completion")
        XCTAssertEqual(duplicateFailure,
                       "A scene is already on its way. Ask again when it arrives.")
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
                switch message {
                case .fileList(let request):
                    try? guest.send(.fileListing(FileListing(
                        id: request.id, path: request.path, entries: [],
                        more: false, cursor: nil, root: "HD:Shared:")))
                case .processList(let request):
                    try? guest.send(.processListing(ProcessListing(
                        id: request.id, processes: [], more: false,
                        cursor: nil)))
                case .commandRequest(let request):
                    try? guest.send(.commandResult(CommandResult(
                        id: request.id, ok: request.name == "help",
                        output: request.name == "help"
                            ? ["help": [["software.list", "a family"]]]
                            : nil,
                        error: request.name == "help" ? nil : .init(
                            code: "unknown-command",
                            message: "\(request.name): no such command"))))
                case .softwareList(let request):
                    let isInventory = request.domain == "apps"
                    if isInventory { asks += 1 }
                    try? guest.send(.softwareListing(SoftwareListing(
                        id: request.id, domain: request.domain,
                        entries: isInventory ? [SoftwareEntry(
                            name: app, path: "HD:Applications:\(app)",
                            type: "APPL", creator: "????", sizeK: 100,
                            off: nil, running: nil, version: nil)] : [],
                        more: false, cursor: nil, note: nil)))
                default:
                    break
                }
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
        let software = try XCTUnwrap(state.moduleRuntime(
            for: "software", as: SoftwareHostModuleRuntime.self))

        software.model.refresh()
        try await waitUntil("the 1400c's inventory") {
            software.model.rows.map(\.name) == ["SimpleText"]
        }

        XCTAssertTrue(state.selectGuest(try liveKey(state, "PowerBook 180c")))
        try await waitUntil("the switch reaches Software") {
            software.model.connection.peerLabel == "PowerBook 180c"
        }
        XCTAssertTrue(software.model.rows.isEmpty,
                      "the 1400c's applications are not the 180c's")

        software.model.refresh()
        try await waitUntil("the 180c's inventory") {
            software.model.rows.map(\.name) == ["TeachText"]
        }

        XCTAssertTrue(state.selectGuest(try liveKey(state, "PowerBook 1400c")))
        try await waitUntil("the switch back") {
            software.model.connection.peerLabel == "PowerBook 1400c"
        }
        XCTAssertEqual(software.model.rows.map(\.name), ["SimpleText"],
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

    /// The live session key for a connected Mac, by the name it reports.
    /// A key is not derivable from a name any more — that derivation was
    /// the defect — so a test asks the roster, as the picker does.
    private func liveKey(_ state: HostAppState, _ name: String) throws
        -> GuestKey {
        try XCTUnwrap(state.listener.guests.first { $0.name == name }?.key,
                      "no connected guest called \(name)")
    }

    // MARK: - The menu

    func testTheDriveMenuNamesTheMacsAndTicksTheOneBeingDriven() throws {
        let holder = NSMenuItem(title: "Drive", action: nil, keyEquivalent: "")
        holder.submenu = NSMenu(title: "Drive")
        let jem = Self.guest(id: "pb1400c", name: "PowerBook 1400c",
                             address: "10.91.5.180", active: false)
        let ess = Self.guest(id: "pb180c", name: "PowerBook 180c",
                             address: "10.91.5.181", active: true)
        let menu = MainMenu.fillDriveMenu(
            holder,
            guests: [jem, ess],
            target: self, action: #selector(noop))
        XCTAssertEqual(menu.items.map(\.title),
                       ["PowerBook 1400c", "PowerBook 180c"])
        XCTAssertEqual(menu.items.map(\.state), [.off, .on])
        // The item carries its SESSION id. The title cannot be the
        // identity any more — two Macs may report the same name — so what
        // the action acts on travels beside it.
        XCTAssertEqual(menu.items[1].representedObject as? String,
                       ess.sessionID)
        XCTAssertEqual(GuestKey.parse(
            try XCTUnwrap(menu.items[1].representedObject as? String)),
                       ess.key)
    }

    /// Two Macs that call themselves the SAME thing are two rows with two
    /// handles — the case that used to refuse the second machine `busy`.
    func testTheDriveMenuTellsTwoMacsOfTheSameNameApart() throws {
        let holder = NSMenuItem(title: "Drive", action: nil, keyEquivalent: "")
        holder.submenu = NSMenu(title: "Drive")
        let first = Self.guest(id: "guest-1", name: "NOW Guest 0.14",
                               address: "10.91.5.180", active: true)
        let second = Self.guest(id: "guest-2", name: "NOW Guest 0.14",
                                displayName: "NOW Guest 0.14",
                                address: "10.91.5.181", active: false)
        let menu = MainMenu.fillDriveMenu(
            holder, guests: [first, second],
            target: self, action: #selector(noop))
        XCTAssertEqual(menu.items.count, 2)
        XCTAssertEqual(menu.items.map(\.title), [
            "NOW Guest 0.14 — guest-1",
            "NOW Guest 0.14 — guest-2",
        ])
        XCTAssertNotEqual(
            menu.items[0].representedObject as? String,
            menu.items[1].representedObject as? String)
    }

    private static func guest(id: String, name: String,
                              displayName: String? = nil, address: String,
                              active: Bool) -> ConnectedGuest {
        let key = GuestKey(machine: GuestID(id)!, session: UUID())
        return ConnectedGuest(
            key: key, id: GuestID(id)!, idIsAutoAssigned: true,
            idIsAnchored: true, name: name,
            displayName: displayName ?? name,
            address: GuestAddress(text: address), version: nil,
            operatingSystem: nil, connectedAt: Date(), isActive: active)
    }

    func testAnEmptyDriveMenuSaysSoRatherThanOpeningOntoNothing() {
        let holder = NSMenuItem(title: "Drive", action: nil, keyEquivalent: "")
        let menu = MainMenu.fillDriveMenu(holder, guests: [], target: self,
                                          action: #selector(noop))
        XCTAssertEqual(menu.items.map(\.title),
                       ["No Old World Macs Connected"])
        XCTAssertFalse(holder.isEnabled)
    }

    @objc private func noop() {}
}
