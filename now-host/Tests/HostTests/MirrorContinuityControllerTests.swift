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

    private struct ArmingRig {
        let guest: FakeGuest
        let controller: MirrorContinuityController
        let arm: ContinuityArm
    }

    private func makeArmingRig(
        initial: MirrorKit.Point = .init(x: 40, y: 50),
        autoReconnect: Bool = false,
        fastPump: Bool = false,
        pinHeldPoint: Bool = false,
        virtualGetMouse: Bool = false,
        settleSyntheticDevice: Bool = false,
        hideGuestCursorWhileDragging: Bool = false,
        acknowledgementTimeout: TimeInterval = 3,
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
            acknowledgementTimeout: acknowledgementTimeout, audit: audit)
        controller.autoReconnect = autoReconnect
        controller.fastPump = fastPump
        controller.pinHeldPoint = pinHeldPoint
        controller.virtualGetMouse = virtualGetMouse
        controller.settleSyntheticDevice = settleSyntheticDevice
        controller.hideGuestCursorWhileDragging =
            hideGuestCursorWhileDragging
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
        audit: MirrorContinuityController.Audit? = nil
    ) async throws -> ActiveRig {
        let port = try XCTUnwrap(listener.boundPort)
        let udp = try FakeContinuityUDP(port: port)
        udp.start()
        try await waitUntil("UDP listener") { udp.ready }
        let rig = try await makeArmingRig(
            initial: initial, autoReconnect: autoReconnect,
            fastPump: fastPump,
            acknowledgementTimeout: acknowledgementTimeout, audit: audit)
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

    func testAppKitConfirmedSecondClickCarriesPrecedingUpWithoutWaitingForAck()
        async throws {
        let rig = try await makeActiveRig()
        defer { rig.udp.stop() }
        /* The scenario under test is a starved application with a live
           resident: acknowledgements stall while liveness keeps answering.
           Without this, the silence lane ends ownership first and the
           cycle-abandon path below can never be observed. */
        rig.controller.machineIsAnsweringOverride = { _ in true }

        let source = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(rig.controller.primaryDown(
            at: .init(x: 40, y: 50), inMenuBar: false,
            sourceUptime: source, clickCount: 1))
        try await waitUntil("first confirmed press") {
            rig.udp.packets.contains {
                $0.flags.contains(.primaryDown) && $0.buttonGeneration != 0
            }
        }
        let firstDown = try XCTUnwrap(rig.udp.packets.last {
            $0.flags.contains(.primaryDown) && $0.buttonGeneration != 0
        })
        rig.udp.acknowledge(firstDown)
        XCTAssertTrue(rig.controller.primaryUp(at: .init(x: 40, y: 50)))
        try await waitUntil("first confirmed release") {
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

        XCTAssertTrue(rig.controller.primaryDown(
            at: .init(x: 42, y: 52), inMenuBar: false,
            sourceUptime: source + 0.12, clickCount: 2))
        XCTAssertTrue(rig.controller.primaryUp(at: .init(x: 42, y: 52)))
        try await waitUntil("second press before first release ack") {
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
                       firstUp.buttonGeneration)
        XCTAssertFalse(secondDown.previousButtonDown,
                       "v4 must carry the intervening up beside the second down")
        /* The second cycle rides guest task time that the click's own target
           may hold for hundreds of milliseconds; a slow acknowledgement is a
           starved cooperative guest, not a dead one. The timeout abandons
           only this cycle - forcing the wire button up inside the epoch so
           no logical hold can leak - and ownership survives. */
        try await waitUntil("unacknowledged press abandons its cycle",
                            timeout: 4.5) {
            rig.udp.packets.contains {
                $0.buttonGeneration != 0
                    && $0.buttonGeneration != firstDown.buttonGeneration
                    && $0.buttonGeneration != firstUp.buttonGeneration
                    && $0.buttonGeneration != secondDown.buttonGeneration
                    && !$0.flags.contains(.primaryDown)
            }
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
            $0.1.contains("primary down interval")
        }, "the first click of an epoch has no cross-epoch timing interval")
    }

    func testFastPumpIsRequestedOnlyWhenOptedIn() async throws {
        let fast = try await makeArmingRig(fastPump: true)
        XCTAssertEqual(fast.arm.fastPump, true)
    }

    func testHeldPointExperimentsAreRequestedOnlyWhenOptedIn() async throws {
        let experiments = try await makeArmingRig(
            pinHeldPoint: true, virtualGetMouse: true,
            settleSyntheticDevice: true,
            hideGuestCursorWhileDragging: true)
        XCTAssertEqual(experiments.arm.pinHeldPoint, true)
        XCTAssertEqual(experiments.arm.virtualGetMouse, true)
        XCTAssertEqual(experiments.arm.settleSyntheticDevice, true)
        XCTAssertEqual(experiments.arm.hideGuestCursorWhileDragging, true)
    }

    func testProductArmDoesNotEnableRejectedADBCarrierExperiment()
        async throws {
        let rig = try await makeArmingRig()
        XCTAssertEqual(rig.arm.virtualADB, false)
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
        controller?.pinHeldPoint = true
        controller?.virtualGetMouse = true
        controller?.settleSyntheticDevice = true
        controller?.hideGuestCursorWhileDragging = true
        controller?.keyboardForwardingEnabled = false
        controller?.escapeShortcut = .controlOptionReturn
        controller?.isEnabled = true
        controller = nil

        let reopened = MirrorContinuityController(listener: listener,
                                                  defaults: defaults)
        XCTAssertEqual(reopened.requestedHz, 60)
        XCTAssertTrue(reopened.autoReconnect)
        XCTAssertTrue(reopened.fastPump)
        XCTAssertTrue(reopened.pinHeldPoint)
        XCTAssertTrue(reopened.virtualGetMouse)
        XCTAssertTrue(reopened.settleSyntheticDevice)
        XCTAssertTrue(reopened.hideGuestCursorWhileDragging)
        XCTAssertFalse(reopened.keyboardForwardingEnabled)
        XCTAssertEqual(reopened.escapeShortcut, .controlOptionReturn)
        XCTAssertFalse(reopened.isEnabled,
                       "opening a new Mirror session must not seize input")
    }
}
