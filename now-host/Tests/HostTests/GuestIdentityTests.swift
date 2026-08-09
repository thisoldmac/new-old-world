import XCTest
import NOWAgentIntegration
@testable import Host

/// The three identities, and the rules that keep them apart.
///
/// Everything here is about the failure the old model had: `hello.name`
/// was the identity, so two Macs with one name were one guest and every
/// redeploy — which changes that name, because it is the deployed
/// binary's — minted a phantom machine.
@MainActor
final class GuestIdentityTests: XCTestCase {

    // MARK: - The registry's rules

    private func registry() -> GuestRegistry { GuestRegistry() }

    func testDisplayNamesDefaultToTheMachineNameAndNumberDuplicates() {
        let book = registry()
        let first = book.identify(
            address: GuestAddress(text: "10.0.0.1"),
            name: "PowerBook 1400c", operatingSystem: "9.1",
            occupiedSlots: [])
        let second = book.identify(
            address: GuestAddress(text: "10.0.0.2"),
            name: "PowerBook 1400c", operatingSystem: "9.1",
            occupiedSlots: [])
        let third = book.identify(
            address: GuestAddress(text: "10.0.0.3"),
            name: "PowerBook 1400c", operatingSystem: "9.1",
            occupiedSlots: [])

        XCTAssertEqual(first.displayName, "PowerBook 1400c")
        XCTAssertEqual(second.displayName, "PowerBook 1400c-2")
        XCTAssertEqual(third.displayName, "PowerBook 1400c-3")
    }

    func testACustomDisplayNamePersistsAcrossReconnects() {
        let book = registry()
        let first = book.identify(
            address: GuestAddress(text: "10.0.0.1", port: 49152),
            name: "PowerBook 1400c", operatingSystem: "9.1",
            occupiedSlots: [])

        XCTAssertEqual(book.renameDisplayName(first.key, to: "Desk Mac"),
                       .success("Desk Mac"))
        let reconnected = book.identify(
            address: GuestAddress(text: "10.0.0.1", port: 49153),
            name: "PowerBook 1400c", operatingSystem: "9.1",
            occupiedSlots: [])

        XCTAssertEqual(reconnected.displayName, "Desk Mac")
    }

    func testObservedEndpointFormatsIPAndPort() {
        XCTAssertEqual(
            GuestAddress(text: "10.0.0.1", port: 49152).endpointText,
            "10.0.0.1:49152")
        XCTAssertEqual(
            GuestAddress(text: "fe80::1", port: 49152).endpointText,
            "[fe80::1]:49152")
    }

    func testForgettingAMachineRemovesOnlyThatRememberedRecord() {
        let registry = registry()
        let first = registry.identify(
            address: GuestAddress(text: "10.0.0.1"), name: "First",
            operatingSystem: "9.1", occupiedSlots: [])
        let second = registry.identify(
            address: GuestAddress(text: "10.0.0.2"), name: "Second",
            operatingSystem: "8.6", occupiedSlots: [])

        XCTAssertTrue(registry.forget(first.key))
        XCTAssertFalse(registry.forget(first.key))
        XCTAssertEqual(registry.known.map(\.id), [second.id])
    }

    func testForgettingOneLegacyDuplicateIdKeepsTheOtherRecord() throws {
        let suite = "GuestIdentityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = GuestID("q950")!
        let first = GuestRegistry.Record(
            id: id, address: "127.0.0.1", fingerprint: "now|9.1",
            slot: 0, autoAssigned: false, lastSeen: Date(),
            lastName: "First")
        let second = GuestRegistry.Record(
            id: id, address: "127.0.0.1", fingerprint: "now|9.1",
            slot: 1, autoAssigned: false, lastSeen: Date(),
            lastName: "Second")
        let storageKey = "legacy-duplicates"
        defaults.set(try JSONEncoder().encode([first, second]),
                     forKey: storageKey)
        let registry = GuestRegistry(defaults: defaults,
                                     storageKey: storageKey)

        XCTAssertTrue(registry.forget(first.key))
        XCTAssertEqual(registry.known.map(\.key), [second.key])
    }

