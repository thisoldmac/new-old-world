import Foundation

enum MirrorPlaneID: String, Codable, CaseIterable, Identifiable, Sendable {
    case structure
    case semantics
    case content
    case interaction
    /// P5. Appended last, matching the guest's own ordering, because both
    /// sides read these rows positionally and a reordering would silently
    /// relabel four planes.
    case transitions

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var isUserPolicy: Bool { self != .structure }
}

enum MirrorExtensionLifecycle: String, Codable, Equatable, Sendable {
    case absent
    case needsRestart = "needs-restart"
    case wrongVersion = "wrong-version"
    case active
    case degraded
}

enum MirrorPlaneFreshness: String, Codable, Equatable, Sendable {
    case unavailable
    case pending
    case stale
    case current
}

enum MirrorGuestPlaneState: String, Codable, Equatable, Sendable {
    case unsupported
    case inactive
    case requested
    case refused
    case degraded
    case activeStale = "active-stale"
    case activeCurrent = "active-current"
}

struct MirrorWireExtension: Codable, Equatable, Sendable {
    var selector: String
    var lifecycle: MirrorExtensionLifecycle
    var expectedMajor: Int
    var residentMajor: Int?
    var residentMinor: Int?
    var tableLength: Int?
    var capabilities: Int?
    var requested: Int?
    var active: Int?
    var heartbeat: Int?
    var sourceManifest: String?
    var buildFingerprint: String?
    var reason: String?
}

struct MirrorWirePlane: Codable, Equatable, Identifiable, Sendable {
    var id: MirrorPlaneID
    var purpose: String
    var capability: Int
    var supported: Bool
    var format: Int
    var requested: Bool
    var active: Bool
    var freshness: MirrorPlaneFreshness
    var state: MirrorGuestPlaneState
    var generation: Int
    var reason: String?
}

/* In an extension so the memberwise initialiser survives. Declared
   inside the struct it suppressed the memberwise one, and every call
   site that builds a plane field by field stopped compiling. */
extension MirrorWirePlane {
    /// The row a guest that predates this plane could not have sent.
    /// Reported as present-and-unsupported rather than absent, which is
    /// the same distinction the wire keeps for every other plane: an
    /// unsupported plane and an unasked one must not collapse.
    init(unsupported plane: MirrorPlaneID) {
        self.init(id: plane,
                  purpose: "Not reported by this Mac's extension",
                  capability: 0, supported: false, format: 0,
                  requested: false, active: false,
                  freshness: .unavailable, state: .unsupported,
                  generation: 0,
                  reason: "This Mac's NOW Extension predates the plane.")
    }
}

struct MirrorWireFacts: Codable, Equatable, Sendable {
    var schema: Int
    var resident: MirrorWireExtension
    var planes: [MirrorWirePlane]

    private enum CodingKeys: String, CodingKey {
        case schema
        case resident = "extension"
        case planes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        guard schema == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .schema, in: c,
                debugDescription: "unsupported mirror schema \(schema)")
        }
        resident = try c.decode(MirrorWireExtension.self, forKey: .resident)
        guard resident.selector == "NWex" else {
            throw DecodingError.dataCorruptedError(
                forKey: .resident, in: c,
                debugDescription: "mirror facts did not describe NWex")
        }
        let reported = try c.decode([MirrorWirePlane].self, forKey: .planes)
        /* A guest built before a plane existed knows nothing of it and
           honestly sends a shorter list. Refusing that is the NEWER side
           reinterpreting an older peer's correct message as a fault —
           the opposite of the rule this project holds, which is that an
           older reader refuses a newer message rather than guessing at
           it. So a PREFIX of the known planes is accepted and the
           missing trailing rows are filled as unsupported.

           Michelle saw the refusal this replaces on 2026-08-05: the
           Mirror page read "The Mac's mirror facts do not match schema
           1 … must carry every plane, in order" against a guest that was
           reporting its four planes perfectly correctly. */
        guard reported.map(\.id)
                == Array(MirrorPlaneID.allCases.prefix(reported.count)),
              !reported.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .planes, in: c,
                debugDescription:
                    "mirror facts must carry the planes in order, "
                    + "starting from structure")
        }
        planes = reported + MirrorPlaneID.allCases
            .dropFirst(reported.count)
            .map { MirrorWirePlane(unsupported: $0) }
    }

    init(schema: Int, resident: MirrorWireExtension,
         planes: [MirrorWirePlane]) {
        self.schema = schema
        self.resident = resident
        self.planes = planes
    }
}

