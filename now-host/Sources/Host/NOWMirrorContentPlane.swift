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
    struct Update {
        var scene: MirrorKit.Scene
        var sentence: String
    }

    private let listener: GuestListener
    private(set) var targetPSN: String?
    private(set) var cursor = 0
    private(set) var operations: [UInt32: [DisplayOp]] = [:]
    private var armedAt: Date?

    /// Keep enough ordered drawing to include a full repaint without allowing
    /// a busy application to grow the host indefinitely.
    static let operationCapPerWindow = 1_200
    private static let renewAfter: TimeInterval = 9 * 60

    init(listener: GuestListener) {
        self.listener = listener
    }

    func guestChanged() {
        targetPSN = nil
        cursor = 0
        operations.removeAll()
        armedAt = nil
    }

    /// One bounded content ask after a scene transfer. There is no independent
    /// timer or poller; the structural scene remains the cadence owner.
    func join(into scene: MirrorKit.Scene,
              completion: @escaping (Update) -> Void) {
        guard let front = scene.windows.first(where: \.front) else {
            completion(.init(scene: scene,
                             sentence: "content: no front window"))
            return
        }
        let needsTarget = targetPSN != front.psn
        let needsRenewal = armedAt.map {
            Date().timeIntervalSince($0) >= Self.renewAfter
        } ?? true
        if needsTarget {
            targetPSN = front.psn
            cursor = 0
            operations.removeAll()
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
            self.listener.runCommand("qdtrace", typed: [
                "op": .text("start"),
                "serialHi": .number(serial.hi),
                "serialLo": .number(serial.lo),
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
                    sentence: "content: armed \(front.app); waiting for its "
                        + "next guest-authored draw"))
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
        if drain.resync {
            operations.removeAll()
        }

        let visibleAddresses = Set(scene.windows.compactMap(\.addr))
        var matched = 0
        var unjoined = 0
        for record in drain.records {
            guard let address = record.portAddress,
                  visibleAddresses.contains(address) else {
                unjoined += 1
                continue
            }
            operations[address, default: []].append(record.op)
            if operations[address, default: []].count
                    > Self.operationCapPerWindow {
                operations[address]!.removeFirst(
                    operations[address]!.count - Self.operationCapPerWindow)
            }
            matched += 1
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
        if unjoined > 0 {
            facts.append("\(unjoined) op\(unjoined == 1 ? "" : "s") named "
                         + "no window in this scene")
        }
        if drain.more { facts.append("more remain in the guest ring") }
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

    private func attachCached(to scene: MirrorKit.Scene) -> MirrorKit.Scene {
        var attached = scene
        for index in attached.windows.indices {
            guard let address = attached.windows[index].addr,
                  let ops = operations[address], !ops.isEmpty else { continue }
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
