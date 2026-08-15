import Foundation

/// **This side's log, projected** — the host sibling of `tail`.
///
/// The guest's row (`GuestLogTailProjection`) reads the classic Mac's own
/// ring. Nothing read THIS Mac's, and the gap was paid for on 2026-08-14: a
/// Continuity Accessibility-permission defect could only be diagnosed by an
/// agent finding `~/Library/Logs/now-logs/*.log` on the filesystem by hand,
/// and only because the disk switch happened to be on. With it off the
/// evidence exists solely in an in-memory ring that the Logs page renders
/// and nothing else can reach.
///
/// **The ring is the answer and the file is a field beside it.** The ring is
/// live from the first line of every launch; the file is a user switch. A log
/// surface that returns nothing because a switch is off is a gate that reads
/// green having reached nothing, so the file's path and state are DECLARED —
/// `persistsToDisk`, `file` — and never substituted for the lines.
public enum AgentIntegrationHostLogPolicy {
    /// The ring's size, stated HERE and read by `HostLog` rather than the
    /// other way round.
    ///
    /// It has to live on this side of the module boundary: `Host` depends on
    /// `NOWAgentIntegration` and not the reverse, so a projection cannot read
    /// a constant declared in the app. Both sides now read one number —
    /// `HostLog.ringCapacity` is this — which is the same rule the
    /// control-frame cap taught (AGENTS.md: state a limit once, where both
    /// sides read it).
    public static let ringCapacity = 2000

    /// How many lines a caller gets without asking.
    ///
    /// Five times the guest verb's 20, and the difference is not generosity:
    /// the guest's default is sized for a 4 KB control frame crossing a
    /// serial-speed link to a 68030, while this answer crosses a Unix socket
    /// on the same Mac. This log is also ONE interleaved stream across every
    /// subsystem — wire, files, continuity, cloud — so 20 lines of it is
    /// frequently 20 lines of whatever was noisiest.
    public static let defaultLineCount = 100

    /// The most a caller may ask for: the whole ring, because asking for more
    /// than the ring holds is asking for lines that do not exist.
    ///
    /// Derived and never a second literal. The budget below may still return
    /// fewer, and says so out loud — which is a different thing from this
    /// bound, and the two must not be collapsed: this one refuses a request
    /// that could never be honest, and that one reports an answer that was
    /// cut.
    public static var maximumLineCount: Int { ringCapacity }

    /// The area tag's width, which is the width `HostLog.write` pads and
    /// TRUNCATES to. A filter longer than this could never match a line, so
    /// it is refused rather than answered with an empty tail — an empty tail
    /// reads exactly like a quiet subsystem, which is the wrong conclusion to
    /// hand somebody diagnosing one.
    public static let areaTagScalars = 6

    /// One line's own cap. Host log lines are prose this side wrote and are
    /// not bounded by any guest buffer, so a single pathological line cannot
    /// be allowed to consume the whole budget below.
    public static let maximumLineScalars = 512

    /// The whole answer's budget, **in BYTES**, derived from the local frame
    /// cap rather than guessed beside it.
    ///
    /// Bytes and not scalars, which is the unit the cap is actually in: a
    /// scalar budget looks equivalent for ASCII and is not, because one
    /// non-ASCII scalar is up to four bytes on the wire — so a log full of
    /// them could pass a scalar budget and still overflow the frame. Half the
    /// cap leaves the envelope, the declared fields and JSON escaping the
    /// other half.
    public static var maximumTotalBytes: Int {
        AgentIntegrationLocalProtocol.maximumMessageBytes / 2
    }

    /// What one line costs beyond its own bytes once it is a JSON array
    /// member: two quotes, a comma, and a byte of slack.
    public static let perLineEnvelopeBytes = 4

    public static func isValidLineCount(_ value: Int) -> Bool {
        value >= 1 && value <= maximumLineCount
    }

    /// An area filter is a non-empty tag no wider than the tag field.
    public static func isValidArea(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.count <= areaTagScalars
    }
}

/// One read of this Mac's log.
///
/// The lines are whole formatted lines in the shape `docs/logging.md`
/// defines — `HH:MM:SS area [!?] message` — carried as text and not parsed
/// into fields. The host wrote them for a person to read, and a projection
/// that split them into a typed record would be answering a question about
/// this Mac out of its own head the moment the wording changed. That is the
/// same rule `AgentIntegrationGuestRowReport` keeps for the guest's words.
public struct AgentIntegrationHostLogTail: Codable, Equatable, Sendable {
    /// Oldest first — the last line is the most recent thing that happened,
    /// which is the same order the Logs page and the guest's `tail` use.
    public let lines: [String]
    /// What the caller asked for, after the default was applied.
    public let requested: Int
    /// How many lines the ring holds that match the filter. Read beside
    /// `shown` to tell "the log only has twelve" from "twelve of the hundred
    /// you asked for fitted".
    public let matching: Int
    /// **How the answer says it was cut.** `"40 of 40"`, or
    /// `"12 of 100 (older ones did not fit)"` when the scalar budget bound
    /// before the count did. Modelled on the guest row's own `shown`, and
    /// present for its reason: nothing may truncate silently in either
    /// direction.
    public let shown: String
    /// The area filter that was applied, or nil for every area.
    public let area: String?
    /// The ring's size, so a caller reading `matching == ringCapacity` knows
    /// the beginning of the launch has already rolled off.
    public let ringCapacity: Int
    /// Whether this launch is ALSO writing to a file. Declared beside the
    /// lines and never instead of them.
    public let persistsToDisk: Bool
    /// Where that file is, when there is one. Nil is the ordinary answer and
    /// is not a failure: the ring above is the log.
    public let file: String?
    public let observedAt: Date

    public init(lines: [String], requested: Int, matching: Int,
                shown: String, area: String?, ringCapacity: Int,
                persistsToDisk: Bool, file: String?, observedAt: Date) {
        self.lines = lines
        self.requested = requested
        self.matching = matching
        self.shown = shown
        self.area = area
        self.ringCapacity = ringCapacity
        self.persistsToDisk = persistsToDisk
        self.file = file
        self.observedAt = observedAt
    }
}

public typealias AgentIntegrationHostLogTailResult =
    AgentIntegrationProjectedResult<AgentIntegrationHostLogTail>
