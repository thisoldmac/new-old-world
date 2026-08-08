import Foundation
import MirrorKit

/// Joins NOW's bounded QuickDraw log onto the structural scene by the one
/// exact key both planes report: WindowRecord/GrafPort address.
///
/// This is data, not framebuffer transport. Text and primitive operations are
/// replayed by MirrorKit; CopyBits and other unsupported visual families stay
/// visible as content-plane limitations instead of becoming hidden pixels.
@MainActor
final class NOWMirrorContentPlane {
    struct ContentIdentity: Hashable {
        var psn: String
        var a5: String
        var window: UInt32
        var displayEpoch: Int
        var generation: Int
    }

    struct Update {
        var scene: MirrorKit.Scene
        var sentence: String
    }

    /// One offscreen world the guest's probe hooked, as this host keys it.
    /// The port address alone is NOT durable — a disposed world's address
    /// is reused by the next NewGWorld of the same size (measured
    /// 2026-08-06: 0x1ea59e00 twice running) — so it is paired with the
    /// record header's generation, which moves on every re-arm.
    struct SourceKey: Hashable {
        var port: UInt32
        var generation: Int
    }

    /// The window stream's last-known drawing state, tracked so a spliced
    /// run of offscreen ops can restore what it changed. State flows
    /// across ops in the replay, so a splice that set its own origin,
    /// clip or colours and restored nothing would bend every window op
    /// that follows it.
    struct PortState {
        var origin: [Int] = [0, 0]
        var clip: [Int]?
        var fg: [Int]?
        var bg: [Int]?

        mutating func absorb(_ op: DisplayOp) {
            guard op.op == "state" else { return }
            switch op.kind {
            case "origin": if let o = op.origin, o.count == 2 { origin = o }
            case "clip": if let r = op.rect, r.count == 4 { clip = r }
            case "fg": if let c = op.rgb, c.count == 3 { fg = c }
            case "bg": if let c = op.rgb, c.count == 3 { bg = c }
            default: break
            }
        }
    }

    private let listener: GuestListener
    private let sendCommand: GuestCommandSend
    private var sessionGeneration = 0
    private(set) var targetPSN: String?
    private(set) var targetWindow: UInt32?
    private(set) var cursor = 0
    private(set) var operations: [ContentIdentity: [DisplayOp]] = [:]
    private(set) var settledOperations: [ContentIdentity: [DisplayOp]] = [:]
    /// The identity currently being accumulated is not necessarily the one
    /// safe to display. A repaint can span several drains, and changing the
    /// active application must not turn that partial accumulator into a blank
    /// inactive window. Keep the published identity per exact guest window.
    private var settledDisplay: [String: ContentIdentity] = [:]
    private var currentDisplay: [String: ContentIdentity] = [:]
    /// A ring overwrite makes the remainder of the current guest display
    /// incomplete. Keep the last settled pixels until this exact slot reports
    /// a strictly newer guest-authored epoch/generation.
    private var replacementFloor: [String: ContentIdentity] = [:]
    private var armedAt: Date?

    /// Ops recorded under an offscreen port's key — the drawing that BUILT
    /// a composite, held until the blit that reveals it arrives (013 slice
    /// C: ops precede their blit, so the host accumulates into a buffer it
    /// cannot place yet). Bounded both ways: per-source at the window cap,
    /// and at `sourceCap` sources with the oldest evicted loudly.
    private(set) var sourceOperations: [SourceKey: [DisplayOp]] = [:]
    private var sourceOrder: [SourceKey] = []
    /// A `blitsrc` record names the source of the `bits` record that
    /// IMMEDIATELY follows it; anything else in between voids the claim.
    /// Keyed by DESTINATION port, because composition nests: Sherlock 2
    /// draws its list into one offscreen world, blits that into the
    /// world holding the whole interior, and blits THAT into the window
    /// (measured 2026-08-06). A destination is not always a window, and
    /// a claim belongs to the port it was made on.
    private var pendingBlitSource: [UInt32: UInt32] = [:]
    /// Live drawing state per DESTINATION port. The window's is the one
    /// a splice restores; an offscreen world's matters for a different
    /// reason — its ORIGIN is part of the join's arithmetic. Sherlock 2
    /// blits its list into the composite at `dst [0,0,451,76]` while
    /// the destination's origin is shifted, which is the same SetOrigin
    /// idiom its channel grid uses; a join that ignores the origin
    /// places that list at the window's top-left instead of inside the
    /// list area, and the render says so plainly.
    private var portStates: [UInt32: PortState] = [:]
    /// Where each offscreen world was BORN. A `NewGWorld` rect is often
    /// stated in the destination window's coordinates rather than at the
    /// origin, and that rect is the frame the world's own ops — and the
    /// `src` of the blit that reveals them — are expressed in. See
    /// `rehome`, which double-counted it until 2026-08-07.
    private var sourceBirth: [SourceKey: [Int]] = [:]
    private var evictedSourceCount = 0
    /// **THE GENERATION EACH PORT'S HELD OPS WERE RECORDED UNDER**, which is
    /// not always the generation of the blit that comes to place them.
    ///
    /// A world's ops arrive before the blit that reveals them — that is the
    /// whole reason they are held — and `generation` moves on every RE-ARM,
    /// which happens on a 9-minute timer against a 10-minute guest TTL. So a
    /// renewal landing between a world's drawing and its placing blit is not
    /// exotic: it is routine, and until this ledger existed the lookup used
    /// the BITS record's generation, missed, and the composite never joined.
    /// The failure was at least honest — the bits op falls through and the
    /// renderer hatches it — but honest is not the same as correct.
    ///
    /// The generation stays in ``SourceKey`` because a disposed world's
    /// address is reused by the next `NewGWorld` of the same size (measured
    /// 2026-08-06: `0x1ea59e00` twice running), and two different worlds must
    /// never share a bucket. What changes is only WHICH generation a lookup
    /// quotes: the one the ops were written under, tracked here, rather than
    /// the one the reader happens to be standing in.
    ///
    /// **WHAT THIS GIVES UP, stated rather than discovered later.** A bare
    /// generation change used to void the join, and that was read as a guard
    /// against address reuse. It cannot be: from the wire, "a re-arm happened
    /// between this world's ops and its blit" and "this world was disposed
    /// and its address reused" look identical if generation is all you
    /// consult — and the first is ROUTINE, because the arm renews every nine
    /// minutes against a ten-minute TTL. So the void was firing constantly on
    /// live worlds to catch a case it could not actually identify.
    ///
    /// Reuse is now guarded by the evidence that can tell them apart: the
    /// guest's own `worlddied`, which releases the hold outright. The
    /// residual is a world disposed and its address reused with the death
    /// record never reaching this host — and there the join is wrong, where
    /// before every join across a renewal was missing.
    private var sourceGeneration: [UInt32: Int] = [:]

    /// The key `port`'s held ops actually live under. Falls back to the
    /// caller's own generation when this host has never held anything for
    /// that port — in which case the lookup was going to miss either way,
    /// and missing under the caller's generation is the older behaviour.
    private func heldSourceKey(_ port: UInt32,
                               orUnder generation: Int) -> SourceKey {
        SourceKey(port: port,
                  generation: sourceGeneration[port] ?? generation)
    }

