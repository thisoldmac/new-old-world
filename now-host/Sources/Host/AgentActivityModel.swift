import Combine
import Foundation
import NOWAgentIntegration

/// One invocation, as the Agent page draws it.
///
/// It is `HostProjectionAuditEvent` — the same typed event the log line is
/// composed from — plus the two things only this side can supply: when the
/// host wrote it down, and the row's own words for the capability. Nothing
/// is added to what the event carries: no arguments, no paths, no payloads,
/// because the event refuses them on purpose and a pane that showed more
/// would mean somebody had put them back on the wire.
struct AgentActivityEvent: Identifiable, Equatable {
    let id: Int
    let at: Date
    let capability: String
    let face: HostInvokingFace
    /// Which machine it concerned, resolved by the host when the caller
    /// omitted the selector. Nil only when the host was driving nothing.
    let machine: String?
    let outcome: HostProjectionAuditEvent.Outcome
    /// The projection's own refusal sentence. Present only on a refusal.
    let reason: String?

    /// The capability in the words its own row already uses.
    ///
    /// **Derived from the registry rather than kept as a table here.** The
    /// row states its title once for the MCP face; a second list of
    /// human-readable names on this side is the fifth hand-maintained
    /// capability list this arc has had to collapse, and it would go stale
    /// silently — a pane showing a raw tool name for one row and a phrase
    /// for the rest is not a failure anything fails on.
    let title: String

    /// Whether the row declares itself destructive, read from the same
    /// annotation the MCP face publishes. It is what makes "trashed a file"
    /// legible beside "read the process list" without this side re-deciding
    /// which is which.
    let isDestructive: Bool

    /// A capability no row claims cannot reach the log (the codec refuses
    /// it), so this is reached only by a row that exists — and the fallback
    /// says the name rather than inventing a phrase for it.
    static func title(for capability: String) -> String {
        guard let row = HostProjectionRegistry.hostFaces
            .projection(named: capability),
            let title = row.mcpDescriptor["title"] as? String
        else { return capability }
        /* The product's own name, dropped: these titles are written for a
           tool list in somebody else's client, where "New Old World" is
           what tells them which Mac is meant. Inside NOW it is every row's
           first two words and says nothing. */
        return title
            .replacingOccurrences(of: "the New Old World ", with: "the ")
            .replacingOccurrences(of: "New Old World ", with: "")
    }

    static func isDestructive(_ capability: String) -> Bool {
        guard let row = HostProjectionRegistry.hostFaces
            .projection(named: capability),
            let annotations =
                row.mcpDescriptor["annotations"] as? [String: Any]
        else { return false }
        return annotations["destructiveHint"] as? Bool ?? false
    }
}

/// Where the local endpoint is, or why there is none.
///
/// The third case is the reason this is not just a path string. A host whose
/// endpoint failed to open reports `.neverAttached` presence — correctly,
/// nothing has reached it — and a pane that then printed a socket path would
/// be naming a file that is not there to someone trying to configure a
/// client against it.
enum MCPTransportState: Equatable {
    /// Before the app has tried. Only ever seen by a test or a preview.
    case unopened
    case open(endpoint: String)
    /// The server did not stand up, with the reason as it was logged.
    case unavailable(String)
    /// Stopped from the MCP pane. A fourth case rather than a return to
    /// `unopened`, because "you switched it off" and "it has not started
    /// yet" are different answers to the same question, and only one of
    /// them tells a person why their client cannot connect.
    case stopped

    /// Whether the server is serving right now. The pane's Start/Stop pair
    /// reads this, so a failed endpoint offers Start and not Stop.
    var isRunning: Bool {
        if case .open = self { return true }
        return false
    }
}

/// What has reached this host's local agent endpoint, in the pane's own
/// vocabulary: the audit stream, and where the socket is.
///
/// **Presence is not here.** It lives in `AgentCompanionModel`, fed by the
/// server's ledger, and this model deliberately does not mirror it: the
/// ledger records who and when, this records what, and the division is
/// documented in `AgentCompanionActivity`'s own header as the thing not to
/// undo. The page observes both.
@MainActor
final class AgentActivityModel: ObservableObject {
    @Published private(set) var stdio: MCPTransportState = .unopened
    @Published private(set) var http: MCPTransportState = .unopened
    /// Available only while HTTP is running. The view offers an explicit
    /// Copy action and never prints the secret into its normal hierarchy.
    @Published private(set) var httpBearerToken: String?
    @Published private(set) var httpRequests = 0
    @Published private(set) var httpInFlight = 0
    @Published private(set) var httpFirstSeen: Date?
    @Published private(set) var httpLastSeen: Date?

