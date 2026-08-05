import Foundation

enum ProductIdentity {
    // Product name: "New Old World", "NOW" for short (decided 2026-07-19).
    static let displayName = "New Old World"
    static let version = "0.1.0"
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

    static let windowFrameName = "now-main-window"
}
