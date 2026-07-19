import Foundation

enum ProductIdentity {
    // Product name: "New Old World", "NOW" for short (decided 2026-07-19).
    static let displayName = "New Old World"
    static let version = "0.1.0"
    static let bundleIdentifier = "dev.newoldworld.now"
    // Must differ from the bundle identifier — UserDefaults(suiteName:)
    // rejects a suite equal to the app's own bundle id.
    static let preferencesSuite = "dev.newoldworld.now.settings"
    static let windowFrameName = "now-main-window"
}