    /* ── ONE CLOCK (plan 018 slice 1) ──────────────────────────────────
       Three small ledgers, and between them they answer the only question
       the renderer could not previously ask: do the pixels I am about to
       draw still describe the window this scene is about?

       The pieces already existed and never met. `displayEpoch` and
       `generation` ride every drain record and were used ONLY to reject
       older ops into the current accumulator. `worlddied` fired and
       released held source ops, and said nothing to the composite those
       ops had already been spliced into — so a Finder view switch, which
       disposes the interior GWorld and builds a new one, left the OLD
       view's pixels published as though they were current. That is
       "new view drawn on top of old" from the driving session. */

    /// The newest (generation, epoch) the guest has been SEEN drawing for
    /// each slot, whether or not it has settled. A settled display older
    /// than this is a frame the machine has moved on from.
    private var latestEpoch: [String: (generation: Int, epoch: Int)] = [:]
    /// Which offscreen worlds a window identity's ops were composed from.
    /// A world's death invalidates every composite spliced from it, and
    /// nothing could previously make that connection.
    private var contributingSources: [ContentIdentity: Set<SourceKey>] = [:]
    /// Nested composition: a world built from another world inherits its
    /// lineage, so a death two levels down still reaches the window.
    private var sourceLineage: [SourceKey: Set<SourceKey>] = [:]
    /// Slots whose settled pixels were composed from a world the guest has
    /// since disposed. Cleared when a newer epoch settles for that slot.
    private var deadWorldSlots: Set<String> = []
    /// Identities whose accumulator hit the cap with no pass boundary to
    /// compact to, so ops that are still on the guest's screen were
    /// dropped by this host. Their frames publish `stale`: a marked gap
    /// is honest, a confident subset is not.
    private var hollowed: Set<ContentIdentity> = []
    /// Set by a RENEWAL arm (same window, fresh ring baseline), so the
    /// first identity to arrive afterwards inherits the pixels the guest
    /// still has rather than starting from nothing. Cleared once used —
    /// it describes one arm, not a standing mode. Internal so tests can
    /// drive a renewal without a listener.
    var carryForward = false
    /// The structural scene sequence each slot's display last settled
    /// against — reported, never gated on. See ``DisplayEpoch``.
    private var settledAtSequence: [String: Int] = [:]
    /// **Every `psn:addr` this host has ever armed P3 on**, so a window
    /// with no interior can say WHY it has none. P3 is a one-window
    /// spotlight, so most windows in most scenes are in neither this set
    /// nor `settledDisplay`, and until now they rendered the same hatch as
    /// a window the plane looked at and found nothing in — captioned with
    /// a claim about the guest that was only true of the second.
    /// See ``MirrorKit/ContentPlaneAttention``.
    ///
    /// It grows and is never pruned within one guest session, which is the
    /// correct shape: "we asked about this window at 12:04" does not stop
    /// being true because the arm has since moved on. `guestChanged`
    /// clears it, because a different guest is a different machine.
    ///
    /// Internal rather than private so tests can drive an arm without a
    /// listener, the same seam `carryForward` uses.
    var attempted: Set<String> = []

    /// Keep enough ordered drawing to include a full repaint without allowing
    /// a busy application to grow the host indefinitely.
    static let operationCapPerWindow = 1_200
    static let sourceCap = 16
    /// Drain pages one structural cycle may spend chasing a busy ring.
    /// Twelve × 4 KiB covers a whole 64 KiB ring's worth of records
    /// within one cycle, which is the point: the writer must not lap a
    /// reader that is awake. Idle machines never reach page two.
    static let pagesPerCycle = 12
    private static let renewAfter: TimeInterval = 9 * 60

    init(listener: GuestListener, sendCommand: GuestCommandSend? = nil) {
        self.listener = listener
        self.sendCommand = sendCommand ?? { verb, args, completion in
            listener.runCommand(verb, typed: args, completion: completion)
        }
    }

    func guestChanged() {
        sessionGeneration &+= 1
        targetPSN = nil
        targetWindow = nil
        cursor = 0
        operations.removeAll()
        settledOperations.removeAll()
        settledDisplay.removeAll()
        currentDisplay.removeAll()
        replacementFloor.removeAll()
        sourceOperations.removeAll()
        sourceOrder.removeAll()
        pendingBlitSource.removeAll()
        portStates.removeAll()
        latestEpoch.removeAll()
        contributingSources.removeAll()
        sourceLineage.removeAll()
        deadWorldSlots.removeAll()
        hollowed.removeAll()
        settledAtSequence.removeAll()
        attempted.removeAll()
        armedAt = nil
    }

    /// Withdraw this named owner's request before clearing its cached display.
    /// qdtrace stop releases only kNowPeekOwnerContent; P1/P2/P4 are untouched.
    func disable(completion: @escaping (String?) -> Void) {
        let hadClaim = armedAt != nil || targetPSN != nil
        /* Local state ends synchronously. A stopped Mirror must become
           not-fetched even when the guest never answers the release command.
           The command below is still sent when there was a claim, but its
           latency no longer keeps the dead session addressable. */
        guestChanged()
        guard hadClaim else {
            completion(nil)
            return
        }
        sendCommand("qdtrace", ["op": .text("stop")]) { result in
            guard result.ok else {
                completion(Self.failure(result))
                return
            }
            completion(nil)
        }
    }

    /// One bounded content ask after a scene transfer. There is no independent
    /// timer or poller; the structural scene remains the cadence owner.
    func join(into scene: MirrorKit.Scene,
              completion: @escaping (Update) -> Void) {
        let generation = sessionGeneration
        guard let front = scene.windows.first(where: \.front) else {
            targetPSN = nil
            targetWindow = nil
            armedAt = nil
            replacementFloor.removeAll()
            let retained = settledOperations.values.reduce(0) {
                $0 + $1.count
            }
            completion(.init(
                scene: attachCached(to: scene),
                sentence: retained == 0
                    ? "content: no front window"
                    : "content: no front window; retained \(retained) "
                        + "expected-stale draw ops"))
            return
        }
        let needsTarget = Self.needsTarget(
            currentPSN: targetPSN, currentWindow: targetWindow, front: front)
        let needsRenewal = armedAt.map {
            Date().timeIntervalSince($0) >= Self.renewAfter
        } ?? true
        if needsTarget {
            /* The accumulator belongs to one arm of P3. Retargeting starts a
               fresh arm, but the last PUBLISHED display remains valid as
               expected-stale data for every inactive window. This is the
               same distinction the state engine makes between an incomplete
               observation and a deletion. */
            let slot = Self.slot(psn: front.psn, window: front.addr)
            if let slot, let incomplete = currentDisplay.removeValue(
                forKey: slot) {
                operations[incomplete] = nil
            }
            targetPSN = front.psn
            targetWindow = front.addr
            cursor = 0
            replacementFloor.removeAll()
            sourceOperations.removeAll()
            sourceOrder.removeAll()
            sourceLineage.removeAll()
            pendingBlitSource.removeAll()
            portStates.removeAll()
            armedAt = nil
        }
        if needsTarget || needsRenewal {
            /* **A RENEWAL IS NOT A NEW WINDOW, and the accumulator must
               not pretend it is.** Re-arming bumps the guest's
               `display_epoch`, so the next record carries an identity
               this host has never seen and starts an EMPTY op list —
               while the window on the guest still holds every pixel it
               drew before. The first thing a settled panel draws
               afterwards is one clock tick, and that single op settled
               as the whole published display: the interior collapsed to
               whatever happened to be redrawn in the seconds after a
               renewal nobody asked for.

               The renewal fires on a 9-minute timer against a 10-minute
               guest TTL, so this arrives with the machine untouched and
               looks exactly like the picture decaying on its own. It is
               also why RE-FRONTING cures it and the timer does not:
               fronting a window makes the application repaint the whole
               thing, so the fresh accumulator is immediately complete.

               Carrying the settled ops forward keeps the picture the
               guest still has. It is only ever done for the SAME window
               of the same process — a retarget is a different window and
               inherits nothing. */
            carryForward = !needsTarget
            prepare(front: front, scene: scene, generation: generation,
                    completion: completion)
        } else {
            drain(scene: scene, generation: generation,
                  completion: completion)
        }
    }

