import Foundation

/// Exactly one engine for one live GuestKey/session. A reconnect has another
/// key and therefore cannot inherit the prior replica accidentally.
@MainActor
final class MirrorStateEngineRegistry {
    private var engines: [GuestKey: MirrorStateEngine] = [:]

    func engine(for key: GuestKey) -> MirrorStateEngine {
        if let existing = engines[key] { return existing }
        let engine = MirrorStateEngine(guestKey: key)
        engines[key] = engine
        return engine
    }

    func remove(_ key: GuestKey) { engines.removeValue(forKey: key) }
    func existing(for key: GuestKey) -> MirrorStateEngine? { engines[key] }
    var count: Int { engines.count }
}