    func testForgottenOrdinalsAreNeverReassigned() {
        let book = registry()
        let first = book.identify(
            address: GuestAddress(text: "10.0.0.1"), name: "First",
            operatingSystem: "9.1", occupiedSlots: [])
        XCTAssertEqual(first.id.slug, "guest-1")
        XCTAssertTrue(book.forget(first.key))

        let later = book.identify(
            address: GuestAddress(text: "10.0.0.2"), name: "Later",
            operatingSystem: "8.6", occupiedSlots: [])
        XCTAssertEqual(later.id.slug, "guest-2",
                       "a stale guest-1 selector must not reach Later")
    }

    func testAFirstSightMachineIsAddressableWithNoConfiguration() {
        let book = registry()
        let record = book.identify(
            address: GuestAddress(text: "10.91.5.180"),
            name: "NOW Guest 0.14", operatingSystem: "9.1",
            occupiedSlots: [])
        XCTAssertEqual(record.id.slug, "guest-1")
        XCTAssertTrue(record.autoAssigned,
                      "an ordinal addresses the machine and claims "
                          + "nothing about it")
    }

    /// The correction that started this: an identifier that changes every
    /// time you deploy is not an identifier.
    func testTheIdSurvivesARedeployThatRenamesTheGuest() {
        let book = registry()
        let before = book.identify(
            address: GuestAddress(text: "10.91.5.180"),
            name: "NOW Guest 0.14", operatingSystem: "9.1",
            occupiedSlots: [])
        _ = book.rename(before.id, to: "pb1400c")
        let after = book.identify(
            address: GuestAddress(text: "10.91.5.180"),
            name: "NOW Guest 0.15", operatingSystem: "9.1",
            occupiedSlots: [])
        XCTAssertEqual(after.id.slug, "pb1400c")
        XCTAssertFalse(after.autoAssigned)
    }

    /// The other half of the same rule: a stranger that picks up the old
    /// lease must not inherit the name of the Mac that used to hold it.
    func testADifferentMachineAtTheSameAddressDoesNotInheritTheId() {
        let book = registry()
        let first = book.identify(
            address: GuestAddress(text: "10.91.5.180"),
            name: "NOW Guest 0.14", operatingSystem: "9.1",
            occupiedSlots: [])
        _ = book.rename(first.id, to: "pb1400c")
        let stranger = book.identify(
            address: GuestAddress(text: "10.91.5.180"),
            name: "Some Other Guest 1.0", operatingSystem: "7.1",
            occupiedSlots: [])
        XCTAssertNotEqual(stranger.id.slug, "pb1400c")
        XCTAssertTrue(stranger.autoAssigned)
    }

    /// A DHCP lease change costs one rename and never a silent rebind.
    func testARedialFromANewAddressIsANewRecord() {
        let book = registry()
        let first = book.identify(
            address: GuestAddress(text: "10.91.5.180"),
            name: "NOW Guest 0.14", operatingSystem: "9.1",
            occupiedSlots: [])
        _ = book.rename(first.id, to: "pb1400c")
        let moved = book.identify(
            address: GuestAddress(text: "10.91.5.200"),
            name: "NOW Guest 0.14", operatingSystem: "9.1",
            occupiedSlots: [])
        XCTAssertNotEqual(moved.id.slug, "pb1400c")
        XCTAssertEqual(book.record(for: GuestID("pb1400c")!)?.address,
                       "10.91.5.180",
                       "the old binding is intact, not moved behind "
                           + "somebody's back")
    }

    func testARenameOntoATakenIdIsRefusedAndNamesTheHolder() {
        let book = registry()
        let first = book.identify(
            address: GuestAddress(text: "10.91.5.180"),
            name: "NOW Guest 0.14", operatingSystem: "9.1",
            occupiedSlots: [])
        let second = book.identify(
            address: GuestAddress(text: "10.91.5.181"),
            name: "NOW Guest 0.14", operatingSystem: "9.1",
            occupiedSlots: [])
        XCTAssertEqual(book.rename(first.id, to: "pb1400c"),
                       .success(GuestID("pb1400c")!))
        guard case .failure(.taken(let holder)) =
            book.rename(second.id, to: "pb1400c") else {
            return XCTFail("a second machine must not take a live id")
        }
        XCTAssertEqual(holder, "NOW Guest 0.14")
        XCTAssertNotEqual(book.record(for: second.id)?.id.slug, "pb1400c")
    }