    /// Baseline the monotonic ring before arming a new process. Otherwise a
    /// target switch could replay records written by the previous app and
    /// mis-join them merely because an address was later reused.
    private func prepare(front: MirrorKit.Scene.Window,
                         scene: MirrorKit.Scene,
                         generation: Int,
                         completion: @escaping (Update) -> Void) {
        sendCommand("qdtrace", ["op": .text("status")]) {
            [weak self] result in
            guard let self,
                  self.sessionGeneration == generation else { return }
            guard result.ok,
                  case .object(let qd)? = result.outputObjects?["qdtrace"],
                  case .object(let ring)? = qd["ring"],
                  let write = Self.int(ring["writeCursor"]) else {
                completion(.init(
                    scene: self.attachCached(to: scene),
                    sentence: "content: could not baseline the draw ring — "
                        + Self.failure(result)))
                return
            }
            self.cursor = write
            guard let serial = Self.serial(front.psn) else {
                completion(.init(
                    scene: self.attachCached(to: scene),
                    sentence: "content: the front process has an unreadable "
                        + "serial \(front.psn)"))
                return
            }
            guard let window = front.addr else {
                completion(.init(
                    scene: self.attachCached(to: scene),
                    sentence: "content: the front window has no exact guest "
                        + "address, so P3 refused an all-windows arm"))
                return
            }
            self.sendCommand("qdtrace", [
                "op": .text("start"),
                "serialHi": .number(serial.hi),
                "serialLo": .number(serial.lo),
                "window": .text(String(format: "0x%08x", window)),
                "mode": .text("record"),
                "ttlTicks": .number(36_000),
            ]) { [weak self] start in
                guard let self,
                      self.sessionGeneration == generation else { return }
                guard start.ok else {
                    self.armedAt = nil
                    completion(.init(
                        scene: self.attachCached(to: scene),
                        sentence: "content: could not arm \(front.app) — "
                            + Self.failure(start)))
                    return
                }
                self.armedAt = Date()
                /* THE ONE PLACE THAT KNOWS WE LOOKED. Recorded on the
                   REQUEST rather than on the first record, because the
                   question this answers is "did this host ask about this
                   window", and a window we armed and that drew nothing has
                   been asked. Recording it at the first record instead
                   would make a genuinely empty interior indistinguishable
                   from one nobody looked at all over again, which is the
                   defect this exists to close. */
                self.attempted.insert("\(front.psn):\(window)")
                completion(.init(
                    scene: self.attachCached(to: scene),
                    sentence: "content: requested \(front.app)'s trace; "
                        + "waiting for its event loop to arm and draw"))
            }
        }
    }

    private func drain(scene: MirrorKit.Scene,
                       generation: Int,
                       completion: @escaping (Update) -> Void) {
        drainPage(scene: scene, pagesLeft: Self.pagesPerCycle,
                  generation: generation,
                  completion: completion)
    }

    /// One drain, then MORE while the guest says there are more, up to a
    /// bounded number of pages within this one structural cycle.
    ///
    /// THE RING IS THE LIMIT, MEASURED: a compositing application under
    /// active repaint writes ~12 KB/s into a 64 KiB ring — about five
    /// seconds of headroom — while the structural cycle that used to
    /// carry the only drain runs every ~2.2 s and drained ONE page of
    /// it. Sherlock lost 114018 bytes in one settle that way, and the
    /// interior text went with them. Chasing the cursor while the guest
    /// still reports `more` costs nothing when the machine is idle (the
    /// first page answers `more: false` and the loop ends) and is the
    /// difference between a composed window and a hatch when it is not.
    ///
    /// It is deliberately BOUNDED rather than a loop-until-empty: the
    /// scene cycle remains the cadence owner — that is the sibling
    /// perf thread's territory and this must not take it — so a page
    /// budget caps what one cycle may spend, and anything still pending
    /// is drained by the next cycle exactly as before.
    private func drainPage(scene: MirrorKit.Scene, pagesLeft: Int,
                           generation: Int,
                           completion: @escaping (Update) -> Void) {
        sendCommand("qdtrace", [
            "op": .text("drain"), "cursor": .text(String(cursor)),
        ]) { [weak self] result in
            guard let self,
                  self.sessionGeneration == generation else { return }
            guard result.ok,
                  case .object(let object)? = result.outputObjects?["qdtrace"],
                  let decoded = QDTraceDecode.drain(Self.plain(object)) else {
                completion(.init(
                    scene: self.attachCached(to: scene),
                    sentence: "content: draw drain failed — "
                        + Self.failure(result)))
                return
            }
            let update = self.apply(decoded, to: scene)
            guard decoded.more, pagesLeft > 1 else {
                completion(update)
                return
            }
            self.drainPage(scene: scene, pagesLeft: pagesLeft - 1,
                           generation: generation,
                           completion: completion)
        }
    }

