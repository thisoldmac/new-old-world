import Foundation

/// **One place a change is announced, so a page never has to be told twice.**
///
/// Before this file the host had four different ways of saying "something
/// happened", and which one a fact travelled on was an accident of the week
/// it was written: two Combine subjects on the listener (`pushedCaptures`,
/// `streamFrames`), a scatter of `@Published` properties that pages sank
/// individually, a pair of assignment hooks (`announceReceivedFile`) set
/// from `HostAppState`, and — for most of the modules — nothing at all, so
/// the page only became true again when a person clicked Refresh.
///
/// The cost of that was not the plumbing, it was the silence. An agent that
/// uploaded a file, a `process.quit` that took, a change the guest made to
/// this Mac's shared folder: all of them changed the truth and none of them
/// reached the page showing it. A page that is only correct immediately
/// after a click is a page that is usually wrong.
///
/// Three rules hold this together:
///
/// * **Publish where the truth changes, not where it is convenient.** The
///   listener publishes from `didSet` on the properties that ARE the truth
///   (`state`, `guests`, `activeKey`, `captureProgress`), so a new
///   assignment cannot forget to announce itself. That is deliberate: the
///   old hand-written `publishActive()` fan-out drifted out of step with
///   the thing it published exactly once, and that once put a disconnected
///   guest on screen.
/// * **A guest-scoped event carries its guest.** This host serves several
///   Macs at a time. An event about a machine nobody is looking at must
///   never repaint the machine they are. `HostEvent.guest` is that identity
///   and `subscribe(scopedTo:)` is the filter; a subscriber that genuinely
///   wants every machine's events (the Screenshots page files a background
///   Mac's push under the Mac that sent it) asks for the unscoped
///   `subscribe` and says why.
/// * **Delivery is a turn, not a stack.** A subscriber that publishes while
///   being delivered to — a page that refreshes, which settles a request,
///   which changes state — queues behind the event in flight rather than
///   re-entering the fan-out. Otherwise the second event reaches half the
///   subscribers before the first reaches the rest, and which half depends
///   on dictionary order.
@MainActor
final class HostEventBus {
    /// **Weak, and that is the whole lifetime story.** The subscription
    /// object holds the handler; the bus only points at it. So a page whose
    /// model went away stops being delivered to without anything having to
    /// run at release time — which matters because `deinit` is not isolated
    /// to this actor, and reaching into a main-actor dictionary from one
    /// would either need `MainActor.assumeIsolated` (newer than this app's
    /// floor) or a hop that lands after the object is gone.
    private struct Slot {
        weak var subscription: HostEventSubscription?
    }

    private var subscribers: [Slot] = []
    /// Non-empty while a fan-out is in progress; see the re-entrancy rule.
    private var queue: [HostEvent] = []
    private var delivering = false

    init() {}

    /// Announces a change. Cheap when nothing is listening, which is the
    /// case in most of this project's tests and in every preview.
    func publish(_ event: HostEvent) {
        queue.append(event)
        guard !delivering else { return }
        delivering = true
        defer { delivering = false }
        while !queue.isEmpty {
            let next = queue.removeFirst()
            /* A snapshot, so a handler that subscribes or unsubscribes
               during delivery changes what the NEXT event sees rather than
               this one — the alternative is a fan-out whose membership
               depends on how far through it got. */
            let live = subscribers.compactMap(\.subscription)
            subscribers = live.map(Slot.init(subscription:))
            for subscription in live { subscription.deliver(next) }
        }
    }

    /// Every event, whichever machine it is about.
    ///
    /// The right choice only for a subscriber that is about the host itself
    /// (the roster, the link, a notification) or one that routes per guest
    /// on its own. Anything showing ONE machine wants `scopedTo`.
    func subscribe(_ handler: @escaping (HostEvent) -> Void)
        -> HostEventSubscription {
        let subscription = HostEventSubscription(handler)
        subscribers.append(Slot(subscription: subscription))
        return subscription
    }

    /// Events about one machine, plus the host-wide ones.
    ///
    /// `focus` is read at DELIVERY, not at subscription: a model's focused
    /// machine changes under it, and a filter that closed over the key it
    /// had when the page was built would go on repainting for a Mac the
    /// person left half an hour ago.
    ///
    /// An event with no guest (`rosterChanged`, `linkStateChanged`) is
    /// about the host and always arrives. An event about a machine while
    /// the subscriber is focused on nothing is DROPPED: a page with no Mac
    /// selected has nothing it could truthfully repaint.
    func subscribe(scopedTo focus: @escaping () -> GuestKey?,
                   _ handler: @escaping (HostEvent) -> Void)
        -> HostEventSubscription {
        subscribe { event in
            guard let subject = event.guest else {
                handler(event)
                return
            }
            guard subject == focus() else { return }
            handler(event)
        }
    }

    /// How many handlers are attached. For tests, and for the one thing a
    /// leak of these looks like from outside. Counts LIVE ones: a slot
    /// whose subscription has been released is already not a subscriber,
    /// whether or not a publish has swept it yet.
    var subscriberCount: Int {
        subscribers.filter { $0.subscription?.isActive == true }.count
    }
}

/// A subscription's lifetime. Held by the subscriber; unsubscribes when it
/// is released, the way an `AnyCancellable` does, because a model that
/// outlives its page and a page that outlives its model are both normal
/// here and neither should have to remember to detach.
/// It owns the handler; the bus points at it weakly. Releasing this IS
/// unsubscribing — there is no `deinit` here, because there is nothing for
/// one to do.
@MainActor
final class HostEventSubscription {
    private var handler: ((HostEvent) -> Void)?

