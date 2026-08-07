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
    /// The structural scene sequence each slot's display last settled
    /// against — reported, never gated on. See ``DisplayEpoch``.
    private var settledAtSequence: [String: Int] = [:]

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

    init(listener: GuestListener) {
        self.listener = listener
    }

    func guestChanged() {
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
        settledAtSequence.removeAll()
        armedAt = nil
    }

    /// Withdraw this named owner's request before clearing its cached display.
    /// qdtrace stop releases only kNowPeekOwnerContent; P1/P2/P4 are untouched.
    func disable(completion: @escaping (String?) -> Void) {
        guard armedAt != nil || targetPSN != nil else {
            guestChanged()
            completion(nil)
            return
        }
        listener.runCommand("qdtrace", args: ["op": "stop"]) { [weak self] result in
            guard result.ok else {
                completion(Self.failure(result))
                return
            }
            self?.guestChanged()
            completion(nil)
        }
    }

    /// One bounded content ask after a scene transfer. There is no independent
    /// timer or poller; the structural scene remains the cadence owner.
    func join(into scene: MirrorKit.Scene,
              completion: @escaping (Update) -> Void) {
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
            prepare(front: front, scene: scene, completion: completion)
        } else {
            drain(scene: scene, completion: completion)
        }
    }

    /// Baseline the monotonic ring before arming a new process. Otherwise a
    /// target switch could replay records written by the previous app and
    /// mis-join them merely because an address was later reused.
    private func prepare(front: MirrorKit.Scene.Window,
                         scene: MirrorKit.Scene,
                         completion: @escaping (Update) -> Void) {
        listener.runCommand("qdtrace", args: ["op": "status"]) {
            [weak self] result in
            guard let self else { return }
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
            self.listener.runCommand("qdtrace", typed: [
                "op": .text("start"),
                "serialHi": .number(serial.hi),
                "serialLo": .number(serial.lo),
                "window": .text(String(format: "0x%08x", window)),
                "mode": .text("record"),
                "ttlTicks": .number(36_000),
            ]) { [weak self] start in
                guard let self else { return }
                guard start.ok else {
                    self.armedAt = nil
                    completion(.init(
                        scene: self.attachCached(to: scene),
                        sentence: "content: could not arm \(front.app) — "
                            + Self.failure(start)))
                    return
                }
                self.armedAt = Date()
                completion(.init(
                    scene: self.attachCached(to: scene),
                    sentence: "content: requested \(front.app)'s trace; "
                        + "waiting for its event loop to arm and draw"))
            }
        }
    }

    private func drain(scene: MirrorKit.Scene,
                       completion: @escaping (Update) -> Void) {
        drainPage(scene: scene, pagesLeft: Self.pagesPerCycle,
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
                           completion: @escaping (Update) -> Void) {
        listener.runCommand("qdtrace", args: [
            "op": "drain", "cursor": String(cursor),
        ]) { [weak self] result in
            guard let self else { return }
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
                    let key = SourceKey(port: address,
                                        generation: record.generation)
                    if sourceOperations.removeValue(forKey: key) != nil {
                        sourceOrder.removeAll { $0 == key }
                        died += 1
                    }
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
                if record.op.op == "bits",
                   let inner = pendingBlitSource.removeValue(forKey: address),
                   let heldOps = sourceOperations[
                       SourceKey(port: inner, generation: record.generation)],
                   !heldOps.isEmpty,
                   let rehomed = Self.rehome(
                       heldOps, bits: record.op,
                       restoring: portStates[address] ?? PortState(),
                       into: portStates[address] ?? PortState(),
                       bornAt: sourceBirth[SourceKey(
                           port: inner,
                           generation: record.generation)] ?? [0, 0]) {
                    appendSource(destKey, rehomed)
                    /* Composition nests, so lineage must too: this world's
                       pixels now depend on the inner world's life as well
                       as its own. */
                    let innerKey = SourceKey(port: inner,
                                             generation: record.generation)
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
                }
            } else {
                currentDisplay[slot] = identity
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
                let key = SourceKey(port: source,
                                    generation: record.generation)
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
            if operations[identity, default: []].count
                    > Self.operationCapPerWindow {
                operations[identity]!.removeFirst(
                    operations[identity]!.count - Self.operationCapPerWindow)
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
            guard let address = attached.windows[index].addr,
                  let identity = settledDisplay[
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
                stale: newer || deadWorldSlots.contains(slot))
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
