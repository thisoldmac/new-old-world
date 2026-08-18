import XCTest
import Network
import MirrorKit
@testable import Host

@MainActor
private final class FakeContinuityUDP {
    private let listener: NWListener
    private(set) var ready = false
    private(set) var connection: NWConnection?
    private(set) var packets: [ContinuityStateDatagram] = []

    init(port: UInt16) throws {
        listener = try NWListener(
            using: .udp, on: NWEndpoint.Port(rawValue: port)!)
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .ready = state { self?.ready = true }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self else { return }
                self.connection = connection
                connection.start(queue: .main)
                self.receive(on: connection)
            }
        }
        listener.start(queue: .main)
    }

    func stop() {
        connection?.cancel()
        listener.cancel()
    }

    func acknowledge(_ packet: ContinuityStateDatagram,
                     reason: ContinuityAckDatagram.ExitReason = .none,
                     state: ContinuityAckDatagram.State = .active) {
        let ack = ContinuityAckDatagram(
            nonceHi: packet.nonceHi, nonceLo: packet.nonceLo,
            epoch: packet.epoch, positionSequence: packet.positionSequence,
            buttonGeneration: packet.buttonGeneration,
            arrivalTicks: 1, applyTicks: 2, rejectedPackets: 0,
            state: state, acceptedHz: packet.requestedHz,
            exitReason: reason)
        connection?.send(content: ContinuityDatagramCodec.encode(ack),
                         completion: .idempotent)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            Task { @MainActor in
                guard let self, let connection,
                      connection === self.connection else { return }
                if let data,
                   let packet = try? ContinuityDatagramCodec.decodeState(data) {
                    self.packets.append(packet)
                }
                if error == nil { self.receive(on: connection) }
            }
        }
    }
}

@MainActor
final class MirrorContinuityControllerTests: XCTestCase {
    private struct Timeout: Error {}
    private var listener: GuestListener!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!

