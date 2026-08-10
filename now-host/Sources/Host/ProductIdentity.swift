import Foundation

enum ProductIdentity {
    // Product name: "New Old World", "NOW" for short (decided 2026-07-19).
    static let displayName = "New Old World"
    static let version = "0.2.0"
    static let bundleIdentifier = "dev.newoldworld.now"
    // Must differ from the bundle identifier — UserDefaults(suiteName:)
    // rejects a suite equal to the app's own bundle id.
    static let basePreferencesSuite = "dev.newoldworld.now.settings"

    /// Where this instance's settings live.
    ///
    /// `NOW_PREFS_SUFFIX` gives a run its OWN suite, so a second copy can
    /// be launched without writing into the desk's real preferences. This
    /// checkout is shared and several sessions work in it at once: before
    /// this existed, launching a build to look at it overwrote whichever
    /// page another session's window would reopen on, and there was no way
    /// to avoid that short of not looking.
    ///
    /// It is deliberately opt-in and env-only — nothing in a normal launch
    /// sets it, so the shipped app has exactly the behaviour it always had.
    /// A suffixed run also starts from DEFAULTS, which means its own port:
    /// set one that nothing else is holding, or the listener will collide
    /// with the instance you were trying not to disturb.
    static var preferencesSuite: String {
        guard let suffix = ProcessInfo.processInfo
                .environment["NOW_PREFS_SUFFIX"],
              !suffix.isEmpty else {
            return basePreferencesSuite
        }
        return "\(basePreferencesSuite).\(suffix)"
    }

    /// **The defaults store for this instance's host state — every part of
    /// it, not just the settings suite.**
    ///
    /// `preferencesSuite` above scopes exactly four call sites:
    /// `SettingsModel`, `HostAppState`, `App` and `ChatModuleModel`.
    /// Everything else in this application defaulted to
    /// `UserDefaults.standard`, which is the app's own bundle-id domain —
    /// **one store shared by every host copy running on the Mac**. So a
    /// run launched with `NOW_PREFS_SUFFIX` had its listening port
    /// isolated and its Mirror controls, file locations, share directory,
    /// cloud settings, sidebar and screenshot settings still pointed at
    /// the desk's real ones, writing into them while a human's session was
    /// open. `mirror.appPath`, `mirror.qmpSocket` and
    /// `mirror.forwardedAgentPort` are in that shared domain, and they are
    /// exactly the settings that decide what a Mirror is looking at.
    ///
    /// Found on 2026-08-07 while establishing whether an agent lane had
    /// reached a human's running app. It had not — the wire and the agent
    /// socket were both properly isolated, and each guest was paired with
    /// its own host throughout. But the isolation a lane was relying on
    /// was much narrower than its name suggested, and nothing said so.
    ///
    /// Opt-in and env-only, exactly like `preferencesSuite`: with no
    /// suffix this IS `.standard`, so a shipped launch behaves as it
    /// always did and no existing preference moves.
    static var defaults: UserDefaults {
        guard let suffix = ProcessInfo.processInfo
                .environment["NOW_PREFS_SUFFIX"],
              !suffix.isEmpty,
              let suite = UserDefaults(
                suiteName: "\(bundleIdentifier).\(suffix)")
        else { return .standard }
        return suite
    }

    static let windowFrameName = "now-main-window"
}