    func testARenameOntoATakenIdIsRefusedAtTheSameAddress() {
        let book = registry()
        let loopback = GuestAddress(text: "127.0.0.1")
        let first = book.identify(
            address: loopback, name: "NOW Guest 0.14",
            operatingSystem: "9.1", occupiedSlots: [])
        let second = book.identify(
            address: loopback, name: "NOW Guest 0.14",
            operatingSystem: "9.1", occupiedSlots: [first.slot])
        XCTAssertEqual(book.rename(first.id, to: "q950"),
                       .success(GuestID("q950")!))
        guard case .failure(.taken) = book.rename(second.id, to: "q950")
        else { return XCTFail("loopback must not permit duplicate ids") }
    }

    /// Where the address cannot tell machines apart, the slot does — and
    /// two concurrent guests still get two ids rather than collapsing.
    func testTwoMachinesAtOneAddressGetTwoIds() {
        let book = registry()
        let loopback = GuestAddress(text: "127.0.0.1")
        let first = book.identify(
            address: loopback, name: "NOW Guest 0.14",
            operatingSystem: "9.1", occupiedSlots: [])
        let second = book.identify(
            address: loopback, name: "NOW Guest 0.14",
            operatingSystem: "9.1", occupiedSlots: [first.slot])
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertFalse(loopback.distinguishesMachines,
                       "and the host says out loud that it is guessing")
    }

    func testTheVersionIsStrippedButAModelNumberIsNot() {
        XCTAssertEqual(
            GuestRegistry.fingerprint(name: "NOW Guest 0.14",
                                      operatingSystem: "9.1"),
            GuestRegistry.fingerprint(name: "NOW Guest 0.15",
                                      operatingSystem: "9.1"))
        XCTAssertNotEqual(
            GuestRegistry.fingerprint(name: "PowerBook 1400c",
                                      operatingSystem: "9.1"),
            GuestRegistry.fingerprint(name: "PowerBook 180c",
                                      operatingSystem: "9.1"))
    }

    // MARK: - The session id

    func testASessionIdRoundTripsAndAMachineIdIsNotOne() throws {
        let key = GuestKey(machine: GuestID("pb1400c")!, session: UUID())
        XCTAssertEqual(GuestKey.parse(key.text), key)
        XCTAssertEqual(GuestKey.parse(key.text)?.machine.slug, "pb1400c")
        XCTAssertNil(GuestKey.parse("pb1400c"),
                     "a machine id must not read as a session id")
        XCTAssertNil(GuestKey.parse("guest-1"))
    }

