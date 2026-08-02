import Foundation

enum ProductIdentity {
    // Product name: "New Old World", "NOW" for short (decided 2026-07-19).
    static let displayName = "New Old World"
    static let version = "0.1.0"
    static let bundleIdentifier = "dev.newoldworld.now"

    /// A second copy of this app on one desk shares this domain with the
    /// first — same bundle id, same suite — and therefore shares the guest
    /// REGISTRY. Two instances then assign slots from one another's book:
    /// measured 2026-08-02, a metal PowerBook and an emulated Power Mac
    /// both holding slot 0 while one instance accepted a guest's socket
    /// and never answered its hello.
    ///
    /// `NOW_PREFS_SUFFIX` gives a spike its own domain — settings, guest
    /// registry and all — so a second copy can run beside a working one
    /// without either editing the other's book. Unset in a normal launch,
    /// which is the shipping behaviour and unchanged.
    static var preferencesSuite: String {
        let base = "dev.newoldworld.now.settings"
        guard let suffix = ProcessInfo.processInfo
            .environment["NOW_PREFS_SUFFIX"],
              !suffix.isEmpty else { return base }
        return "\(base).\(suffix)"
    }

    static let windowFrameName = "now-main-window"
}
