import Foundation

/// Which machine is on the other end — derived from `hello`, in one place.
///
/// The host serves several guests over one port, so something has to say
/// whether an arriving dial is a NEW machine (serve it alongside the
/// others) or the one already connected dialling again (refuse it busy,
/// as before). The contract's answer is the name: trimmed and case-folded
/// so "PowerBook 180c" and "powerbook 180c " are one machine, and no
/// stronger than the names are distinct — two Macs calling themselves the
/// same thing ARE one guest to this type, and the second is refused.
///
/// Deriving it here rather than at the admission check is the whole point:
/// the gate and the session table must agree about what "the same guest"
/// means, and they agreed by accident for exactly as long as there was
/// only ever one.
struct GuestKey: Hashable, Sendable {
    /// The comparison form. Never shown to anyone — `ConnectedGuest.name`
    /// carries what the guest called itself.
    let folded: String

    init(name: String?) {
        let trimmed = (name ?? "").trimmingCharacters(
            in: .whitespacesAndNewlines)
        /// An unnamed guest is not anonymous, it is "Classic Mac" — the
        /// same fallback the session's display name uses, so an unnamed
        /// second dial collides with the first rather than opening an
        /// unbounded row of nameless sessions.
        folded = (trimmed.isEmpty ? Session.unnamedGuest : trimmed)
            .lowercased()
    }

    init(hello: Hello) {
        self.init(name: hello.name)
    }
}

/// One connected guest, in the shape a list of them wants: enough to
/// name it and choose it, and nothing that would go stale.
struct ConnectedGuest: Identifiable, Equatable, Sendable {
    var key: GuestKey
    var name: String
    var version: String?
    var operatingSystem: String?
    var connectedAt: Date
    /// True for the one the single-guest API — the console, the modules,
    /// the agent projection — is currently driving.
    var isActive: Bool

    var id: GuestKey { key }
}
