import Foundation

/// State that is a claim about ONE machine, parked when the UI is pointed
/// at another and handed back on return.
///
/// Every module model on this side caches something the guest told it — a
/// process table, a software inventory, a census, a browse path, a
/// scrollback. All of it was written when there was one guest, so all of
/// it clears on DISCONNECT and never on anything else. The moment a picker
/// exists that is wrong in the loudest possible way: one Mac's rows under
/// the other's name, with nothing on screen saying so.
///
/// The two answers to that are keeping the state per key and throwing it
/// away on every switch, and this type is the first one, offered once
/// because five models want it and writing the dictionary five times is how
/// four of them end up subtly different. What each model parks — and what
/// it throws away instead — is that model's own decision, stated at its
/// snapshot type.
///
/// **A disconnect is not a switch.** Focus only ever moves between machines
/// that are connected; a guest going away leaves the last thing it said on
/// screen, which is what every model here already did and what a person
/// reading a scrollback after the wire dropped needs. `forget` is the other
/// half: a model whose cache genuinely dies with the connection says so by
/// calling it, and one whose cache outlives the connection says so by not.
@MainActor
final class GuestStateCache<Snapshot> {
    /// What a focus change asks the caller to do.
    enum Change {
        /// The same machine (or none). Nothing to park, nothing to restore.
        case unchanged
        /// A different machine. `to` is what it left here last time, or nil
        /// when it has never been focused — which reads as "start empty",
        /// not as "no change", and keeping those two apart is the whole
        /// reason this is an enum rather than an optional.
        case switched(to: Snapshot?)
    }

    /// Which machine the live state currently belongs to.
    private(set) var focused: GuestKey?
    private var parked: [GuestKey: Snapshot] = [:]
    /// Focus order, oldest first, so the cache is bounded by machines seen
    /// rather than by machines connected. A desk with one Mac never reaches
    /// it; a fleet that dials in over a week does not grow without end.
    private var order: [GuestKey] = []
    private let limit: Int

    init(limit: Int = 8) {
        self.limit = max(1, limit)
    }

    /// Parks what the outgoing machine had and reports what the incoming
    /// one left. `parking` is an autoclosure because it is not evaluated
    /// when nothing is switching — reading a model's whole visible state is
    /// not free, and this runs on every connection change.
    func focus(_ key: GuestKey?,
               parking outgoing: @autoclosure () -> Snapshot) -> Change {
        // Nil is a disconnect, not a switch: the live state stays where it
        // is, still attributed to `focused`, so the same machine dialling
        // back in finds its own state rather than an empty page.
        guard let key, key != focused else { return .unchanged }
        if let leaving = focused {
            parked[leaving] = outgoing()
            remember(leaving)
        }
        focused = key
        let restored = parked.removeValue(forKey: key)
        return .switched(to: restored)
    }

    /// Drops a machine's parked state. For the models whose cache is a
    /// claim about a LIVE connection — a process table full of PSNs, an
    /// inventory taken before a redeploy — and not for the ones whose cache
    /// is a record of what a person did.
    func forget(_ key: GuestKey) {
        parked.removeValue(forKey: key)
        order.removeAll { $0 == key }
        if focused == key { focused = nil }
    }

    /// Reads or writes the state of a machine that is not the focused one —
    /// the path a background guest's PUSH takes. Returns false when the
    /// caller must handle it live instead, which is the case that matters:
    /// a push from the machine being driven is not a background push.
    @discardableResult
    func updateParked(_ key: GuestKey,
                      startingFrom empty: @autoclosure () -> Snapshot,
                      _ body: (inout Snapshot) -> Void) -> Bool {
        guard key != focused else { return false }
        var snapshot = parked[key] ?? empty()
        body(&snapshot)
        parked[key] = snapshot
        remember(key)
        return true
    }

    /// Test seam, and the only read of a parked snapshot from outside: a
    /// guard for "the background guest's push landed on the background
    /// guest" cannot be written against the visible state, by definition.
    func parkedState(for key: GuestKey) -> Snapshot? {
        parked[key]
    }

    private func remember(_ key: GuestKey) {
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > limit, let oldest = order.first {
            order.removeFirst()
            parked.removeValue(forKey: oldest)
        }
    }
}

/// A module model that shows one machine's state.
///
/// Two methods, because there are two events and they mean different
/// things. `connection` moving to another machine is a SWITCH and every
/// model must handle it or it lies. A machine leaving the roster is a
/// DISCONNECT, which most of these models deliberately survive — so it is a
/// separate call that most of them ignore, rather than a flag that would
/// read as the same event with a parameter.
@MainActor
protocol GuestScopedModel: AnyObject {
    var connection: GuestConnectionState { get set }
    /// A machine left the roster. The default does nothing.
    func guestLeft(_ key: GuestKey)
}

extension GuestScopedModel {
    func guestLeft(_ key: GuestKey) {}
}
