import Foundation

/// Product priority at the one boundary all request-shaped guest work shares.
/// Protocol replies, transfer cancellation and heartbeats never enter this
/// scheduler; they remain direct transport traffic so product work cannot
/// delay the protocol required to make progress.
enum GuestWorkClass: Int, Comparable, Sendable {
    case humanInteractive = 0
    case humanDependency = 1
    case foreground = 2
    case structuralRepair = 3
    case ambient = 4
    case bulk = 5

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum GuestWorkPurpose: Hashable, Sendable {
    case interaction(String)
    case actionPostcondition(String)
    case scene
    case content
    case finder(String)
    case visibility
    case semantics
    case command(String)
    case console
    case files
    case processes
    case software
    case capture
    case bulk(String)

    var summary: String {
        switch self {
        case .interaction(let label): return label
        case .actionPostcondition(let label): return "confirm " + label
        case .scene: return "scene observation"
        case .content: return "content drain"
        case .finder(let target): return "Finder " + target
        case .visibility: return "visibility census"
        case .semantics: return "semantic read"
        case .command(let verb): return "command " + verb
        case .console: return "console command"
        case .files: return "file request"
        case .processes: return "process request"
        case .software: return "software request"
        case .capture: return "capture"
        case .bulk(let label): return label
        }
    }
}

struct GuestWorkToken: Hashable, Sendable {
    let traceID: String
    let sessionID: String
}

struct GuestWorkSnapshot: Equatable, Sendable {
    var activePurpose: GuestWorkPurpose?
    var activeAge: TimeInterval?
    var queuedHumanCount: Int
    var queueDepth: Int
    var oldestHumanWait: TimeInterval?
}

/// One admission owner for one exact guest session.
///
/// Work already admitted is cooperative and cannot be preempted safely on a
/// classic Macintosh. Priority applies at every release boundary: after the
/// active slice finishes, a waiting human gesture is selected before ambient
/// work regardless of arrival order. Stable sequence numbers preserve order
/// within a class.
@MainActor
final class GuestWorkScheduler {
    typealias Work = @MainActor (GuestWorkToken) async -> Void
    typealias CallbackWork = @MainActor (
        GuestWorkToken, @escaping @MainActor () -> Void
    ) -> Void
    typealias Cancel = @MainActor () -> Void
    typealias ClockSink = @MainActor (MirrorWorkClocks) -> Void

    private struct Entry {
        let token: GuestWorkToken
        let workClass: GuestWorkClass
        let purpose: GuestWorkPurpose
        let coalescingKey: String?
        let sequence: UInt64
        let enqueuedAt: Date
        let start: CallbackWork
        let cancel: Cancel?
    }

    private(set) var sessionID: String
    private var generation: UInt64 = 0
    private var nextSequence: UInt64 = 0
    private var queue: [Entry] = []
    private var active: Entry?
    private let now: () -> Date
    private let clocks: ClockSink?
    private let didChange: (@MainActor () -> Void)?
    private static let debug = ProcessInfo.processInfo.environment[
        "NOW_SCHEDULER_DEBUG"] != nil

    init(sessionID: String,
         now: @escaping () -> Date = Date.init,
         clocks: ClockSink? = nil,
         didChange: (@MainActor () -> Void)? = nil) {
        self.sessionID = sessionID
        self.now = now
        self.clocks = clocks
        self.didChange = didChange
    }

    var depth: Int { queue.count + (active == nil ? 0 : 1) }

    func snapshot(at date: Date? = nil) -> GuestWorkSnapshot {
        let instant = date ?? now()
        let humans = queue.filter { $0.workClass == .humanInteractive }
        return .init(
            activePurpose: active?.purpose,
            activeAge: active.map { instant.timeIntervalSince($0.enqueuedAt) },
            queuedHumanCount: humans.count,
            queueDepth: depth,
            oldestHumanWait: humans.map {
                instant.timeIntervalSince($0.enqueuedAt)
            }.max())
    }

