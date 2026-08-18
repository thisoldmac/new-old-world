import XCTest
@testable import Host

/// **A machine profile's own port, and what it is for.**
///
/// The wire port used to be app-scoped: one listener on one settings value.
/// Two Macs behind an emulator therefore arrived at the same socket, from
/// the same loopback address, wearing the same product fingerprint — and
/// the only thing left to tell them apart was `slot`, handed out in the
/// order they happened to dial. Restart them in the other order and they
/// swapped identities, taking each other's names and history with them.
///
/// These tests are about the port being an ANCHOR rather than a note of
/// where a guest turned up. The first one is the whole point of the change;
/// the rest are the ways the change could quietly not be an improvement.
@MainActor
final class GuestProfilePortTests: XCTestCase {

    /// Every emulated guest looks like this: same address, same fingerprint.
    private let loopback = GuestAddress(text: "127.0.0.1")
    private let guestName = "New Old World 0.2"
    private let os = "9.1"

    private func identify(_ book: GuestRegistry, port: UInt16?,
                          occupied: Set<Int> = []) -> GuestRegistry.Record {
        book.identify(address: loopback, name: guestName, operatingSystem: os,
                      occupiedSlots: occupied, listenPort: port)
    }

    // MARK: - The failure this exists to remove

    func testTwoMachinesOnTheirOwnPortsKeepTheirIdsWhicheverDialsFirst() {
        let book = GuestRegistry()
        let first = identify(book, port: 5250)
        let second = identify(book, port: 5251)
        XCTAssertNotEqual(first.id, second.id,
                          "two ports are two machines, not one")

        /* The same two Macs, dialling in the opposite order — a reboot, or
           one of them being slower to come up. Under slot-ordering alone
           this is where they traded identities. */
        let secondAgain = identify(book, port: 5251)
        let firstAgain = identify(book, port: 5250)
        XCTAssertEqual(firstAgain.id, first.id)
        XCTAssertEqual(secondAgain.id, second.id)
        XCTAssertEqual(book.known.count, 2,
                       "and neither redial minted a phantom machine")
    }

    func testASlotIsCountedWithinAPortAndNotAcrossPorts() {
        let book = GuestRegistry()
        let first = identify(book, port: 5250)
        /* The listener passes the slots it has LIVE for this anchor. A Mac
           on its own port shares no anchor with the one on 5250, so it must
           be offered slot 0 too — counting them together would push it to
           slot 1 and re-create the ordering the port removes. */
        let second = identify(book, port: 5251, occupied: [])
        XCTAssertEqual(first.slot, 0)
        XCTAssertEqual(second.slot, 0)
        XCTAssertNotEqual(first.key, second.key,
                          "the port keeps the keys apart, not the slot")
    }

    func testTwoMachinesSharingOnePortStillFallBackToSlots() {
        let book = GuestRegistry()
        let first = identify(book, port: 5250)
        let second = identify(book, port: 5250, occupied: [first.slot])
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(second.slot, 1,
                       "the old disambiguation is still there for machines "
                           + "nobody has separated yet")
    }

    /// **The port anchors only where the address cannot.**
    ///
    /// The counterpart to the test above, and the reason the rule is not
    /// simply "the port is part of the key". A PowerBook on the LAN that a
    /// person repoints at another port is the same PowerBook: address and
    /// fingerprint already identify it, and treating the new port as a new
    /// machine would turn an ordinary reconfiguration into the silent loss
    /// of its name and its history.
    func testAMachineAtARoutableAddressKeepsItsNameWhenItsPortChanges() {
        let book = GuestRegistry()
        let lan = GuestAddress(text: "10.0.0.7")
        let first = book.identify(address: lan, name: guestName,
                                  operatingSystem: os, occupiedSlots: [],
                                  listenPort: 5250)
        book.renameDisplayName(first.key, to: "The PowerBook")

        let moved = book.identify(address: lan, name: guestName,
                                  operatingSystem: os, occupiedSlots: [],
                                  listenPort: 5251)
        XCTAssertEqual(moved.id, first.id)
        XCTAssertEqual(moved.displayName, "The PowerBook")
        XCTAssertEqual(book.known.count, 1)
    }

