import Foundation

/// Persisted connection settings. Deliberately small: the port we listen on
/// and whether to listen at launch.
@MainActor
final class SettingsModel: ObservableObject {
    static let defaultPort: UInt16 = 5250

    @Published var listenPort: UInt16 {
        didSet { defaults.set(Int(listenPort), forKey: Keys.listenPort) }
    }
    @Published var listenAtLaunch: Bool {
        didSet { defaults.set(listenAtLaunch, forKey: Keys.listenAtLaunch) }
    }

    private enum Keys {
        static let listenPort = "listenPort"
        static let listenAtLaunch = "listenAtLaunch"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = UserDefaults(
        suiteName: ProductIdentity.preferencesSuite) ?? .standard) {
        self.defaults = defaults
        let stored = defaults.integer(forKey: Keys.listenPort)
        listenPort = (1...65535).contains(stored)
            ? UInt16(stored) : Self.defaultPort
        listenAtLaunch = defaults.object(forKey: Keys.listenAtLaunch) == nil
            ? true : defaults.bool(forKey: Keys.listenAtLaunch)
    }
}
