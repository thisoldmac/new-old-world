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
        case wire(code: String, message: String)

        var errorDescription: String? {
            switch self {
            case .noStub:
                return "That dragged item is no longer available on "
                    + MachineNaming.simpleReference + "."
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
    ///
    /// `revisable` is the late-bind half: a candidate that came from the
    /// SELECTION cache may still be replaced by a drag-sourced generation
    /// arriving after the cross, and bytes fetched eagerly under the old
    /// identity would then be pinned onto the pasteboard as the wrong file —
    /// a promise can be revised and a `file://` URL cannot. It also keeps
    /// the single wire lane free, so the drop's own redemption is never
    /// refused `busy` by a head start it no longer wants. A drag-sourced
    /// candidate has nothing left to revise and keeps the head start.
    func dragItem(for stub: ContinuityDragStub,
                  revisable: Bool = false) -> HostFileDragItem {
        let bytes = ContinuityFileDragPolicy.totalBytes(
            dataSize: stub.item.dataSize, resourceSize: stub.item.resourceSize)
        let promiseWriter = promise(for: stub)
        let binding = newBinding(for: stub, provider: promiseWriter)
        let image = NSWorkspace.shared.icon(for: stub.utType)
        if revisable {
            audit(.info, "drag payload: keeping this drag on its promise "
                + "(gesture \(binding.gesture)): it is bound to the "
                + "SELECTION cache, and the Mac can still name a different "
                + "file for this gesture up to the drop — fetched bytes "
                + "cannot be revised, a promise can")
            return HostFileDragItem(writer: promiseWriter, image: image)
        }
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
            if let binding = self.liveBinding,
               binding.providerID == providerID {
                stub = binding.redeem()
                if let stub, stub.generation != frozen?.generation {
                    self.audit(.info, "grab redeems a LATE bind: gesture "
                        + "\(binding.gesture), name=\(stub.item.name), "
                        + "generation=\(stub.generation), replacing the "
                        + "generation this crossing started with "
                        + "(\(frozen.map { String($0.generation) } ?? "none"))")
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
