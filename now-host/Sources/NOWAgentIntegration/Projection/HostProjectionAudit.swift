import Foundation

/// **WHICH face invoked a projection, on this call** — a runtime fact about
/// one invocation, recorded in the audit log.
///
/// Rule 3 of the parity slice: *user-initiable where possible;
/// strictly-headless surfaced as a log event*. MCP is an optional feature of
/// NOW, and optional does not mean kneecapped — but a suite of agentic
/// controls opaque to the person at the machine is not what NOW is. So every
/// invocation says who asked, and the person can read it.
///
/// **This is a different axis from `HostCapabilityFace`, not a subset of it.**
/// That enum is the design-time reach model — *can this face reach this
/// capability* — declared per row and checked by `HostFaceParityTests`. This
/// one is *who called, just now*. A face can appear in that model and never
/// appear here, which is exactly what the app UI does.
///
/// **The absence of an `appUI` case is deliberate, and load-bearing rather
/// than an omission.** The app UI never invokes a projection at all: a person
/// clicking a button reaches the app's own model directly, and those paths
/// already log under their own areas (`proc`, `sw`, `files`). Adding an
/// `appUI` case would model a caller that cannot exist by construction — the
/// only way one could is if some pane started dispatching through
/// `HostProjectionDispatch`, and then the case belongs here and that pane gets
/// audited by adding it. So this type covers the **agent faces only**, which
/// is precisely the set rule 3 is about: the callers a person at the machine
/// cannot see happening.
///
/// Neither case here is proof a human is present. The MCP obviously is not,
/// and an AppIntent is not either: a Shortcuts automation fires one
/// unattended, which is why the parity plan keeps granted control behind an
/// app-UI grant regardless of which face asks.
public enum HostInvokingFace: String, Codable, Sendable {
    case mcp
    case api
    case appIntent = "intent"
    /// The host's own chat harness: a language model a person is talking to
    /// (from the host page or over the chat.* wire family) using projections
    /// as tools. An agent face by the rule above — the model's tool calls are
    /// exactly the "caller a person at the machine cannot see happening".
    case chat
}

/// One invocation of one capability by one face, in the words a person
/// reading the log needs.
///
/// What it carries, and why only this:
///
/// - **capability** — which capability was invoked, by the one spelling the
///   registry keys on. It is also what the host validates the event against,
///   so a name no row claims cannot reach the log.
/// - **face** — who asked. This is the fact the log is missing today: the
///   guest families already write `sw`/`proc`/`files` lines when something
///   launches or is quit, but nothing in either file says whether the person
///   at the machine or an agent asked for it.
/// - **guest** — which machine it concerned, as the caller addressed it. Nil
///   means "the machine this host is driving", which the host resolves to
///   that machine's id when it writes the line, because the selector a
///   caller omitted is not the answer to "which Mac was this".
/// - **outcome** — whether the projection answered or refused the caller,
///   plus the refusal's own sentence.
///
/// What it deliberately does NOT carry: the arguments. A path, an upload's
/// bytes, a receipt, a process reference or a software name would put
/// user content and one-use credentials into a file, and none of them is
/// needed to answer "what was driven, by whom, about which machine, and did
/// it happen". The guest-Files family already logs its own paths under
/// `files` for the operations where the path IS the event; duplicating them
/// here would be a second copy with no second reader.
public struct HostProjectionAuditEvent: Codable, Equatable, Sendable {
    /// What the invocation came to, as the DISPATCH can honestly see it.
    ///
    /// `answered` means the projection produced a typed result — which may
    /// itself say the guest was unavailable or the host refused. That
    /// distinction lives inside the result, and reading it back out here
    /// would mean this file learning the shape of a dozen result types and
    /// going stale behind the thirteenth.
    public enum Outcome: String, Codable, Sendable {
        /// A typed result was produced and handed to the caller.
        case answered
        /// The projection refused the caller's arguments. Nothing was asked
        /// of the host, and nothing reached the machine.
        case refused
        /// **The machine's own ceiling refused it.** Its own outcome and not
        /// a shade of `refused`, for the same reason the typed denial is not
        /// an `unavailable`: to the person at the machine these are two
        /// different events, and only one of them says somebody tried to do
        /// something their machine had already said no to. That is the line
        /// they most want to be able to find.
        ///
        /// It extends the value space of an existing v8 field rather than
        /// changing the shape, so the local protocol version does NOT move.
        /// The skew it leaves, stated rather than discovered: a host built
        /// before this case rejects an audit report carrying it, which costs
        /// one log line on a mixed install and never a call — the reporting
        /// path is already best-effort. Bumping to v9 instead would make
        /// that host reject EVERY request from this companion, which is a
        /// far worse trade for one enum value.
        case denied
    }

