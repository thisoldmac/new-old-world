import Foundation

/// Host-owned authority for agent-visible guest files.
///
/// There is intentionally no UI setter in V0.5's first slice. Persisting the
/// approved default makes the authority inspectable and versioned instead of
/// inheriting the guest share silently. A future host Integrations surface may
/// own changes to these keys.
@MainActor
final class GuestFileAccessPolicy {
    static let rootKey = "files.agentGuestRoot"
    static let versionKey = "files.agentGuestRootVersion"

    struct Snapshot: Equatable, Sendable {
        let guestRoot: GuestFilePath
        let version: Int
    }

    private(set) var snapshot: Snapshot

    init(
        defaults: UserDefaults = ProductIdentity.defaults,
        audit: ((String) -> Void)? = nil
    ) {
        let writeAudit = audit ?? {
            HostLog.shared.write(.info, "files", $0)
        }
        if let stored = defaults.object(forKey: Self.rootKey) as? String {
            if let root = try? GuestFilePath(stored) {
                let storedVersion = defaults.integer(forKey: Self.versionKey)
                let version = max(1, storedVersion)
                if storedVersion < 1 {
                    defaults.set(version, forKey: Self.versionKey)
                }
                snapshot = Snapshot(guestRoot: root, version: version)
                writeAudit("agent guestRoot policy loaded: "
                           + "\(Self.describe(root)), version \(version)")
                return
            }
            writeAudit(
                "invalid stored agent guestRoot policy rejected; "
                + "restoring approved share-root default")
        }

        let root = GuestFilePath(unchecked: "")
        let version = 1
        defaults.set(root.wireValue, forKey: Self.rootKey)
        defaults.set(version, forKey: Self.versionKey)
        snapshot = Snapshot(guestRoot: root, version: version)
        writeAudit(
            "agent guestRoot policy initialized: share root, version 1")
    }

    private static func describe(_ root: GuestFilePath) -> String {
        root.wireValue.isEmpty ? "share root" : root.wireValue
    }
}