enum MirrorPlanePresentation: Equatable, Sendable {
    case unsupported
    case disconnected
    case userDisabled
    case unavailable(MirrorExtensionLifecycle)
    case refused(String)
    case degraded(String)
    case enabledInactive
    case requested
    case activeStale
    case activeCurrent

    var label: String {
        switch self {
        case .unsupported: return "Unsupported"
        case .disconnected: return "Disconnected"
        case .userDisabled: return "Off"
        case .unavailable(let lifecycle):
            switch lifecycle {
            case .absent: return "Extension absent"
            case .needsRestart: return "Restart required"
            case .wrongVersion: return "Wrong version"
            case .active: return "Unavailable"
            case .degraded: return "Degraded"
            }
        case .refused: return "Refused"
        case .degraded: return "Degraded"
        case .enabledInactive: return "Enabled, inactive"
        case .requested: return "Requested"
        case .activeStale: return "Active, stale"
        case .activeCurrent: return "Active"
        }
    }

    var explanation: String? {
        switch self {
        case .refused(let reason), .degraded(let reason): return reason
        default: return nil
        }
    }
}

enum MirrorPlaneReducer {
    static func resolve(plane: MirrorWirePlane,
                        lifecycle: MirrorExtensionLifecycle,
                        connected: Bool,
                        policyEnabled: Bool,
                        pendingTimedOut: Bool = false) -> MirrorPlanePresentation {
        if !plane.supported { return .unsupported }
        if !connected { return .disconnected }
        guard lifecycle == .active || lifecycle == .degraded else {
            return .unavailable(lifecycle)
        }
        if !policyEnabled { return .userDisabled }
        switch plane.state {
        case .unsupported:
            return .unsupported
        case .refused:
            return .refused(plane.reason ?? "The resident refused this plane.")
        case .degraded:
            return .degraded(plane.reason ?? "This plane is degraded.")
        case .inactive:
            return .enabledInactive
        case .requested:
            return pendingTimedOut
                ? .degraded("The resident did not activate this plane within 5 seconds.")
                : .requested
        case .activeStale:
            return .activeStale
        case .activeCurrent:
            return .activeCurrent
        }
    }
}

/// Only user intent is stored. Support, request, active, freshness and refusal
/// are live guest facts and are never written into preferences.
final class MirrorPlanePolicyStore {
    private let defaults: UserDefaults
    private var sessions: [String: [MirrorPlaneID: Bool]] = [:]

    init(defaults: UserDefaults = ProductIdentity.defaults) {
        self.defaults = defaults
    }

    func isEnabled(_ plane: MirrorPlaneID, machineID: String,
                   identityAnchored: Bool, sessionID: String) -> Bool {
        guard plane.isUserPolicy else { return true }
        if identityAnchored {
            let key = persistentKey(plane, machineID: machineID)
            return defaults.object(forKey: key) == nil
                ? true : defaults.bool(forKey: key)
        }
        return sessions[sessionID]?[plane] ?? true
    }

    func set(_ enabled: Bool, plane: MirrorPlaneID, machineID: String,
             identityAnchored: Bool, sessionID: String) {
        guard plane.isUserPolicy else { return }
        if identityAnchored {
            defaults.set(enabled, forKey: persistentKey(plane,
                                                        machineID: machineID))
        } else {
            sessions[sessionID, default: [:]][plane] = enabled
        }
    }

    private func persistentKey(_ plane: MirrorPlaneID,
                               machineID: String) -> String {
        "mirror.policy.\(machineID).\(plane.rawValue)"
    }
}