    override func setUp() async throws {
        defaultsSuite = "MirrorContinuityControllerTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"),
            timing: .init(idleTimeout: 60))
        listener.start(port: 0)
        try await waitUntil("TCP listener") {
            if case .listening = self.listener.state { return true }
            return false
        }
    }

    override func tearDown() async throws {
        listener.stop()
        listener = nil
        defaults.removePersistentDomain(forName: defaultsSuite)
        defaults = nil
        defaultsSuite = nil
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 5,
                           _ condition: @escaping () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < end else {
                XCTFail("timed out waiting for \(message)")
                throw Timeout()
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func awaitPacket(
        in udp: FakeContinuityUDP, _ message: String,
        timeout: TimeInterval = 5,
        matching predicate: @escaping (ContinuityStateDatagram) -> Bool
    ) async throws -> ContinuityStateDatagram {
        try await waitUntil(message, timeout: timeout) {
            udp.packets.contains(where: predicate)
        }
        return try XCTUnwrap(udp.packets.last(where: predicate))
    }

    private struct ActiveRig {
        let guest: FakeGuest
        let udp: FakeContinuityUDP
        let controller: MirrorContinuityController
        let arm: ContinuityArm
    }

    func testNetworkDownNamesTheUnresolvedPermissionWithoutClaimingDenial() {
        XCTAssertEqual(
            MirrorContinuityController.pointerLaneWaitingStatus(
                .posix(.ENETDOWN)),
            "Waiting for macOS Local Network access. Approve its prompt or "
                + "enable NOW Continuity in System Settings > Privacy & "
                + "Security > Local Network.")
        XCTAssertEqual(
            MirrorContinuityController.pointerLaneFailure(.posix(.ENETDOWN)),
            "macOS has not granted the Local Network path; approve its prompt "
                + "or enable NOW Continuity in System Settings > Privacy & "
                + "Security > Local Network")
    }

    func testOtherPointerLaneErrorsKeepTheirSystemDescription() {
        let error = NWError.posix(.ECONNREFUSED)
        XCTAssertEqual(
            MirrorContinuityController.pointerLaneWaitingStatus(error),
            "waiting for the pointer lane: \(error.localizedDescription)")
        XCTAssertEqual(
            MirrorContinuityController.pointerLaneFailure(error),
            "UDP failed: \(error.localizedDescription)")
    }

    func testEnablingContinuityVerifiesTheActiveGuestPathBeforeMovement()
        async throws {
        let guest = FakeGuest(port: try XCTUnwrap(listener.boundPort))
        guest.start()
        try guest.send(.hello(Hello(
            contract: Contract.revision, side: "guest", version: "0.1.0",
            build: nil, agent: nil, name: "PowerBook 1400", os: "9.1",
            chunk: 8192)))
        try await waitUntil("host hello") { !guest.received.isEmpty }
        let expectedHost = try XCTUnwrap(
            listener.activeContinuityTarget?.host)
        let directConnection =
            FakeLocalNetworkDirectAccessConnection()
        var verifiedHosts: [String] = []
        let permission = LocalNetworkAccessController(
            audit: { _, _ in },
            makeConnection: { host, _ in
                verifiedHosts.append(host)
                return directConnection
            })
        let controller = MirrorContinuityController(
            listener: listener, defaults: defaults,
            localNetworkAccess: permission)

        controller.isEnabled = true

        XCTAssertEqual(verifiedHosts, [expectedHost])
        XCTAssertTrue(directConnection.started)
        XCTAssertEqual(controller.phase, .idle,
                       "direct verification must not seize guest input")
        XCTAssertTrue(controller.status.contains("Local Network access"))
    }

    func testPermissionApprovalRearmsAWaitingPointerLane() async throws {
        let rig = try await makeArmingRig()
        rig.controller.pointerLaneWaitingForLocalNetworkAccess()
        rig.controller.localNetworkAccessBecameReady()

        try await waitUntil("permission retry arm", timeout: 2) {
            rig.guest.received.compactMap { message -> ContinuityArm? in
                if case .continuityArm(let arm) = message { return arm }
                return nil
            }.count == 2
        }
        let arms = rig.guest.received.compactMap { message -> ContinuityArm? in
            if case .continuityArm(let arm) = message { return arm }
            return nil
        }
        XCTAssertNotEqual(arms[0].epoch, arms[1].epoch)
        XCTAssertTrue(rig.guest.received.contains { message in
            if case .continuityDisarm(let disarm) = message {
                return disarm.epoch == arms[0].epoch
            }
            return false
        })
        XCTAssertTrue(rig.controller.isEnabled)
        XCTAssertEqual(rig.controller.phase, .arming)
    }

    /* THE FOREIGN-MODAL SENTENCE. A guest inside another application's
       modal alert stops acknowledging while the resident's Time Manager
       liveness keeps answering — the exact split these two tests hold the
       controller to. Reproduced on the emulator 2026-08-16 (guest
       `4e7f6404953a`): `wirestat` reported `pass max 30,060,017 us` across a
       30 s window, so the guest's event loop did not run once, and one
       acknowledgement arrived out of 818 datagrams sent. */
    func testProlongedStarvationIsAnnouncedOnceWithWhatToDo() async throws {
        let rig = try await makeActiveRig(
            acknowledgementTimeout: 0.2, starvationAnnounceAfter: 0.6)
        defer { rig.udp.stop() }
        rig.controller.machineIsAnsweringOverride = { _ in true }
        var announced: [String] = []
        rig.controller.onStarvation = { announced.append($0) }

        try await waitUntil("the starvation announcement") {
            !announced.isEmpty
        }
        let message = try XCTUnwrap(announced.first)
        /* Not a spelling test: each clause is a separate promise the page
           and the notification both make. What is known (the Mac is silent
           but running), and what the person can do about it (dismiss it
           themselves, because Continuity cannot). */
        XCTAssertTrue(message.contains("has not answered"), message)
        XCTAssertTrue(message.contains("still running"), message)
        XCTAssertTrue(message.contains("Dismiss it at the Mac"), message)
        XCTAssertEqual(message, rig.controller.status,
                       "the status line and the notification must be the "
                       + "same sentence, never two drafts of it")

        try await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertEqual(announced.count, 1,
                       "a two-minute modal is one notification, not sixty")
    }

    func testBriefStarvationIsNotAnnouncedAtAll() async throws {
        /* The status line already changes at `acknowledgementTimeout`, which
           is short enough that an ordinary tracking loop — a menu held down,
           a window being dragged — trips it. Escalating there would train a
           person to ignore the one that matters. */
        let rig = try await makeActiveRig(
            acknowledgementTimeout: 0.2, starvationAnnounceAfter: 30)
        defer { rig.udp.stop() }
        rig.controller.machineIsAnsweringOverride = { _ in true }
        var announced: [String] = []
        rig.controller.onStarvation = { announced.append($0) }

        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertTrue(announced.isEmpty,
                      "announced a one-second stall: \(announced)")
        XCTAssertTrue(rig.controller.status.contains("busy in another"),
                      rig.controller.status)
    }

    private struct ArmingRig {
        let guest: FakeGuest
        let controller: MirrorContinuityController
        let arm: ContinuityArm
    }

    private func makeArmingRig(
        initial: MirrorKit.Point = .init(x: 40, y: 50),
        autoReconnect: Bool = false,
        fastPump: Bool = false,
        deepClickLog: Bool = false,
        acknowledgementTimeout: TimeInterval = 3,
        starvationAnnounceAfter: TimeInterval = 10,
        starvationBackstop: TimeInterval = 300,
        audit: MirrorContinuityController.Audit? = nil
    ) async throws -> ArmingRig {
        let guest = FakeGuest(port: try XCTUnwrap(listener.boundPort))
        guest.start()
        try guest.send(.hello(Hello(
            contract: Contract.revision, side: "guest", version: "0.1.0",
            build: nil, agent: nil, name: "PowerBook 1400", os: "9.1",
            chunk: 8192)))
        try await waitUntil("host hello") { !guest.received.isEmpty }

        let controller = MirrorContinuityController(
            listener: listener, defaults: defaults,
            acknowledgementTimeout: acknowledgementTimeout,
            starvationAnnounceAfter: starvationAnnounceAfter,
            starvationBackstop: starvationBackstop, audit: audit)
        controller.autoReconnect = autoReconnect
        controller.fastPump = fastPump
        controller.deepClickLog = deepClickLog
        controller.isEnabled = true
        controller.pointerMoved(to: initial)
        try await waitUntil("arm") {
            guest.received.contains {
                if case .continuityArm = $0 { return true }
                return false
            }
        }
        let arm = try XCTUnwrap(guest.received.compactMap { message in
            if case .continuityArm(let value) = message { return value }
            return nil
        }.last)
        return ArmingRig(guest: guest, controller: controller, arm: arm)
    }

    private func makeActiveRig(
        initial: MirrorKit.Point = .init(x: 40, y: 50),
        autoReconnect: Bool = false,
        fastPump: Bool = false,
        acknowledgementTimeout: TimeInterval = 3,
        starvationAnnounceAfter: TimeInterval = 10,
        starvationBackstop: TimeInterval = 300,
        audit: MirrorContinuityController.Audit? = nil
    ) async throws -> ActiveRig {
        let port = try XCTUnwrap(listener.boundPort)
        let udp = try FakeContinuityUDP(port: port)
        udp.start()
        try await waitUntil("UDP listener") { udp.ready }
        let rig = try await makeArmingRig(
            initial: initial, autoReconnect: autoReconnect,
            fastPump: fastPump,
            acknowledgementTimeout: acknowledgementTimeout,
            starvationAnnounceAfter: starvationAnnounceAfter,
            starvationBackstop: starvationBackstop, audit: audit)
        try rig.guest.send(.continuityReport(.init(
            version: ContinuityContract.version,
            id: rig.arm.id, epoch: rig.arm.epoch, state: "armed",
            acceptedHz: rig.arm.requestedHz, udpPort: Int(port), reason: nil,
            acceptedPackets: 0, stalePackets: 0, malformedPackets: 0,
            appliedPositionSequence: 0, appliedButtonGeneration: 0)))
        try await waitUntil("active UDP") { rig.controller.isActive }
        return ActiveRig(guest: rig.guest, udp: udp,
                         controller: rig.controller, arm: rig.arm)
    }

    func testMissingControlVersionIsNamedInsteadOfTimingOut() async throws {
        let rig = try await makeArmingRig()
        try rig.guest.send(.continuityReport(.init(
            version: nil, id: rig.arm.id, epoch: rig.arm.epoch,
            state: "armed", acceptedHz: rig.arm.requestedHz,
            udpPort: Int(try XCTUnwrap(listener.boundPort)), reason: nil,
            acceptedPackets: 0, stalePackets: 0, malformedPackets: 0,
            appliedPositionSequence: 0, appliedButtonGeneration: 0)))

        try await waitUntil("version refusal") {
            !rig.controller.isEnabled
        }
        XCTAssertEqual(
            rig.controller.status,
            "Continuity ended on the Mac: the guest is missing Continuity "
                + "control version \(ContinuityContract.version)")
    }

    func testWrongControlVersionIsNamedInsteadOfTimingOut() async throws {
        let rig = try await makeArmingRig()
        try rig.guest.send(.continuityReport(.init(
            version: ContinuityContract.version + 1,
            id: rig.arm.id, epoch: rig.arm.epoch, state: "refused",
            acceptedHz: nil, udpPort: nil, reason: "wrong-version",
            acceptedPackets: 0, stalePackets: 0, malformedPackets: 0,
            appliedPositionSequence: 0, appliedButtonGeneration: 0)))

        try await waitUntil("version refusal") {
            !rig.controller.isEnabled
        }
        XCTAssertEqual(
            rig.controller.status,
            "Continuity ended on the Mac: the guest reported Continuity "
                + "control version \(ContinuityContract.version + 1), "
                + "expected \(ContinuityContract.version)")
    }

    func testResidentMismatchNamesTheExtensionAndRestartRecovery()
        async throws {
        let rig = try await makeArmingRig()
        try rig.guest.send(.continuityReport(.init(
            version: ContinuityContract.version, id: rig.arm.id,
            epoch: rig.arm.epoch, state: "refused", acceptedHz: nil,
            udpPort: nil, reason: "resident-unavailable",
            acceptedPackets: 0, stalePackets: 0, malformedPackets: 0,
            appliedPositionSequence: 0,
            appliedButtonGeneration: 0)))

        try await waitUntil("resident refusal") {
            !rig.controller.isEnabled
        }
        XCTAssertEqual(
            rig.controller.status,
            "Continuity ended on the Mac: the installed NOW Extension is "
                + "incompatible or not active; replace it and restart the Mac")
    }

    func testUncorrelatedTerminalSnapshotCannotOutrunArmReply()
        async throws {
        let port = try XCTUnwrap(listener.boundPort)
        let udp = try FakeContinuityUDP(port: port)
        udp.start()
        defer { udp.stop() }
        try await waitUntil("UDP listener") { udp.ready }
        let rig = try await makeArmingRig()

        try rig.guest.send(.continuityReport(.init(
            version: ContinuityContract.version,
            id: nil, epoch: rig.arm.epoch, state: "exited",
            acceptedHz: rig.arm.requestedHz, udpPort: Int(port),
            reason: "disarmed", acceptedPackets: 0,
            stalePackets: 0, malformedPackets: 0,
            appliedPositionSequence: 0, appliedButtonGeneration: 0)))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(rig.controller.isEnabled)
        XCTAssertEqual(rig.controller.phase, .arming)

        try rig.guest.send(.continuityReport(.init(
            version: ContinuityContract.version,
            id: rig.arm.id, epoch: rig.arm.epoch, state: "armed",
            acceptedHz: rig.arm.requestedHz, udpPort: Int(port), reason: nil,
            acceptedPackets: 0, stalePackets: 0, malformedPackets: 0,
            appliedPositionSequence: 0, appliedButtonGeneration: 0)))
        try await waitUntil("correlated arm wins") {
            rig.controller.isActive
        }
        XCTAssertTrue(rig.controller.isEnabled)
    }

    func testMoveModeSendsTheArmPointThenTheLatestGuestPoint()
        async throws {
        let rig = try await makeActiveRig()
        defer { rig.udp.stop() }

        try await waitUntil("initial point", timeout: 1) {
            rig.udp.packets.contains {
                $0.h == 40 && $0.v == 50 && $0.flags.contains(.inside)
                    && !$0.flags.contains(.primaryDown)
                    && !$0.flags.contains(.keepalive)
            }
        }
        let initial = try XCTUnwrap(rig.udp.packets.last {
            $0.h == 40 && $0.v == 50 && !$0.flags.contains(.keepalive)
        })
        XCTAssertGreaterThan(initial.positionSequence, 0)

        rig.controller.pointerMoved(to: .init(x: 80, y: 90))
        rig.controller.pointerMoved(to: .init(x: 120, y: 130))
        try await waitUntil("coalesced move") {
            rig.udp.packets.contains { $0.h == 120 && $0.v == 130 }
        }
        let latest = try XCTUnwrap(rig.udp.packets.last {
            $0.h == 120 && $0.v == 130
        })
        XCTAssertGreaterThan(latest.positionSequence,
                             initial.positionSequence)
        XCTAssertEqual(latest.buttonGeneration, 0)
    }

    func testSilentAcknowledgementLaneEndsOwnership() async throws {
        let rig = try await makeActiveRig(acknowledgementTimeout: 0.15)
        defer { rig.udp.stop() }

        try await waitUntil("acknowledgement silence teardown", timeout: 1) {
            !rig.controller.isEnabled
        }
        XCTAssertFalse(rig.controller.isActive)
        XCTAssertEqual(
            rig.controller.status,
            "Continuity ended on the Mac: UDP acknowledgements stopped")
    }

    func testResidentLivenessKeepsModalStarvationAttachedUntilAckRecovers()
        async throws {
        var audit: [(HostLog.LogLevel, String)] = []
        let rig = try await makeActiveRig(
            acknowledgementTimeout: 0.15) {
                audit.append(($0, $1))
            }
        defer { rig.udp.stop() }
        rig.controller.machineIsAnsweringOverride = { _ in true }

        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertTrue(rig.controller.isActive)
        XCTAssertTrue(rig.controller.status.contains("busy"))
        XCTAssertTrue(audit.contains {
            $0.1.contains("resident liveness is still answering")
        })

        rig.udp.acknowledge(try XCTUnwrap(rig.udp.packets.last))
        try await waitUntil("acknowledgement recovery") {
            audit.contains { $0.1.contains("acknowledgements recovered") }
        }
        XCTAssertTrue(rig.controller.isActive)
        XCTAssertTrue(rig.controller.status.contains("direct pointer connected"))
    }

    /// THE KEY TEST: an indefinitely held gesture — modal, menu hold,
    /// whatever shape — must survive for as long as resident liveness
    /// answers, well past several multiples of `acknowledgementTimeout`.
    /// This is the behaviour the ack-silence watchdog must never regress:
    /// silence with a live resident is starvation, not death, and starving
    /// for a while longer must not be distinguishable from starving for a
    /// moment in the one place that matters — whether the epoch survives.
    func testExtendedStarvationWithLiveResidentNeverEndsTheEpoch()
        async throws {
        let rig = try await makeActiveRig(
            acknowledgementTimeout: 0.05, starvationBackstop: 300)
        defer { rig.udp.stop() }
        rig.controller.machineIsAnsweringOverride = { _ in true }

        // Many multiples of acknowledgementTimeout, none of the backstop:
        // long enough that the old unconditional watchdog would have ended
        // the epoch dozens of times over.
        try await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertTrue(rig.controller.isActive,
                      "resident liveness answered throughout; the epoch "
                      + "must still be owned")
        XCTAssertTrue(rig.controller.isEnabled)
    }

    /// Every additional `acknowledgementTimeout` of tolerated silence is
    /// audited on its own line, not just the onset — the log must be able
    /// to narrate how long a hold has been tolerated without the reader
    /// re-deriving it from timestamps.
    func testToleratedStarvationIsAuditedPeriodicallyNotOnlyAtOnset()
        async throws {
        var audit: [(HostLog.LogLevel, String)] = []
        let rig = try await makeActiveRig(
            acknowledgementTimeout: 0.05, starvationBackstop: 300) {
                audit.append(($0, $1))
            }
        defer { rig.udp.stop() }
        rig.controller.machineIsAnsweringOverride = { _ in true }

        try await waitUntil("more than one tolerated-silence line",
                            timeout: 2) {
            audit.filter {
                $0.1.contains("tolerated: resident liveness answering "
                    + "(starvation, not death)")
            }.count >= 3
        }
    }

    /// THE BACKSTOP. Resident liveness is a TCP read, and this project
    /// already argues elsewhere that such a channel can answer "alive"
    /// long after the machine behind it stopped being reachable. Past the
    /// backstop, ack silence ends the epoch even while liveness still
    /// claims the machine is there — the dead-man fallback for evidence
    /// that may itself be lying.
    func testStarvationPastTheBackstopEndsTheEpochDespiteLiveResident()
        async throws {
        var audit: [(HostLog.LogLevel, String)] = []
        let rig = try await makeActiveRig(
            acknowledgementTimeout: 0.05, starvationBackstop: 0.3) {
                audit.append(($0, $1))
            }
        defer { rig.udp.stop() }
        rig.controller.machineIsAnsweringOverride = { _ in true }

        try await waitUntil("backstop ends the epoch", timeout: 2) {
            !rig.controller.isEnabled
        }
        XCTAssertFalse(rig.controller.isActive)
        XCTAssertTrue(audit.contains {
            $0.1.contains("exceeded the") && $0.1.contains("backstop")
        }, "no backstop line was audited: \(audit.map(\.1))")
        XCTAssertTrue(
            rig.controller.status.contains("UDP acknowledgements")
                && rig.controller.status.contains("backstop exceeded"),
            rig.controller.status)
    }

    /// The lease clock that keeps the GUEST's own timeout armed is driven
    /// on its own queue by `ContinuityKeepaliveClock`, independent of the
    /// ack-silence watchdog. Confirms host patience does not come at the
    /// cost of the datagrams the guest's lease depends on hearing.
    func testKeepalivesKeepFlowingThroughoutTolerableStarvation()
        async throws {
        let rig = try await makeActiveRig(
            acknowledgementTimeout: 0.05, starvationBackstop: 300)
        defer { rig.udp.stop() }
        rig.controller.machineIsAnsweringOverride = { _ in true }
        try await waitUntil("initial state") { !rig.udp.packets.isEmpty }
        let baseline = rig.udp.packets.count

        try await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertTrue(rig.controller.isActive,
                      "the epoch must still be owned while asserting on "
                      + "keepalive delivery")
        XCTAssertTrue(
            rig.udp.packets.dropFirst(baseline).contains {
                $0.flags.contains(.keepalive)
            }, "no keepalive datagrams arrived during the tolerated hold; "
                + "the guest's host-fed lease would have expired")
    }

    /// **THE LEVEL AND THE EDGE ARE ONE BIT AND TWO CONSUMERS, TOLD APART
    /// BY THE GENERATION** (F2 defect B, attended metal 2026-08-17).
    ///
    /// The guest's drag input proc reads the LEVEL out of the datagram
    /// flags; the resident applies a press only on a NEWER
    /// `button_generation` (`now_continuity_logic.c:47-49`). So a carried
    /// button must appear in the flags and must NOT move the generation —
    /// that is what lets a host→guest drag hold a button for the length of a
    /// human gesture while no synthetic click ever reaches the guest's
    /// Finder, which is the D5 guarantee this fix was not allowed to break.
    func testTheCarriedButtonIsALevelWithNoGenerationBehindIt() async throws {
        let rig = try await makeActiveRig()
        defer { rig.udp.stop() }
        let before = try await awaitPacket(in: rig.udp, "a settled datagram") {
            !$0.flags.contains(.primaryDown)
        }

        XCTAssertTrue(rig.controller.setCarriedButtonLevel(
            true, gesture: 4, reason: "a file is being carried"))
        let held = try await awaitPacket(in: rig.udp, "the carried level") {
            $0.flags.contains(.carriedLevel)
        }
        XCTAssertFalse(held.flags.contains(.primaryDown),
                       "the level must NEVER ride .primaryDown: a stale "
                        + "generation plus that flag at a fresh epoch is "
                        + "the phantom press that clicked and "
                        + "marquee-selected at random on 2026-08-17")
        XCTAssertEqual(held.buttonGeneration, before.buttonGeneration,
                       "a carried level that advances the generation is a "
                        + "click the resident will apply — D5, and the "
                        + "reason a drag opened Classilla")
        XCTAssertEqual(held.previousButtonGeneration,
                       before.previousButtonGeneration,
                       "nor may it disturb the pair the resident reads")

        XCTAssertTrue(rig.controller.setCarriedButtonLevel(
            false, gesture: 4, reason: "the person let the file go"))
        let released = try await awaitPacket(
            in: rig.udp, "the cleared level", timeout: 5
        ) { $0.positionSequence >= held.positionSequence
            && !$0.flags.contains(.carriedLevel) }
        XCTAssertEqual(released.buttonGeneration, before.buttonGeneration,
                       "and the clear is a level too: the guest's TrackDrag "
                        + "reads it and returns, and nothing was posted")

        /* AND THE CLICK CYCLE IS UNTOUCHED. The level is not
           `wireButtonDown`; an ordinary press after a carry must still mint
           its own generation. */
        XCTAssertTrue(rig.controller.primaryDown(at: .init(x: 45, y: 55)))
        let click = try await awaitPacket(in: rig.udp, "an ordinary press") {
            $0.flags.contains(.primaryDown) && $0.buttonGeneration != 0
        }
        XCTAssertNotEqual(click.buttonGeneration, before.buttonGeneration)
    }

    /// A level cannot outlive the epoch it was raised in: the next epoch's
    /// guest holds nothing, and a stale level would hand its first drag a
    /// button nobody is pressing.
    func testAnEndingEpochDropsTheCarriedLevel() async throws {
        var lines: [String] = []
        let rig = try await makeActiveRig(audit: { _, line in
            lines.append(line)
        })
        defer { rig.udp.stop() }
        XCTAssertTrue(rig.controller.setCarriedButtonLevel(
            true, gesture: 9, reason: "a file is being carried"))
        _ = try await awaitPacket(in: rig.udp, "the carried level") {
            $0.flags.contains(.carriedLevel)
        }

        rig.controller.cancel(reason: "the pointer left")
        try await waitUntil("the epoch to end") {
            rig.controller.phase == .idle
        }

        /* Asked by RAISING it again: a level the teardown dropped is a
           transition and says so, while a level still held would make this
           call a silent no-op. That difference is the whole assertion —
           there is no wire left to read the answer off. */
        lines.removeAll()
        _ = rig.controller.setCarriedButtonLevel(
            true, gesture: 10, reason: "a second carry")
        XCTAssertTrue(lines.contains { $0.contains("carried button level "
            + "RAISED") },
                      "the epoch's teardown left the level standing: "
                        + "\(lines)")
    }

    func testDirectClickStreamsReleaseWithoutWaitingForPressAck()
        async throws {
        let rig = try await makeActiveRig()
        defer { rig.udp.stop() }

        XCTAssertTrue(rig.controller.primaryDown(at: .init(x: 45, y: 55)))
        try await waitUntil("primary down") {
            rig.udp.packets.contains {
                $0.h == 45 && $0.v == 55
                    && $0.flags.contains(.primaryDown)
                    && $0.buttonGeneration != 0
            }
        }
        let down = try XCTUnwrap(rig.udp.packets.last {
            $0.flags.contains(.primaryDown) && $0.buttonGeneration != 0
        })
        XCTAssertTrue(rig.controller.primaryUp(at: .init(x: 46, y: 56)))
        /* No acknowledgement was given: the release must stream anyway,
           carrying the unacknowledged press beside it in the v4 pair.
           Ordering belongs to generations and the resident's two-slot
           release, not to host-side pacing. */
        try await waitUntil("streamed release") {
            rig.udp.packets.contains {
                $0.buttonGeneration != down.buttonGeneration
                    && !$0.flags.contains(.primaryDown)
                    && $0.h == 46 && $0.v == 56
            }
        }
        let up = try XCTUnwrap(rig.udp.packets.last {
            $0.buttonGeneration != down.buttonGeneration
                && !$0.flags.contains(.primaryDown)
        })
        XCTAssertEqual(up.previousButtonGeneration, down.buttonGeneration,
                       "the streamed release must carry the press beside it")
        XCTAssertTrue(up.previousButtonDown)

        rig.udp.acknowledge(down)
        rig.udp.acknowledge(up)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(rig.controller.primaryDown(at: .init(x: 50, y: 60)),
                      "a completed cycle opens the next click")
    }

    func testDirectDragPinsToPressUntilAckThenStreamsAndReleases()
        async throws {
        let rig = try await makeActiveRig()
        defer { rig.udp.stop() }

        XCTAssertTrue(rig.controller.primaryDown(at: .init(x: 40, y: 50)))
        try await waitUntil("drag press") {
            rig.udp.packets.contains {
                $0.flags.contains(.primaryDown) && $0.buttonGeneration != 0
            }
        }
        let down = try XCTUnwrap(rig.udp.packets.last {
            $0.flags.contains(.primaryDown) && $0.buttonGeneration != 0
        })
        XCTAssertTrue(rig.controller.primaryDragged(to: .init(x: 160, y: 170)))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(rig.udp.packets.contains {
            $0.buttonGeneration == down.buttonGeneration
                && $0.h == 160 && $0.v == 170
        })

        rig.udp.acknowledge(down)
        try await waitUntil("held drag movement") {
            rig.udp.packets.contains {
                $0.buttonGeneration == down.buttonGeneration
                    && $0.flags.contains(.primaryDown)
                    && $0.h == 160 && $0.v == 170
            }
        }
        XCTAssertTrue(rig.controller.primaryUp(at: .init(x: 180, y: 190)))
        try await waitUntil("drag release") {
            rig.udp.packets.contains {
                $0.buttonGeneration != down.buttonGeneration
                    && !$0.flags.contains(.primaryDown)
                    && $0.h == 180 && $0.v == 190
            }
        }
    }

    func testMenuBarClickLatchesUntilTheSelectionClickReleases()
        async throws {
        let rig = try await makeActiveRig()
        defer { rig.udp.stop() }

        XCTAssertTrue(rig.controller.primaryDown(
            at: .init(x: 42, y: 10), inMenuBar: true))
        XCTAssertTrue(rig.controller.isMenuTracking,
                      "the raw press must immediately project the guest menu")
        try await waitUntil("menu press") {
            rig.udp.packets.contains {
                $0.flags.contains(.primaryDown) && $0.buttonGeneration != 0
            }
        }
        let down = try XCTUnwrap(rig.udp.packets.last {
            $0.flags.contains(.primaryDown) && $0.buttonGeneration != 0
        })
        rig.udp.acknowledge(down)
        XCTAssertTrue(rig.controller.primaryUp(at: .init(x: 42, y: 10)))
        XCTAssertTrue(rig.controller.isMenuTracking,
                      "the OS 8/9 click-open latch must keep the projection open")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(rig.udp.packets.contains {
            $0.buttonGeneration != 0
                && $0.buttonGeneration != down.buttonGeneration
                && !$0.flags.contains(.primaryDown)
        }, "a stationary menubar click must leave native menu tracking live")

        XCTAssertTrue(rig.controller.primaryDown(at: .init(x: 55, y: 48)))
        XCTAssertTrue(rig.controller.primaryUp(at: .init(x: 55, y: 48)))
        XCTAssertFalse(rig.controller.isMenuTracking,
                       "the selection click closes guest and projected menus")
        try await waitUntil("menu selection release") {
            rig.udp.packets.contains {
                $0.buttonGeneration != down.buttonGeneration
                    && !$0.flags.contains(.primaryDown)
                    && $0.h == 55 && $0.v == 48
            }
        }
    }

    func testMenuBarDragUsesNativeReleaseWithoutLatching()
        async throws {
        let rig = try await makeActiveRig()
        defer { rig.udp.stop() }

        XCTAssertTrue(rig.controller.primaryDown(
            at: .init(x: 42, y: 10), inMenuBar: true))
        try await waitUntil("menu drag press") {
            rig.udp.packets.contains {
                $0.flags.contains(.primaryDown) && $0.buttonGeneration != 0
            }
        }
        let down = try XCTUnwrap(rig.udp.packets.last {
            $0.flags.contains(.primaryDown) && $0.buttonGeneration != 0
        })
        rig.udp.acknowledge(down)
        XCTAssertTrue(rig.controller.primaryDragged(to: .init(x: 55, y: 48)))
        XCTAssertTrue(rig.controller.primaryUp(at: .init(x: 55, y: 48)))
        XCTAssertFalse(rig.controller.isMenuTracking,
                       "click-drag-release must not retain a projected menu")
        try await waitUntil("menu drag release") {
            rig.udp.packets.contains {
                $0.buttonGeneration != down.buttonGeneration
                    && !$0.flags.contains(.primaryDown)
            }
        }
    }

    func testManagerReleaseMaySettleAfterTrackingLoopWithoutDisconnect()
        async throws {
        let rig = try await makeActiveRig()
        defer { rig.udp.stop() }

        XCTAssertTrue(rig.controller.primaryDown(at: .init(x: 40, y: 50)))
        try await waitUntil("release-timeout press") {
            rig.udp.packets.contains {
                $0.flags.contains(.primaryDown) && $0.buttonGeneration != 0
            }
        }
        let down = try XCTUnwrap(rig.udp.packets.last {
            $0.flags.contains(.primaryDown) && $0.buttonGeneration != 0
        })
        rig.udp.acknowledge(down)
        XCTAssertTrue(rig.controller.primaryUp(at: .init(x: 41, y: 51)))
        try await waitUntil("release packet") {
            rig.udp.packets.contains {
                $0.buttonGeneration != down.buttonGeneration
                    && !$0.flags.contains(.primaryDown)
            }
        }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertTrue(rig.controller.isActive,
                      "a tracking loop may starve the manager-up report")
        let up = try XCTUnwrap(rig.udp.packets.last {
            $0.buttonGeneration != down.buttonGeneration
                && !$0.flags.contains(.primaryDown)
        })
        rig.udp.acknowledge(up)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(rig.controller.isActive)
    }

    func testSecondClickStreamsWithoutWaitingForFirstReleaseAck()
        async throws {
        let rig = try await makeActiveRig()
        defer { rig.udp.stop() }

        XCTAssertTrue(rig.controller.primaryDown(at: .init(x: 40, y: 50)))
        try await waitUntil("first press") {
            rig.udp.packets.contains {
                $0.flags.contains(.primaryDown) && $0.buttonGeneration != 0
            }
        }
        let firstDown = try XCTUnwrap(rig.udp.packets.last {
            $0.flags.contains(.primaryDown) && $0.buttonGeneration != 0
        })
        rig.udp.acknowledge(firstDown)
        XCTAssertTrue(rig.controller.primaryUp(at: .init(x: 40, y: 50)))
        try await waitUntil("first release") {
            rig.udp.packets.contains {
                $0.buttonGeneration != 0
                    && $0.buttonGeneration != firstDown.buttonGeneration
                    && !$0.flags.contains(.primaryDown)
            }
        }
        let firstUp = try XCTUnwrap(rig.udp.packets.last {
            $0.buttonGeneration != 0
                && $0.buttonGeneration != firstDown.buttonGeneration
                && !$0.flags.contains(.primaryDown)
        })

        /* The first up is never acknowledged, and the second click must
           stream anyway: each edge is a new generation, ordered by the v4
           previous/current pair, never by host-side pacing. Holding it for
           the manager-up is what a starved target turned into piled-up
           drags (2026-08-13 185037). */
        XCTAssertTrue(rig.controller.primaryDown(at: .init(x: 42, y: 52)))
        XCTAssertTrue(rig.controller.primaryUp(at: .init(x: 42, y: 52)))
        try await waitUntil("second press streams") {
            rig.udp.packets.contains {
                $0.buttonGeneration != firstDown.buttonGeneration
                    && $0.buttonGeneration != firstUp.buttonGeneration
                    && $0.flags.contains(.primaryDown)
            }
        }
        let secondDown = try XCTUnwrap(rig.udp.packets.last {
            $0.buttonGeneration != firstDown.buttonGeneration
                && $0.buttonGeneration != firstUp.buttonGeneration
                && $0.flags.contains(.primaryDown)
        })
        XCTAssertEqual(secondDown.previousButtonGeneration,
                       firstUp.buttonGeneration,
                       "the second press must carry the first up beside it")
        try await waitUntil("second release streams") {
            rig.udp.packets.contains {
                $0.buttonGeneration != firstDown.buttonGeneration
                    && $0.buttonGeneration != firstUp.buttonGeneration
                    && $0.buttonGeneration != secondDown.buttonGeneration
                    && !$0.flags.contains(.primaryDown)
            }
        }
    }

    func testDownAckTimeoutAbandonsCycleWithoutEndingOwnership() async throws {
        let rig = try await makeActiveRig()
        defer { rig.udp.stop() }
        /* The scenario under test is a starved application with a live
           resident: acknowledgements stall while liveness keeps answering.
           Without this, the silence lane ends ownership first and the
           cycle-abandon path below can never be observed. */
        rig.controller.machineIsAnsweringOverride = { _ in true }

        XCTAssertTrue(rig.controller.primaryDown(
            at: .init(x: 40, y: 50), inMenuBar: false,
            sourceUptime: ProcessInfo.processInfo.systemUptime))
        let down = try await awaitPacket(
            in: rig.udp, "unacknowledged press") {
            $0.flags.contains(.primaryDown) && $0.buttonGeneration != 0
        }
        _ = try await awaitPacket(
            in: rig.udp, "unacknowledged press abandons its cycle",
            timeout: 4.5) {
                $0.buttonGeneration != 0
                    && $0.buttonGeneration != down.buttonGeneration
                    && !$0.flags.contains(.primaryDown)
        }
        XCTAssertTrue(rig.controller.isActive,
                      "a late down acknowledgement must not end ownership")
        XCTAssertTrue(rig.controller.isEnabled)
    }

    func testIndependentKeepaliveContinuesWhileMainActorIsBusy() async throws {
        let rig = try await makeActiveRig()
        defer { rig.udp.stop() }
        try await waitUntil("initial state") { !rig.udp.packets.isEmpty }
        rig.udp.acknowledge(try XCTUnwrap(rig.udp.packets.last))
        let baseline = rig.udp.packets.count

        let end = Date().addingTimeInterval(1.7)
        while Date() < end { _ = 1 + 1 }

        try await waitUntil("independent keepalive") {
            rig.udp.packets.dropFirst(baseline).contains {
                $0.flags.contains(.keepalive)
            }
        }
    }

    func testAutoReconnectRearmsAfterLeaseExpiry() async throws {
        let rig = try await makeActiveRig(autoReconnect: true)
        defer { rig.udp.stop() }

        try rig.guest.send(.continuityReport(.init(
            version: ContinuityContract.version,
            id: nil, epoch: rig.arm.epoch, state: "exited",
            acceptedHz: rig.arm.requestedHz, udpPort: nil,
            reason: "lease-expired", acceptedPackets: 4,
            stalePackets: 0, malformedPackets: 0,
            appliedPositionSequence: 3, appliedButtonGeneration: 0)))
        try await waitUntil("automatic rearm", timeout: 2) {
            rig.guest.received.compactMap { message -> ContinuityArm? in
                if case .continuityArm(let arm) = message { return arm }
                return nil
            }.count == 2
        }
        let arms = rig.guest.received.compactMap { message -> ContinuityArm? in
            if case .continuityArm(let arm) = message { return arm }
            return nil
        }
        XCTAssertNotEqual(arms[0].epoch, arms[1].epoch)
        XCTAssertTrue(rig.controller.isEnabled)
        XCTAssertEqual(rig.controller.phase, .arming)
    }

    func testConfiguredReconnectDelayIsRespected() async throws {
        let rig = try await makeActiveRig(autoReconnect: true)
        defer { rig.udp.stop() }
        rig.controller.reconnectDelay = 0.05

        try rig.guest.send(.continuityReport(.init(
            version: ContinuityContract.version,
            id: nil, epoch: rig.arm.epoch, state: "exited",
            acceptedHz: rig.arm.requestedHz, udpPort: nil,
            reason: "lease-expired", acceptedPackets: 4,
            stalePackets: 0, malformedPackets: 0,
            appliedPositionSequence: 3, appliedButtonGeneration: 0)))
        /* The old hardcoded 0.75s default would still be mid-wait here; a
           0.3s timeout only passes if scheduleReconnect actually read the
           configured 0.05s value instead of a fixed constant. */
        try await waitUntil("fast automatic rearm", timeout: 0.3) {
            rig.guest.received.compactMap { message -> ContinuityArm? in
                if case .continuityArm(let arm) = message { return arm }
                return nil
            }.count == 2
        }
        XCTAssertTrue(rig.controller.isEnabled)
        XCTAssertEqual(rig.controller.phase, .arming)
    }

    func testGuestExitDoesNotCarryClickTimingIntoTheNextEpoch()
        async throws {
        var audit: [(HostLog.LogLevel, String)] = []
        let rig = try await makeActiveRig {
            audit.append(($0, $1))
        }
        defer { rig.udp.stop() }

        XCTAssertTrue(rig.controller.primaryDown(at: .init(x: 40, y: 50)))
        try await waitUntil("first epoch press") {
            rig.udp.packets.contains {
                $0.flags.contains(.primaryDown) && $0.buttonGeneration != 0
            }
        }
        try rig.guest.send(.continuityReport(.init(
            version: ContinuityContract.version,
            id: nil, epoch: rig.arm.epoch, state: "exited",
            acceptedHz: rig.arm.requestedHz, udpPort: nil,
            reason: "lease-expired", acceptedPackets: 1,
            stalePackets: 0, malformedPackets: 0,
            appliedPositionSequence: 1, appliedButtonGeneration: 0)))
        try await waitUntil("first epoch ended") {
            rig.controller.phase == .idle && !rig.controller.isEnabled
        }

        audit.removeAll()
        rig.controller.isEnabled = true
        rig.controller.pointerMoved(to: .init(x: 60, y: 70))
        try await waitUntil("second epoch arm") {
            rig.guest.received.compactMap { message -> ContinuityArm? in
                if case .continuityArm(let arm) = message { return arm }
                return nil
            }.count == 2
        }
        let secondArm = try XCTUnwrap(
            rig.guest.received.compactMap { message -> ContinuityArm? in
                if case .continuityArm(let arm) = message { return arm }
                return nil
            }.last)
        try rig.guest.send(.continuityReport(.init(
            version: ContinuityContract.version,
            id: secondArm.id, epoch: secondArm.epoch, state: "armed",
            acceptedHz: secondArm.requestedHz,
            udpPort: Int(try XCTUnwrap(listener.boundPort)), reason: nil,
            acceptedPackets: 0, stalePackets: 0, malformedPackets: 0,
            appliedPositionSequence: 0, appliedButtonGeneration: 0)))
        try await waitUntil("second epoch active") {
            rig.controller.isActive
        }

        XCTAssertTrue(rig.controller.primaryDown(at: .init(x: 61, y: 71)))
        XCTAssertFalse(audit.contains {
            $0.1.contains("primary down source interval")
        }, "the first click of an epoch has no cross-epoch timing interval")
    }

    func testFastPumpIsRequestedOnlyWhenOptedIn() async throws {
        let fast = try await makeArmingRig(fastPump: true)
        XCTAssertEqual(fast.arm.fastPump, true)
    }

    func testDeepClickLogIsRequestedWhenOptedIn() async throws {
        let diagnostic = try await makeArmingRig(deepClickLog: true)
        XCTAssertEqual(diagnostic.arm.deepClickLog, true)
    }

    func testProductArmSendsBlessedContinuityMechanismsByDefault()
        async throws {
        let rig = try await makeArmingRig()
        XCTAssertEqual(rig.arm.settleSyntheticDevice, true)
        XCTAssertEqual(rig.arm.wideDoubleTime, true)
        XCTAssertEqual(rig.arm.compressClickWhen, true)
        XCTAssertEqual(rig.arm.interruptPress, true)
        XCTAssertEqual(rig.arm.settleIdleCursor, true)
    }

    func testOptionCatalogSeparatesProductMechanismsFromDiagnostics() {
        XCTAssertEqual(
            ContinuityOptionCatalog.options(in: .product).map(\.id),
            [.settleSyntheticDevice, .wideDoubleTime, .compressClickWhen,
             .interruptPress, .settleIdleCursor])
        XCTAssertEqual(
            ContinuityOptionCatalog.options(in: .diagnostic).map(\.id),
            [.fastPump, .deepClickLog])
        XCTAssertTrue(ContinuityOptionCatalog.options(in: .product)
            .allSatisfy(\.defaultEnabled))
        XCTAssertTrue(ContinuityOptionCatalog.options(in: .diagnostic)
            .allSatisfy { !$0.defaultEnabled })
    }

    func testClicksFallThroughUntilTheRawLaneIsActive() async throws {
        let rig = try await makeArmingRig()
        XCTAssertFalse(rig.controller.primaryDown(at: .init(x: 45, y: 55)))
        XCTAssertFalse(rig.controller.primaryDragged(to: .init(x: 50, y: 60)))
        XCTAssertFalse(rig.controller.primaryUp(at: .init(x: 50, y: 60)))
    }

    func testActiveKeyboardEventUsesTheOwnedEpochAndReliableLane()
        async throws {
        let rig = try await makeActiveRig()
        defer { rig.udp.stop() }
        XCTAssertTrue(rig.controller.keyboardForwardingEnabled,
                      "keyboard forwarding defaults on")

        XCTAssertTrue(rig.controller.keyboardEvent(.init(
            action: .down, code: 12, character: 113, modifiers: 0x300)))
        try await waitUntil("keyboard message") {
            rig.guest.received.contains {
                guard case .continuityKey(let key) = $0 else { return false }
                return key.epoch == rig.arm.epoch && key.generation == 1
                    && key.action == .down && key.code == 12
                    && key.character == 113 && key.modifiers == 0x300
            }
        }
        let sentKeys = rig.guest.received.reduce(into: 0) { count, message in
            if case .continuityKey = message { count += 1 }
        }
        XCTAssertFalse(rig.controller.keyboardEvent(.init(
            action: .down, code: 200, character: 0, modifiers: 0)))
        XCTAssertEqual(rig.guest.received.reduce(into: 0) { count, message in
            if case .continuityKey = message { count += 1 }
        }, sentKeys, "unrepresentable host keys must remain host-owned")
    }

    /// A bare modifier change crosses as state, and only when it is news.
    ///
    /// macOS raises flagsChanged for keys the classic word has no bit for —
    /// Fn, the numeric-pad flag, left versus right of the same modifier — so
    /// without the comparison every one of them would put a packet on the
    /// reliable stream saying exactly what the guest already held.
    func testOnlyAChangedModifierWordReachesTheGuest() async throws {
        var audit: [(HostLog.LogLevel, String)] = []
        let rig = try await makeActiveRig { audit.append(($0, $1)) }
        defer { rig.udp.stop() }

        func modifierMessages() -> [ContinuityKey] {
            rig.guest.received.compactMap {
                guard case .continuityKey(let key) = $0,
                      key.action == .modifiers else { return nil }
                return key
            }
        }

        /* Option down, Option down again (macOS says this for keys the
           classic word cannot name), then Command joins it. All three are
           accepted; only two are news. Asserted as the WHOLE sequence after
           the last one has landed rather than as a count between sends: a
           count sampled mid-flight reads correct while the extra packet is
           still on the wire, which is how this test first passed against the
           very mutation it exists for. */
        for word: UInt16 in [1 << 11, 1 << 11, (1 << 8) | (1 << 11)] {
            XCTAssertTrue(rig.controller.keyboardEvent(
                .init(action: .modifiers, code: 0, character: 0,
                      modifiers: word)))
        }
        try await waitUntil("the changed word arrived") {
            modifierMessages().last?.modifiers == (1 << 8) | (1 << 11)
        }
        XCTAssertEqual(modifierMessages().map(\.modifiers),
                       [1 << 11, (1 << 8) | (1 << 11)],
                       "the repeated word must not reach the wire")
        XCTAssertEqual(modifierMessages().map(\.code), [0, 0])
        XCTAssertEqual(modifierMessages().map(\.character), [0, 0])
        XCTAssertTrue(audit.contains {
            $0.1.contains("modifier change not forwarded, word unchanged")
        }, "the skipped decision must be named, not silent")
        XCTAssertTrue(audit.contains {
            $0.1.contains("modifier state forwarded")
        })
    }

    /// **A settled release is the last thing the guest can possibly see.**
    ///
    /// The wire is a latest-state mailbox and a guest starved inside the
    /// Finder's drag-tracking loop reads ONE snapshot of it per pass. The
    /// cross-edge handback used to put three datagrams on it inside a
    /// millisecond — settle to the press origin, release carrying that same
    /// origin, then the epoch teardown with `inside` cleared — and both the
    /// resident's timer task and the guest application honour a cleared
    /// `inside` BEFORE they take the snapshot's position. The settled origin
    /// went with it and the release landed on whatever mid-drag point the
    /// guest had last ingested.
    ///
    /// Metal, 2026-08-15: this side commanded and logged origin=522,199 and
    /// 524,203; the guest settled at 792,231 and 799,232, one drag sample
    /// short of the 802,231 and 800,232 crosses. Slow drags only, because a
    /// slow drag is the one where the guest is starved deeply enough for the
    /// three to collapse into one.
    ///
    /// The epoch still ends — over the RELIABLE control stream, asserted
    /// here — so the withheld datagram costs nothing and buys the shape the
    /// fast path already had by accident.
    func testASettledReleaseIsNotFollowedByTheEpochTeardownDatagram()
        async throws {
        var audit: [(HostLog.LogLevel, String)] = []
        let rig = try await makeActiveRig { audit.append(($0, $1)) }
        defer { rig.udp.stop() }
        let origin = MirrorKit.Point(x: 522, y: 199)

        XCTAssertTrue(rig.controller.primaryDown(at: origin))
        try await waitUntil("the press") {
            rig.udp.packets.contains {
                $0.flags.contains(.primaryDown) && $0.buttonGeneration != 0
            }
        }
        let down = try XCTUnwrap(rig.udp.packets.last {
            $0.flags.contains(.primaryDown) && $0.buttonGeneration != 0
        })
        /* Acknowledged, then dragged: this is the SLOW path, the one where
           the settle becomes a datagram of its own. An unacknowledged press
           defers instead and never had the defect. */
        rig.udp.acknowledge(down)
        XCTAssertTrue(rig.controller.primaryDragged(to: .init(x: 794, y: 231)))
        try await waitUntil("the held drag") {
            rig.udp.packets.contains {
                $0.buttonGeneration == down.buttonGeneration
                    && $0.h == 794 && $0.v == 231
            }
        }

        XCTAssertTrue(rig.controller.settleHeldPosition(to: origin))
        XCTAssertTrue(rig.controller.primaryUp(at: origin))
        try await waitUntil("the settled release") {
            rig.udp.packets.contains {
                $0.buttonGeneration != down.buttonGeneration
                    && !$0.flags.contains(.primaryDown)
                    && $0.h == origin.x && $0.v == origin.y
            }
        }
        rig.controller.pointerLeft()
        try await waitUntil("the reliable disarm") {
            rig.guest.received.contains {
                guard case .continuityDisarm(let disarm) = $0 else {
                    return false
                }
                return disarm.epoch == rig.arm.epoch
            }
        }
        /* Sampled AFTER a wait long enough for a teardown datagram to have
           landed. Asserting the absence at the instant of the call would pass
           while the packet was still on the wire — the shape that let a
           sibling test in this file pass against its own mutation. */
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertFalse(rig.udp.packets.contains {
            !$0.flags.contains(.inside)
        }, "the epoch-ending datagram followed the settled release onto the "
            + "wire; a starved guest reads only the last one and drops the "
            + "settled origin with it")
        let last = try XCTUnwrap(rig.udp.packets.last)
        XCTAssertEqual(MirrorKit.Point(x: Int(last.h), y: Int(last.v)), origin,
                       "the last datagram must carry the press origin")
        XCTAssertFalse(last.flags.contains(.primaryDown),
                       "and the release edge beside it")
        XCTAssertTrue(audit.contains {
            $0.1.contains("epoch-ending datagram withheld")
                && $0.1.contains("\(origin.x),\(origin.y)")
        }, "a withheld packet is a decision and must name itself")
    }

    /// The withholding is scoped to a settled release, not to leaving.
    ///
    /// Asserted on the DECISION rather than on the packet's arrival. The
    /// teardown datagram is sent one statement before `relinquish` cancels
    /// the connection under it, so whether loopback delivers it is a race
    /// this suite loses on a busy Mac — and a gate that fails for the
    /// machine's reasons teaches nothing about this branch. The branch is
    /// what a mutation flips, and the audit line names which one ran.
    func testAnOrdinaryReleaseStillEndsTheEpochOnTheWire() async throws {
        var audit: [(HostLog.LogLevel, String)] = []
        let rig = try await makeActiveRig { audit.append(($0, $1)) }
        defer { rig.udp.stop() }

        XCTAssertTrue(rig.controller.primaryDown(at: .init(x: 45, y: 55)))
        try await waitUntil("the press") {
            rig.udp.packets.contains {
                $0.flags.contains(.primaryDown) && $0.buttonGeneration != 0
            }
        }
        let down = try XCTUnwrap(rig.udp.packets.last {
            $0.flags.contains(.primaryDown) && $0.buttonGeneration != 0
        })
        rig.udp.acknowledge(down)
        XCTAssertTrue(rig.controller.primaryUp(at: .init(x: 46, y: 56)))
        try await waitUntil("the release") {
            rig.udp.packets.contains {
                $0.buttonGeneration != down.buttonGeneration
                    && !$0.flags.contains(.primaryDown)
            }
        }

        rig.controller.pointerLeft()
        try await waitUntil("the reliable disarm") {
            rig.guest.received.contains {
                guard case .continuityDisarm(let disarm) = $0 else {
                    return false
                }
                return disarm.epoch == rig.arm.epoch
            }
        }
        XCTAssertFalse(audit.contains {
            $0.1.contains("epoch-ending datagram withheld")
        }, "an ordinary release must leave the epoch ending on the wire; "
            + "withholding it everywhere would silence a signal the guest "
            + "uses to end an epoch it is not starved for")
    }

    func testLeavingV0DisarmsImmediately() async throws {
        var audit: [(HostLog.LogLevel, String)] = []
        let rig = try await makeActiveRig {
            audit.append(($0, $1))
        }
        defer { rig.udp.stop() }

        rig.controller.pointerLeft()
        try await waitUntil("host-left disarm") {
            rig.guest.received.contains {
                guard case .continuityDisarm(let disarm) = $0 else {
                    return false
                }
                return disarm.epoch == rig.arm.epoch
                    && disarm.reason == "host-left"
            }
        }
        XCTAssertFalse(rig.controller.isActive)
        XCTAssertTrue(rig.controller.isEnabled,
                      "leaving the canvas keeps the optional mode armed")
        XCTAssertEqual(rig.controller.status,
                       "move over the Mirror to reconnect")
        XCTAssertTrue(audit.contains {
            $0.0 == .info
                && $0.1.contains("ending locally: reason=pointer left Mirror")
                && $0.1.contains("validAcks=0")
        })
    }

    func testLeaseExitNamesPacketCountersAndTurnsTheModeOff()
        async throws {
        let rig = try await makeActiveRig()
        defer { rig.udp.stop() }

        try rig.guest.send(.continuityReport(.init(
            version: ContinuityContract.version,
            id: nil, epoch: rig.arm.epoch, state: "exited",
            acceptedHz: rig.arm.requestedHz, udpPort: nil,
            reason: "lease-expired", acceptedPackets: 4,
            stalePackets: 2, malformedPackets: 1,
            appliedPositionSequence: 3, appliedButtonGeneration: 0)))
        try await waitUntil("lease exit") { !rig.controller.isEnabled }
        XCTAssertFalse(rig.controller.isActive)
        XCTAssertEqual(
            rig.controller.status,
            "Continuity ended on the Mac: the input lease expired "
                + "(4 accepted, 2 stale, 1 malformed)")
    }

    func testMovementAckCanReportOptimisticGuestTakeover() async throws {
        let port = try XCTUnwrap(listener.boundPort)

        let guest = FakeGuest(port: port)
        guest.start()
        try guest.send(.hello(Hello(
            contract: Contract.revision, side: "guest", version: "0.1.0",
            build: nil, agent: nil, name: "PowerBook 1400", os: "9.1",
            chunk: 8192)))
        try await waitUntil("host hello") { !guest.received.isEmpty }
        XCTAssertNotNil(listener.activeKey)

        let udp = try FakeContinuityUDP(port: port)
        udp.start()
        try await waitUntil("UDP listener") { udp.ready }

        let controller = MirrorContinuityController(listener: listener,
                                                    defaults: defaults)
        controller.isEnabled = true
        controller.pointerMoved(to: .init(x: 40, y: 50))
        try await waitUntil("arm") {
            guest.received.contains {
                if case .continuityArm = $0 { return true }
                return false
            }
        }
        let arm = try XCTUnwrap(guest.received.compactMap { message in
            if case .continuityArm(let value) = message { return value }
            return nil
        }.last)
        try guest.send(.continuityReport(.init(
            version: ContinuityContract.version,
            id: arm.id, epoch: arm.epoch, state: "armed",
            acceptedHz: arm.requestedHz, udpPort: Int(port), reason: nil,
            acceptedPackets: 0, stalePackets: 0, malformedPackets: 0,
            appliedPositionSequence: 0, appliedButtonGeneration: 0)))
        try await waitUntil("active UDP") { controller.isActive }

        try await waitUntil("movement packet") { !udp.packets.isEmpty }
        let movement = try XCTUnwrap(udp.packets.last)
        XCTAssertEqual(movement.buttonGeneration, 0)
        XCTAssertFalse(movement.flags.contains(.primaryDown))
        udp.acknowledge(movement, reason: .guestInput, state: .inactive)
        try await waitUntil("guest takeover") { !controller.isEnabled }
        XCTAssertEqual(controller.status,
                       "Continuity ended on the Mac: the guest mouse moved")

        udp.stop()
    }

    func testFirstValidAckAndGuestExitAreAudited() async throws {
        var audit: [(HostLog.LogLevel, String)] = []
        let rig = try await makeActiveRig {
            audit.append(($0, $1))
        }
        defer { rig.udp.stop() }

        try await waitUntil("movement packet") { !rig.udp.packets.isEmpty }
        rig.udp.acknowledge(try XCTUnwrap(rig.udp.packets.last),
                            reason: .leaseExpired, state: .inactive)

        try await waitUntil("audited terminal acknowledgement") {
            audit.contains { $0.1.contains("reason=leaseExpired") }
        }
        XCTAssertTrue(audit.contains {
            $0.0 == .info
                && $0.1.contains("UDP acknowledgement: state=inactive")
                && $0.1.contains("reason=leaseExpired")
        })
        XCTAssertTrue(audit.contains {
            $0.0 == .warn
                && $0.1.contains("guest ended Continuity")
                && $0.1.contains("input lease expired")
                && $0.1.contains("validAcks=1")
        })
    }

    func testContinuitySettingsPersistButEnablementDoesNot()
        async throws {
        let port = try XCTUnwrap(listener.boundPort)
        let guest = FakeGuest(port: port)
        guest.start()
        try guest.send(.hello(Hello(
            contract: Contract.revision, side: "guest", version: "0.1.0",
            build: nil, agent: nil, name: "PowerBook 1400", os: "9.1",
            chunk: 8192)))
        try await waitUntil("host hello") { !guest.received.isEmpty }

        var controller: MirrorContinuityController? =
            MirrorContinuityController(listener: listener, defaults: defaults)
        controller?.requestedHz = 60
        controller?.autoReconnect = true
        controller?.fastPump = true
        controller?.settleSyntheticDevice = true
        XCTAssertTrue(controller?.interruptPress == true)
        XCTAssertTrue(controller?.settleIdleCursor == true)
        controller?.interruptPress = false
        controller?.settleIdleCursor = false
        controller?.keyboardForwardingEnabled = false
        controller?.escapeShortcut = .controlOptionReturn
        controller?.isEnabled = true
        controller = nil

        let reopened = MirrorContinuityController(listener: listener,
                                                  defaults: defaults)
        XCTAssertEqual(reopened.requestedHz, 60)
        XCTAssertTrue(reopened.autoReconnect)
        XCTAssertTrue(reopened.fastPump)
        XCTAssertTrue(reopened.settleSyntheticDevice)
        XCTAssertFalse(reopened.interruptPress)
        XCTAssertFalse(reopened.settleIdleCursor)
        XCTAssertFalse(reopened.keyboardForwardingEnabled)
        XCTAssertEqual(reopened.escapeShortcut, .controlOptionReturn)
        XCTAssertFalse(reopened.isEnabled,
                       "opening a new Mirror session must not seize input")
    }

    /// Item 1 of the Continuity Accessibility fix: the system dialog is
    /// asked for only when the feature that needs it is actually turned
    /// on, and only once per launch — a second `beginEdgeMode` (a manual
    /// toggle off and on) must not re-show a dialog macOS already answered
    /// by listing the app in the Accessibility pane.
    func testBeginEdgeModePromptsForAccessibilityOncePerLaunch() {
        let accessibility = AccessibilityFake()
        let controller = MirrorContinuityController(
            listener: listener, defaults: defaults,
            accessibility: accessibility)

        controller.beginEdgeMode()
        XCTAssertEqual(accessibility.promptCount, 1)

        controller.endEdgeMode(reason: "test toggle off")
        controller.beginEdgeMode()
        XCTAssertEqual(accessibility.promptCount, 1,
                       "the same launch must not prompt a second time")
    }

    /// A process already trusted for Accessibility needs no dialog at all —
    /// prompting an already-granted person would be noise, not a request.
    func testBeginEdgeModeDoesNotPromptWhenAlreadyTrusted() {
        let accessibility = AccessibilityFake()
        accessibility.trusted = true
        let controller = MirrorContinuityController(
            listener: listener, defaults: defaults,
            accessibility: accessibility)

        controller.beginEdgeMode()

        XCTAssertEqual(accessibility.promptCount, 0)
    }

    /// The other half of "only when the feature is turned on": constructing
    /// the controller — which happens once at app launch, in
    /// `HostAppState` — must not itself ask for Accessibility. Only
    /// `beginEdgeMode` may.
    func testConstructingTheControllerNeverPrompts() {
        let accessibility = AccessibilityFake()
        _ = MirrorContinuityController(
            listener: listener, defaults: defaults,
            accessibility: accessibility)

        XCTAssertEqual(accessibility.promptCount, 0)
    }

    /// The half the 2026-08-14 metal round did not have. That log carried
    /// 31 lines naming the missing permission and NOT ONE naming what the
    /// app did about it, so nothing could distinguish "the prompt never
    /// fired" from "the prompt fired and macOS suppressed it". Each branch
    /// of the decision must say which branch it took.
    func testBeginEdgeModeAuditsThePromptDecision() {
        let accessibility = AccessibilityFake()
        var audits: [(HostLog.LogLevel, String)] = []
        let controller = MirrorContinuityController(
            listener: listener, defaults: defaults,
            accessibility: accessibility,
            audit: { audits.append(($0, $1)) })

        controller.beginEdgeMode()
        XCTAssertTrue(audits.contains { $0.1.contains("asking macOS for it") },
                      "the untrusted first ask must be named: \(audits)")
        XCTAssertTrue(audits.contains { $0.1.contains("asked macOS") },
                      "the outcome of the ask must be named: \(audits)")

        // Second turn-on this launch: suppressed by the once-per-launch
        // guard, and that suppression is the reading a metal round needs.
        audits.removeAll()
        controller.endEdgeMode(reason: "test toggle off")
        controller.beginEdgeMode()
        XCTAssertTrue(audits.contains {
            $0.1.contains("already asked")
        }, "the launch guard suppressing the prompt must be named: \(audits)")
    }

    /// The already-trusted branch is the one that looks identical to a
    /// broken prompt in a log that says nothing: no dialog appears, and
    /// without this line there is no way to tell that from a prompt macOS
    /// swallowed.
    func testBeginEdgeModeAuditsAlreadyTrusted() {
        let accessibility = AccessibilityFake()
        accessibility.trusted = true
        var audits: [(HostLog.LogLevel, String)] = []
        let controller = MirrorContinuityController(
            listener: listener, defaults: defaults,
            accessibility: accessibility,
            audit: { audits.append(($0, $1)) })

        controller.beginEdgeMode()

        XCTAssertTrue(audits.contains {
            $0.1.contains("already granted")
        }, "an already-trusted launch must say so: \(audits)")
        XCTAssertFalse(audits.contains { $0.1.contains("asking macOS") })
    }

    /// The affordance that always works, unlike the one-shot prompt. It
    /// goes through the seam so a test never opens System Settings for
    /// real, and so the audit records that the person asked.
    func testOpenAccessibilitySettingsGoesThroughTheSeamAndIsAudited() {
        let accessibility = AccessibilityFake()
        var audits: [(HostLog.LogLevel, String)] = []
        let controller = MirrorContinuityController(
            listener: listener, defaults: defaults,
            accessibility: accessibility,
            audit: { audits.append(($0, $1)) })

        controller.openAccessibilitySettings()

        XCTAssertEqual(accessibility.openSettingsCount, 1)
        XCTAssertTrue(audits.contains {
            $0.1.contains("Accessibility pane")
        }, "the person's escape hatch must be readable in the log: \(audits)")
    }

    /// Fakes the two AX calls `beginEdgeMode` depends on, without ever
    /// touching the real system prompt.
    final class AccessibilityFake: AccessibilityAuthorization, @unchecked Sendable {
        var trusted = false
        var promptCount = 0

        var openSettingsCount = 0

        func isProcessTrusted() -> Bool { trusted }
        func promptForTrust() { promptCount += 1 }
        func openAccessibilitySettings() { openSettingsCount += 1 }
    }
}
