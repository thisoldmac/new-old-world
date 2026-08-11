import Foundation
import XCTest
@testable import Host
@testable import NOWAgentIntegration

/// An ADDRESSED agent request against a real machine — `guestSelector`, over
/// the wire it was built for.
///
///     NOW_METAL=1 NOW_METAL_PORT=5251 NOW_METAL_MACHINE=10.91.5.47 \
///       swift test --package-path now-host --filter MetalAddressingTests
///
/// Opt-in; with `NOW_METAL` set it FAILS rather than skips.
///
/// ---- Why this gate exists ---------------------------------------------
///
/// The machine-id / session-id scheme shipped 2026-07-28 and was broken by
/// its own codec until 2026-07-29: `guestSelector` was absent from
/// `decodeRequest`'s strict allowlist, so every request that actually named
/// a machine was rejected as invalid, and `notAddressed` was absent from the
/// response allowlist, so the refusal arrived as a protocol error. Both are
/// fixed and unit-tested (`AgentIntegrationAddressingCodecTests`). Neither
/// had ever been sent to a machine.
///
/// A gate for addressing has to prove two things, and the second is the
/// feature:
///
/// 1. **Naming the connected machine is answered on its merits.** The id
///    comes from the host's own roster, and the answer has to be the real
///    machine's — this asks for its process table and looks for the Finder,
///    because "answered" and "answered by the Mac" are different claims.
/// 2. **Naming a machine that is not this one is REFUSED**, with the reason
///    naming what is connected — never quietly answered by whichever guest
///    happened to be there. Being handed the wrong Mac's process table while
///    believing you asked about yours is the whole failure addressing
///    exists to prevent.
///
/// ---- What one connected machine can and cannot prove -------------------
///
/// There are three distinct refusals, and they are not interchangeable:
///
/// | selector | refusal |
/// |---|---|
/// | a machine that is not connected | `now-guest-not-connected` |
/// | a session id whose connection has ended | `now-guest-session-ended` |
/// | a machine that IS connected but is not the one being driven | `now-guest-not-addressed` |
///
/// **With one machine connected only the first two are reachable**, and this
/// file asserts those two and says so rather than pretending otherwise. The
/// third needs a second guest connected to the same listener at the same
/// time — the host refuses it precisely because it will not re-point the
/// console out from under whoever is sitting at the machine, so the state it
/// describes cannot exist with a single connection. When a second guest is
/// present the case runs; `testAConnectedButNotDrivenMachineIsRefused`
/// reports exactly what it needed when it is not.
@MainActor
final class MetalAddressingTests: XCTestCase {
    private var surface: MetalAgentLocalSurface!
    private var port: UInt16 = 5251

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["NOW_METAL"] != nil,
                          "set NOW_METAL=1 to run against the Mac")
        port = env["NOW_METAL_PORT"].flatMap { UInt16($0) } ?? 5251
        try MetalMachineGuard.preflight(port: port)
        surface = MetalAgentLocalSurface(port: port)
        try surface.start()
    }

    override func tearDown() async throws {
        surface?.stop()
        surface = nil
    }

    // MARK: - The machine, as the host addresses it

    /// The roster is the only place a caller can learn the id it must pass,
    /// so it is read here and printed: an id nobody can discover is not an
    /// addressing scheme.
    private func driven() throws -> ConnectedGuest {
        let guests = surface.listener.guests
        for guest in guests {
            print("=== roster: id=\(guest.id.slug) "
                  + "session=\(guest.sessionID) name=\(guest.name) "
                  + "address=\(guest.address.text) "
                  + "auto=\(guest.idIsAutoAssigned) "
                  + "anchored=\(guest.idIsAnchored) "
                  + "active=\(guest.isActive) ===")
        }
        return try XCTUnwrap(guests.first(where: \.isActive),
                             "no guest is being driven")
    }

    /// Naming the machine that is connected, and being answered by it.
    ///
    /// `process.list` rather than `session_health`, deliberately: health is
    /// answered from host state and would be a green light for a wire that
    /// had gone quiet. A process table has to come off the Macintosh, so an
    /// answer containing the Finder is proof the addressed request reached
    /// the machine the caller named.
    func testNamingTheConnectedMachineIsAnsweredByThatMachine() async throws {
        try await surface.waitForGuest()
        try await surface.requireTheBuildUnderTest()
        let guest = try driven()

        let client = try surface.localClient(addressing: guest.id.slug)
        let result = try await client.listProcesses()
        guard case .available(let snapshot) = result else {
            guard case .unavailable(let why) = result else { return }
            return XCTFail("""
                An addressed request naming \(guest.id.slug) — the machine \
                this host IS driving — was refused: [\(why.code)] \
                \(why.message). That is the codec defect's signature if the \
                code is now-host-invalid-response.
                """)
        }

        XCTAssertEqual(snapshot.guest?.id, guest.id.slug, """
            The answer does not say it came from the machine that was named, \
            so a caller cannot tell whose process table it is holding.
            """)
        XCTAssertEqual(snapshot.guest?.sessionID, guest.sessionID)
        XCTAssertFalse(snapshot.processes.isEmpty,
                       "a running Mac has at least the Finder")
        XCTAssertTrue(snapshot.processes.contains { $0.kind == .finder },
                      "no Finder in the answer, so this is not a live "
                          + "classic Mac's process table: "
                          + snapshot.processes.map(\.name)
                              .joined(separator: ", "))
        print("=== \(guest.id.slug) answered an ADDRESSED process.list with "
              + "\(snapshot.processes.count) processes ===")
        XCTAssertEqual(surface.selectorsSeen.last, guest.id.slug,
                       "the host never saw the machine the caller named")
    }

    /// The session-id form of the same thing. It goes through one field, and
    /// the codec must not develop an opinion about which form it holds.
    func testNamingThisConnectionBySessionIdIsAnswered() async throws {
        try await surface.waitForGuest()
        try await surface.requireTheBuildUnderTest()
        let guest = try driven()

        let client = try surface.localClient(addressing: guest.sessionID)
        let health = try await client.sessionHealth()
        guard case .available(let snapshot) = health else {
            return XCTFail("addressing this connection by its session id "
                           + "was refused: \(health)")
        }
        XCTAssertEqual(snapshot.state, .connected)
        XCTAssertEqual(snapshot.guest?.reference?.sessionID, guest.sessionID)
    }

    // MARK: - The refusals

    /// A machine that is not connected is refused, and the refusal arrives
    /// AS a refusal.
    ///
    /// Both halves matter. If the host answered, a caller asking about a Mac
    /// that is switched off would be handed this one's answer; if the
    /// refusal arrived as `now-host-invalid-response` — which is what it did
    /// before 2026-07-29 — a caller would be told to retry the one thing
    /// that cannot work.
    func testNamingAMachineThatIsNotConnectedIsRefusedNotAnswered()
        async throws {
        try await surface.waitForGuest()
        try await surface.requireTheBuildUnderTest()
        let guest = try driven()
        let stranger = "no-such-mac-\(UInt32.random(in: 1000...9999))"
        XCTAssertNotEqual(stranger, guest.id.slug)

        let client = try surface.localClient(addressing: stranger)
        do {
            let answered = try await client.listProcesses()
            return XCTFail("""
                A request naming \(stranger) — nothing this host has ever \
                seen — was ANSWERED: \(answered). The answer can only have \
                come from \(guest.id.slug), which is the substitution this \
                whole scheme exists to prevent.
                """)
        } catch AgentIntegrationLocalTransportError.notAddressed(let refusal) {
            XCTAssertEqual(refusal.code, "now-guest-not-connected",
                           refusal.message)
            XCTAssertTrue(refusal.message.contains(stranger),
                          "the refusal does not name what was asked for: "
                              + refusal.message)
            print("=== \(stranger): [\(refusal.code)] \(refusal.message) ===")
        }
        XCTAssertEqual(surface.selectorsSeen.last, stranger)
    }

    /// A session id for a connection that has ended is its own refusal, and
    /// not "nothing is connected": only one of those two facts is fixed by
    /// reconnecting, and the message says which.
    ///
    /// The dead session id is composed from the LIVE machine's id with a
    /// different UUID, which is exactly the shape of the string an agent
    /// holds after a reconnection.
    func testAStaleSessionIdIsRefusedAsAnEndedSession() async throws {
        try await surface.waitForGuest()
        try await surface.requireTheBuildUnderTest()
        let guest = try driven()
        let stale = GuestKey(machine: guest.id, session: UUID()).text
        XCTAssertNotEqual(stale, guest.sessionID)

        let client = try surface.localClient(addressing: stale)
        do {
            let answered = try await client.sessionHealth()
            return XCTFail("""
                A dead session id was answered: \(answered). An agent that \
                cached one across a reconnection would believe it was still \
                talking to the same connection.
                """)
        } catch AgentIntegrationLocalTransportError.notAddressed(let refusal) {
            XCTAssertEqual(refusal.code, "now-guest-session-ended",
                           refusal.message)
            print("=== stale session: [\(refusal.code)] "
                  + "\(refusal.message) ===")
        }
    }

    /// The case the feature is FOR: a machine that is connected but is not
    /// the one being driven.
    ///
    /// It needs two guests on one listener, and it is written to run when
    /// there are — pointing a second machine, or an emulator, at the same
    /// `NOW_METAL_PORT` is all it takes. With one connection the state
    /// cannot exist, so this reports what it would have needed instead of
    /// asserting something weaker under the same name. A skip that says why
    /// is worth more than a green that covered a different case.
    func testAConnectedButNotDrivenMachineIsRefused() async throws {
        try await surface.waitForGuest()
        try await surface.requireTheBuildUnderTest()
        let driven = try self.driven()
        var peer: Process?
        defer { peer?.terminate() }
        if surface.listener.guests.count < 2 {
            peer = try await secondPeer()
        }
        guard let other = surface.listener.guests
            .first(where: { !$0.isActive }) else {
            print("""
                === now-guest-not-addressed was NOT exercised: only \
                \(driven.id.slug) is connected, and this refusal means \
                "connected but not driven", which one connection cannot be. \
                To cover it, connect a second guest to port \(port) while \
                this run waits — a second Mac, a QEMU guest, or set \
                NOW_METAL_SECOND_PEER to a command that dials it (see \
                secondPeer below) — and it will assert the refusal against \
                whichever one the host is not driving.
                """)
            throw XCTSkip("needs a second connected guest; see the note above")
        }
        print("=== driven=\(driven.id.slug) (\(driven.address.text)) "
              + "other=\(other.id.slug) (\(other.address.text)) ===")

        let client = try surface.localClient(addressing: other.id.slug)
        do {
            let answered = try await client.listProcesses()
            return XCTFail("""
                A request naming \(other.id.slug), which is connected but \
                NOT being driven, was answered: \(answered). That answer \
                came from \(driven.id.slug) — the wrong Mac, wearing the \
                right name.
                """)
        } catch AgentIntegrationLocalTransportError.notAddressed(let refusal) {
            XCTAssertEqual(refusal.code, "now-guest-not-addressed",
                           refusal.message)
            XCTAssertTrue(refusal.message.contains(other.id.slug))
            XCTAssertTrue(refusal.message.contains(driven.id.slug), """
                The refusal does not name the machine that IS being driven, \
                so it does not say what to do next: \(refusal.message)
                """)
            print("=== \(other.id.slug) vs \(driven.id.slug): "
                  + "[\(refusal.code)] \(refusal.message) ===")
        }
    }

    /// Brings up a SECOND connected guest, when the run names a command that
    /// can.
    ///
    ///     NOW_METAL_SECOND_PEER="tools/fakeguest.py --kind 68k --port 5251"
    ///
    /// **What the second peer's identity does and does not prove.** The
    /// refusal under test is a decision the HOST makes: it has two live
    /// sessions, it is driving one, and a caller named the other. Nothing
    /// about that decision depends on what the other end of the second
    /// socket is — only on its being there — and the machine that matters,
    /// the one being DRIVEN, is the real PowerBook throughout.
    ///
    /// So a run with `tools/fakeguest.py` as the second peer is evidence
    /// about the addressing decision and is NOT evidence about any guest:
    /// that peer is hand-written from the contract, and AGENTS.md is
    /// explicit that nothing verified against it may be called
    /// metal-verified. Say which of the two claims a run supports. A second
    /// real Mac on the same port needs none of this and is strictly better.
    private func secondPeer() async throws -> Process? {
        guard let command = ProcessInfo.processInfo
            .environment["NOW_METAL_SECOND_PEER"], !command.isEmpty else {
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        // The repository root, so a relative command reads the way it would
        // be typed at a shell there.
        process.currentDirectoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // HostTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // now-host
            .deletingLastPathComponent()   // the repository
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        print("=== second peer: \(command) ===")

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, surface.listener.guests.count < 2 {
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard surface.listener.guests.count >= 2 else {
            process.terminate()
            XCTFail("""
                NOW_METAL_SECOND_PEER was set and no second guest appeared \
                within 30s, so the refusal this test exists for still has \
                not been exercised. That is a failure rather than a skip: a \
                run that asked for the case and did not get it must not read \
                the same as one that never asked.
                """)
            throw XCTSkip("the second peer never connected")
        }
        // Let its hello settle into the roster before it is addressed.
        try await Task.sleep(nanoseconds: 500_000_000)
        return process
    }

    /// An unaddressed request — what every existing caller sends — still
    /// means "the machine this host is driving", over the real socket.
    ///
    /// It is the regression that would be least visible: the addressing
    /// field is optional, and a host that started requiring it would break
    /// every caller at once.
    func testAnUnaddressedRequestStillReachesTheDrivenMachine() async throws {
        try await surface.waitForGuest()
        try await surface.requireTheBuildUnderTest()
        let guest = try driven()

        let health = try await surface.localClient().sessionHealth()
        guard case .available(let snapshot) = health else {
            return XCTFail("an unaddressed request was refused: \(health)")
        }
        XCTAssertEqual(snapshot.state, .connected)
        XCTAssertEqual(snapshot.guest?.reference?.id, guest.id.slug)
        XCTAssertNil(surface.selectorsSeen.last ?? nil,
                     "the host saw a selector nobody sent")
    }
}