    func testTwoSessionsWithOneMachineAreTwoSessionIds() {
        let machine = GuestID("pb1400c")!
        let first = GuestKey(machine: machine, session: UUID())
        let second = GuestKey(machine: machine, session: UUID())
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.machine, second.machine)
    }

    func testAnIdIsASlugOrItIsNothing() {
        XCTAssertNil(GuestID("PowerBook 1400c"))
        XCTAssertNil(GuestID("-leading"))
        XCTAssertNil(GuestID(""))
        XCTAssertEqual(GuestID.slugify("PowerBook 1400c")?.slug,
                       "powerbook-1400c")
        XCTAssertEqual(GuestID("pb1400c")?.slug, "pb1400c")
    }

    // MARK: - The wire, over loopback

    private func startedListener() async throws -> GuestListener {
        let listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"),
            timing: .init(idleTimeout: 60))
        listener.start(port: 0)
        try await waitUntil("listening") {
            if case .listening = listener.state { return true }
            return false
        }
        return listener
    }

    private func dial(_ listener: GuestListener, name: String) async throws
        -> FakeGuest {
        let guest = FakeGuest(port: try XCTUnwrap(listener.boundPort))
        guest.start()
        try guest.send(.hello(Hello(
            contract: Contract.revision, side: "guest", version: "0.1.0",
            name: name, os: "9.1", chunk: 8192)))
        return guest
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

    /// Both fake guests arrive from the loopback address, which is the
    /// honest shape of this desk: every emulated Mac does too. The roster
    /// must still be two rows with two handles, and must SAY that the id's
    /// survival across a reconnection is a guess here.
    func testTwoGuestsOfOneNameOverLoopbackAreTwoAddressableRows()
        async throws {
        let listener = try await startedListener()
        defer { listener.stop() }
        let first = try await dial(listener, name: "NOW Guest 0.14")
        let second = try await dial(listener, name: "NOW Guest 0.14")
        try await waitUntil("both connected") {
            listener.guests.count == 2
        }
        defer {
            first.connection.cancel()
            second.connection.cancel()
        }
        XCTAssertEqual(Set(listener.guests.map(\.id.slug)).count, 2)
        XCTAssertEqual(Set(listener.guests.map(\.sessionID)).count, 2)
        for guest in listener.guests {
            XCTAssertEqual(guest.address.text, "127.0.0.1")
            XCTAssertFalse(guest.idIsAnchored,
                           "the host cannot tell machines apart here and "
                               + "must not pretend it can")
        }
    }

    func testTheRosterPairsTheHandleWithTheAddress() async throws {
        let listener = try await startedListener()
        defer { listener.stop() }
        let guest = try await dial(listener, name: "NOW Guest 0.14")
        try await waitUntil("connected") { listener.guests.count == 1 }
        defer { guest.connection.cancel() }
        let row = try XCTUnwrap(listener.guests.first)
        XCTAssertEqual(row.address.text, "127.0.0.1")
        XCTAssertEqual(row.name, "NOW Guest 0.14")
        XCTAssertEqual(row.displayName, "NOW Guest 0.14")
        XCTAssertEqual(row.label, "NOW Guest 0.14")
        XCTAssertTrue(row.sessionID.hasPrefix("\(row.id.slug)-"))
        XCTAssertEqual(GuestKey.parse(row.sessionID), row.key)
    }

    func testRenamingAMachineRelabelsItsRowButNotItsLiveSessionId()
        async throws {
        let listener = try await startedListener()
        defer { listener.stop() }
        let guest = try await dial(listener, name: "NOW Guest 0.14")
        try await waitUntil("connected") { listener.guests.count == 1 }
        defer { guest.connection.cancel() }
        let before = try XCTUnwrap(listener.guests.first)
        XCTAssertEqual(listener.renameGuest(before.key, to: "PB 1400c"),
                       .success(GuestID("pb-1400c")!))
        let after = try XCTUnwrap(listener.guests.first)
        XCTAssertEqual(after.id.slug, "pb-1400c")
        XCTAssertFalse(after.idIsAutoAssigned)
        XCTAssertEqual(after.sessionID, before.sessionID,
                       "a caller holding this session id must keep being "
                           + "able to present it")
    }

    func testRenamingTheDisplayNameRepublishesWithoutChangingIdentity()
        async throws {
        let listener = try await startedListener()
        defer { listener.stop() }
        let guest = try await dial(listener, name: "PowerBook 1400c")
        try await waitUntil("connected") { listener.guests.count == 1 }
        defer { guest.connection.cancel() }
        let before = try XCTUnwrap(listener.guests.first)

        XCTAssertEqual(
            listener.renameGuestDisplayName(before.key, to: "Desk Mac"),
            .success("Desk Mac"))
        let after = try XCTUnwrap(listener.guests.first)
        XCTAssertEqual(after.displayName, "Desk Mac")
        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.sessionID, before.sessionID)
    }

    // MARK: - Addressing the agent projection

    func testAddressingTheDrivenMachineIsAllowedAndNamesItBack()
        async throws {
        let listener = try await startedListener()
        defer { listener.stop() }
        let guest = try await dial(listener, name: "NOW Guest 0.14")
        try await waitUntil("connected") { listener.guests.count == 1 }
        defer { guest.connection.cancel() }
        let adapter = AgentIntegrationHostAdapter(listener: listener)
        let row = try XCTUnwrap(listener.guests.first)

        XCTAssertNil(adapter.addressingRefusal(nil))
        XCTAssertNil(adapter.addressingRefusal(row.id.slug))
        XCTAssertNil(adapter.addressingRefusal(row.sessionID))

        guard case .available(let health) = adapter.sessionHealth() else {
            return XCTFail("expected a health snapshot")
        }
        XCTAssertEqual(health.guest?.reference?.id, row.id.slug)
        XCTAssertEqual(health.guest?.reference?.sessionID, row.sessionID)
        XCTAssertEqual(health.roster.map(\.id), [row.id.slug])
    }

    /// The requirement's sharp end: a caller that names the OTHER machine
    /// is refused, and is never answered by the one being driven.
    func testAddressingABackgroundMachineIsRefusedRatherThanRedirected()
        async throws {
        let listener = try await startedListener()
        defer { listener.stop() }
        let first = try await dial(listener, name: "NOW Guest 0.14")
        let second = try await dial(listener, name: "NOW Guest 0.14")
        try await waitUntil("both connected") { listener.guests.count == 2 }
        defer {
            first.connection.cancel()
            second.connection.cancel()
        }
        let adapter = AgentIntegrationHostAdapter(listener: listener)
        let background = try XCTUnwrap(
            listener.guests.first { !$0.isActive })
        let driven = try XCTUnwrap(listener.guests.first { $0.isActive })

        let refusal = try XCTUnwrap(
            adapter.addressingRefusal(background.id.slug))
        XCTAssertEqual(refusal.code, "now-guest-not-addressed")
        XCTAssertTrue(refusal.message.contains(driven.id.slug),
                      "the refusal must say which machine IS being driven")
        XCTAssertEqual(
            adapter.addressingRefusal(background.sessionID)?.code,
            "now-guest-not-addressed")
        // And the roster lets a caller discover both ids in the first place.
        guard case .available(let health) = adapter.sessionHealth() else {
            return XCTFail("expected a health snapshot")
        }
        XCTAssertEqual(Set(health.roster.map(\.id)),
                       [driven.id.slug, background.id.slug])
    }

    func testAStaleSessionIdIsToldItEndedRatherThanAnsweredBySuccessor()
        async throws {
        let listener = try await startedListener()
        defer { listener.stop() }
        let guest = try await dial(listener, name: "NOW Guest 0.14")
        try await waitUntil("connected") { listener.guests.count == 1 }
        defer { guest.connection.cancel() }
        let adapter = AgentIntegrationHostAdapter(listener: listener)
        let live = try XCTUnwrap(listener.guests.first)
        let ended = GuestKey(machine: live.key.machine, session: UUID()).text

        let refusal = try XCTUnwrap(adapter.addressingRefusal(ended))
        XCTAssertEqual(refusal.code, "now-guest-session-ended")
        // The machine id still reaches whatever is connected to it now —
        // the two addressing modes mean different things on purpose.
        XCTAssertNil(adapter.addressingRefusal(live.id.slug))
    }

    func testAnUnknownMachineIsNotConnectedRatherThanNotAddressed()
        async throws {
        let listener = try await startedListener()
        defer { listener.stop() }
        let guest = try await dial(listener, name: "NOW Guest 0.14")
        try await waitUntil("connected") { listener.guests.count == 1 }
        defer { guest.connection.cancel() }
        let adapter = AgentIntegrationHostAdapter(listener: listener)
        XCTAssertEqual(adapter.addressingRefusal("pb180c")?.code,
                       "now-guest-not-connected")
    }

    /// The session token the agent surface scopes its references to is the
    /// UUID inside the session id — one fact read two ways, rather than
    /// two facts free to disagree.
    func testTheAgentSessionTokenIsTheSessionIdsOwnUUID() async throws {
        let listener = try await startedListener()
        defer { listener.stop() }
        let guest = try await dial(listener, name: "NOW Guest 0.14")
        try await waitUntil("connected") { listener.guests.count == 1 }
        defer { guest.connection.cancel() }
        let adapter = AgentIntegrationHostAdapter(listener: listener)
        let row = try XCTUnwrap(listener.guests.first)
        XCTAssertEqual(adapter.connectedSessionID(), row.key.session)
    }
}