    func stdioOpened(at endpoint: String) {
        stdio = .open(endpoint: endpoint)
    }

    func stdioUnavailable(_ reason: String) {
        stdio = .unavailable(reason)
    }

    /// The person switched the server off from the MCP pane.
    ///
    /// The events stay: what an agent did to this Mac is not undone by
    /// closing the door it came through, and a record that vanished when the
    /// server stopped would be the one that mattered most.
    func stdioStopped() {
        stdio = .stopped
    }

    /// `bearerToken` is nil when the listener runs in a mode that has no
    /// copyable secret (unauthenticated, oauth).
    func httpOpened(at endpoint: String, bearerToken: String?) {
        http = .open(endpoint: endpoint)
        httpBearerToken = bearerToken
    }

    func httpUnavailable(_ reason: String) {
        http = .unavailable(reason)
        httpBearerToken = nil
    }

    func httpStopped() {
        http = .stopped
        httpBearerToken = nil
    }

    func httpRequestBegan(at moment: Date = Date()) {
        httpRequests += 1
        httpInFlight += 1
        if httpFirstSeen == nil { httpFirstSeen = moment }
        httpLastSeen = moment
    }

    func httpRequestEnded(at moment: Date = Date()) {
        httpInFlight = max(0, httpInFlight - 1)
        httpLastSeen = moment
    }

    /// The presence card is about agents, not transport implementation.
    /// Preserve the kernel-backed stdio companion rows while folding HTTP's
    /// bounded request clocks into the totals the person reads.
    func combinedActivity(_ stdio: AgentCompanionActivity)
        -> AgentCompanionActivity {
        .init(
            companions: stdio.companions,
            totalRequests: stdio.totalRequests + httpRequests,
            inFlight: stdio.inFlight + httpInFlight,
            refusedPeers: stdio.refusedPeers,
            lastRefusal: stdio.lastRefusal,
            firstSeen: [stdio.firstSeen, httpFirstSeen]
                .compactMap { $0 }.min(),
            lastSeen: [stdio.lastSeen, httpLastSeen]
                .compactMap { $0 }.max())
    }
}

/// What the presence pane says, right now, in words.
///
/// A value derived from the ledger and a clock, so the sentences a person
/// reads have a test and the view has no judgement in it. Deriving it needs
/// the clock because the reading changes with **nothing happening** — a
/// companion goes active → idle on time alone, with no event to redraw on —
/// which is why `AgentCompanionModel.presence` is a method and why the view
/// re-derives this on a schedule rather than on a publisher.
struct AgentPresenceReading: Equatable {
    enum Tone: Equatable {
        /// Nothing is happening and nothing is wrong.
        case resting
        case attached
        case working
    }

    let headline: String
    let detail: String
    let symbol: String
    let tone: Tone
    /// Whether the counters below the headline mean anything yet.
    ///
    /// False for exactly one state, and it is the whole point of the state:
    /// "0 companions, 0 requests, last seen never" is the shape of a broken
    /// thing, and a Mac nothing has ever driven is not broken. On that
    /// machine the page says so in sentences and shows no numbers at all.
    let showsCounters: Bool

    init(_ activity: AgentCompanionActivity, asOf now: Date = Date()) {
        switch activity.presence(asOf: now) {
        case .neverAttached:
            /* The resting state on most Macs, for the whole life of the
               app on them. It gets its own words rather than an empty
               table because an empty table teaches nothing and reads as a
               feature that failed to load — and because the true sentence
               here is reassuring rather than absent: nothing is driving
               this Mac, nothing is meant to be, and this page is where it
               would appear if something ever did.

               "since New Old World started" is not a hedge. The ledger is
               in memory and begins at launch, so "never" is a claim this
               side can actually support only about this launch; the log,
               which can be written to disk, is where a longer answer
               lives. */
            headline = "No agent has attached"
            detail = "Nothing has connected to this Mac's agent endpoint "
                + "since New Old World started. Nothing is driving this "
                + "Mac but you.\n\nThere is nothing to switch on here. If "
                + "you ever point an agent at New Old World, this page is "
                + "where its work appears — every call it makes, which "
                + "Mac it made it about, and whether it was answered or "
                + "refused."
            symbol = "person.slash"
            tone = .resting
            showsCounters = false
        case .working:
            headline = activity.inFlight == 1
                ? "An agent is working now"
                : "\(activity.inFlight) agent calls are in flight"
            detail = "A request is being served at this instant."
            symbol = "bolt.horizontal.circle"
            tone = .working
            showsCounters = true
        case .active(let since):
            headline = "An agent is attached"
            detail = "Last call \(Self.elapsed(since, to: now)). New Old "
                + "World counts an agent as attached for two minutes after "
                + "its last call, whichever MCP transport it used."
            symbol = "person.wave.2"
            tone = .attached
            showsCounters = true
        case .idle(let since):
            headline = "No agent attached now"
            detail = "One was: the last call was "
                + "\(Self.elapsed(since, to: now)). What it did is below."
            symbol = "person"
            tone = .resting
            showsCounters = true
        }
    }