    // MARK: - The desks that already exist

    func testARecordWrittenBeforePortsIsAdoptedRatherThanDuplicated() throws {
        let suite = "GuestProfilePortTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storageKey = "legacy-record"
        let print = GuestRegistry.fingerprint(name: guestName,
                                              operatingSystem: os)
        let id = try XCTUnwrap(GuestID("pb1400c"))
        let legacy = GuestRegistry.Record(
            id: id, address: "127.0.0.1", fingerprint: print,
            slot: 0, autoAssigned: false, lastSeen: Date(),
            lastName: guestName, displayName: "The PowerBook", listenPort: nil)
        let stored: [GuestRegistry.Record] = [legacy]
        defaults.set(try JSONEncoder().encode(stored), forKey: storageKey)

        let book = GuestRegistry(defaults: defaults, storageKey: storageKey)
        let seen = identify(book, port: 5250)

        XCTAssertEqual(book.known.count, 1,
                       "an upgrade must not double every remembered machine")
        XCTAssertEqual(seen.id, legacy.id, "the id a person types survives")
        XCTAssertEqual(seen.displayName, "The PowerBook")
        XCTAssertEqual(seen.listenPort, 5250,
                       "and it is exact from now on, not adopted again")
    }

    func testADeskWithNoAssignedPortsBindsOnlyItsDefault() {
        let book = GuestRegistry()
        _ = identify(book, port: 5250)
        XCTAssertEqual(book.portsToBind(base: 5250), [5250])
    }

    func testEveryProfilePortIsBoundAndTheDefaultLeads() {
        let book = GuestRegistry()
        _ = identify(book, port: 5251)
        _ = identify(book, port: 5252)
        _ = identify(book, port: 5251)
        XCTAssertEqual(book.portsToBind(base: 5250), [5250, 5251, 5252],
                       "deduplicated, and the default first so boundPort "
                           + "still means the host's own port")
    }

    // MARK: - Giving a machine its port

    func testAssigningAPortMovesTheProfileAndKeepsWhoItIs() {
        let book = GuestRegistry()
        let record = identify(book, port: 5250)
        book.renameDisplayName(record.key, to: "Quadra")

        XCTAssertEqual(book.setListenPort(record.key, to: 5251),
                       .success(5251))
        let moved = book.record(for: record.id)
        XCTAssertEqual(moved?.listenPort, 5251)
        XCTAssertEqual(moved?.displayName, "Quadra",
                       "the machine moved, not its identity")
        XCTAssertEqual(book.portsToBind(base: 5250), [5250, 5251])
    }

    func testAPortAnotherProfileClaimsIsRefusedAndNamesTheHolder() {
        let book = GuestRegistry()
        let first = identify(book, port: 5251)
        book.renameDisplayName(first.key, to: "Quadra")
        let second = identify(book, port: 5252)

        /* Two profiles on one port is not something the listener could
           report: it binds once and serves both. The person would believe
           they had separated two Macs and would be wrong, silently. */
        XCTAssertEqual(book.setListenPort(second.key, to: 5251),
                       .failure(.taken(by: "Quadra")))
        XCTAssertEqual(book.record(for: second.id)?.listenPort, 5252)
    }

    func testAnEphemeralPortIsNotAProfilesPort() {
        let book = GuestRegistry()
        let record = identify(book, port: 5250)
        XCTAssertEqual(book.setListenPort(record.key, to: 0),
                       .failure(.reserved),
                       "nothing could be told to dial it")
    }