    /// Pure state transition once a drain is decoded; internal so host tests
    /// can prove exact-address joins and the torn/resync rules without a VM.
    func apply(_ drain: QDTraceDecode.Drain,
               to scene: MirrorKit.Scene) -> Update {
        cursor = drain.nextCursor
        if drain.torn || drain.busy {
            return .init(
                scene: attachCached(to: scene),
                sentence: drain.torn
                    ? "content: the guest retracted a torn draw read"
                    : "content: a draw was committing; retained the last "
                        + "settled display")
        }
        guard drain.recordCountAgrees else {
            return .init(
                scene: attachCached(to: scene),
                sentence: "content: guest reported \(drain.reportedRecords) "
                    + "draw records but this host decoded "
                    + "\(drain.records.count); retained the prior display")
        }
        if drain.resync || drain.lostBytes > 0 {
            operations.removeAll()
            replacementFloor.removeAll()
            /* A hole in the ring makes every held accumulation suspect: a
               composite missing its erase, or its first half, joined into
               a window is worse than a hatch. */
            sourceOperations.removeAll()
            sourceOrder.removeAll()
            pendingBlitSource.removeAll()
            let front = scene.windows.first(where: \.front)
            if let slot = Self.slot(psn: targetPSN ?? front?.psn,
                                    window: targetWindow ?? front?.addr),
               let current = currentDisplay[slot] {
                replacementFloor[slot] = current
            }
        }

        let visible = Dictionary(uniqueKeysWithValues: scene.windows.compactMap {
            window in window.addr.map { ($0, window.psn) }
        })
        /// Each visible window's own size, so a "this op covers the whole
        /// window" test is measured against the window rather than guessed
        /// from the stream. Used only by ``lastRepaintPass``.
        let windowSize = Dictionary(uniqueKeysWithValues: scene.windows
            .compactMap { window -> (UInt32, (w: Int, h: Int))? in
                guard let addr = window.addr else { return nil }
                return (addr, (w: window.rect.r - window.rect.l,
                               h: window.rect.b - window.rect.t))
            })
        let expectedPSN = targetPSN
            ?? scene.windows.first(where: \.front)?.psn
        let expectedWindow = targetWindow
            ?? scene.windows.first(where: \.front)?.addr
        var matched = 0
        var unjoined = 0
        var stale = 0
        var incomplete = 0
        var held = 0
        var joined = 0
        var born = 0
        var died = 0
        var compactedPasses = 0
        var carried = 0
        evictedSourceCount = 0
        for record in drain.records {
            guard let address = record.portAddress else {
                unjoined += 1
                continue
            }
            if address != expectedWindow {
                /* Not the armed window — but in probe mode the armed
                   process's ring also carries ops recorded under a hooked
                   offscreen GWorld's own port key: the drawing that BUILT
                   a composite, arriving before the blit that reveals it.
                   Hold those, bounded, keyed by port + generation, until
                   a blitsrc/bits pair on the window claims them. Anything
                   from another process stays unjoined, as before. */
                /* Only a port that is NOT any window in this scene can be
                   an offscreen world; a record from another window of the
                   same process stays unjoined exactly as before. */
                /* `blitsrc` is NOT excluded here any more, and the
                   change is the whole of nested composition: when only
                   windows could be a blit's destination, a blitsrc on
                   an offscreen port could only be noise. Sherlock 2
                   blits world into world, so a claim made on an
                   offscreen port is a real join. */
                guard record.psn == expectedPSN, visible[address] == nil
                else {
                    unjoined += 1
                    continue
                }
                /* worldborn/worlddied are the guest's own word about a
                   world's lifetime (plan 014). A death releases the ops
                   held for it immediately - the application says the
                   composite is gone, which beats any retention guess -
                   and neither record is drawing, so neither is held. */
                if record.op.op == "worlddied" {
                    /* RESOLVED THE SAME WAY THE JOIN IS, and it has to be:
                       a death is now the ONLY thing that voids a hold, so a
                       death arriving after a re-arm must find the ops it is
                       about. Keyed on this record's own generation it would
                       miss exactly when it matters most. */
                    let key = heldSourceKey(address,
                                            orUnder: record.generation)
                    if sourceOperations.removeValue(forKey: key) != nil {
                        sourceOrder.removeAll { $0 == key }
                        died += 1
                    }
                    sourceGeneration[address] = nil
                    sourceBirth[key] = nil
                    sourceLineage[key] = nil
                    /* THE DEATH REACHES THE COMPOSITE, which is the half
                       that was missing. Releasing the held ops was always
                       right and was never enough: by the time a world dies
                       its pixels have usually already been spliced into a
                       window's settled display, and that display went on
                       being published as current. The Finder disposes and
                       rebuilds its interior GWorld on every view switch
                       (it imports NewGWorld/DisposeGWorld and no
                       UpdateGWorld — docs/toolbox-and-gworld.md §5a), so
                       this is exactly "the old view still drawn under the
                       new one" from the driving session. */
                    for (identity, sources) in contributingSources
                    where sources.contains(key) {
                        let slot = "\(identity.psn):\(identity.window)"
                        if settledDisplay[slot] == identity {
                            deadWorldSlots.insert(slot)
                        }
                    }
                    continue
                }
                if record.op.op == "worldborn" {
                    born += 1
                    /* THE FRAME THE WORLD'S OWN COORDINATES ARE IN. A
                       GWorld made with a rect in its destination's space
                       reports that rect at birth and every op it draws —
                       and the `src` of the blit that reveals it — is
                       stated in it. `rehome` needs it to avoid counting
                       the shift twice; see the note there. */
                    if let r = record.op.rect, r.count == 4 {
                        sourceBirth[SourceKey(port: address,
                                              generation: record.generation)]
                            = [r[0], r[1]]
                    }
                    continue
                }
                let destKey = SourceKey(port: address,
                                        generation: record.generation)
                /* A NESTED join: this offscreen world is the destination
                   of a blit from another one. Splice the inner world's
                   ops into this one's, re-homed, exactly as the window
                   branch does - composition nests, so the join must too.
                   The restore state is a fresh one: an offscreen world's
                   stream opens with its own erase, so there is no prior
                   state of its own to put back. */
                if record.op.op == "blitsrc" {
                    pendingBlitSource[address] = record.srcPort
                    continue
                }
                portStates[address, default: PortState()].absorb(record.op)
                /* Same key correction as the window branch below: the inner
                   world's ops were recorded under whatever generation was
                   current WHEN THEY WERE DRAWN, which a re-arm moves off. */
                if record.op.op == "bits",
                   let inner = pendingBlitSource.removeValue(forKey: address),
                   case let innerKey = heldSourceKey(
                       inner, orUnder: record.generation),
                   let heldOps = sourceOperations[innerKey],
                   !heldOps.isEmpty,
                   let rehomed = Self.rehome(
                       heldOps, bits: record.op,
                       restoring: portStates[address] ?? PortState(),
                       into: portStates[address] ?? PortState(),
                       bornAt: sourceBirth[innerKey] ?? [0, 0]) {
                    appendSource(destKey, rehomed)
                    /* Composition nests, so lineage must too: this world's
                       pixels now depend on the inner world's life as well
                       as its own. */
                    sourceLineage[destKey, default: []].insert(innerKey)
                    sourceLineage[destKey, default: []]
                        .formUnion(sourceLineage[innerKey] ?? [])
                    joined += 1
                    held += rehomed.count
                    continue
                }
                if record.op.op != "bits" {
                    pendingBlitSource[address] = nil
                }
                appendSource(destKey, [record.op])
                held += 1
                continue
            }
            guard let scenePSN = visible[address], scenePSN == record.psn,
                  record.psn == expectedPSN else {
                unjoined += 1
                continue
            }
            let identity = ContentIdentity(
                psn: record.psn, a5: record.a5, window: address,
                displayEpoch: record.displayEpoch,
                generation: record.generation)
            let slot = "\(record.psn):\(address)"
            /* THE NEWEST CLOCK THE GUEST HAS BEEN SEEN ON, tracked
               separately from what has settled. A settled display older
               than this is a frame the machine has already moved past,
               and until now nothing recorded the difference. */
            let seen = latestEpoch[slot]
            if seen == nil
                || MirrorKit.DisplayEpoch.isNewer(
                    generation: record.generation, epoch: record.displayEpoch,
                    thanGeneration: seen!.generation, epoch: seen!.epoch) {
                latestEpoch[slot] = (generation: record.generation,
                                     epoch: record.displayEpoch)
            }
            if let floor = replacementFloor[slot] {
                guard Self.isNewer(identity, than: floor) else {
                    incomplete += 1
                    continue
                }
                replacementFloor[slot] = nil
            }
            if let current = currentDisplay[slot] {
                let isOlder = Self.isNewer(current, than: identity)
                let isSame = record.generation == current.generation
                    && record.displayEpoch == current.displayEpoch
                if isOlder || (isSame
                    && record.a5 != current.a5) {
                    stale += 1
                    continue
                }
                if !isSame {
                    operations[current] = nil
                    currentDisplay[slot] = identity
                    inherit(identity, at: slot, carried: &carried)
                }
            } else {
                currentDisplay[slot] = identity
                inherit(identity, at: slot, carried: &carried)
            }
            /* The join (013 slice C). A blitsrc record names the source of
               the bits record immediately after it; any other op between
               them voids the claim rather than letting it drift onto a
               later blit. When the claim holds and this host has that
               source's ops, the bits op is REPLACED by the held ops
               re-homed into the window — otherwise the bits op lands as
               before and the renderer hatches it. */
            var toAppend = [record.op]
            if record.op.op == "blitsrc" {
                pendingBlitSource[address] = record.srcPort
                continue
            }
            if record.op.op == "bits",
               let source = pendingBlitSource.removeValue(forKey: address) {
                /* KEYED ON THE GENERATION THE OPS WERE RECORDED UNDER, not
                   on this record's. See `sourceGeneration`: a re-arm between
                   a world's drawing and its placing blit used to miss here
                   and the composite never joined. */
                let key = heldSourceKey(source, orUnder: record.generation)
                if let heldOps = sourceOperations[key], !heldOps.isEmpty,
                   let rehomed = Self.rehome(
                       heldOps, bits: record.op,
                       restoring: portStates[address] ?? PortState(),
                       bornAt: sourceBirth[key] ?? [0, 0]) {
                    toAppend = rehomed
                    contributingSources[identity, default: []].insert(key)
                    contributingSources[identity, default: []]
                        .formUnion(sourceLineage[key] ?? [])
                    joined += 1
                }
            } else {
                pendingBlitSource[address] = nil
            }
            for op in toAppend { portStates[address, default: PortState()].absorb(op) }
            operations[identity, default: []].append(contentsOf: toAppend)
            if operations[identity]!.count > Self.operationCapPerWindow {
                /* **THE CAP TRIMS PASSES, NOT RAW OPS.** A raw
                   `removeFirst` drops the OLDEST ops, and the oldest ops
                   are the establishing repaint — the erase, the group
                   boxes, the static labels. `displayEpoch` advances once
                   per ARM and not per repaint, so a panel with a live
                   clock accumulates into ONE identity for as long as it
                   stays front, and every tick pushed the frame that made
                   the window a window one op closer to the edge. Michelle
                   watched Date & Time lose its group boxes, its date
                   field and half of two labels while touching nothing
                   (2026-08-07); re-fronting fixed it because that
                   retargets, and a fresh arm starts a fresh accumulator.

                   Compacting to the last pass boundary costs nothing,
                   because `lastRepaintPass` is already the only thing
                   ever PUBLISHED from this list — so everything it cuts
                   was, by construction, never going to be drawn. It is
                   idempotent, and it drops far below the cap, so this
                   runs rarely rather than per record. */
                let compacted = Self.lastRepaintPass(
                    operations[identity]!, window: windowSize[identity.window])
                if compacted.count < operations[identity]!.count {
                    operations[identity] = compacted
                    hollowed.remove(identity)
                    compactedPasses += 1
                }
            }
            if operations[identity]!.count > Self.operationCapPerWindow {
                /* Still over: the application has drawn 1200 ops inside
                   ONE pass, which is Date & Time's live clock and every
                   other window that updates a field in place. Forget
                   what a later op has already repainted — those pixels
                   are not on the guest's screen either. */
                let dense = Self.coalesce(operations[identity]!)
                if dense.count < operations[identity]!.count {
                    operations[identity] = dense
                    hollowed.remove(identity)
                    compactedPasses += 1
                }
            }
            if operations[identity]!.count > Self.operationCapPerWindow {
                /* No pass boundary to cut at — the application has drawn
                   1200 ops without once replacing the whole window, so
                   ops that ARE still on the machine's screen are about to
                   leave this host. Dropping them is forced; doing it
                   quietly is the defect. Mark the slot so the frame
                   publishes `stale` and the renderer shows a gap instead
                   of a confident subset, and say so in the sentence. */
                operations[identity]!.removeFirst(
                    operations[identity]!.count - Self.operationCapPerWindow)
                hollowed.insert(identity)
            }
            matched += 1
        }

        /* A drain is one bounded control answer, not one display frame. The
           resident deliberately returns `more` while a coherent repaint is
           still split across later answers. Publishing the accumulator at
           that point showed a half-redrawn application for several polls and
           then mixed it with the semantic layer. Keep the previous settled
           display visible until the host has caught the ring completely. */
        if !drain.more && replacementFloor.isEmpty {
            for (slot, identity) in currentDisplay {
                guard let complete = operations[identity], !complete.isEmpty
                else { continue }
                /* ONE FRAME, NOT THREE CONCATENATED (plan 018 slice 1).
                   `displayEpoch` advances once per ARM and never per
                   repaint pass, so a capture spanning several front/back
                   cycles arrives as one identity carrying successive
                   repaints end to end. Replayed whole, a LATER pass's
                   window-spanning op lands on top of an EARLIER pass's
                   content: the Sound panel's nine list rows are all
                   present in the three-pass capture and painted over
                   (`testFlattenedPassesPutAWindowBlitOverTheSoundList`),
                   and the Finder's interior does the same thing with an
                   unjoined composite blit.

                   Publishing the last pass alone is what makes a frame a
                   frame. It is also what makes it STABLE: which pass a
                   drain happens to end on stops changing the picture,
                   because only the final one is ever drawn. And it is
                   honest in the direction rule 1 demands — where the last
                   pass's composite did not join, the result is a marked
                   gap rather than an earlier pass's pixels wearing a
                   hatch, which is a plausible answer to a question nobody
                   asked. */
                let published = Self.lastRepaintPass(
                    complete, window: windowSize[identity.window])
                if let prior = settledDisplay[slot], prior != identity {
                    settledOperations[prior] = nil
                    contributingSources[prior] = nil
                    hollowed.remove(prior)
                }
                settledDisplay[slot] = identity
                settledOperations[identity] = published
                settledAtSequence[slot] = scene.seq
                deadWorldSlots.remove(slot)
            }
        }
        let attached = attachCached(to: scene)
        var facts: [String] = []
        if matched > 0 {
            facts.append("\(matched) new draw op\(matched == 1 ? "" : "s")")
        } else if operations.isEmpty {
            facts.append("waiting for the guest to draw")
        } else {
            facts.append("retained \(operations.values.reduce(0) { $0 + $1.count }) draw ops")
        }
        if born > 0 {
            facts.append("\(born) offscreen world\(born == 1 ? "" : "s") "
                         + "hooked at creation")
        }
        if died > 0 {
            facts.append("released \(died) world\(died == 1 ? "" : "s") "
                         + "the guest disposed")
        }
        if held > 0 {
            facts.append("holding \(held) offscreen op\(held == 1 ? "" : "s") "
                         + "for a blit to place")
        }
        if joined > 0 {
            facts.append("joined \(joined) composite"
                         + "\(joined == 1 ? "" : "s") from offscreen worlds")
        }
        if carried > 0 {
            facts.append("carried \(carried) settled op"
                         + "\(carried == 1 ? "" : "s") across the re-arm")
        }
        if compactedPasses > 0 {
            facts.append("compacted \(compactedPasses) accumulator"
                         + "\(compactedPasses == 1 ? "" : "s") at the cap to "
                         + "the last full repaint pass")
        }
        /* A STANDING FACT, not a per-drain one. The drop happens on the
           record that crosses the cap and its consequence — a window
           published without drawing it still has — lasts until the
           application repaints. Reporting it only on the drain that did
           it is how a subtraction goes quiet. */
        let hollowNow = settledDisplay.values.filter(hollowed.contains).count
        if hollowNow > 0 {
            facts.append("dropped older ops past the cap in \(hollowNow) "
                         + "window\(hollowNow == 1 ? "" : "s") with no repaint "
                         + "pass to compact to; marked incomplete")
        }
        if evictedSourceCount > 0 {
            facts.append("evicted \(evictedSourceCount) held source"
                         + "\(evictedSourceCount == 1 ? "" : "s") at the cap")
        }
        if unjoined > 0 {
            facts.append("\(unjoined) op\(unjoined == 1 ? "" : "s") named "
                         + "no window in this scene")
        }
        if stale > 0 {
            facts.append("rejected \(stale) stale/superseded draw "
                         + "op\(stale == 1 ? "" : "s")")
        }
        if incomplete > 0 {
            facts.append("ignored \(incomplete) op"
                         + "\(incomplete == 1 ? "" : "s") from the "
                         + "overwritten display generation")
        }
        if drain.more {
            facts.append("more remain in the guest ring")
            facts.append("retained the last settled display")
        }
        if drain.lostBytes > 0 {
            facts.append("\(drain.lostBytes) earlier bytes were overwritten")
        }
        if drain.dropped > 0 {
            facts.append("guest dropped \(drain.dropped) ops")
        }
        if drain.detailless > 0 {
            facts.append("\(drain.detailless) arrived without geometry")
        }
        if !drain.undrawn.isEmpty {
            let names = drain.undrawn.sorted { $0.key < $1.key }
                .map { "\($0.value)×\($0.key)" }.joined(separator: ", ")
            facts.append("renderer defers \(names)")
        }
        return .init(scene: attached,
                     sentence: "content: " + facts.joined(separator: "; "))
    }

