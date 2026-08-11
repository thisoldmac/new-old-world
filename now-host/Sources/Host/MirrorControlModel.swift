import Combine
import Foundation

/// The host-owned policy and guest-observed lifecycle for NOW's native
/// data-driven Mirror. There is no second guest service, external launcher,
/// forwarded port, or QEMU input path behind this model.
@MainActor
final class MirrorControlModel: ObservableObject, GuestScopedModel {
    @Published var connection: GuestConnectionState = .disconnected {
        didSet { connectionChanged(from: oldValue) }
    }
    @Published private(set) var wireFacts: MirrorWireFacts?
    @Published private(set) var lifecycleError: String?
    @Published private(set) var isLifecycleChecking = false
    @Published private(set) var policyGeneration = 0

    private let guestProbe: MirrorGuestProbing
    private let policyStore: MirrorPlanePolicyStore
    private var policyDidChange: @MainActor () -> Void
    private var checkToken = 0
    private var pendingSince: [MirrorPlaneID: Date] = [:]
    private var pendingWake: Task<Void, Never>?
    private var factsByGuest: [GuestKey: MirrorWireFacts] = [:]
    private var guestsByKey: [GuestKey: ConnectedGuest] = [:]
    private static let pendingTimeout: TimeInterval = 5

    init(guestProbe: MirrorGuestProbing,
         defaults: UserDefaults = ProductIdentity.defaults,
         policyDidChange: @escaping @MainActor () -> Void = {}) {
        self.guestProbe = guestProbe
        self.policyStore = MirrorPlanePolicyStore(defaults: defaults)
        self.policyDidChange = policyDidChange
    }

    func refreshLifecycle() {
        guard connection.canCapture else {
            lifecycleError = "No Mac is connected."
            return
        }
        let requestedGuest = guestProbe.activeGuest
        if let requestedGuest { guestsByKey[requestedGuest.key] = requestedGuest }
        isLifecycleChecking = true
        lifecycleError = nil
        let token = checkToken
        guestProbe.readMirrorFacts { [weak self] result in
            guard let self, token == self.checkToken else { return }
            self.isLifecycleChecking = false
            switch result {
            case .success(let facts):
                self.wireFacts = facts
                if let requestedGuest {
                    self.factsByGuest[requestedGuest.key] = facts
                }
                self.updatePendingDeadlines(for: facts, now: Date())
                self.logIdentity(facts, guest: requestedGuest)
            case .failure(let failure):
                self.lifecycleError = failure.reason
            }
        }
    }

    /// Writes which machine and which resident answered, beside the act
    /// measurements they will be read with. See
    /// `MirrorActTimeline.identityLine` for why this is not decoration.
    private func logIdentity(_ facts: MirrorWireFacts,
                             guest: ConnectedGuest?) {
        let line = MirrorActTimeline.identityLine(
            guestName: guest?.name ?? "unknown",
            guestBuild: guest?.build,
            address: guest.map { "\($0.address)" },
            lifecycle: facts.resident.lifecycle.rawValue,
            residentBuild: facts.resident.buildFingerprint,
            capabilities: facts.resident.capabilities,
            requested: facts.resident.requested,
            active: facts.resident.active,
            planes: facts.planes)
        ActLog.note(action: "identity\n    " + line,
                    outcome: facts.resident.lifecycle.rawValue, ms: 0)
    }

    var planeFacts: [MirrorWirePlane] { wireFacts?.planes ?? [] }

    func policyEnabled(_ plane: MirrorPlaneID) -> Bool {
        guard let guest = guestProbe.activeGuest else { return true }
        return policyEnabled(plane, for: guest)
    }

    private func policyEnabled(_ plane: MirrorPlaneID,
                               for guest: ConnectedGuest) -> Bool {
        return policyStore.isEnabled(
            plane, machineID: guest.id.slug,
            identityAnchored: guest.idIsAnchored,
            sessionID: guest.sessionID)
    }

