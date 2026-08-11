import Combine
import Foundation
import MirrorKit
import MirrorKitUI
import Network

/// Owns the optional raw-pointer lane. TCP grants authority; UDP carries
/// replaceable latest state and acknowledgements. Nothing here is reachable
/// from the command or agent surfaces.
@MainActor
final class MirrorContinuityController: ObservableObject,
                                      ContinuityInputDriver {
    typealias Audit = (HostLog.LogLevel, String) -> Void

    enum Phase: Equatable {
        case idle
        case arming
        case active
    }

    @Published var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if !isEnabled {
                relinquish(reason: "disabled", keepEnabled: false)
            } else {
                if let host = listener.activeContinuityTarget?.host {
                    localNetworkAccess?.verifyDirectAccess(to: host)
                    status = "requesting Local Network access; move over "
                        + "the Mirror to connect the pointers"
                } else {
                    status = "unavailable: no Mac is connected"
                }
            }
        }
    }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status = "off"
    @Published var requestedHz = 30 {
        didSet {
            guard requestedHz != oldValue else { return }
            guard [15, 30, 60].contains(requestedHz) else {
                requestedHz = 30
                return
            }
            if !loadingRate,
               let machine = listener.activeContinuityTarget?.key.machine {
                defaults.set(requestedHz, forKey: rateKey(for: machine))
            }
            if phase != .idle {
                relinquish(reason: "rate changed", keepEnabled: true)
            }
        }
    }

    var isActive: Bool { phase == .active }

    private let listener: GuestListener
    private let defaults: UserDefaults
    private let audit: Audit
    private weak var localNetworkAccess: LocalNetworkAccessController?
    private var target: GuestListener.ContinuityTarget?
    private var armID: Int?
    private var nonceHi: UInt32 = 0
    private var nonceLo: UInt32 = 0
    private var epoch: UInt32 = 0
    private var positionSequence: UInt32 = 0
    private var point = MirrorKit.Point(x: 0, y: 0)
    private var positionDirty = false
    private var idleIntervals = 0
    private var udp: NWConnection?
    /* Network.framework may spend time preparing a physical interface while
       the main actor is also reconciling Mirror scenes. The UDP state machine
       therefore owns a serial queue, and its ready callback puts the first
       state on the wire before handing presentation back to the main actor. */
    private let udpQueue = DispatchQueue(
        label: "dev.newoldworld.mirror.continuity.udp")
    private var timer: DispatchSourceTimer?
    private var armTimeout: Task<Void, Never>?
    private var permissionRetry: Task<Void, Never>?
    private var waitingForLocalNetworkAccess = false
    private var permissionRetryCount = 0
    private var suppressEnabledObserver = false
    private var loadingRate = false
    private var acceptedHz = 30
    private var sentDatagrams: UInt32 = 0
    private var validAcks: UInt32 = 0

    init(listener: GuestListener,
         defaults: UserDefaults = ProductIdentity.defaults,
         localNetworkAccess: LocalNetworkAccessController? = nil,
         audit: Audit? = nil) {
        self.listener = listener
        self.defaults = defaults
        self.localNetworkAccess = localNetworkAccess
        self.audit = audit ?? {
            HostLog.shared.write($0, "continuity", $1)
        }
        localNetworkAccess?.onDirectAccessReady = { [weak self] in
            self?.localNetworkAccessBecameReady()
        }
        listener.onContinuityReport = { [weak self] key, report in
            self?.received(report, from: key)
        }
        loadRateForActiveGuest()
    }

    func pointerMoved(to point: MirrorKit.Point) {
        self.point = point
        positionDirty = true
        guard isEnabled else { return }
        switch phase {
        case .idle: arm()
        case .arming: break
        case .active: break
        }
    }

    func pointerLeft() {
        guard phase != .idle else { return }
        if phase == .active { sendState(inside: false, keepalive: false) }
        relinquish(reason: "pointer left Mirror", keepEnabled: true)
    }

    @discardableResult
    func primaryDown(at point: MirrorKit.Point) -> Bool {
        /* v0 is movement only. Returning false leaves Mirror's existing
           semantic click path in charge; v0.5a will add a separately gated
           button contract after movement has earned metal safety. */
        _ = point
        return false
    }

    @discardableResult
    func primaryDragged(to point: MirrorKit.Point) -> Bool {
        _ = point
        return false
    }

    @discardableResult
    func primaryUp(at point: MirrorKit.Point) -> Bool {
        _ = point
        return false
    }

    func cancel(reason: String) {
        relinquish(reason: reason, keepEnabled: true)
    }

    /// Called while the outgoing guest is still authoritative, so its epoch
    /// can be explicitly retired before the listener changes focus.
    func sessionWillEnd(reason: String) {
        relinquish(reason: reason, keepEnabled: false)
        setEnabledWithoutTeardown(false)
    }

    /// A disconnect has no peer left to answer, and a focus switch must never
    /// send the old epoch's disarm to the newly selected guest.
    func sessionDidChange() {
        resetTransport()
        setEnabledWithoutTeardown(false)
        status = "off"
        loadRateForActiveGuest()
    }

    private func arm(permissionRetry: Bool = false) {
        if !permissionRetry { permissionRetryCount = 0 }
        guard let target = listener.activeContinuityTarget else {
            status = "unavailable: no Mac is connected"
            return
        }
        let rate = [15, 30, 60].contains(requestedHz) ? requestedHz : 30
        requestedHz = rate
        epoch = nextNonzero(epoch)
        repeat {
            nonceHi = UInt32.random(in: UInt32.min ... UInt32.max)
            nonceLo = UInt32.random(in: UInt32.min ... UInt32.max)
        } while nonceHi == 0 && nonceLo == 0
        self.target = target
        armID = listener.armContinuity(
            nonceHi: nonceHi, nonceLo: nonceLo, epoch: epoch,
            requestedHz: rate, leaseTicks: 90)
        guard armID != nil else {
            status = "unavailable: no Mac is connected"
            self.target = nil
            return
        }
        audit(.info, "arm requested: epoch=\(epoch), id=\(armID!), "
            + "rate=\(rate) Hz, guest=\(target.key.machine.slug)")
        phase = .arming
        status = "asking the Mac for pointer control…"
        let armedEpoch = epoch
        armTimeout?.cancel()
        armTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, !Task.isCancelled,
                  self.phase == .arming, self.epoch == armedEpoch else {
                return
            }
            self.relinquish(reason: "arm timed out", keepEnabled: false)
            self.setEnabledWithoutTeardown(false)
            self.status = "Continuity is unavailable"
        }
    }

    private func received(_ report: ContinuityReport, from key: GuestKey) {
        guard target?.key == key, report.epoch == epoch else {
            audit(.warn, "ignored control report: state=\(report.state), "
                + "reason=\(report.reason ?? "none"), epoch=\(report.epoch), "
                + "expectedEpoch=\(epoch), guest=\(key.machine.slug)")
            return
        }
        audit(.info, "control report: id=\(report.id.map(String.init) ?? "none"), "
            + "epoch=\(report.epoch), state=\(report.state), "
            + "reason=\(report.reason ?? "none"), "
            + "accepted=\(report.acceptedPackets ?? 0), "
            + "stale=\(report.stalePackets ?? 0), "
            + "malformed=\(report.malformedPackets ?? 0), "
            + "appliedPosition=\(report.appliedPositionSequence ?? 0)")
        guard report.version == ContinuityContract.version else {
            guestEnded(reason: report.version == nil
                ? "the guest is missing Continuity control version 1"
                : "the guest reported Continuity control version "
                    + "\(report.version!), expected 1")
            return
        }
        if report.id == armID {
            guard report.state == "armed", let port = report.udpPort,
                  port > 0, port <= Int(UInt16.max) else {
                guestEnded(reason: reportDescription(report))
                return
            }
            acceptedHz = [15, 30, 60].contains(report.acceptedHz ?? 0)
                ? report.acceptedHz! : requestedHz
            openUDP(host: target!.host, port: UInt16(port))
            return
        }
        /* A control reply is pending, so an uncorrelated terminal snapshot
           cannot settle this epoch. Older guests can publish the preceding
           exit after writing the new epoch but before P9 observes the arm;
           the correlated arm reply that follows is authoritative. */
        if phase == .arming, report.id == nil { return }
        if report.id == nil,
           report.state == "exited" || report.state == "refused" {
            guestEnded(reason: reportDescription(report))
        }
    }

    private func openUDP(host: String, port: UInt16) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            guestEnded(reason: "invalid UDP port")
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(host),
                                      port: nwPort, using: .udp)
        udp = connection
        audit(.info, "opening UDP pointer lane to \(host):\(port)")
        advancePositionIfNeeded()
        let initialState = encodedState(inside: true, keepalive: false)
        let initialSequence = positionSequence
        status = "opening the pointer lane…"
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            /* This send deliberately precedes the actor hop. The resident's
               live-input lease does not start until it accepts this packet,
               and a busy Mirror main actor must not be able to consume the
               startup grace before the first state is even queued. */
            if case .ready = state, let connection {
                connection.send(content: initialState,
                                completion: .contentProcessed {
                    [weak self, weak connection] error in
                    Task { @MainActor in
                        guard let self, let connection,
                              connection === self.udp else { return }
                        if let error {
                            self.audit(.error, "initial UDP state failed: "
                                + "\(String(describing: error)); "
                                + "epoch=\(self.epoch), "
                                + "positionSequence=\(initialSequence)")
                        } else {
                            self.audit(.info, "initial UDP state queued: "
                                + "epoch=\(self.epoch), "
                                + "positionSequence=\(initialSequence)")
                        }
                    }
                })
            }
            Task { @MainActor in
                guard let self, let connection,
                      connection === self.udp else { return }
                switch state {
                case .ready:
                    self.waitingForLocalNetworkAccess = false
                    self.permissionRetry?.cancel()
                    self.permissionRetry = nil
                    self.sentDatagrams = 1
                    self.audit(.info, "UDP pointer lane is ready")
                    self.localNetworkAccess?.directAccessBecameReady(
                        host: self.target?.host,
                        path: connection.currentPath.map(
                            String.init(describing:)))
                    self.armTimeout?.cancel()
                    self.armTimeout = nil
                    self.phase = .active
                    self.status = "pointer connected at \(self.acceptedHz) Hz"
                    self.startTimer()
                    self.receiveAck()
                case .failed(let error):
                    self.auditPointerLane("failed", error: error,
                                          connection: connection)
                    if case .posix(.ENETDOWN) = error {
                        self.pointerLaneWaitingForLocalNetworkAccess(
                            error: error, connection: connection)
                    } else {
                        self.guestEnded(reason: Self.pointerLaneFailure(error))
                    }
                case .waiting(let error):
                    self.auditPointerLane("waiting", error: error,
                                          connection: connection)
                    if case .posix(.ENETDOWN) = error {
                        self.pointerLaneWaitingForLocalNetworkAccess(
                            error: error, connection: connection)
                    } else {
                        self.status = Self.pointerLaneWaitingStatus(error)
                    }
                case .cancelled:
                    break
                default:
                    break
                }
            }
        }
        connection.start(queue: udpQueue)
    }

    func pointerLaneWaitingForLocalNetworkAccess(
        error: NWError = .posix(.ENETDOWN), connection: NWConnection? = nil
    ) {
        waitingForLocalNetworkAccess = true
        armTimeout?.cancel()
        armTimeout = nil
        let host = target?.host ?? "the connected Mac"
        let path = connection?.currentPath.map(String.init(describing:))
            ?? "no current path"
        localNetworkAccess?.directAccessIsWaiting(
            host: host, error: error, path: path)
        status = Self.pointerLaneWaitingStatus(error)
        if localNetworkAccess?.directAccessReady == true {
            schedulePermissionRetry()
        }
    }

    func localNetworkAccessBecameReady() {
        guard waitingForLocalNetworkAccess else { return }
        schedulePermissionRetry()
    }

    private func schedulePermissionRetry() {
        guard permissionRetry == nil, permissionRetryCount < 2 else { return }
        permissionRetry = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !Task.isCancelled,
                  self.waitingForLocalNetworkAccess, self.isEnabled else {
                return
            }
            self.permissionRetry = nil
            self.permissionRetryCount += 1
            self.relinquish(reason: "Local Network permission changed",
                            keepEnabled: true)
            self.positionDirty = true
            self.status = "Local Network access approved; reconnecting…"
            self.arm(permissionRetry: true)
        }
    }

    private func startTimer() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let interval = DispatchTimeInterval.nanoseconds(
            1_000_000_000 / max(1, acceptedHz))
        timer.schedule(deadline: .now() + interval, repeating: interval,
                       leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self, self.phase == .active else { return }
            if self.positionDirty {
                self.advancePositionIfNeeded()
                self.sendState(inside: true, keepalive: false)
                return
            }
            self.idleIntervals += 1
            if self.idleIntervals >= max(1, self.acceptedHz / 2) {
                self.idleIntervals = 0
                self.sendState(inside: true, keepalive: true)
            }
        }
        self.timer = timer
        timer.resume()
    }

    static func pointerLaneWaitingStatus(_ error: NWError) -> String {
        if case .posix(.ENETDOWN) = error {
            return "Waiting for macOS Local Network access. Approve its "
                + "prompt or enable NOW Continuity in System Settings > "
                + "Privacy & Security > Local Network."
        }
        return "waiting for the pointer lane: \(error.localizedDescription)"
    }

    static func pointerLaneFailure(_ error: NWError) -> String {
        if case .posix(.ENETDOWN) = error {
            return "macOS has not granted the Local Network path; approve "
                + "its prompt or enable NOW Continuity in System Settings > "
                + "Privacy & Security > Local Network"
        }
        return "UDP failed: \(error.localizedDescription)"
    }

    private func auditPointerLane(_ state: String, error: NWError,
                                  connection: NWConnection?) {
        let path = connection?.currentPath.map { String(describing: $0) }
            ?? "no current path"
        audit(
            state == "failed" ? .error : .warn,
            "UDP pointer lane \(state): \(String(describing: error)) — "
                + "\(error.localizedDescription); \(path)")
    }

    private func sendState(inside: Bool, keepalive: Bool) {
        guard let udp, phase == .active else { return }
        sentDatagrams &+= 1
        udp.send(content: encodedState(inside: inside, keepalive: keepalive),
                 completion: .idempotent)
    }

    private func encodedState(inside: Bool, keepalive: Bool) -> Data {
        var flags: ContinuityStateDatagram.Flags = []
        if inside { flags.insert(.inside) }
        if keepalive { flags.insert(.keepalive) }
        let packet = ContinuityStateDatagram(
            nonceHi: nonceHi, nonceLo: nonceLo, epoch: epoch,
            positionSequence: positionSequence,
            h: Int16(clamping: point.x), v: Int16(clamping: point.y),
            buttonGeneration: 0, flags: flags,
            requestedHz: UInt16(requestedHz),
            hostStamp: UInt32(truncatingIfNeeded:
                Int(ProcessInfo.processInfo.systemUptime * 60)))
        return ContinuityDatagramCodec.encode(packet)
    }

    private func receiveAck() {
        guard let udp else { return }
        udp.receiveMessage { [weak self, weak udp] data, _, _, error in
            Task { @MainActor in
                guard let self, udp === self.udp else { return }
                if let error {
                    self.audit(.error, "UDP acknowledgement receive failed: "
                        + "\(String(describing: error)); "
                        + "sent=\(self.sentDatagrams), "
                        + "validAcks=\(self.validAcks)")
                    return
                }
                if let data {
                    do {
                        let ack = try ContinuityDatagramCodec.decodeAck(data)
                        guard ack.nonceHi == self.nonceHi,
                              ack.nonceLo == self.nonceLo,
                              ack.epoch == self.epoch else {
                            self.audit(.warn, "ignored UDP acknowledgement "
                                + "for another lease: bytes=\(data.count), "
                                + "epoch=\(ack.epoch), expectedEpoch=\(self.epoch)")
                            if udp === self.udp { self.receiveAck() }
                            return
                        }
                        self.validAcks &+= 1
                        if self.validAcks == 1
                            || ack.exitReason != .none
                            || ack.state == .inactive {
                            self.audit(.info, "UDP acknowledgement: "
                                + "state=\(ack.state), "
                                + "reason=\(ack.exitReason), "
                                + "positionSequence=\(ack.positionSequence), "
                                + "arrivalTicks=\(ack.arrivalTicks), "
                                + "applyTicks=\(ack.applyTicks), "
                                + "rejected=\(ack.rejectedPackets)")
                        }
                        self.apply(ack)
                    } catch {
                        self.audit(.warn, "rejected UDP acknowledgement: "
                            + "bytes=\(data.count), error=\(String(describing: error))")
                    }
                }
                if udp === self.udp { self.receiveAck() }
            }
        }
    }

    private func apply(_ ack: ContinuityAckDatagram) {
        if ack.exitReason != .none || ack.state == .inactive {
            guestEnded(reason: exitDescription(ack.exitReason))
        }
    }

    private func advancePositionIfNeeded() {
        guard positionDirty else { return }
        positionSequence = nextNonzero(positionSequence)
        positionDirty = false
        idleIntervals = 0
    }

    private func relinquish(reason: String, keepEnabled: Bool) {
        let oldEpoch = epoch
        let wasOwned = phase != .idle
        let oldPhase = phase
        let oldSent = sentDatagrams
        let oldAcks = validAcks
        timer?.cancel()
        timer = nil
        armTimeout?.cancel()
        armTimeout = nil
        permissionRetry?.cancel()
        permissionRetry = nil
        waitingForLocalNetworkAccess = false
        udp?.cancel()
        udp = nil
        phase = .idle
        armID = nil
        target = nil
        positionDirty = false
        idleIntervals = 0
        sentDatagrams = 0
        validAcks = 0
        if wasOwned {
            audit(.info, "ending locally: reason=\(reason), "
                + "phase=\(oldPhase), epoch=\(oldEpoch), "
                + "sent=\(oldSent), validAcks=\(oldAcks)")
            _ = listener.disarmContinuity(
                epoch: oldEpoch, reason: wireDisarmReason(for: reason))
        }
        if !keepEnabled && !suppressEnabledObserver { status = "off" }
        else if keepEnabled { status = "move over the Mirror to reconnect" }
    }

    private func guestEnded(reason: String) {
        audit(.warn, "guest ended Continuity: reason=\(reason), "
            + "epoch=\(epoch), sent=\(sentDatagrams), "
            + "validAcks=\(validAcks)")
        resetTransport()
        status = "Continuity ended on the Mac: \(reason)"
        setEnabledWithoutTeardown(false)
    }

    private func reportDescription(_ report: ContinuityReport) -> String {
        let reason: String
        switch report.reason {
        case "wrong-version": reason = "the Continuity control versions differ"
        case "guest-input": reason = "the guest mouse moved"
        case "lease-expired": reason = "the input lease expired"
        case "host-left": reason = "the host pointer left"
        case "disarmed": reason = "disarmed"
        case .some(let value): reason = value
        case nil: reason = report.state
        }
        guard report.reason == "lease-expired" else { return reason }
        let accepted = report.acceptedPackets ?? 0
        let stale = report.stalePackets ?? 0
        let malformed = report.malformedPackets ?? 0
        return "\(reason) (\(accepted) accepted, \(stale) stale, "
            + "\(malformed) malformed)"
    }

    private func resetTransport() {
        timer?.cancel()
        timer = nil
        armTimeout?.cancel()
        armTimeout = nil
        permissionRetry?.cancel()
        permissionRetry = nil
        waitingForLocalNetworkAccess = false
        udp?.cancel()
        udp = nil
        phase = .idle
        armID = nil
        target = nil
        positionDirty = false
        idleIntervals = 0
        sentDatagrams = 0
        validAcks = 0
    }

    private func setEnabledWithoutTeardown(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        suppressEnabledObserver = true
        isEnabled = enabled
        suppressEnabledObserver = false
    }

    private func loadRateForActiveGuest() {
        guard let machine = listener.activeContinuityTarget?.key.machine else {
            return
        }
        let stored = defaults.integer(forKey: rateKey(for: machine))
        let rate = [15, 30, 60].contains(stored) ? stored : 30
        loadingRate = true
        requestedHz = rate
        loadingRate = false
    }

    private func rateKey(for machine: GuestID) -> String {
        "mirror.continuity.rate.\(machine.slug)"
    }

    private func wireDisarmReason(for reason: String) -> String {
        switch reason {
        case "disabled": return "disabled"
        case "pointer left Mirror": return "host-left"
        case "Mirror stopped": return "mirror-closed"
        default: return "disconnecting"
        }
    }

    private func exitDescription(_ reason: ContinuityAckDatagram.ExitReason)
        -> String {
        switch reason {
        case .none: return "inactive"
        case .hostLeft: return "host pointer left"
        case .guestInput: return "the guest mouse moved"
        case .leaseExpired: return "the input lease expired"
        case .disarmed: return "disarmed"
        }
    }

    private func nextNonzero(_ value: UInt32) -> UInt32 {
        let next = value &+ 1
        return next == 0 ? 1 : next
    }

}