    /// **The last repaint pass in a flattened capture, with the drawing
    /// state that pass inherited put back in front of it.**
    ///
    /// A pass OPENER is an operation that covers the window: a composite
    /// blit or a full-area erase/paint. Everything an application drew
    /// before its own most recent one is, by construction, underneath it on
    /// the machine — so replaying it changes nothing when the composite
    /// joined, and lies when it did not.
    ///
    /// The 80 % bound is measured, not picked. A Finder window at 404×238
    /// opens its passes with `bits [0,0,404,218]` (91 % of the height) and
    /// `bits [0,0,404,203]` (85 %), while the biggest thing inside a pass —
    /// its info-bar blit, `[0,0,404,21]` — is 9 %. Nothing in the committed
    /// capture corpus sits between 9 % and 85 %, so the bound has an order
    /// of magnitude of margin on both sides and does not need to be exact.
    ///
    /// STATE IS RESTORED RATHER THAN INHERITED. Origin, clip and the two
    /// colours flow across ops, and the opener does not re-establish them —
    /// the Finder sets its origin once in the first pass and never again.
    /// Cutting without replaying that prologue would shift every op in the
    /// published pass. So the state up to the cut is folded and re-emitted
    /// as synthetic state ops, which the replay already understands.
    static func lastRepaintPass(_ ops: [DisplayOp],
                                window: (w: Int, h: Int)?) -> [DisplayOp] {
        guard let window, window.w > 0, window.h > 0 else { return ops }
        func spans(_ box: [Int]?) -> Bool {
            guard let box, box.count == 4 else { return false }
            let w = box[2] - box[0], h = box[3] - box[1]
            return Double(w) >= 0.8 * Double(window.w)
                && Double(h) >= 0.8 * Double(window.h)
        }
        /* AN OPENER MUST REPLACE PIXELS, and that qualification is the
           whole difference between this rule working and this rule
           destroying a window. The Date & Time panel closes every one of
           its eleven passes by FRAMING its own window rect (GrafVerb 0,
           `[-1,-1,365,342]` — the border, one pixel outside the content).
           A frame is a hairline, not a repaint: cutting there published a
           pass consisting of one rectangle outline and threw away the
           panel's date, its time and every label. The suite said so
           within a minute of the rule being written, which is the only
           reason it is written correctly here.

           So: a composite blit replaces what it covers; a paint, fill or
           erase (verbs 1, 4, 2) replaces what it covers; a frame does
           not. Where an application's passes are separated by nothing
           destructive — Date & Time's are — this refuses to cut at all,
           because a boundary we cannot prove is not a boundary. */
        let cut = ops.lastIndex { op in
            switch op.op {
            case "bits": return spans(op.dst)
            case "rect": return (op.verb == 1 || op.verb == 2 || op.verb == 4)
                && spans(op.rect)
            default: return false
            }
        }
        guard let cut, cut > 0 else { return ops }

        var state = PortState()
        var sawOrigin = false, sawClip = false
        for op in ops[..<cut] {
            state.absorb(op)
            if op.op == "state" {
                if op.kind == "origin" { sawOrigin = true }
                if op.kind == "clip" { sawClip = true }
            }
        }
        func stateOp(_ kind: String, _ build: (inout DisplayOp) -> Void)
            -> DisplayOp {
            var op = DisplayOp(op: "state", ticks: ops[cut].ticks)
            op.kind = kind
            build(&op)
            return op
        }
        var prologue: [DisplayOp] = []
        if sawOrigin { prologue.append(stateOp("origin") { $0.origin = state.origin }) }
        if sawClip, let clip = state.clip {
            prologue.append(stateOp("clip") { $0.rect = clip })
        }
        if let fg = state.fg { prologue.append(stateOp("fg") { $0.rgb = fg }) }
        if let bg = state.bg { prologue.append(stateOp("bg") { $0.rgb = bg }) }
        return prologue + Array(ops[cut...])
    }

