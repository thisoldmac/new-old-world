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
    private var pendingBlitSource: UInt32?
    private var windowPortState = PortState()

    /// Keep enough ordered drawing to include a full repaint without allowing
    /// a busy application to grow the host indefinitely.
    static let operationCapPerWindow = 1_200
    static let sourceCap = 16
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
        pendingBlitSource = nil
        windowPortState = PortState()
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
            pendingBlitSource = nil
            windowPortState = PortState()
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
            completion(self.apply(decoded, to: scene))
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
            pendingBlitSource = nil
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
        var evictedSources = 0
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
                guard record.psn == expectedPSN, visible[address] == nil,
                      record.op.op != "blitsrc" else {
                    unjoined += 1
                    continue
                }
                let key = SourceKey(port: address,
                                    generation: record.generation)
                if sourceOperations[key] == nil {
                    if sourceOrder.count >= Self.sourceCap,
                       let oldest = sourceOrder.first {
                        sourceOrder.removeFirst()
                        sourceOperations[oldest] = nil
                        evictedSources += 1
                    }
                    sourceOrder.append(key)
                    sourceOperations[key] = []
                }
                sourceOperations[key]!.append(record.op)
                if sourceOperations[key]!.count > Self.operationCapPerWindow {
                    sourceOperations[key]!.removeFirst(
                        sourceOperations[key]!.count
                            - Self.operationCapPerWindow)
                }
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
                pendingBlitSource = record.srcPort
                continue
            }
            if record.op.op == "bits", let source = pendingBlitSource {
                pendingBlitSource = nil
                let key = SourceKey(port: source,
                                    generation: record.generation)
                if let heldOps = sourceOperations[key], !heldOps.isEmpty,
                   let rehomed = Self.rehome(heldOps, bits: record.op,
                                             restoring: windowPortState) {
                    toAppend = rehomed
                    joined += 1
                }
            } else {
                pendingBlitSource = nil
            }
            for op in toAppend { windowPortState.absorb(op) }
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
                if let prior = settledDisplay[slot], prior != identity {
                    settledOperations[prior] = nil
                }
                settledDisplay[slot] = identity
                settledOperations[identity] = complete
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
        if held > 0 {
            facts.append("holding \(held) offscreen op\(held == 1 ? "" : "s") "
                         + "for a blit to place")
        }
        if joined > 0 {
            facts.append("joined \(joined) composite"
                         + "\(joined == 1 ? "" : "s") from offscreen worlds")
        }
        if evictedSources > 0 {
            facts.append("evicted \(evictedSources) held source"
                         + "\(evictedSources == 1 ? "" : "s") at the cap")
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
                       restoring state: PortState) -> [DisplayOp]? {
        guard let src = bits.src, src.count == 4,
              let dst = bits.dst, dst.count == 4 else { return nil }
        let dx = dst[0] - src[0]
        let dy = dst[1] - src[1]

        func stateOp(_ kind: String, _ build: (inout DisplayOp) -> Void)
            -> DisplayOp {
            var op = DisplayOp(op: "state", ticks: bits.ticks)
            op.kind = kind
            build(&op)
            return op
        }

        var out: [DisplayOp] = [
            stateOp("origin") { $0.origin = [-dx, -dy] },
            stateOp("clip") { $0.rect = src },
        ]
        var touchedFg = false
        var touchedBg = false
        for var op in heldOps {
            if op.op == "state" {
                switch op.kind {
                case "origin":
                    if let o = op.origin, o.count == 2 {
                        op.origin = [o[0] - dx, o[1] - dy]
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