    init(_ handler: @escaping (HostEvent) -> Void) {
        self.handler = handler
    }

    var isActive: Bool { handler != nil }

    /// Detach now, without waiting to be released. For a subscriber whose
    /// own lifetime is longer than its interest.
    func unsubscribe() {
        handler = nil
    }

    fileprivate func deliver(_ event: HostEvent) {
        handler?(event)
    }
}

/// **Everything this host can learn without being asked.**
///
/// Closed on purpose. A page cannot subscribe to "anything interesting"; it
/// names the changes it is a view of, and a new kind of change is a case
/// here — which is the compiler asking every exhaustive reader whether it
/// cares. The alternative shape, a string-keyed notification, is what this
/// replaces: it could not be enumerated, so nobody could answer "what
/// repaints the Files page" without reading every file.
///
/// The first associated value of a guest-scoped case is the machine it is
/// about, and `guest` reads it back. Nil there means "the host could not
/// attribute it", not "all of them" — a subscriber that treats nil as its
/// own machine is the stale-repaint defect this carries identity to avoid.
enum HostEvent {
    // MARK: Machines

    /// A connection passed the hello gate and is being served.
    case guestConnected(GuestKey)
    /// A connection ended, with the reason a human reads.
    case guestDisconnected(GuestKey, reason: String)
    /// A machine's durable handle changed. The session id does not — see
    /// `GuestListener.renameGuest`.
    case guestRenamed(GuestKey, id: GuestID)
    /// Which connection the single-guest API is now driving. Nil when
    /// nothing is: the last Mac left and none was promoted.
    ///
    /// Host-wide rather than guest-scoped, deliberately: it is the event
    /// that TELLS a scoped subscriber its machine changed, so filtering it
    /// by the focus it announces would mean nobody heard it.
    case focusChanged(to: GuestKey?)
    /// The roster's contents or any field in it changed.
    case rosterChanged
    /// The listener's own link: idle, listening, connected, failed.
    case linkStateChanged(GuestListener.State)

    // MARK: Screen

    /// A machine sent a screenshot nobody asked for.
    case captureArrived(GuestKey?, GuestListener.CaptureDelivery)
    /// A frame of an open stream bracket.
    case streamFrame(GuestKey?, GuestListener.CaptureDelivery)
    /// A stream bracket opened (an id) or closed (nil).
    case streamStateChanged(GuestKey?, id: Int?)

    // MARK: Transfers

    /// A bulk transfer moved. There is no separate "started": the first
    /// progress IS the moment this host learns a transfer exists, and a
    /// second case that could only ever be published beside this one would
    /// be a claim the wire does not make.
    case transferProgressed(GuestKey?, received: Int, expected: Int)
    /// A bulk transfer stopped — finished, failed or was cancelled. Which
    /// of the three is the business of whoever was awaiting it; this says
    /// only that the bar is over.
    case transferEnded(GuestKey?)
    /// A guest finished installing one exact host-published component.
    case updateFinished(GuestKey, UpdateResult)

    // MARK: Files

    /// A file the guest sent landed on this Mac.
    case fileReceived(GuestKey?, url: URL, bytes: Int, guestName: String)
    /// Something under `path` is no longer what a listing said it was.
    case fileTreeChanged(GuestKey?, side: FileTreeSide, path: String)

    // MARK: The machine's own tables

    /// The guest's process table changed because this host changed it —
    /// a front, a quit that took. The guests do not push this, so it is
    /// only ever as good as what we did to them.
    case processListChanged(GuestKey?)
    /// The peer that serves scene state says one or more domain generations
    /// advanced. This is a scheduling hint, never replacement state.
    case mirrorInvalidated(GuestKey, MirrorInvalidate)
    /// A guest reported an error that no pending request claimed. The one
    /// signal a refused `stream.start` has.
    case guestReportedError(GuestKey?, ErrorMessage)

    /// Which side of the wire a file change happened on.
    ///
    /// Both directions are real and they are not the same event: the guest
    /// changing this Mac's shared folder repaints nothing the Files page
    /// shows, and a change we made on the guest repaints all of it.
    enum FileTreeSide: Equatable, Sendable {
        /// The classic Mac's disk.
        case guest
        /// This Mac's shared folder.
        case host
    }

    /// The machine this event is about, or nil when it is about the host.
    var guest: GuestKey? {
        switch self {
        case .guestConnected(let key): return key
        case .guestDisconnected(let key, _): return key
        case .guestRenamed(let key, _): return key
        /* Not the key it announces: see the case's own note. A focus
           change is how a scoped subscriber finds out, so it cannot be
           filtered by the focus it is announcing. */
        case .focusChanged: return nil
        case .rosterChanged, .linkStateChanged: return nil
        case .captureArrived(let key, _): return key
        case .streamFrame(let key, _): return key
        case .streamStateChanged(let key, _): return key
        case .transferProgressed(let key, _, _): return key
        case .transferEnded(let key): return key
        case .updateFinished(let key, _): return key
        case .fileReceived(let key, _, _, _): return key
        case .fileTreeChanged(let key, _, _): return key
        case .processListChanged(let key): return key
        case .mirrorInvalidated(let key, _): return key
        case .guestReportedError(let key, _): return key
        }
    }
}