    /* ── WHAT A CAPPED ACCUMULATOR MAY FORGET ───────────────────────────
       `lastRepaintPass` cuts at a pass boundary, and an application that
       never repaints its whole window has none — Date & Time opens one
       pass and then updates its clock field forever inside it. So the
       cap has a second, weaker question to ask: which of these ops is
       not on the guest's screen ANY MORE?

       An op a LATER opaque op fully repaints is gone from the machine
       too, so dropping it costs the picture nothing. The clock's own
       previous 600 seconds are exactly that: each tick erases the same
       field rect and draws into it, so tick N is covered by tick N+1's
       erase, while the group boxes and labels outside that rect are
       covered by nothing and stay.

       Every judgement here is deliberately CONSERVATIVE in one
       direction: bounds are over-estimated and coverage is
       under-claimed, so the rule keeps an op it could have dropped
       rather than dropping one still on screen. Failing to drop enough
       falls through to the honest marker; dropping too much would put a
       hole in a window and say nothing. */

    /// Drop ops a later opaque op provably repaints. Order-preserving,
    /// and never drops what it cannot measure.
    static func coalesce(_ ops: [DisplayOp]) -> [DisplayOp] {
        var origin = [0, 0]
        var clip: [Int]?
        var bounds: [[Int]?] = []
        var covers: [[Int]?] = []
        bounds.reserveCapacity(ops.count)
        covers.reserveCapacity(ops.count)
        for op in ops {
            guard op.op != "state" else {
                bounds.append(nil)
                covers.append(nil)
                if op.kind == "origin", let o = op.origin, o.count == 2 {
                    origin = o
                }
                if op.kind == "clip", let r = op.rect, r.count == 4 {
                    clip = r
                }
                continue
            }
            let box = Self.absolute(Self.inkBox(op), origin: origin)
            bounds.append(box)
            /* A COVERER IS CLIPPED TOO. The clip is what the guest
               actually allowed onto the screen, so an erase reaching
               past it repaints only the intersection — claiming the
               whole rect would drop ops the clip protected. */
            covers.append(Self.replacesPixels(op)
                ? Self.intersect(box, Self.absolute(clip, origin: origin))
                : nil)
        }

        var keep = [Bool](repeating: true, count: ops.count)
        var stack: [[Int]] = []
        for index in stride(from: ops.count - 1, through: 0, by: -1) {
            guard ops[index].op != "state" else { continue }
            if let box = bounds[index],
               stack.contains(where: { Self.contains($0, box) }) {
                keep[index] = false
            }
            guard let cover = covers[index], !stack.contains(cover) else {
                continue
            }
            /* A repeating update writes the SAME rect every time, so
               de-duplication alone keeps this tiny. The bound is a floor
               under a pathological stream, and it evicts the smallest
               cover rather than the newest — a big cover is worth more. */
            stack.append(cover)
            if stack.count > 64,
               let smallest = stack.indices.min(by: {
                   Self.area(stack[$0]) < Self.area(stack[$1])
               }) {
                stack.remove(at: smallest)
            }
        }

        /* A run of state ops with nothing surviving between them is one
           state op: only the last of each kind is ever read. Without
           this, an application that re-states its colours every tick
           would keep the accumulator growing after all its drawing had
           been coalesced away. */
        var out: [DisplayOp] = []
        out.reserveCapacity(ops.count)
        for (index, op) in ops.enumerated() where keep[index] {
            if op.op == "state", let kind = op.kind,
               let last = out.last, last.op == "state", last.kind == kind {
                out[out.count - 1] = op
                continue
            }
            out.append(op)
        }
        return out
    }