    /// Plain elapsed time, written out rather than formatted, so the
    /// sentences above have a test that does not depend on a locale or on
    /// which day it is.
    static func elapsed(_ moment: Date, to now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(moment).rounded())
        switch seconds {
        case ..<10: return "just now"
        case ..<60: return "\(max(seconds, 1)) seconds ago"
        case ..<3600:
            let minutes = Int((Double(seconds) / 60).rounded())
            return "\(minutes) minute\(minutes == 1 ? "" : "s") ago"
        case ..<172_800:
            let hours = Int((Double(seconds) / 3600).rounded())
            return "\(hours) hour\(hours == 1 ? "" : "s") ago"
        default:
            let days = Int((Double(seconds) / 86400).rounded())
            return "\(days) day\(days == 1 ? "" : "s") ago"
        }
    }
}

/// **The machine's own answer, read back to the person — never offered as a
/// control.**
///
/// Consent belongs to the Mac being driven: it arrives on `hello` and is
/// changed at that machine. A host-side switch that could override it would
/// make the answer the host's, which is the one thing this field exists to
/// prevent. So this type has no setter and the page has no toggle.
///
/// Four readings for four states, and the important one is the fourth.
/// Silence is a build older than the field, and it must not read as a yes —
/// so it is written as the absence of an answer, with the fact that this
/// host currently proceeds anyway said out loud rather than left for
/// somebody to discover.
struct AgentConsentReading: Equatable {
    let machine: String
    let title: String
    let detail: String
    let symbol: String
    /// True when the machine has actually consented to something. The page
    /// draws the rest as absence rather than as a lesser yes.
    let isConsent: Bool

    init(machine: String, access: AgentIntegrationGuestAccess?) {
        self.machine = machine
        /* Every sentence below is about the machine being driven, and this
           page shows them under the host's own window — so none of them may
           reach for "this Mac", which here means the reader's machine and
           not the one that answered. */
        let plain = MachineNaming.sentence(machine)
        /* `title` and not `startingSentence(sentence(_:))` for a sentence
           that OPENS on the machine: capitalising the first character
           would turn "pb1400c" into "Pb1400c", and a machine spells its
           own name. Only the nameless fallback needs the capital, which
           is exactly what `title` gives it. */
        let opens = MachineNaming.title(machine)
        switch access {
        case nil:
            title = "Has not said"
            detail = "\(opens) has a build that predates the question, so "
                + "it has neither agreed nor refused. Silence is not "
                + "consent: it "
                + "is a build that was never asked. Agent calls still "
                + "reach it for now, and that is a decision made on "
                + "\(MachineNaming.thisMac), not an answer from \(plain)."
            symbol = "questionmark.circle"
            isConsent = false
        case .disabled:
            title = "Refuses"
            detail = "\(opens) says no to being driven by an agent — "
                + "either its installer left the agent features out or "
                + "somebody flipped the switch on the machine itself. "
                + "Changing it is done there, not here."
            symbol = "hand.raised"
            isConsent = false
        case .readOnly:
            title = "Read Only"
            detail = "\(opens) consents to calls that change nothing on it: "
                + "reading its screen, its files, its processes, what it is."
            symbol = "eye"
            isConsent = true
        case .fullAccess:
            title = "Full Access"
            detail = "\(opens) consents to everything the product can do "
                + "to it, including changing its files and what is on its "
                + "screen."
            symbol = "checkmark.shield"
            isConsent = true
        case .unrecognized(let raw):
            title = "Answered “\(raw)”"
            detail = "\(opens) named a limit this copy of New Old World "
                + "has never heard of, so it is a newer build rather than "
                + "a broken one. A ceiling that cannot be named cannot be "
                + "claimed to be under, so it does not read as consent "
                + "here."
            symbol = "exclamationmark.triangle"
            isConsent = false
        }
    }
}
