import AppKit
import Foundation

/// This Mac's running processes, in the guest's process.listing shape.
///
/// Symmetric with the guest's Process Manager walk: when the classic Mac
/// asks `process.list`, this side serves its OWN running applications the
/// same way the guest serves its. It is the mirror's degraded plane —
/// modern macOS gives no OSType code/creator and no classic partition
/// size, so those fields are simply absent rather than invented. What is
/// honest here is the name, the kind, and which one is front.
@MainActor
enum HostProcesses {
    /// One page of the running-process list, 1-based cursor, bounded by
    /// the contract's process array cap.
    static func page(cursor: Int, limit: Int = 24)
        -> (entries: [ProcessEntry], more: Bool, next: Int?) {
        let apps = NSWorkspace.shared.runningApplications
            // A stable order the guest can page through: user-visible
            // apps first, then by name. runningApplications order is not
            // promised to hold still between calls.
            .filter { $0.activationPolicy != .prohibited || $0.isActive }
            .sorted { lhs, rhs in
                let ln = lhs.localizedName ?? lhs.bundleIdentifier ?? ""
                let rn = rhs.localizedName ?? rhs.bundleIdentifier ?? ""
                return ln.localizedCaseInsensitiveCompare(rn) == .orderedAscending
            }

        let start = max(0, cursor - 1)
        guard start < apps.count else { return ([], false, nil) }
        let end = min(start + limit, apps.count)
        let entries = apps[start..<end].map(entry(for:))
        let more = end < apps.count
        return (entries, more, more ? end + 1 : nil)
    }

    private static func entry(for app: NSRunningApplication) -> ProcessEntry {
        let name = app.localizedName
            ?? app.bundleIdentifier
            ?? "pid \(app.processIdentifier)"
        return ProcessEntry(name: name, kind: kind(for: app),
                            code: nil, creator: nil,
                            sizeKB: nil, front: app.isActive)
    }

    private static func kind(for app: NSRunningApplication) -> String {
        if app.bundleIdentifier == "com.apple.finder" { return "finder" }
        switch app.activationPolicy {
        case .regular: return "application"
        default: return "background"
        }
    }
}