    /// A generous box around what an op could possibly ink, in the port's
    /// own coordinates. Nil when this host cannot bound it — a polygon or
    /// a region carries no geometry here, so neither is ever dropped.
    static func inkBox(_ op: DisplayOp) -> [Int]? {
        func box(_ r: [Int]?) -> [Int]? { r?.count == 4 ? r : nil }
        switch op.op {
        case "bits": return box(op.dst)
        case "rect", "rrect", "oval", "arc": return box(op.rect)
        case "line":
            guard let a = op.from, a.count == 2,
                  let b = op.to, b.count == 2 else { return nil }
            // The pen is at least one pixel wide and can be wider; this
            // host is not told, so allow a generous margin.
            return [min(a[0], b[0]) - 2, min(a[1], b[1]) - 2,
                    max(a[0], b[0]) + 2, max(a[1], b[1]) + 2]
        case "text":
            guard let pen = op.pen, pen.count == 2 else { return nil }
            /* No metrics reach this host, so the box is bounded by the
               point size: no glyph in a classic bitmap face is wider
               than its size, and none ascends more than twice it. An
               over-wide box only ever means "kept". */
            let size = max(op.size ?? 12, 1)
            let count = max(op.fullLen ?? op.len ?? op.text?.count ?? 0, 0)
            return [pen[0] - size, pen[1] - 2 * size,
                    pen[0] + (count + 1) * size, pen[1] + size]
        default: return nil
        }
    }

    /// Paint, erase and fill replace what they cover; frame and invert do
    /// not, and neither does any shape that does not fill its own
    /// bounding rectangle. A `bits` replaces its destination.
    static func replacesPixels(_ op: DisplayOp) -> Bool {
        switch op.op {
        case "bits": return op.dst?.count == 4
        case "rect": return op.verb == 1 || op.verb == 2 || op.verb == 4
        default: return false
        }
    }

    private static func absolute(_ box: [Int]?, origin: [Int]) -> [Int]? {
        guard let box, box.count == 4, origin.count == 2 else { return nil }
        return [box[0] - origin[0], box[1] - origin[1],
                box[2] - origin[0], box[3] - origin[1]]
    }

    private static func intersect(_ lhs: [Int]?, _ rhs: [Int]?) -> [Int]? {
        guard let lhs else { return nil }
        guard let rhs else { return lhs }
        let box = [max(lhs[0], rhs[0]), max(lhs[1], rhs[1]),
                   min(lhs[2], rhs[2]), min(lhs[3], rhs[3])]
        return box[0] < box[2] && box[1] < box[3] ? box : nil
    }

    private static func contains(_ outer: [Int], _ inner: [Int]) -> Bool {
        outer[0] <= inner[0] && outer[1] <= inner[1]
            && outer[2] >= inner[2] && outer[3] >= inner[3]
    }

    private static func area(_ box: [Int]) -> Int {
        max(box[2] - box[0], 0) * max(box[3] - box[1], 0)
    }

    /// Seed a freshly-opened accumulator with the pixels the guest still
    /// has, when this identity opened because of a RENEWAL rather than
    /// because the window changed. Consumes the flag: exactly one
    /// identity inherits per arm.
    private func inherit(_ identity: ContentIdentity, at slot: String,
                         carried: inout Int) {
        guard carryForward else { return }
        carryForward = false
        guard let prior = settledDisplay[slot], prior != identity,
              let ops = settledOperations[prior], !ops.isEmpty else { return }
        operations[identity] = ops
        carried += ops.count
    }

    /// Append to a held source's ops, opening its bucket if needed and
    /// evicting the oldest source at the cap. Shared by the plain hold
    /// and the nested join, so both obey the same bounds.
    private func appendSource(_ key: SourceKey, _ ops: [DisplayOp]) {
        if sourceOperations[key] == nil {
            if sourceOrder.count >= Self.sourceCap,
               let oldest = sourceOrder.first {
                sourceOrder.removeFirst()
                sourceOperations[oldest] = nil
                evictedSourceCount += 1
            }
            sourceOrder.append(key)
            sourceOperations[key] = []
        }
        /* The one place a port's generation is LEARNED. Every hold goes
           through here, so a later blit can always ask what generation this
           port's ops were written under instead of assuming its own. */
        sourceGeneration[key.port] = key.generation
        sourceOperations[key]!.append(contentsOf: ops)
        if sourceOperations[key]!.count > Self.operationCapPerWindow {
            sourceOperations[key]!.removeFirst(
                sourceOperations[key]!.count - Self.operationCapPerWindow)
        }
    }

