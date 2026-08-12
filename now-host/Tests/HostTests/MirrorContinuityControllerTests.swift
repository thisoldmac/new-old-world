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
            listener: listener, defaults: defaults, audit: audit)
        controller.autoReconnect = autoReconnect
        controller.fastPump = fastPump
        controller.pinHeldPoint = pinHeldPoint
        controller.virtualGetMouse = virtualGetMouse
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
        audit: MirrorContinuityController.Audit? = nil
    ) async throws -> ActiveRig {
        let port = try XCTUnwrap(listener.boundPort)
        let udp = try FakeContinuityUDP(port: port)
        udp.start()
        try await waitUntil("UDP listener") { udp.ready }
        let rig = try await makeArmingRig(
            initial: initial, autoReconnect: autoReconnect,
            fastPump: fastPump, audit: audit)
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

    func testDirectClickWaitsForPressAckBeforeSendingRelease()
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
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(rig.udp.packets.contains {
            $0.buttonGeneration != 0
                && $0.buttonGeneration != down.buttonGeneration
        }, "release must not outrun the press acknowledgement")

        rig.udp.acknowledge(down)
        try await waitUntil("primary release") {
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
        rig.udp.acknowledge(up)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(rig.controller.primaryDown(at: .init(x: 50, y: 60)),
                      "an acknowledged release opens the next click cycle")
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

    func testSecondClickIsBufferedUntilFirstReleaseSettles()
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

        XCTAssertTrue(rig.controller.primaryDown(at: .init(x: 42, y: 52)))
        XCTAssertTrue(rig.controller.primaryUp(at: .init(x: 42, y: 52)))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(rig.udp.packets.contains {
            $0.buttonGeneration != 0
                && $0.buttonGeneration != firstDown.buttonGeneration
                && $0.buttonGeneration != firstUp.buttonGeneration
        }, "the second click must wait for the first manager-up")

        rig.udp.acknowledge(firstUp)
        try await waitUntil("second press") {
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
        rig.udp.acknowledge(secondDown)
        try await waitUntil("second release") {
            rig.udp.packets.contains {
                $0.buttonGeneration != firstDown.buttonGeneration
                    && $0.buttonGeneration != firstUp.buttonGeneration
                    && $0.buttonGeneration != secondDown.buttonGeneration
                    && !$0.flags.contains(.primaryDown)
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

    func testFastPumpIsRequestedOnlyWhenOptedIn() async throws {
        let fast = try await makeArmingRig(fastPump: true)
        XCTAssertEqual(fast.arm.fastPump, true)
    }

    func testHeldPointExperimentsAreRequestedOnlyWhenOptedIn() async throws {
        let experiments = try await makeArmingRig(
            pinHeldPoint: true, virtualGetMouse: true)
        XCTAssertEqual(experiments.arm.pinHeldPoint, true)
        XCTAssertEqual(experiments.arm.virtualGetMouse, true)
    }

    func testClicksFallThroughUntilTheRawLaneIsActive() async throws {
        let rig = try await makeArmingRig()
        XCTAssertFalse(rig.controller.primaryDown(at: .init(x: 45, y: 55)))
        XCTAssertFalse(rig.controller.primaryDragged(to: .init(x: 50, y: 60)))
        XCTAssertFalse(rig.controller.primaryUp(at: .init(x: 50, y: 60)))
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
        controller?.isEnabled = true
        controller = nil

        let reopened = MirrorContinuityController(listener: listener,
                                                  defaults: defaults)
        XCTAssertEqual(reopened.requestedHz, 60)
        XCTAssertTrue(reopened.autoReconnect)
        XCTAssertTrue(reopened.fastPump)
        XCTAssertTrue(reopened.pinHeldPoint)
        XCTAssertTrue(reopened.virtualGetMouse)
        XCTAssertFalse(reopened.isEnabled,
                       "opening a new Mirror session must not seize input")
    }
}
