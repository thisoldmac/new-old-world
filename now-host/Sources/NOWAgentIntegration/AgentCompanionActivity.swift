import Darwin
import Foundation

/// **What the host knows about companions that have reached its local
/// endpoint** — the fact the MCP module will draw, and the one thing
/// `AgentIntegrationLocalServer` could not answer at all.
///
/// ## Why this is not `isConnected`
///
/// The local surface is **one request per connection**, and the companion is
/// short-lived and client-launched: a process appears, asks one thing, and is
/// gone. A boolean tracking the socket would therefore be true for the
/// milliseconds a request is in flight and false every time a person looked
/// at it — technically accurate and useless, and worse than useless because
/// "no agent connected" reads as *nothing is driving this Mac* when an agent
/// may have trashed a file a second earlier.
///
/// So this models the **companion**, not the socket. The questions it answers
/// are the ones a person actually has:
///
/// - *Has anything ever attached?* — `.neverAttached`, which is the resting
///   state on most Macs and is deliberately its own case rather than a zeroed
///   struct (see below).
/// - *Is one doing something right now?* — `inFlight`.
/// - *Was one active recently?* — `lastSeen` against `activeWindow`.
/// - *How many distinct companions?* — `companions`, counted by the peer
///   process the KERNEL reports, not by connection and not by any name a peer
///   gave itself.
///
/// ## What it deliberately does not carry
///
/// No operation names, no arguments, no paths, no payloads, no responses —
/// nothing about *what* was asked. That is not an oversight to be filled in
/// later: `HostProjectionAuditEvent` already refuses arguments on purpose,
/// and the audit stream is where "what did it last do" is answered, in the
/// module's own pane. Peer tracking recording the same fact a second time
/// would be a second source of truth about one thing, and recording MORE than
/// the audit event does would make the presence ledger the back door that
/// reintroduces exactly what the audit event was careful to leave out. Counts
/// and clock times only.
public struct AgentCompanionActivity: Equatable, Sendable {
    /// How long after its last request a companion still reads as *active*.
    ///
    /// Two minutes: long enough that a conversational burst of tool calls —
    /// each its own connection, seconds apart — reads as one continuous
    /// presence rather than flickering, and short enough that a person
    /// glancing at the pane is not told "active" about something that
    /// happened over lunch.
    public static let activeWindow: TimeInterval = 120

    /// How many distinct companions are remembered individually.
    ///
    /// Bounded because an unbounded list of every process that ever spoke is
    /// both a leak and a surveillance ledger nobody asked for. The aggregate
    /// counters below do not forget, so the *totals* stay honest while the
    /// per-companion detail ages out.
    public static let rememberedCompanions = 8

    /// One companion process, as the kernel identified it.
    ///
    /// `processID` comes from `LOCAL_PEERPID` on the accepted socket, which
    /// is the kernel's answer, not the peer's claim. **Known limit:** pids
    /// are recycled, so two short-lived companions that happen to reuse one
    /// pid read here as a single companion with more requests. That
    /// undercounts rather than inventing a companion, which is the direction
    /// to be wrong in, and it is why nothing here is called a "session".
    public struct Companion: Equatable, Sendable {
        public let processID: pid_t
        public let firstSeen: Date
        public let lastSeen: Date
        /// Requests this process has made. One connection is one request by
        /// contract, malformed ones included — a peer that spoke badly still
        /// spoke.
        public let requests: Int

        public init(processID: pid_t,
                    firstSeen: Date,
                    lastSeen: Date,
                    requests: Int) {
            self.processID = processID
            self.firstSeen = firstSeen
            self.lastSeen = lastSeen
            self.requests = requests
        }
    }

    /// Distinct companion processes, most recently active first, bounded by
    /// `rememberedCompanions`.
    public let companions: [Companion]
    /// Every authorized request this host has served on the local endpoint,
    /// across all companions, since launch. Does not age out with the list.
    public let totalRequests: Int
    /// Requests being served at this instant. The only genuinely
    /// *live* number here, and the reason the module can show a companion
    /// working rather than only that one was.
    public let inFlight: Int
    /// Peers the uid gate turned away, and when it last did.
    ///
    /// Kept because it is the one thing about the boundary a person might
    /// want to see and cannot infer from anything else: something on this Mac
    /// running as another user reached for the endpoint. No identity is
    /// recorded for them — a refused peer is refused, and looking it up would
    /// mean the gate learning about processes it exists to ignore.
    public let refusedPeers: Int
    public let lastRefusal: Date?
    /// When the first companion ever spoke, and when the last one did. Nil
    /// together, and only when nothing ever has.
    public let firstSeen: Date?
    public let lastSeen: Date?

    public init(companions: [Companion] = [],
                totalRequests: Int = 0,
                inFlight: Int = 0,
                refusedPeers: Int = 0,
                lastRefusal: Date? = nil,
                firstSeen: Date? = nil,
                lastSeen: Date? = nil) {
        self.companions = companions
        self.totalRequests = totalRequests
        self.inFlight = inFlight
        self.refusedPeers = refusedPeers
        self.lastRefusal = lastRefusal
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }

    /// A host no companion has ever reached.
    public static let none = AgentCompanionActivity()

    /// Whether any companion has ever been served.
    ///
    /// Derived from `totalRequests` rather than from `companions`, because
    /// the list is bounded and the count is not — a host that served one
    /// companion an hour ago and forgot the detail has still been reached.
    public var hasEverAttached: Bool { totalRequests > 0 }

    /// What to tell a person, right now.
    ///
    /// The clock is a parameter so the reading is testable without waiting,
    /// which is the whole reason a time-derived state is worth having.
    public func presence(asOf now: Date = Date(),
                         window: TimeInterval = activeWindow)
        -> AgentCompanionPresence {
        if inFlight > 0 { return .working }
        guard let lastSeen else { return .neverAttached }
        return now.timeIntervalSince(lastSeen) <= window
            ? .active(since: lastSeen)
            : .idle(since: lastSeen)
    }
}

/// The reading a person gets, in the vocabulary the question deserves.
///
/// **`neverAttached` is its own case, and that is the point.** A struct of
/// zeroes would let a pane render "0 companions, last seen never" — the shape
/// of a thing that is switched off and broken. Nothing has ever attached is a
/// different sentence from nothing is attached *now*, and on most Macs it is
/// the true one and the permanent one. The module owes that state its own
/// words (the plan's open question), and it cannot write them if the type
/// makes it indistinguishable from an idle companion with no clock.
public enum AgentCompanionPresence: Equatable, Sendable {
    /// No companion has reached this host since it launched.
    case neverAttached
    /// A request is being served at this instant.
    case working
    /// Nothing in flight, but a companion spoke within the active window.
    case active(since: Date)
    /// A companion has spoken, but not lately.
    case idle(since: Date)
}

/// The mutable side of the above: what the local server writes into.
///
/// A lock rather than an actor because it is written from the accept thread
/// and the client queue, both of which are synchronous plain-thread contexts
/// in this server, and every operation is a handful of field updates. An
/// actor would put an `await` in the accept loop for no gain.
final class AgentCompanionLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var companions: [pid_t: AgentCompanionActivity.Companion] = [:]
    private var totalRequests = 0
    private var inFlight = 0
    private var refusedPeers = 0
    private var lastRefusal: Date?
    private var firstSeen: Date?
    private var lastSeen: Date?

    /// An authorized peer has been accepted and is about to be served.
    ///
    /// `processID` nil means the kernel would not name the peer — a peer that
    /// closed between accept and the lookup. It still counts toward the
    /// totals, because it was served; it simply joins no companion row, which
    /// is more honest than inventing a pid for it.
    func began(processID: pid_t?, at moment: Date)
        -> AgentCompanionActivity {
        mutate {
            totalRequests += 1
            inFlight += 1
            if firstSeen == nil { firstSeen = moment }
            lastSeen = moment
            guard let processID else { return }
            if let existing = companions[processID] {
                companions[processID] = .init(
                    processID: processID,
                    firstSeen: existing.firstSeen,
                    lastSeen: moment,
                    requests: existing.requests + 1)
            } else {
                companions[processID] = .init(
                    processID: processID,
                    firstSeen: moment,
                    lastSeen: moment,
                    requests: 1)
                forgetOldestIfNeeded()
            }
        }
    }

    /// The request has been answered and the connection closed.
    func ended(at moment: Date) -> AgentCompanionActivity {
        mutate {
            inFlight = max(0, inFlight - 1)
            lastSeen = moment
        }
    }

    /// The uid gate turned a peer away.
    func refused(at moment: Date) -> AgentCompanionActivity {
        mutate {
            refusedPeers += 1
            lastRefusal = moment
        }
    }

    var snapshot: AgentCompanionActivity {
        lock.lock()
        defer { lock.unlock() }
        return current()
    }

    /// Drops the companion whose last request is oldest.
    ///
    /// By last activity rather than by first, so a long-lived companion that
    /// is still working is never evicted by a burst of one-shot ones.
    private func forgetOldestIfNeeded() {
        guard companions.count
            > AgentCompanionActivity.rememberedCompanions else { return }
        if let stalest = companions.min(by: {
            $0.value.lastSeen < $1.value.lastSeen
        })?.key {
            companions.removeValue(forKey: stalest)
        }
    }

    private func mutate(
        _ body: () -> Void
    ) -> AgentCompanionActivity {
        lock.lock()
        defer { lock.unlock() }
        body()
        return current()
    }

    /// Called with the lock held.
    private func current() -> AgentCompanionActivity {
        .init(companions: companions.values.sorted {
                  $0.lastSeen > $1.lastSeen
              },
              totalRequests: totalRequests,
              inFlight: inFlight,
              refusedPeers: refusedPeers,
              lastRefusal: lastRefusal,
              firstSeen: firstSeen,
              lastSeen: lastSeen)
    }
}