    func setPolicy(_ enabled: Bool, for plane: MirrorPlaneID) {
        guard plane.isUserPolicy, let guest = guestProbe.activeGuest else {
            return
        }
        policyStore.set(enabled, plane: plane, machineID: guest.id.slug,
                        identityAnchored: guest.idIsAnchored,
                        sessionID: guest.sessionID)
        policyGeneration &+= 1
        policyDidChange()
        refreshLifecycle()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshLifecycle()
        }
    }

    func bindPolicyProjection(_ callback: @escaping @MainActor () -> Void) {
        policyDidChange = callback
    }

    func presentation(for plane: MirrorWirePlane) -> MirrorPlanePresentation {
        MirrorPlaneReducer.resolve(
            plane: plane,
            lifecycle: wireFacts?.resident.lifecycle ?? .absent,
            connected: connection.canCapture,
            policyEnabled: policyEnabled(plane.id),
            guestEnabled: wireFacts?.policy.allows(plane.id) ?? true,
            pendingTimedOut: pendingSince[plane.id].map {
                Date().timeIntervalSince($0) >= Self.pendingTimeout
            } ?? false)
    }

    func canToggle(_ plane: MirrorWirePlane) -> Bool {
        guard plane.id.isUserPolicy, plane.supported, connection.canCapture,
              let lifecycle = wireFacts?.resident.lifecycle else { return false }
        return (lifecycle == .active || lifecycle == .degraded)
            && (wireFacts?.policy.allows(plane.id) ?? true)
    }

    var requestedPlaneIDs: Set<MirrorPlaneID> {
        guard let key = guestProbe.activeGuest?.key else { return [.structure] }
        return requestedPlaneIDs(for: key)
    }

    /// Policy follows the session pinned by the Mirror, not the guest picker.
    /// The picker can move while a Mirror window remains open, so both the
    /// support facts and preference identity are retained by exact GuestKey.
    func requestedPlaneIDs(for key: GuestKey) -> Set<MirrorPlaneID> {
        if let active = guestProbe.activeGuest, active.key == key {
            guestsByKey[key] = active
            if let wireFacts { factsByGuest[key] = wireFacts }
        }
        guard let guest = guestsByKey[key], let facts = factsByGuest[key] else {
            return [.structure]
        }
        return Set(facts.planes.compactMap { plane in
            plane.supported && facts.policy.allows(plane.id)
                && policyEnabled(plane.id, for: guest)
                ? plane.id : nil
        })
    }

    func finderComplementsAllowed(for key: GuestKey) -> Bool {
        if let active = guestProbe.activeGuest, active.key == key,
           let wireFacts {
            factsByGuest[key] = wireFacts
        }
        return factsByGuest[key]?.policy.finderComplements ?? false
    }

    private func updatePendingDeadlines(for facts: MirrorWireFacts, now: Date) {
        let pending = Set<MirrorPlaneID>(facts.planes.compactMap { plane in
            guard plane.supported, facts.policy.allows(plane.id),
                  policyEnabled(plane.id),
                  plane.state == .requested,
                  facts.resident.lifecycle == .active
                    || facts.resident.lifecycle == .degraded else { return nil }
            return plane.id
        })
        pendingSince = pendingSince.filter { pending.contains($0.key) }
        for plane in pending where pendingSince[plane] == nil {
            pendingSince[plane] = now
        }
        schedulePendingWake(now: now)
    }

    private func schedulePendingWake(now: Date) {
        pendingWake?.cancel()
        let future = pendingSince.values
            .map { $0.addingTimeInterval(Self.pendingTimeout) }
            .filter { $0 > now }
            .min()
        guard let future else { return }
        let delay = UInt64(max(0, future.timeIntervalSince(now))
                           * 1_000_000_000)
        pendingWake = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self else { return }
            self.policyGeneration &+= 1
            self.refreshLifecycle()
        }
    }

    private func connectionChanged(from old: GuestConnectionState) {
        guard connection != old else { return }
        checkToken += 1
        isLifecycleChecking = false
        pendingWake?.cancel()
        pendingSince.removeAll()

        /* A disconnect pins the last guest facts so every row can say stale
           and disconnected. A switch names a different machine, so carrying
           the old resident identity across it would be a lie. */
        if let newKey = connection.key, newKey != old.key {
            wireFacts = nil
            lifecycleError = nil
            refreshLifecycle()
        }
    }
}

struct MirrorProbeFailure: Error, Equatable, Sendable {
    var reason: String
    init(_ reason: String) { self.reason = reason }
}

@MainActor
protocol MirrorGuestProbing: AnyObject {
    var activeGuest: ConnectedGuest? { get }
    func readMirrorFacts(
        completion: @escaping (Result<MirrorWireFacts, MirrorProbeFailure>) -> Void)
}

@MainActor
final class MirrorGuestWireProbe: MirrorGuestProbing {
    private let listener: GuestListener

    init(listener: GuestListener) { self.listener = listener }

    var activeGuest: ConnectedGuest? {
        listener.guests.first { $0.isActive }
    }

    func readMirrorFacts(
        completion: @escaping (Result<MirrorWireFacts, MirrorProbeFailure>) -> Void) {
        listener.runScheduledCommand(
            "mirror", purpose: .command("Mirror lifecycle"),
            workClass: .structuralRepair) { result in
            guard result.ok else {
                completion(.failure(MirrorProbeFailure(
                    result.error?.message ?? "The Mac refused mirror facts.")))
                return
            }
            guard let value = result.outputObjects?["mirror"] else {
                completion(.failure(MirrorProbeFailure(
                    "The Mac returned no unified mirror object.")))
                return
            }
            do {
                let data = try JSONEncoder().encode(value)
                completion(.success(try JSONDecoder().decode(
                    MirrorWireFacts.self, from: data)))
            } catch {
                completion(.failure(MirrorProbeFailure(
                    "The Mac's mirror facts do not match schema 1: \(error)")))
            }
        }
    }
}
