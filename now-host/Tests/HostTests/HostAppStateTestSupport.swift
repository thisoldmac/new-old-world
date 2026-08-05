import Darwin
import Foundation

/// Two rules about ports that every `HostAppState` test needs, stated here
/// once because they were being got wrong in five files independently.
extension UserDefaults {
    /// Keeps a test's `HostAppState` off the wire.
    ///
    /// `SettingsModel` reads an ABSENT `listenAtLaunch` as true and an
    /// absent (or zero) `listenPort` as `SettingsModel.defaultPort`, so a
    /// HostAppState built on a fresh suite starts listening during `init`
    /// — on 5250, the port the shipping product uses and the port a NOW app
    /// on this desk is already holding. Five tests were doing that without
    /// meaning to and not one of them stopped the listener afterwards: a
    /// test reaching every later test, and the mechanism behind the
    /// 2026-08-02 entry in docs/open-issues.md.
    ///
    /// A test that wants a listener starts one itself, on port 0.
    @discardableResult
    func offTheWire() -> UserDefaults {
        set(false, forKey: "listenAtLaunch")
        return self
    }
}

/// A listen port for the one test that must name one before it binds.
///
/// Not 0: `SettingsModel` reads 0 as unset and substitutes 5250, so asking
/// for an ephemeral port through settings gets you the product's own.
/// Not a fixed number either — the two that were here (52981 and 52983)
/// sat inside the ephemeral range 49152–65535, which is where this same
/// process draws every port-0 listener and every dial from, so it took
/// those ports from itself and the bind failed with EADDRINUSE.
///
/// So: above the ephemeral floor, and keyed to the process, because two
/// `swift test` runs in two worktrees at once is ordinary on this desk and
/// a constant would have them fighting over one number.
func testListenPort(slot: Int = 0) -> UInt16 {
    UInt16(20_000 + (Int(getpid()) % 20_000) + slot)
}
