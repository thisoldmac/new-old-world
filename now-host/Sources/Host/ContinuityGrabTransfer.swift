import AppKit
import Foundation
import MirrorKitUI
import UniformTypeIdentifiers

/// Turns one bound selection stub into a native macOS file promise, and
/// redeems it over `continuity.grab`.
///
/// It is a sibling of `MirrorFileTransferModel`'s promise half rather than an
/// extension of it because the two answer to different authorities: that one
/// resolves a scene item inside the Files share, this one redeems a gesture's
/// consent for one generation. What they SHARE is the wire — the grab is
/// served down the ordinary `file.begin` / bulk / `file.end` lane, through the
/// same receive machinery and the same `FileConverter` finalization, so a
/// grabbed file resumes, reports and materializes exactly as a Files pull
/// does. There is no second bulk receiver here and there must never be one.

/// One selection's identity on the wire, exactly as the guest scopes a
/// grant — epoch plus generation. Local to attempt counting: nothing else
/// here needs a stub's identity as a dictionary key.
private struct ContinuityFileStubKey: Hashable {
    let epoch: UInt32
    let generation: UInt32
}

@MainActor
final class ContinuityGrabTransfer: NSObject, ObservableObject,
                                    NSFilePromiseProviderDelegate {
    typealias Audit = (HostLog.LogLevel, String) -> Void

    /// The one place a grab's failure becomes an error macOS can show. Each
    /// case is also audited by name where it is raised.
    enum GrabError: LocalizedError, Equatable {
        case noStub
        case busy
        /// The drop knew WHICH file and never learned its generation. Its
        /// own case rather than `noStub`: nothing is missing or gone — the
        /// Macintosh simply never minted the number a grab must name, and
        /// saying "no longer available" about a file sitting on the desktop
        /// is the kind of wrong sentence a person cannot act on.
        case notYetNamed(name: String, waitedMs: Int)
        case wire(code: String, message: String)

        var errorDescription: String? {
            switch self {
            case .noStub:
                return "That dragged item is no longer available on "
                    + MachineNaming.simpleReference + "."
            case .notYetNamed(let name, _):
                return MachineNaming.startingSentence(
                    "\(MachineNaming.simpleReference) did not finish naming "
                    + "\(name) before the drop. Try dragging it across "
                    + "again.")
            case .busy:
                return "Another file is already crossing from "
                    + MachineNaming.simpleReference + "."
            case .wire(let code, let message):
                switch code {
                case "stale-selection":
                    return MachineNaming.startingSentence(
                        "the selection on \(MachineNaming.simpleReference) changed before the "
                        + "file could be copied.")
                case "grant-expired":
                    /* The one refusal that is about TIME. The drag was
                       held past the window the guest keeps open after
                       Continuity ends, which is a thing a person can
                       simply do again. */
                    return "The drag was held too long after Continuity "
                        + "ended. Try dragging it across again."
                default:
                    return message
                }
            }
        }
    }

    @Published private(set) var notice: String?

    /// Forwards every terminal `notice` to wherever a person is actually
    /// looking. `notice` alone is not enough: it is `@Published` on THIS
    /// object, and nothing observed it — the Continuity page draws the
    /// edge controller's status, not this transfer's — so a wrong-file
    /// refusal (`stale-selection`) set `notice` and then sat there
    /// unread, and the person saw the drag simply vanish. Named a sink
    /// rather than wired straight to `ContinuityEdgeController` so a test
    /// can watch it fire without constructing the whole edge stack.
    var outcomeSink: ((String) -> Void)?

    /// The same terminal sentence `outcomeSink` carries, but only for the
    /// two ways a grab can end badly — the wire refusing the redemption
    /// (`stale-selection`, `grant-expired`, …) and this Mac failing to
    /// write what arrived. `outcomeSink` already reaches every terminal
    /// outcome, success included; this is a narrower promise for whoever
    /// wants to interrupt a person ONLY when their drag did not work, the
    /// same way `QuickCaptureOutcome` distinguishes `.copied` from
    /// `.failed` rather than treating every capture alike. No new
    /// sentence is written here — every call site hands this the exact
    /// string it already gave `setNotice`.
    var refusalSink: ((String) -> Void)?

    /// The wire, as one function. Named rather than reached through the
    /// listener so a test can watch a refusal arrive without a socket — the
    /// refusal paths are the half v1 shipped silent, and they must be
    /// exercisable.
    typealias GrabRequest = (
        _ epoch: UInt32,
        _ generation: UInt32,
        _ container: String?,
        _ stagingDirectory: URL,
        _ completion: @escaping (Result<GuestListener.FileDelivery,
                                        GuestListener.FileFailure>) -> Void
    ) -> Void

    private let grab: GrabRequest
    private let audit: Audit
    /// How many wire `grab` calls this generation has seen, across BOTH
    /// lanes that can redeem one — the eager fetch started at press time
    /// and the promise-fallback redemption at drop time race for the same
    /// (epoch, generation) whenever the eager fetch has not finished by the
    /// time AppKit needs an answer, so two attempts inside one drag is
    /// ordinary, not a bug. It exists because a refusal like
    /// `serving=<empty> selected=main.c` that fires on one of those two and
    /// is immediately followed by `grant honored` on the other reads as
    /// guest flakiness unless the host's own line says a second attempt for
    /// the SAME generation was already in flight. This Mac never retries a
    /// refused grab on its own; every entry here is a fresh eager-fetch or
    /// redeem call this session made, not a scheduled retry.
    private var attemptCounts: [ContinuityFileStubKey: Int] = [:]

    /// Counts and returns this attempt's ordinal for one generation. Not
    /// reset on refusal or success — a stub is retried only by a fresh
    /// press, which is a new generation, so the count is naturally scoped
    /// to the identity that matters.
    private func nextAttempt(epoch: UInt32, generation: UInt32) -> Int {
        let key = ContinuityFileStubKey(epoch: epoch, generation: generation)
        let attempt = (attemptCounts[key] ?? 0) + 1
        attemptCounts[key] = attempt
        return attempt
    }
    private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "dev.newoldworld.continuity.grab"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    /// One grab in flight at a time, for the same reason the Mirror lane
    /// holds `promiseInFlight`: the wire has one bulk lane and a second
    /// redemption would be refused by the listener with a less specific
    /// word than this one.
    private var grabInFlight = false

    init(grab: @escaping GrabRequest, audit: Audit? = nil) {
        self.grab = grab
        self.audit = audit ?? { HostLog.shared.write($0, "continuity", $1) }
        super.init()
    }

    convenience init(listener: GuestListener, audit: Audit? = nil) {
        self.init(grab: { [weak listener] epoch, generation, container,
                          staging, completion in
            guard let listener else {
                completion(.failure(.init(
                    code: "disconnected",
                    message: "This Mac is shutting down.")))
                return
            }
            listener.grabContinuityFile(
                epoch: epoch, generation: generation, container: container,
                stagingDirectory: staging, completion: completion)
        }, audit: audit)
    }

    var isBusy: Bool { grabInFlight }

    /// The one place `notice` changes for a terminal outcome, so the sink
    /// can never drift out of step with the published property.
    private func setNotice(_ text: String) {
        notice = text
        outcomeSink?(text)
    }

    /// The host-side stub AppKit drags. No bytes cross until something in
    /// macOS accepts the promise on release.
    func promise(for stub: ContinuityDragStub) -> NSFilePromiseProvider {
        let provider = NSFilePromiseProvider(
            fileType: stub.utType.identifier, delegate: self)
        provider.userInfo = stub
        return provider
    }

    // MARK: - Late bind
    //
    // The measured shape this serves: the crossing RELEASES the guest press,
    // the Finder's drag loop ends, and only then does the Mac get task time
    // to publish what was in the hand — 14 ticks (~230 ms) later, per the
    // 2026-08-16 round. The AppKit session started at the cross outlives that
    // by seconds, and its promise is not asked for a file until the drop. So
    // the identity a drop redeems is held in a box that one late
    // drag-sourced generation may revise. See `ContinuityDragBinding`.

    /// The binding for the crossing this Mac is currently carrying, if any.
    /// One at a time, for the same reason `grabInFlight` is: there is one
    /// wire and one gesture.
    private(set) var liveBinding: ContinuityDragBinding?
    private var gestureSerial: UInt64 = 0

    @discardableResult
    private func newBinding(for stub: ContinuityDragStub?,
                            provider: NSFilePromiseProvider)
        -> ContinuityDragBinding {
        gestureSerial &+= 1
        let binding = ContinuityDragBinding(gesture: gestureSerial, stub: stub)
        binding.attach(provider)
        liveBinding = binding
        return binding
    }

    /// A drag that crosses with NOTHING named yet.
    ///
    /// The single-gesture case reaches the edge before the Mac has said one
    /// word about the file: an icon nobody selected first has no cache entry
    /// to inherit, and the drag-sourced generation is still stuck behind the
    /// Finder's own loop. Refusing there is what forced the select-then-drag
    /// ritual — so the session starts anyway, carrying a promise nobody has
    /// filled in, and the generation that arrives a fifth of a second later
    /// fills it. If none ever does, the drop refuses by name and no byte
    /// moves; an empty promise is not a guess, it is a placeholder that can
    /// only ever be redeemed by something the Mac itself said.
    func pendingDragItem() -> HostFileDragItem {
        let provider = NSFilePromiseProvider(
            fileType: UTType.data.identifier, delegate: self)
        let binding = newBinding(for: nil, provider: provider)
        audit(.info, "drag payload: nothing is named yet (gesture "
            + "\(binding.gesture)); this drag carries an unfilled promise "
            + "until the Mac publishes what was in the hand — the drop is "
            + "what redeems it, and it refuses if nothing ever arrives")
        return HostFileDragItem(
            writer: provider,
            image: NSWorkspace.shared.icon(for: .data))
    }

    /// Applies a late drag-sourced generation to the live crossing.
    func reviseLiveBinding(to stub: ContinuityDragStub)
        -> ContinuityLateBind.Outcome {
        guard let liveBinding else { return .noGesture }
        return liveBinding.revise(to: stub)
    }

    /// Applies a generation the Mac minted for a gesture whose epoch had
    /// already ended, JOINED BY `dragSeq` and by nothing else.
    ///
    /// The cache cannot be consulted for this one and must not be: no epoch
    /// is running, so `bindable(activeEpoch:)` refuses by construction and a
    /// host that leaned on it would be asking the wrong question. What makes
    /// this frame safe to apply is not a cached agreement but the join —
    /// the resident named this gesture mid-drag over its own channel, this
    /// Mac is carrying that identity, and the sequence says the two are one
    /// gesture rather than two drags of the same icon. Exactly the live
    /// join's rule, one epoch later.
    ///
    /// A crossing carrying no identity at all is REFUSED rather than filled
    /// in. There is then nothing to join to, and a generation adopted on
    /// timing alone is the wrong-file bug the join key exists to prevent.
    func joinAfterEpoch(_ stub: ContinuityDragStub)
        -> ContinuityLateBind.Outcome {
        guard let liveBinding else { return .noGesture }
        guard let arriving = stub.dragSeq else {
            return .unusable(reason: "a generation minted after its epoch "
                + "ended arrived with no dragSeq, so nothing says which "
                + "gesture it belongs to; this crossing keeps what it has")
        }
        guard let carried = liveBinding.stub?.dragSeq else {
            return .unusable(reason: "this crossing carries no drag identity "
                + "to join dragSeq \(arriving) to — the resident never named "
                + "the gesture on this Mac, and a generation adopted on "
                + "timing alone is how the wrong file crosses")
        }
        guard carried == arriving else {
            return .unusable(reason: "dragSeq \(arriving) is not the gesture "
                + "this crossing carries (\(carried)) — a second drag has "
                + "its own consent and its own generation")
        }
        return liveBinding.revise(to: stub)
    }

    /// How long a drop waits for the application to mint the generation the
    /// resident's announcement could not carry.
    ///
    /// Measured shape (2026-08-16, build `cfc5c1a1`): the application's own
    /// frame reaches this Mac about 230 ms after the drag ends. A second is
    /// four times that and still short enough that a person who drops on a
    /// Finder window sees a copy start rather than a stall — and it is a
    /// WAIT, not a retry: nothing has been asked of the wire yet.
    /// Settable so a test can watch the hold expire without spending a real
    /// second on it.
    var mintWaitSeconds: TimeInterval = 1.0
    /// The same wait when this Mac KNOWS a mint is owed — the resident named
    /// the gesture mid-drag, so a `dragSeq` is carried and the application's
    /// frame is a thing that exists rather than a thing hoped for.
    ///
    /// Three seconds, and the number is a ratio rather than a guess. The
    /// mint's measured arrival is ~0.3 s after the release on the emulator
    /// (2026-08-16) and 230 ms after the drag ended on metal, so this is
    /// about ten times the measurement — the margin a slower machine, a
    /// busier Finder or a longer drain is allowed to take. It stays far
    /// inside the guest's own 30-second grant window
    /// (`kNowContinuityGrantTicks`), which is the ceiling that matters: a
    /// wait outliving the grant would redeem nothing and stall for the
    /// privilege. Without an identity the wait stays at one second, because
    /// then nothing is known to be coming.
    var mintWaitWithIdentitySeconds: TimeInterval = 3.0
    /// Polled rather than signalled: the wire, the revision and this wait
    /// all run on the one main actor, so a turn of the run loop is the only
    /// thing that can change the answer, and asking each turn costs a
    /// comparison. A continuation would buy nothing and could be resumed
    /// twice.
    private static let mintPollNanoseconds: UInt64 = 20_000_000

    /// Holds one drop until the application's generation joins, and says
    /// which way it went.
    ///
    /// **This is not a retry of a refused grab.** No grab has been sent for
    /// this gesture — the eager fetch declined to spend one on a zero, and
    /// the wire has been asked nothing. When the mint lands, the grab that
    /// follows is the FIRST attempt for that newly minted generation. The
    /// no-retry rule this project holds to is about not asking twice for a
    /// number the Macintosh already refused; it has nothing to say about
    /// waiting for the number to exist.
    private func holdForMintedGeneration(_ binding: ContinuityDragBinding)
        async -> ContinuityDragStub? {
        let name = binding.stub?.item.name ?? "an unnamed file"
        let started = DispatchTime.now()
        /* HOW LONG DEPENDS ON WHETHER A MINT IS OWED. A crossing carrying a
           `dragSeq` was announced by the resident mid-gesture, so the
           application's own frame is coming — on a crossing gesture it
           cannot even be sent until the cross has ended the epoch. Waiting
           the bare second for that is waiting less than the thing takes on
           an unhurried machine. */
        let waiting = binding.stub?.dragSeq != nil
            ? mintWaitWithIdentitySeconds : mintWaitSeconds
        let deadline = started + waiting
        audit(.info, "grab held: gesture \(binding.gesture) crossed with an "
            + "identity and no generation (name=\(name), dragSeq="
            + "\(binding.stub?.dragSeq.map(String.init) ?? "none")) — "
            + "waiting up to \(Int(waiting * 1000)) ms for the "
            + "Macintosh to mint one rather than asking with a zero")
        while true {
            if let ready = binding.grabbable {
                let waited = Int(Double(DispatchTime.now().uptimeNanoseconds
                    - started.uptimeNanoseconds) / 1_000_000)
                audit(.info, "grab held \(waited) ms and the generation "
                    + "joined: gesture \(binding.gesture), "
                    + "generation=\(ready.generation), "
                    + "dragSeq=\(ready.dragSeq.map(String.init) ?? "none"), "
                    + "name=\(ready.item.name) — this is the FIRST attempt "
                    + "for that generation, not a retry of one refused")
                return ready
            }
            guard DispatchTime.now() < deadline else { return nil }
            try? await Task.sleep(nanoseconds: Self.mintPollNanoseconds)
        }
    }

    /// The drag image. Stub icon extraction from the guest's desktop
    /// database is declared by the contract and deliberately unsent, so this
    /// is the generic icon for the type the OSType named — honest about
    /// being generic rather than a picture of the wrong file.
    ///
    /// The promise is always built — it is the fallback for a large stub,
    /// a busy grab lane, or an eager fetch that does not finish in time —
    /// but a small-enough stub also gets an eager fetch started RIGHT NOW,
    /// racing the crossing rather than waiting for a drop that may never
    /// come at a Finder window. See `ContinuityFileDragPolicy` for the cap
    /// and `EagerFetch` for how the two outcomes are reconciled at drag
    /// start.
    func dragItem(for stub: ContinuityDragStub) -> HostFileDragItem {
        let bytes = ContinuityFileDragPolicy.totalBytes(
            dataSize: stub.item.dataSize, resourceSize: stub.item.resourceSize)
        let promiseWriter = promise(for: stub)
        newBinding(for: stub, provider: promiseWriter)
        let image = NSWorkspace.shared.icon(for: stub.utType)
        guard let fetch = beginEagerFetch(for: stub, bytes: bytes) else {
            audit(.info, "drag payload: " + ContinuityFileDragPolicy.summary(
                bytes: bytes, eager: false))
            return HostFileDragItem(writer: promiseWriter, image: image)
        }
        audit(.info, "drag payload: " + ContinuityFileDragPolicy.summary(
            bytes: bytes, eager: true) + " — fetching during the crossing")
        return HostFileDragItem(writer: promiseWriter, image: image) {
            [weak self] in
            self?.resolveEagerDrag(fetch, stub: stub, bytes: bytes,
                                   fallback: promiseWriter) ?? promiseWriter
        }
    }

    /// The last-instant decision `HostFileDragItem.finalized()` runs, once,
    /// right before AppKit owns the gesture.
    ///
    /// **This must never block.** Everything in this app — the wire
    /// listener included — runs on the main actor, so a synchronous wait
    /// here for a completion that can itself only run on the main actor
    /// would deadlock the process solid rather than merely stall it: the
    /// wait and the thing it is waiting for would be competing for the same
    /// one thread. So this is a plain, instantaneous read of whatever
    /// `EagerFetch` already knows — true "during the crossing" overlap
    /// rather than a pause at the end of it, because every sample the
    /// crossing delivers already runs a full turn of this same run loop,
    /// and the fetch's own completion is queued on it exactly like they are.
    private func resolveEagerDrag(_ fetch: EagerFetch,
                                  stub: ContinuityDragStub, bytes: Int,
                                  fallback: NSPasteboardWriting)
        -> NSPasteboardWriting {
        guard let outcome = fetch.currentOutcome() else {
            let overBudget = fetch.isPastDeadline
            audit(.warn, "drag payload: eager fetch had not finished when "
                + "the drag started; falling back to the promise: "
                + "name=\(stub.item.name), budget="
                + "\(Int(fetch.budgetSeconds * 1000)) ms"
                + (overBudget ? " (past its own budget)" : " (still running)"))
            return fallback
        }
        switch outcome {
        case .success(let url):
            audit(.info, "drag payload: " + ContinuityFileDragPolicy.summary(
                bytes: bytes, eager: true,
                elapsedMs: Int(fetch.elapsedMs ?? 0))
                + " — using a real file URL, not a promise")
            /* AND THE LATE-BIND WINDOW CLOSES WITH IT. The bytes are on the
               pasteboard now; nothing arriving afterwards can change which
               file this drag is carrying, so the binding says so out loud
               instead of accepting a revision that would be cosmetic. */
            if let liveBinding, liveBinding.stub?.generation == stub.generation {
                liveBinding.pin()
            }
            return url as NSURL
        case .failure(let error):
            audit(.warn, "drag payload: eager fetch failed; falling back to "
                + "the promise: name=\(stub.item.name), "
                + "reason=\(error.localizedDescription)")
            return fallback
        }
    }

    /// One eager fetch, started at press time and raced against the
    /// crossing — never waited on, only ever polled. `budgetSeconds` is
    /// carried for the log line alone; nothing here blocks on it. Kept as
    /// its own small thread-safe box, not a property on the `@MainActor`
    /// transfer, on the same reasoning as `GrabCompletion`: AppKit hands
    /// some of this app's own completions in from queues that are not the
    /// main actor, and a value read from two places wants its own lock
    /// rather than an assumption about which one arrives first.
    final class EagerFetch {
        enum Outcome { case success(URL); case failure(Error) }

        let budgetSeconds: TimeInterval
        private let deadline: DispatchTime
        private let startedAt = DispatchTime.now()
        private let lock = NSLock()
        private var outcome: Outcome?
        private(set) var elapsedMs: Double?

        init(budgetSeconds: TimeInterval) {
            self.budgetSeconds = budgetSeconds
            deadline = .now() + max(0, budgetSeconds)
        }

        func finish(_ outcome: Outcome) {
            lock.lock()
            defer { lock.unlock() }
            guard self.outcome == nil else { return }
            self.outcome = outcome
            elapsedMs = Double(DispatchTime.now().uptimeNanoseconds
                - startedAt.uptimeNanoseconds) / 1_000_000
        }

        /// Whatever is known RIGHT NOW — nil while the fetch is still in
        /// flight. Never blocks; see `resolveEagerDrag` for why that is
        /// load-bearing rather than an optimization.
        func currentOutcome() -> Outcome? {
            lock.lock()
            defer { lock.unlock() }
            return outcome
        }

        var isPastDeadline: Bool { DispatchTime.now() >= deadline }
    }

    /// Starts fetching a stub's bytes into a private staging area right
    /// away, ahead of any drop, when it is small enough and the grab lane is
    /// free. Returns nil when neither is true — the caller's promise is then
    /// the only lane, exactly as before this existed.
    private func beginEagerFetch(for stub: ContinuityDragStub, bytes: Int)
        -> EagerFetch? {
        /* NOTHING TO ASK WITH. A stub at generation 0 is the resident's
           identity and no grant; a fetch started under it can only be
           refused, and on metal 2026-08-16 six crossings spent their first
           attempt on exactly that certainty. The promise carries this drag
           instead, and the drop holds it until a number arrives. */
        guard stub.generation != 0 else {
            audit(.info, "eager fetch skipped: nothing has minted a "
                + "generation for this gesture yet (epoch=\(stub.epoch), "
                + "dragSeq=\(stub.dragSeq.map(String.init) ?? "none"), "
                + "name=\(stub.item.name)) — a grab with a zero is refused "
                + "by the Macintosh that mints them, so none is sent")
            return nil
        }
        guard ContinuityFileDragPolicy.eligibleForEagerFetch(
            dataSize: stub.item.dataSize, resourceSize: stub.item.resourceSize)
        else { return nil }
        guard !grabInFlight else {
            audit(.info, "eager fetch skipped: another grab is already in "
                + "flight (epoch=\(stub.epoch), generation=\(stub.generation))")
            return nil
        }
        let fetch = EagerFetch(
            budgetSeconds: ContinuityFileDragPolicy.budget(forBytes: bytes))
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-eager-\(UUID().uuidString)",
                                    isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: staging, withIntermediateDirectories: true)
        } catch {
            audit(.warn, "eager fetch could not stage a directory; the drag "
                + "falls back to the promise: \(error.localizedDescription)")
            fetch.finish(.failure(error))
            return fetch
        }
        grabInFlight = true
        notice = nil
        let attempt = nextAttempt(epoch: stub.epoch, generation: stub.generation)
        audit(.info, "eager fetch started: epoch=\(stub.epoch), "
            + "generation=\(stub.generation), attempt=\(attempt), "
            + "name=\(stub.item.name), bytes=\(bytes), "
            + "budget=\(Int(fetch.budgetSeconds * 1000)) ms")
        grab(stub.epoch, stub.generation, stub.wireContainer, staging) {
            [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                self.finishEagerFetch(result, stub: stub, staging: staging,
                                      fetch: fetch, attempt: attempt)
            }
        }
        return fetch
    }

    private func finishEagerFetch(
        _ result: Result<GuestListener.FileDelivery, GuestListener.FileFailure>,
        stub: ContinuityDragStub, staging: URL, fetch: EagerFetch,
        attempt: Int
    ) {
        grabInFlight = false
        switch result {
        case .failure(let failure):
            audit(.info, "eager fetch refused by the Mac: code="
                + "\(failure.code), reason=\(failure.message), "
                + "generation=\(stub.generation), attempt=\(attempt) — "
                + "this Mac does not retry a refused grab on its own; the "
                + "promise-fallback redemption is a SEPARATE attempt for "
                + "the same generation if AppKit still needs one, not a "
                + "retry this host scheduled, name=\(stub.item.name)")
            fetch.finish(.failure(GrabError.wire(code: failure.code,
                                                 message: failure.message)))
            /* Nothing will ever read this directory: the promise, not this
               fetch, owns the drag from here. */
            try? FileManager.default.removeItem(at: staging)
        case .success(let file):
            let url = staging.appendingPathComponent(stub.localName)
            do {
                try FileConverter.materialize(
                    name: file.name, container: file.container,
                    fileType: file.fileType, staged: file.staged, to: url)
                fetch.finish(.success(url))
                /* Distinct from `resolveEagerDrag`'s "drag payload: eager"
                   line: this one is the fetch's own fact (it finished, and
                   when) and stands whether or not a drag ever asks for it —
                   the resolve-time line is about what a SPECIFIC drag did
                   with that fact, and the two can now legitimately disagree
                   (finished but too late, finished but the drag chose the
                   promise for some other reason). */
                audit(.info, "eager fetch completed: name=\(file.name), "
                    + "generation=\(stub.generation)")
                /* The staged file is now what the pasteboard may point at —
                   best-effort cleanup, well after any drop had time to read
                   it, rather than deleted out from under one. A drag that
                   never happens at all leaves this behind for the OS's
                   ordinary temp-directory sweep, same as an unfulfilled
                   promise leaves nothing at all: an acceptable asymmetry
                   for a file already proven small. */
                DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
                    try? FileManager.default.removeItem(at: staging)
                }
            } catch {
                audit(.warn, "eager fetch arrived but could not be written; "
                    + "the drag still has its promise: name=\(stub.item.name), "
                    + "reason=\(error.localizedDescription)")
                fetch.finish(.failure(error))
                try? FileManager.default.removeItem(at: staging)
            }
        }
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider,
                             fileNameForType fileType: String) -> String {
        _ = fileType
        guard let stub = provider.userInfo as? ContinuityDragStub else {
            return "Untitled"
        }
        return stub.localName
    }

    func operationQueue(for provider: NSFilePromiseProvider)
        -> OperationQueue { promiseQueue }

    nonisolated func filePromiseProvider(
        _ provider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let frozen = provider.userInfo as? ContinuityDragStub
        let providerID = ObjectIdentifier(provider)
        let completion = GrabCompletion(completionHandler)
        Task { @MainActor [weak self] in
            guard let self else {
                completion.finish(GrabError.noStub)
                return
            }
            /* THE REVISION WINDOW CLOSES HERE, and this is the only place it
               closes. Redeeming is what makes the identity final: from this
               line on a late generation is about the next gesture, and the
               binding says so out loud rather than quietly swapping a file
               whose bytes are already being asked for. */
            let stub: ContinuityDragStub?
            var heldMs: Int?
            /* Named here rather than read back off `liveBinding` at the
               refusal: a second crossing may have replaced it during the
               hold, and a refusal line that names the WRONG gesture is
               worse than one that names none. */
            var heldGesture: UInt64?
            if let binding = self.liveBinding,
               binding.providerID == providerID {
                /* THE HOLD, AND IT HAPPENS BEFORE THE WINDOW SHUTS. A
                   crossing whose only account is the resident's identity
                   has nothing a grab may name, and redeeming it here would
                   close the revision window against the very frame it is
                   waiting for. So the wait comes first and the redemption
                   after it — one gesture, one attempt, made when there is
                   something to attempt with. */
                if binding.grabbable == nil {
                    heldGesture = binding.gesture
                    let started = DispatchTime.now()
                    _ = await self.holdForMintedGeneration(binding)
                    heldMs = Int(Double(DispatchTime.now().uptimeNanoseconds
                        - started.uptimeNanoseconds) / 1_000_000)
                }
                stub = binding.redeem()
                if let stub, stub.generation != binding.seed?.generation {
                    self.audit(.info, "grab redeems a LATE bind: gesture "
                        + "\(binding.gesture), name=\(stub.item.name), "
                        + "generation=\(stub.generation), replacing the "
                        + "generation this crossing started with "
                        + "(\(binding.seed.map { String($0.generation) } ?? "none"))")
                }
            } else {
                stub = frozen
            }
            guard let stub else {
                self.audit(.error, "grab refused: this drag crossed with "
                    + "nothing named and the Mac never published a "
                    + "drag-sourced generation for it, so there is nothing "
                    + "to ask for — no file is guessed at")
                completion.finish(GrabError.noStub)
                return
            }
            /* REFUSED HERE, BY NAME, AND NOT ON THE WIRE. The Macintosh
               mints generations and refuses every number it did not, so a
               zero is a certain refusal — spending the drop's one grab on
               it would report the symptom (`drag-not-yet-named`) instead of
               the cause, which is that this Mac waited and nothing came.
               The listener keeps its own guard as the last line; this one
               exists to say how long the wait was. */
            guard stub.generation != 0 else {
                let waited = heldMs ?? 0
                self.audit(.error, "grab refused: gesture "
                    + "\(heldGesture?.description ?? "none") "
                    + "waited \(waited) ms and the Macintosh never minted a "
                    + "generation for \(stub.item.name) (dragSeq="
                    + "\(stub.dragSeq.map(String.init) ?? "none")) — the "
                    + "identity crossed and the grant never did, so nothing "
                    + "is asked for and no file is guessed at")
                let refusal = GrabError
                    .notYetNamed(name: stub.item.name, waitedMs: waited)
                    .localizedDescription
                self.setNotice(refusal)
                self.refusalSink?(refusal)
                completion.finish(GrabError.notYetNamed(name: stub.item.name,
                                                        waitedMs: waited))
                return
            }
            self.redeem(stub, to: url, completion: completion)
        }
    }

    private func redeem(_ stub: ContinuityDragStub, to url: URL,
                        completion: GrabCompletion) {
        guard !grabInFlight else {
            let key = ContinuityFileStubKey(epoch: stub.epoch,
                                            generation: stub.generation)
            audit(.warn, "grab refused: another grab is already in flight "
                + "(epoch=\(stub.epoch), generation=\(stub.generation), "
                + "attemptsSoFar=\(attemptCounts[key] ?? 0)) — this Mac "
                + "does not schedule a retry; the promise has nothing to "
                + "hand AppKit and the drag ends here")
            completion.finish(GrabError.busy)
            return
        }
        grabInFlight = true
        notice = nil
        let attempt = nextAttempt(epoch: stub.epoch, generation: stub.generation)
        audit(.info, "grab requested: epoch=\(stub.epoch), "
            + "generation=\(stub.generation), attempt=\(attempt), "
            + "name=\(stub.item.name), container=\(stub.wireContainer ?? "auto")")
        grab(stub.epoch, stub.generation, stub.wireContainer,
             url.deletingLastPathComponent()) { [weak self] result in
            guard let self else {
                completion.finish(GrabError.noStub)
                return
            }
            switch result {
            case .failure(let failure):
                self.grabInFlight = false
                /* Named, not counted. `stale-selection` and `bad-epoch` are
                   the guest refusing a grant it will not honour, and they
                   read identically to a dead wire unless the code is in the
                   line. */
                self.audit(.error, "grab refused by the Mac: "
                    + "code=\(failure.code), reason=\(failure.message), "
                    + "epoch=\(stub.epoch), generation=\(stub.generation), "
                    + "attempt=\(attempt) — this Mac does not retry a "
                    + "refused grab on its own; no further attempt for "
                    + "this generation is scheduled")
                let refusal = GrabError.wire(code: failure.code,
                                             message: failure.message)
                    .localizedDescription
                self.setNotice(refusal)
                self.refusalSink?(refusal)
                completion.finish(GrabError.wire(code: failure.code,
                                                 message: failure.message))
            case .success(let file):
                self.materialize(file, stub: stub, to: url,
                                 completion: completion)
            }
        }
    }

    private func materialize(_ file: GuestListener.FileDelivery,
                             stub: ContinuityDragStub,
                             to url: URL,
                             completion: GrabCompletion) {
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                Result {
                    let note = try FileConverter.materialize(
                        name: file.name, container: file.container,
                        fileType: file.fileType, staged: file.staged, to: url)
                    if let modified = file.modified,
                       let date = ClassicDate.date(from: modified) {
                        try? FileManager.default.setAttributes(
                            [.modificationDate: date],
                            ofItemAtPath: url.path)
                    }
                    return note
                }
            }.value
            guard let self else { return }
            self.grabInFlight = false
            switch outcome {
            case .success(let note):
                self.audit(.info, "grab completed: name=\(file.name), "
                    + "generation=\(stub.generation), "
                    + "container=\(file.container), "
                    + "integrity=\(file.crc32 == nil ? "unchecked" : "crc32"), "
                    + "conversion=\(note ?? "none")")
                self.setNotice(note.map {
                    "Copied \(stub.item.name) to this Mac (\($0))."
                } ?? "Copied \(stub.item.name) to this Mac.")
                completion.finish(nil)
            case .failure(let error):
                self.audit(.error, "grab arrived but could not be written: "
                    + "name=\(file.name), reason=\(error.localizedDescription)")
                self.setNotice(error.localizedDescription)
                self.refusalSink?(error.localizedDescription)
                completion.finish(error)
            }
        }
    }

    /// AppKit hands the completion in from its own queue; this box carries it
    /// back to the main actor without pretending the closure is Sendable.
    private final class GrabCompletion: @unchecked Sendable {
        private let body: (Error?) -> Void
        init(_ body: @escaping (Error?) -> Void) { self.body = body }
        @MainActor func finish(_ error: Error?) { body(error) }
    }
}
