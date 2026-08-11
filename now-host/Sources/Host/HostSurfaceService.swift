import Foundation

/* The host's half of the host.* family: the guest asking THIS Mac to
   bring one of its own windows forward.

   WHY IT EXISTS. The Mirror is the host's rendering of the guest's
   screen, and the person who wants it open is usually sitting at the
   classic Mac. Until this family the only ways to open one in an
   already-running host were a click on this Mac's own window and
   `--open-mirror` at launch — so anyone away from the modern machine's
   desktop had no route at all. The cost was not hypothetical: a sweep
   that could not open the Mirror from the agent socket fell back to
   macOS accessibility scripting to click the button, and later sessions
   copied that as a rig fact.

   ONE IMPLEMENTATION BEHIND THREE FACES. This serve, the Window menu
   item and the `mirror_open` agent verb all end at the same
   `NOWMirrorWindow.show` a click performs. Nothing here decides
   anything about the Mirror; it renders an outcome the app produced. */

/// What asking for a host surface produced. `refused` carries the
/// contract's code, so the wire answer and the agent answer cannot
/// disagree about why.
enum HostSurfaceOutcome: Equatable, Sendable {
    /// The surface is showing. Newly opened and already-open-and-raised
    /// are deliberately the same answer — the asker wanted it showing,
    /// and it is — but which one it was rides along for the log and for
    /// the agent verb's report.
    case showing(wasAlreadyOpen: Bool, detail: String)
    case refused(code: String, reason: String)

    var ok: Bool {
        if case .showing = self { return true }
        return false
    }

    var reason: String {
        switch self {
        case .showing(_, let detail): return detail
        case .refused(_, let reason): return reason
        }
    }

    var code: String? {
        if case .refused(let code, _) = self { return code }
        return nil
    }
}

/// The one surface name the contract declares today. A closed set here
/// rather than a free string, so an unknown name is refused BY NAME
/// instead of quietly doing nothing.
enum HostSurface: String, CaseIterable, Sendable {
    case mirror
}

extension GuestListener {

    /// Set by the app, which owns the windows. Unset is the honest
    /// pre-family answer for a headless listener: refused with a reason,
    /// never silence — a guest that gets no reply can only guess between
    /// an old host and a lost frame.
    typealias HostSurfaceOpener = (HostSurface) -> HostSurfaceOutcome

    /// Answered for any connected guest, down the connection that asked
    /// — the cloud and chat rule: it is the guest's own request, not an
    /// answer to one of ours.
    func serveHostShow(_ request: HostShow, on asker: Session) {
        let outcome = openHostSurface(named: request.surface)
        asker.send(.hostShown(HostShown(
            id: request.id,
            surface: request.surface,
            ok: outcome.ok,
            code: outcome.code,
            reason: outcome.reason)))
        note("Guest asked to show \(request.surface): \(outcome.reason)",
             area: "wire", level: outcome.ok ? .info : .warn)
    }

    /// The name-to-surface half, separated from the wire so it can be
    /// tested without a socket and so the agent verb resolves a name the
    /// same way a guest does.
    func openHostSurface(named name: String) -> HostSurfaceOutcome {
        guard let surface = HostSurface(rawValue: name) else {
            return .refused(
                code: "unknown-surface",
                reason: "This Mac has no surface called \"\(name)\".")
        }
        guard let hostSurfaceOpener else {
            return .refused(
                code: "unavailable",
                reason: "No window layer is running on this Mac.")
        }
        return hostSurfaceOpener(surface)
    }
}
