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

    private struct BufferedPrimaryCycle {
        var press: MirrorKit.Point
        var latest: MirrorKit.Point
        var release: MirrorKit.Point?
    }

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
            if !loadingSettings,
               let machine = listener.activeContinuityTarget?.key.machine {
                defaults.set(requestedHz, forKey: rateKey(for: machine))
            }
            if phase != .idle {
                rearmAfterConfigurationChange(reason: "rate changed")
            }
        }
    }
    @Published var autoReconnect = false {
        didSet {
            guard autoReconnect != oldValue, !loadingSettings,
                  let machine = listener.activeContinuityTarget?.key.machine
            else { return }
            defaults.set(autoReconnect, forKey: reconnectKey(for: machine))
        }
    }
    @Published var fastPump = false {
        didSet {
            guard fastPump != oldValue else { return }
            if !loadingSettings,
               let machine = listener.activeContinuityTarget?.key.machine {
                defaults.set(fastPump, forKey: fastPumpKey(for: machine))
            }
            if phase != .idle {
                rearmAfterConfigurationChange(reason: "Fast Pump changed")
            }
        }
    }
    @Published var pinHeldPoint = false {
        didSet {
            guard pinHeldPoint != oldValue else { return }
            if !loadingSettings,
               let machine = listener.activeContinuityTarget?.key.machine {
                defaults.set(pinHeldPoint,
                             forKey: pinHeldPointKey(for: machine))
            }
            if phase != .idle {
                rearmAfterConfigurationChange(reason: "held-point pin changed")
            }
        }
    }
    @Published var virtualGetMouse = false {
        didSet {
            guard virtualGetMouse != oldValue else { return }
            if !loadingSettings,
               let machine = listener.activeContinuityTarget?.key.machine {
                defaults.set(virtualGetMouse,
                             forKey: virtualGetMouseKey(for: machine))
            }
            if phase != .idle {
                rearmAfterConfigurationChange(reason: "GetMouse mode changed")
            }
        }
    }

    var isActive: Bool { phase == .active }
    @Published private(set) var isMenuTracking = false

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
    private var buttonGeneration: UInt32 = 0
    private var buttonCycleActive = false
    private var wireButtonDown = false
    private var pressAcknowledged = false
    private var releasePending = false
    private var deferredButtonPoint: MirrorKit.Point?
    private var bufferedButtonCycle: BufferedPrimaryCycle?
    private var capturingBufferedCycle = false
    private var primaryDownInMenuBar = false
    private var primaryCycleDragged = false
    private var menuLatched = false
    private var menuReleaseArmed = false
    private var pointerInside = false
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
    private var buttonAckTimeout: Task<Void, Never>?
    private var permissionRetry: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var waitingForLocalNetworkAccess = false
    private var permissionRetryCount = 0
    private var suppressEnabledObserver = false
    private var loadingSettings = false
    private var acceptedHz = 30
    private var sentDatagrams: UInt32 = 0
    private var validAcks: UInt32 = 0
    private var lastAuditedButtonGeneration: UInt32 = 0
    private var lastPrimaryDownUptime: TimeInterval?
    private var buttonTransitionSentUptime: TimeInterval?

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
        loadSettingsForActiveGuest()
    }

    func pointerMoved(to point: MirrorKit.Point) {
        pointerInside = true
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
        pointerInside = false
        guard phase != .idle else { return }
        if phase == .active { sendState(inside: false, keepalive: false) }
        relinquish(reason: "pointer left Mirror", keepEnabled: true)
    }

    @discardableResult
    func primaryDown(at point: MirrorKit.Point,
                     inMenuBar: Bool = false) -> Bool {
        guard phase == .active else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        if let lastPrimaryDownUptime {
            audit(.info, String(format: "primary down interval %.1f ms",
                                (now - lastPrimaryDownUptime) * 1_000))
        }
        lastPrimaryDownUptime = now
        if menuLatched, buttonCycleActive, wireButtonDown {
            self.point = point
            positionDirty = true
            deferredButtonPoint = point
            menuReleaseArmed = true
            return true
        }
        /* A human double-click can begin while the first manager-up is still
           settling on a cooperatively scheduled guest. Buffer exactly one
           complete following cycle instead of dropping that second click or
           letting it fall through to Mirror's semantic plane. */
        if buttonCycleActive {
            guard bufferedButtonCycle == nil,
                  releasePending || !wireButtonDown else {
                audit(.warn, "ignored primary down while button is held")
                return true
            }
            bufferedButtonCycle = BufferedPrimaryCycle(
                press: point, latest: point, release: nil)
            capturingBufferedCycle = true
            return true
        }
        beginPrimaryCycle(at: point, inMenuBar: inMenuBar)
        return true
    }

    private func beginPrimaryCycle(at point: MirrorKit.Point,
                                   releasedAt: MirrorKit.Point? = nil,
                                   inMenuBar: Bool = false) {
        self.point = point
        positionDirty = true
        advancePositionIfNeeded()
        buttonGeneration = nextNonzero(buttonGeneration)
        buttonCycleActive = true
        wireButtonDown = true
        pressAcknowledged = false
        releasePending = releasedAt != nil
        deferredButtonPoint = releasedAt
        primaryDownInMenuBar = inMenuBar
        primaryCycleDragged = false
        menuLatched = false
        menuReleaseArmed = false
        isMenuTracking = inMenuBar
        sendState(inside: true, keepalive: false)
        buttonTransitionSentUptime = ProcessInfo.processInfo.systemUptime
        scheduleButtonAckTimeout(generation: buttonGeneration, down: true)
    }

    @discardableResult
    func primaryDragged(to point: MirrorKit.Point) -> Bool {
        guard phase == .active else { return false }
        if capturingBufferedCycle, bufferedButtonCycle != nil {
            bufferedButtonCycle?.latest = point
            return true
        }
        guard buttonCycleActive else { return false }
        primaryCycleDragged = true
        if pressAcknowledged {
            self.point = point
            positionDirty = true
        } else {
            /* Keep the press point stable until the guest confirms its down
               event. The newest held point is sent immediately afterwards. */
            deferredButtonPoint = point
        }
        return true
    }

    @discardableResult
    func primaryUp(at point: MirrorKit.Point) -> Bool {
        guard phase == .active else { return false }
        if capturingBufferedCycle, bufferedButtonCycle != nil {
            bufferedButtonCycle?.latest = point
            bufferedButtonCycle?.release = point
            capturingBufferedCycle = false
            return true
        }
        guard buttonCycleActive else { return false }
        if menuLatched {
            guard menuReleaseArmed else { return true }
            menuLatched = false
            menuReleaseArmed = false
        } else if primaryDownInMenuBar && !primaryCycleDragged {
            /* The raw CDM path otherwise falls back to System 6/7-style
               hold-to-track behavior on this Mac OS 8/9 guest. Keep the
               native tracking loop alive after a stationary host click so
               the next click can select, matching the guest OS's click-open
               model. A real click-drag-release never enters this latch. */
            deferredButtonPoint = point
            menuLatched = true
            return true
        }
        isMenuTracking = false
        deferredButtonPoint = point
        releasePending = true
        if pressAcknowledged { sendPrimaryRelease() }
        return true
    }

    func cancel(reason: String) {
        pointerInside = false
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
        pointerInside = false
        loadSettingsForActiveGuest()
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
            requestedHz: rate, leaseTicks: 90, fastPump: fastPump,
            pinHeldPoint: pinHeldPoint,
            virtualGetMouse: virtualGetMouse)
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
            + "appliedPosition=\(report.appliedPositionSequence ?? 0), "
            + "appliedButton=\(report.appliedButtonGeneration ?? 0)")
        guard report.version == ContinuityContract.version else {
            guestEnded(reason: report.version == nil
                ? "the guest is missing Continuity control version "
                    + "\(ContinuityContract.version)"
                : "the guest reported Continuity control version "
                    + "\(report.version!), expected "
                    + "\(ContinuityContract.version)", retryable: false)
            return
        }
        if report.id == armID {
            guard report.state == "armed", let port = report.udpPort,
                  port > 0, port <= Int(UInt16.max) else {
                guestEnded(reason: reportDescription(report),
                           retryable: report.reason != "unsupported"
                               && report.reason != "wrong-version",
                           retryImmediately: report.reason != "guest-input")
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
            guestEnded(reason: reportDescription(report),
                       retryable: report.reason != "unsupported"
                           && report.reason != "wrong-version",
                       retryImmediately: report.reason != "guest-input")
        }
    }

    private func openUDP(host: String, port: UInt16) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            guestEnded(reason: "invalid UDP port", retryable: false)
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
                    self.status = "direct pointer connected at "
                        + "\(self.acceptedHz) Hz"
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
        if wireButtonDown { flags.insert(.primaryDown) }
        if keepalive { flags.insert(.keepalive) }
        let packet = ContinuityStateDatagram(
            nonceHi: nonceHi, nonceLo: nonceLo, epoch: epoch,
            positionSequence: positionSequence,
            h: Int16(clamping: point.x), v: Int16(clamping: point.y),
            buttonGeneration: buttonGeneration, flags: flags,
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
                            || ack.state == .inactive
                            || ack.buttonGeneration
                                != self.lastAuditedButtonGeneration {
                            self.audit(.info, "UDP acknowledgement: "
                                + "state=\(ack.state), "
                                + "reason=\(ack.exitReason), "
                                + "positionSequence=\(ack.positionSequence), "
                                + "buttonGeneration=\(ack.buttonGeneration), "
                                + "arrivalTicks=\(ack.arrivalTicks), "
                                + "applyTicks=\(ack.applyTicks), "
                                + "rejected=\(ack.rejectedPackets)")
                            self.lastAuditedButtonGeneration =
                                ack.buttonGeneration
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
        applyButtonAcknowledgement(ack)
        if ack.exitReason != .none || ack.state == .inactive {
            guestEnded(reason: exitDescription(ack.exitReason),
                       retryImmediately: ack.exitReason != .guestInput)
        }
    }

    private func applyButtonAcknowledgement(_ ack: ContinuityAckDatagram) {
        guard buttonCycleActive,
              ack.buttonGeneration == buttonGeneration else { return }
        if let sent = buttonTransitionSentUptime {
            let direction = wireButtonDown ? "down" : "up"
            audit(.info, String(format: "primary %@ acknowledged in %.1f ms",
                                direction,
                                (ProcessInfo.processInfo.systemUptime - sent)
                                    * 1_000))
            buttonTransitionSentUptime = nil
        }
        if wireButtonDown {
            guard !pressAcknowledged else { return }
            pressAcknowledged = true
            buttonAckTimeout?.cancel()
            buttonAckTimeout = nil
            if releasePending {
                sendPrimaryRelease()
            } else if let deferredButtonPoint {
                point = deferredButtonPoint
                self.deferredButtonPoint = nil
                positionDirty = true
                advancePositionIfNeeded()
                sendState(inside: true, keepalive: false)
            }
        } else {
            buttonAckTimeout?.cancel()
            buttonAckTimeout = nil
            buttonCycleActive = false
            releasePending = false
            deferredButtonPoint = nil
            primaryDownInMenuBar = false
            primaryCycleDragged = false
            menuLatched = false
            menuReleaseArmed = false
            startBufferedPrimaryCycleIfNeeded()
        }
    }

    private func startBufferedPrimaryCycleIfNeeded() {
        guard let bufferedButtonCycle else { return }
        self.bufferedButtonCycle = nil
        capturingBufferedCycle = false
        beginPrimaryCycle(at: bufferedButtonCycle.press,
                          releasedAt: bufferedButtonCycle.release)
        if bufferedButtonCycle.release == nil,
           bufferedButtonCycle.latest != bufferedButtonCycle.press {
            deferredButtonPoint = bufferedButtonCycle.latest
        }
    }

    private func sendPrimaryRelease() {
        guard phase == .active, buttonCycleActive, wireButtonDown else {
            return
        }
        if let deferredButtonPoint {
            point = deferredButtonPoint
        }
        deferredButtonPoint = nil
        positionDirty = true
        advancePositionIfNeeded()
        buttonGeneration = nextNonzero(buttonGeneration)
        wireButtonDown = false
        releasePending = false
        buttonAckTimeout?.cancel()
        buttonAckTimeout = nil
        sendState(inside: true, keepalive: false)
        buttonTransitionSentUptime = ProcessInfo.processInfo.systemUptime
        scheduleButtonAckTimeout(generation: buttonGeneration, down: false)
    }

    private func scheduleButtonAckTimeout(generation: UInt32, down: Bool) {
        buttonAckTimeout?.cancel()
        buttonAckTimeout = Task { @MainActor [weak self] in
            /* Down must settle quickly before a hold is considered live. Up
               is already safe in low memory and can wait for a starved NOW
               task to regain cooperative time after the target tracking loop
               unwinds. */
            try? await Task.sleep(
                nanoseconds: down ? 1_000_000_000 : 5_000_000_000)
            guard let self, !Task.isCancelled,
                  self.phase == .active, self.buttonCycleActive,
                  self.wireButtonDown == down,
                  self.buttonGeneration == generation,
                  !down || !self.pressAcknowledged else { return }
            let transition = down ? "down" : "up"
            self.audit(.error, "primary \(transition) was not acknowledged; "
                + "ending epoch=\(self.epoch), generation=\(generation)")
            self.relinquish(reason: "button \(transition) acknowledgement timed out",
                            keepEnabled: true)
            self.scheduleReconnect(reason: "button \(transition) timeout")
        }
    }

    private func rearmAfterConfigurationChange(reason: String) {
        let shouldRearm = isEnabled && pointerInside
        relinquish(reason: reason, keepEnabled: true)
        if shouldRearm {
            scheduleReconnect(reason: reason, delay: 0.25,
                              requiresOptIn: false)
        }
    }

    private func scheduleReconnect(reason: String, delay: Double = 0.75,
                                   requiresOptIn: Bool = true) {
        guard (!requiresOptIn || autoReconnect), isEnabled, pointerInside,
              listener.activeContinuityTarget != nil else { return }
        reconnectTask?.cancel()
        status = "Continuity interrupted; reconnecting…"
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled,
                  (!requiresOptIn || self.autoReconnect),
                  self.isEnabled, self.pointerInside,
                  self.phase == .idle,
                  self.listener.activeContinuityTarget != nil else { return }
            self.reconnectTask = nil
            self.positionDirty = true
            self.audit(.info, "automatic reconnect: reason=\(reason)")
            self.arm()
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
        if phase == .active, buttonCycleActive, wireButtonDown {
            if let deferredButtonPoint { point = deferredButtonPoint }
            positionDirty = true
            advancePositionIfNeeded()
            buttonGeneration = nextNonzero(buttonGeneration)
            wireButtonDown = false
            sendState(inside: false, keepalive: false)
        }
        timer?.cancel()
        timer = nil
        armTimeout?.cancel()
        armTimeout = nil
        buttonAckTimeout?.cancel()
        buttonAckTimeout = nil
        permissionRetry?.cancel()
        permissionRetry = nil
        reconnectTask?.cancel()
        reconnectTask = nil
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
        lastAuditedButtonGeneration = 0
        lastPrimaryDownUptime = nil
        buttonTransitionSentUptime = nil
        resetButtonState()
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

    private func guestEnded(reason: String, retryable: Bool = true,
                            retryImmediately: Bool = true) {
        audit(.warn, "guest ended Continuity: reason=\(reason), "
            + "epoch=\(epoch), sent=\(sentDatagrams), "
            + "validAcks=\(validAcks)")
        resetTransport()
        if autoReconnect && retryable && isEnabled {
            if retryImmediately {
                status = "Continuity ended on the Mac: \(reason); reconnecting…"
                scheduleReconnect(reason: reason)
            } else {
                status = "Continuity ended on the Mac: \(reason); move the "
                    + "host pointer to reconnect"
            }
        } else {
            status = "Continuity ended on the Mac: \(reason)"
            setEnabledWithoutTeardown(false)
        }
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
        buttonAckTimeout?.cancel()
        buttonAckTimeout = nil
        permissionRetry?.cancel()
        permissionRetry = nil
        reconnectTask?.cancel()
        reconnectTask = nil
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
        lastAuditedButtonGeneration = 0
        resetButtonState()
    }

    private func resetButtonState() {
        buttonCycleActive = false
        wireButtonDown = false
        pressAcknowledged = false
        releasePending = false
        deferredButtonPoint = nil
        bufferedButtonCycle = nil
        capturingBufferedCycle = false
        primaryDownInMenuBar = false
        primaryCycleDragged = false
        menuLatched = false
        menuReleaseArmed = false
        isMenuTracking = false
    }

    private func setEnabledWithoutTeardown(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        suppressEnabledObserver = true
        isEnabled = enabled
        suppressEnabledObserver = false
    }

    private func loadSettingsForActiveGuest() {
        guard let machine = listener.activeContinuityTarget?.key.machine else {
            return
        }
        let stored = defaults.integer(forKey: rateKey(for: machine))
        let rate = [15, 30, 60].contains(stored) ? stored : 30
        loadingSettings = true
        requestedHz = rate
        autoReconnect = defaults.bool(forKey: reconnectKey(for: machine))
        fastPump = defaults.bool(forKey: fastPumpKey(for: machine))
        pinHeldPoint = defaults.bool(forKey: pinHeldPointKey(for: machine))
        virtualGetMouse = defaults.bool(forKey: virtualGetMouseKey(for: machine))
        loadingSettings = false
    }

    private func rateKey(for machine: GuestID) -> String {
        "mirror.continuity.rate.\(machine.slug)"
    }

    private func reconnectKey(for machine: GuestID) -> String {
        "mirror.continuity.autoReconnect.\(machine.slug)"
    }

    private func fastPumpKey(for machine: GuestID) -> String {
        "mirror.continuity.fastPump.\(machine.slug)"
    }

    private func pinHeldPointKey(for machine: GuestID) -> String {
        "mirror.continuity.pinHeldPoint.\(machine.slug)"
    }

    private func virtualGetMouseKey(for machine: GuestID) -> String {
        "mirror.continuity.virtualGetMouse.\(machine.slug)"
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