    @discardableResult
    func submit(_ purpose: GuestWorkPurpose,
                as workClass: GuestWorkClass,
                coalescingKey: String? = nil,
                onCancel: Cancel? = nil,
                work: @escaping Work) -> GuestWorkToken {
        submitCallback(purpose, as: workClass,
                       coalescingKey: coalescingKey,
                       onCancel: onCancel) { token, finish in
            Task { @MainActor in
                await work(token)
                finish()
            }
        }
    }

    /// Callback-shaped requests begin synchronously when the lane is empty.
    /// That preserves the transport's existing request-registration contract:
    /// a caller can install its pending completion before returning, while the
    /// supplied `finish` still marks the later reply as the release boundary.
    /// A callback that may enqueue a dependent continuation runs that callback
    /// before `finish`, so the scheduler can choose the continuation against
    /// already-waiting enrichment at the boundary instead of blindly starting
    /// the older background entry first.
    @discardableResult
    func submitCallback(_ purpose: GuestWorkPurpose,
                        as workClass: GuestWorkClass,
                        coalescingKey: String? = nil,
                        onCancel: Cancel? = nil,
                        start: @escaping CallbackWork) -> GuestWorkToken {
        nextSequence &+= 1
        let token = GuestWorkToken(traceID: UUID().uuidString,
                                   sessionID: sessionID)
        let enqueuedAt = now()
        let entry = Entry(token: token, workClass: workClass,
                          purpose: purpose, coalescingKey: coalescingKey,
                          sequence: nextSequence, enqueuedAt: enqueuedAt,
                          start: start, cancel: onCancel)
        if let coalescingKey {
            var replaced: [Entry] = []
            queue.removeAll { candidate in
                let matches = candidate.coalescingKey == coalescingKey
                    && candidate.workClass == workClass
                if matches { replaced.append(candidate) }
                return matches
            }
            replaced.forEach { $0.cancel?() }
        }
        queue.append(entry)
        if Self.debug {
            FileHandle.standardError.write(Data(
                "[guest-work] enqueue \(purpose.summary) class=\(workClass) "
                    .appending("active=\(active?.purpose.summary ?? "none") "
                               + "queued=\(queue.count)\n").utf8))
        }
        clocks?(.init(traceID: token.traceID, sessionID: sessionID,
                      purpose: purpose, enqueuedAt: enqueuedAt))
        didChange?()
        drain()
        return token
    }

    /// Ends queued work at a session boundary. The active closure may be in a
    /// non-cancellable callback; generation identity prevents its late return
    /// from admitting work or changing the replacement session.
    func reset(sessionID: String) {
        generation &+= 1
        let cancelled = queue
        active = nil
        queue.removeAll(keepingCapacity: true)
        self.sessionID = sessionID
        cancelled.forEach { $0.cancel?() }
        didChange?()
    }

    private func drain() {
        guard active == nil, !queue.isEmpty else { return }
        let selected = queue.indices.min { left, right in
            let lhs = queue[left]
            let rhs = queue[right]
            if lhs.workClass != rhs.workClass {
                return lhs.workClass < rhs.workClass
            }
            return lhs.sequence < rhs.sequence
        }!
        let entry = queue.remove(at: selected)
        active = entry
        if Self.debug {
            FileHandle.standardError.write(Data(
                "[guest-work] admit \(entry.purpose.summary) "
                    .appending("queued=\(queue.count)\n").utf8))
        }
        let mine = generation
        var admitted = MirrorWorkClocks(
            traceID: entry.token.traceID, sessionID: entry.token.sessionID,
            purpose: entry.purpose, enqueuedAt: entry.enqueuedAt,
            admittedAt: now())
        clocks?(admitted)
        didChange?()
        entry.start(entry.token) { [weak self] in
            guard let self, mine == self.generation,
                  self.active?.token == entry.token else { return }
            if Self.debug {
                FileHandle.standardError.write(Data(
                    "[guest-work] release \(entry.purpose.summary)\n".utf8))
            }
            admitted.replyAt = self.now()
            admitted.outcome = "released"
            self.clocks?(admitted)
            self.active = nil
            self.didChange?()
            self.drain()
        }
    }
}