    /// Re-home one source's held ops into the window a blit revealed them
    /// in. All of it is coordinate bookkeeping over the replay's own state
    /// vocabulary, so the renderer needs no new case:
    ///
    /// - The replay maps a coordinate h to `h - origin`, so a prologue
    ///   origin of `-(dst - src)` shifts every held op by exactly the
    ///   blit's translation without touching the ops themselves; origin
    ///   ops INSIDE the held run are translated the same way so they
    ///   compose instead of resetting the shift.
    /// - The clip is the blit's `src` rect: under that origin it maps to
    ///   exactly `dst`, which is the "clipped to dst" the plan requires.
    /// - The epilogue restores the window stream's own origin, clip and —
    ///   only if the held run touched them — colours, because state flows
    ///   across ops and a splice that bent the ops after it would corrupt
    ///   the window everywhere but inside the joined rectangle.
    ///
    /// Nil when the bits op carries no usable geometry — the caller keeps
    /// the bits op and the renderer hatches it, which is the honest
    /// degradation.
    static func rehome(_ heldOps: [DisplayOp], bits: DisplayOp,
                       restoring state: PortState,
                       into destination: PortState? = nil,
                       bornAt birth: [Int] = [0, 0]) -> [DisplayOp]? {
        guard let src = bits.src, src.count == 4,
              let dst = bits.dst, dst.count == 4 else { return nil }
        /* THE DESTINATION'S ORIGIN IS PART OF THE TRANSLATION, and
           leaving it out is what put Sherlock's list at the top of its
           window instead of inside the list area. The replay draws a
           coordinate x at (x - origin), so for a held op at source
           coordinate s to land where the blit put it, the prologue
           origin must be src - dst + the destination's own origin.
           Sherlock blits every composed element to a constant dst under
           a shifted origin (the same idiom its channel grid uses), so
           without this term every one of them collapses onto the same
           corner. */
        let into = destination?.origin ?? [0, 0]
        let dx = dst[0] - src[0] - (into.count == 2 ? into[0] : 0)
        let dy = dst[1] - src[1] - (into.count == 2 ? into[1] : 0)

        /* A WORLD IS NOT ALWAYS BORN AT (0,0), and assuming it was put
           the Appearance panel's two theme thumbnails — and the white
           erase that opens each of them — on top of its `Themes` and
           `Appearance` tabs (2026-08-07).

           `NewGWorld` takes a rect, and an application composing a piece
           of its own window commonly passes that piece's rect in WINDOW
           coordinates: Appearance's thumbnail worlds are born
           `[36,57,213,182]`, so their portRect starts there, their origin
           reads `[36,57]`, every op they draw is stated in that frame,
           and so is the `src` of the blit that reveals them. `dst - src`
           already carries the whole translation; re-applying the origin
           on top of it moved each world a second time by its full value
           and dropped it at the content's top-left corner.

           So the run is stated relative to the world's BIRTH frame, not
           to (0,0). It is deliberately the birth rect and not the last
           origin the world set: Sherlock 2 shifts its composite's origin
           per element (`[-234,-316]` for the last one) and never restores
           it, while the `src` of its window blit stays in the birth frame
           — reading the frame off the live origin instead moves its whole
           interior by that leftover, which is what `DrawnCellGridTests`
           says when you try it.

           `[0,0]` for a world born at the origin, which is every case
           this join was built against, so nothing else moves. */
        let oBirth = birth.count == 2 ? birth : [0, 0]

        func stateOp(_ kind: String, _ build: (inout DisplayOp) -> Void)
            -> DisplayOp {
            var op = DisplayOp(op: "state", ticks: bits.ticks)
            op.kind = kind
            build(&op)
            return op
        }

        /* The run opens in the source's UNSHIFTED frame — a world draws
           before it sets an origin, and those ops are 0-based — so the
           prologue states that frame relative to `oBlit`, and the clip is
           `src` carried into it. */
        var out: [DisplayOp] = [
            stateOp("origin") { $0.origin = [-oBirth[0] - dx, -oBirth[1] - dy] },
            stateOp("clip") {
                $0.rect = [src[0] - oBirth[0], src[1] - oBirth[1],
                           src[2] - oBirth[0], src[3] - oBirth[1]]
            },
        ]
        var touchedFg = false
        var touchedBg = false
        for var op in heldOps {
            if op.op == "state" {
                switch op.kind {
                case "origin":
                    if let o = op.origin, o.count == 2 {
                        op.origin = [o[0] - oBirth[0] - dx,
                                     o[1] - oBirth[1] - dy]
                    }
                case "fg": touchedFg = true
                case "bg": touchedBg = true
                default: break
                }
            }
            out.append(op)
        }
        out.append(stateOp("origin") { $0.origin = state.origin })
        out.append(stateOp("clip") {
            $0.rect = state.clip ?? [-32_768, -32_768, 32_767, 32_767]
        })
        if touchedFg {
            out.append(stateOp("fg") { $0.rgb = state.fg ?? [0, 0, 0] })
        }
        if touchedBg {
            out.append(stateOp("bg") {
                $0.rgb = state.bg ?? [65_535, 65_535, 65_535]
            })
        }
        return out
    }

    private func attachCached(to scene: MirrorKit.Scene) -> MirrorKit.Scene {
        var attached = scene
        for index in attached.windows.indices {
            guard let address = attached.windows[index].addr else {
                /* No exact guest address is the one case where NEITHER
                   answer is available: P3 cannot be armed on this window
                   at all, so it was not asked and could not have been.
                   `nil` says that, rather than picking one of two answers
                   that are both wrong. */
                continue
            }
            /* WHETHER WE LOOKED, stamped on EVERY window with an address —
               above the display attach, and deliberately not inside its
               guard. The windows that matter most here are exactly the
               ones that fall through it: P3 is a one-window spotlight, so
               in any real scene most windows have no interior, and the
               renderer had no way to tell "we never armed here" from "we
               armed here and the guest drew nothing". */
            attached.windows[index].contentPlane =
                attempted.contains("\(attached.windows[index].psn):\(address)")
                    ? .armed : .notAttempted
            guard let identity = settledDisplay[
                    "\(attached.windows[index].psn):\(address)"],
                  let ops = settledOperations[identity], !ops.isEmpty else {
                continue
            }
            attached.windows[index].display = ops
            /* THE STAMP THAT MAKES A FRAME A PAIR. Only a window with a
               live stream gets one — a window with no content plane keeps
               `displayEpoch == nil` and renders semantics-only,
               immediately, which is the degradation rule and not an
               oversight. */
            let slot = "\(attached.windows[index].psn):\(address)"
            let newer = latestEpoch[slot].map {
                MirrorKit.DisplayEpoch.isNewer(
                    generation: $0.generation, epoch: $0.epoch,
                    thanGeneration: identity.generation,
                    epoch: identity.displayEpoch)
            } ?? false
            attached.windows[index].displayEpoch = MirrorKit.DisplayEpoch(
                generation: identity.generation,
                epoch: identity.displayEpoch,
                sceneSequence: settledAtSequence[slot] ?? attached.seq,
                stale: newer || deadWorldSlots.contains(slot)
                    || hollowed.contains(identity))
            /* P2 FROM P3's OWN EVIDENCE, and it is attached HERE rather
               than in the replay on purpose. A repeated-cell grid — hit
               rects, cell identity, which one is selected — is semantic
               knowledge, so it belongs where typed controls live, and
               docs/render-composition.md exists because the replay had
               already started acquiring rules of this shape by accident.
               Doing it beside the display attach also keeps one
               invariant free: the cells always describe exactly the ops
               published with them. */
            DrawnCellGrid.attach(to: &attached.windows[index])
        }
        return attached
    }

    static func serial(_ psn: String) -> (hi: Int, lo: Int)? {
        let parts = psn.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let hi = Int(parts[0]), let lo = Int(parts[1]) else { return nil }
        return (hi, lo)
    }

    static func needsTarget(currentPSN: String?, currentWindow: UInt32?,
                            front: MirrorKit.Scene.Window) -> Bool {
        currentPSN != front.psn || currentWindow != front.addr
    }

    private static func slot(psn: String?, window: UInt32?) -> String? {
        guard let psn, let window else { return nil }
        return "\(psn):\(window)"
    }

    private static func isNewer(_ lhs: ContentIdentity,
                                than rhs: ContentIdentity) -> Bool {
        lhs.generation > rhs.generation
            || (lhs.generation == rhs.generation
                && lhs.displayEpoch > rhs.displayEpoch)
    }

    private static func int(_ value: JSONValue?) -> Int? {
        guard case .number(let n)? = value, n == n.rounded() else { return nil }
        return Int(n)
    }

    private static func failure(_ result: CommandResult) -> String {
        result.error.map { "\($0.message) [\($0.code)]" }
            ?? "the Mac returned no readable reason"
    }

    static func plain(_ object: [String: JSONValue]) -> [String: Any] {
        object.mapValues(plain(_:))
    }

    private static func plain(_ value: JSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let value): return NSNumber(value: value)
        case .number(let value): return NSNumber(value: value)
        case .string(let value): return value
        case .array(let values): return values.map(plain(_:))
        case .object(let values): return plain(values)
        }
    }
}