    /// The bound on the refusal sentence. A row's refusal text is a written
    /// constant today, but a later one could interpolate a caller's string,
    /// and this line has to fit a 16 KiB local request beside everything
    /// else.
    public static let maximumReasonScalars = 120

    public let capability: String
    public let face: HostInvokingFace
    public let guest: String?
    public let outcome: Outcome
    /// The projection's own refusal sentence, bounded. Present only on a
    /// refusal — `docs/logging.md` rule 4: a string that explains a failure
    /// goes to the log, refusal reasons especially.
    public let reason: String?

    public init(capability: HostCapabilityID,
                face: HostInvokingFace,
                guest: String?,
                outcome: Outcome,
                reason: String? = nil) {
        self.capability = capability.rawValue
        self.face = face
        self.guest = guest
        self.outcome = outcome
        self.reason = reason.map {
            String($0.unicodeScalars.prefix(Self.maximumReasonScalars))
        }
    }

    /// The event for one completed invocation.
    public init(capability: HostCapabilityID,
                face: HostInvokingFace,
                guest: String?,
                outcome: HostProjectionOutcome) {
        switch outcome {
        case .value:
            self.init(capability: capability, face: face, guest: guest,
                      outcome: .answered)
        case .invalidArguments(let message):
            self.init(capability: capability, face: face, guest: guest,
                      outcome: .refused, reason: message)
        case .deniedByConsent(let denial):
            /* The SHORT sentence, not the one written for the agent: this
               line is read by the person standing at the Macintosh, who does
               not need to be told what their own machine answered at length. */
            self.init(capability: capability, face: face, guest: guest,
                      outcome: .denied, reason: denial.reason)
        }
    }

    /// The line's message, in the shape `docs/logging.md` defines — one
    /// line, short, self-contained, written by whoever owns the log rather
    /// than by the process that reported the event.
    ///
    /// `drivenGuest` is what the host resolves an omitted selector to. It is
    /// a parameter rather than a field because only the host knows it, and
    /// the caller that omitted the selector never said which machine it
    /// meant.
    public func logMessage(drivenGuest: String? = nil) -> String {
        let machine = Self.sanitized(guest ?? drivenGuest) ?? "?"
        var line = "\(face.rawValue) \(Self.sanitized(capability) ?? "?") "
            + "guest=\(machine) \(outcome.rawValue)"
        if let reason = Self.sanitized(reason) {
            line += ": \(reason)"
        }
        return line
    }

    public var level: HostProjectionAuditLevel {
        outcome == .answered ? .info : .warn
    }

    /// Control bytes are legal in an HFS name and reach this side inside
    /// paths and machine ids; a raw one in a log line corrupts the row the
    /// Logs page draws. The escape is the same choice the guest-Files audit
    /// text already makes.
    private static func sanitized(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        var escaped = ""
        for scalar in value.unicodeScalars {
            let isControl = scalar.value < 0x20 || scalar.value == 0x7F
                || (0x80...0x9F).contains(scalar.value)
            if isControl {
                escaped += String(format: "\\x%02X", scalar.value)
            } else {
                escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }
}

/// The level an audit line is written at, stated here so the shared module
/// can decide it without importing the host app's log.
public enum HostProjectionAuditLevel: String, Codable, Sendable {
    case info
    case warn
}

/// Where a face's audit events go.
///
/// It is a separate seam from `AgentIntegrationClient` on purpose: a client
/// is how a projection reaches the host to DO something, and a sink is how
/// the invocation itself becomes visible to the person at the machine. The
/// MCP face's sink is a local request to the running host, because the
/// companion is a short-lived separate process and the log a person reads is
/// the host app's.
public protocol HostProjectionAuditSink: Sendable {
    func record(_ event: HostProjectionAuditEvent) async
}
