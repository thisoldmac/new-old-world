import Foundation

/// The Logs module's remembered switches: whether the log persists to
/// disk (delegated to HostLog, which owns the file) and whether the
/// scrollback is inverted (a view preference, like the guest page's).
///
/// The disk switch reads back HostLog's ACTUAL state, so a failed open
/// shows as off rather than claiming a file that is not there — the same
/// honesty the guest page keeps.
@MainActor
final class LogsModel: ObservableObject {
    let log: HostLog

    @Published private(set) var invert: Bool
    @Published private(set) var persistsToDisk: Bool

    private let defaults: UserDefaults
    private static let invertKey = "logsInvert"
    private static let diskKey = "logsPersistsToDisk"

    init(log: HostLog, defaults: UserDefaults) {
        self.log = log
        self.defaults = defaults
        invert = defaults.object(forKey: Self.invertKey) as? Bool ?? false
        // On unless turned off — crash survival is the point of the file.
        let wantDisk = defaults.object(forKey: Self.diskKey) as? Bool ?? true
        log.setPersistsToDisk(wantDisk)
        persistsToDisk = log.persistsToDisk
    }

    func setInvert(_ on: Bool) {
        invert = on
        defaults.set(on, forKey: Self.invertKey)
    }

    func setPersistsToDisk(_ on: Bool) {
        log.setPersistsToDisk(on)
        persistsToDisk = log.persistsToDisk        // the real state, not the ask
        defaults.set(persistsToDisk, forKey: Self.diskKey)
    }
}