    func testClearingAPortReturnsTheMachineToTheHostDefault() {
        let book = GuestRegistry()
        let record = identify(book, port: 5251)
        XCTAssertEqual(book.setListenPort(record.key, to: nil), .success(nil))
        XCTAssertEqual(book.portsToBind(base: 5250), [5250])
    }

    // MARK: - Through a real listener

    /// **Two sockets, two machines, and the order they dial in must stop
    /// mattering.**
    ///
    /// The registry tests above hand `identify` a port directly, so they
    /// cannot see the two places the listener could still throw it away:
    /// filing every connection under the first listener's port, and
    /// counting live slots across ports instead of within one. Both leave
    /// the book looking right and the desk behaving exactly as it did
    /// before this change — which is the failure that would ship.
    func testTwoGuestsOnTwoPortsHoldTheirIdsAcrossAReversedRedial()
        async throws {
        let listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"),
            timing: .init(idleTimeout: 60))
        defer { listener.stop() }
        /* Two CONCRETE ports, because two profiles are two configured
           numbers. `start(ports: [0, 0])` is one request for an ephemeral
           port asked twice, and is deduplicated to one socket — which is
           right for the product and useless here. Walking a lane keeps two
           runs in two worktrees off each other's numbers. */
        var ports: [UInt16] = []
        for attempt in 0..<8 {
            let base = UInt16(42_000 + (Int(getpid()) % 200) * 8 + attempt * 2)
            listener.start(ports: [base, base + 1])
            /* `boundPorts` is populated the moment the listeners are made,
               so waiting on it alone would dial sockets that are not
               accepting yet. Readiness is the state going `.listening`. */
            try await waitUntil("listening") {
                !listener.failedPorts.isEmpty
                    || listener.readyPorts.count == 2
            }
            ports = listener.failedPorts.isEmpty ? listener.boundPorts : []
            if ports.count == 2 { break }
            listener.stop()
        }
        try XCTSkipIf(ports.count != 2, "no free adjacent pair on this Mac")

        /* Both Macs say the same thing about themselves, from the same
           address. This is what an emulated pair looks like, and it is
           why nothing but the port can separate them. */
        func dial(_ port: UInt16) throws -> FakeGuest {
            let guest = FakeGuest(port: port)
            guest.start()
            try guest.send(.hello(Hello(
                contract: Contract.revision, side: "guest", version: "0.1.0",
                name: guestName, os: os, chunk: 8192)))
            return guest
        }

        var first: FakeGuest? = try dial(ports[0])
        var second: FakeGuest? = try dial(ports[1])
        try await waitUntil("both connected") { listener.guests.count == 2 }

        var byPort: [UInt16: String] = [:]
        for guest in listener.guests { byPort[guest.listenPort ?? 0] = guest.id.slug }
        XCTAssertEqual(Set(listener.guests.map { $0.listenPort ?? 0 }),
                       Set(ports),
                       "each guest is filed under the socket it arrived on, "
                           + "not under whichever listener came first")
        XCTAssertEqual(byPort.count, 2, "two sockets, two entries")
        XCTAssertEqual(Set(byPort.values).count, 2)

        first?.connection.cancel()
        second?.connection.cancel()
        first = nil
        second = nil
        try await waitUntil("both gone") { listener.guests.isEmpty }

        /* The reboot. Under a slot count that ignores the port, the Mac
           that now dials first takes slot 0 — a slot its own port has
           never used — and walks away with a brand new identity. */
        let secondAgain = try dial(ports[1])
        defer { secondAgain.connection.cancel() }
        try await waitUntil("second back") { listener.guests.count == 1 }
        let firstAgain = try dial(ports[0])
        defer { firstAgain.connection.cancel() }
        try await waitUntil("both back") { listener.guests.count == 2 }

        for guest in listener.guests {
            XCTAssertEqual(guest.id.slug, byPort[guest.listenPort ?? 0],
                           "the machine on \(guest.listenPort ?? 0) is the "
                               + "same machine it was before the reboot")
        }
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5,
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
