import AppKit
import SwiftUI

/// The MCP page: the server an agent reaches this Mac through — whether it
/// is running, where its socket is, and how to switch it off — together with
/// what a companion has done through it and what the machine being driven has
/// agreed to.
///
/// **One pane, two concerns, and they were separate for a reason that has
/// expired.** The lifecycle of the server and the record of what came in
/// through it are different things, but MCP is the only way in today, so a
/// person asking "is this switched on" and "what has it done" is asking about
/// one surface and was made to find two.
///
/// **The audit model underneath stays transport-agnostic on purpose.**
/// `AgentActivityEvent` carries a `face` (`.mcp`, `.appIntent`) rather than
/// assuming one, and `AgentCompanionActivity` counts calls without naming a
/// transport. What an agent did to this Mac is a fact about the Mac, and it
/// outlives whichever door the call came through: an AppIntent invocation is
/// already a second face, and folding "MCP" into the types would have to be
/// unpicked the first time a third one lands. So the PANE is named for the
/// transport it controls, and the MODEL is not.
///
/// **The division of responsibility is settled**: this host owns the server's
/// lifecycle and its endpoint; the guest surfaces its own enable/disable and
/// status. Nothing here reaches across that line.
///
/// **It exists because the auditable half was built twelve times and the
/// visible half never was.** An agent can trash a file, cancel a transfer a
/// person started, and change what is on their screen; all three write
/// honest lines into Logs, mixed in with everything else, where a person has
/// to already suspect something to go and read them. This is the same facts,
/// in front of them.
///
/// **Its resting state is the designed one.** On most Macs, for the whole
/// life of the app, nothing has ever attached — so that state gets sentences
/// and no counters (`AgentPresenceReading`), because a table of zeroes reads
/// as a feature that failed to load.
///
/// **Nothing here is a control over the guest's consent**, deliberately: the
/// machine being driven owns that answer, and a host-side override would
/// defeat the point of asking it. The page displays and does not decide —
/// what may happen is settled at the dispatch, in one place.
struct MCPModuleView: View {
    @ObservedObject var model: AgentActivityModel
    @ObservedObject var companions: AgentCompanionModel
    @ObservedObject var listener: GuestListener
    @ObservedObject var settings: MCPTransportSettingsModel
    /// Nil in a preview or a test with no Settings window to open.
    var openSettings: (() -> Void)?
    /// Nil in a preview or a test that has no server to run. The buttons are
    /// then absent rather than dead — a control that does nothing is the
    /// thing every page in this app is written to avoid.
    var startStdio: (() -> Void)?
    var stopStdio: (() -> Void)?
    var startHTTP: (() -> Void)?
    var stopHTTP: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 12) {
                    transports
                    presence
                    heldLane
                    consent
                    activity
                }
                .padding(12)
            }
        }
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("MCP")
                    .font(.headline)
                Text("Agent access to \(MachineNaming.thisMac) and the "
                        + "\(MachineNaming.properNounPlural) paired with "
                        + "it, and the traffic through it. Also written to "
                        + "the log.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let openSettings {
                Button("Settings…", action: openSettings)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    // MARK: presence

    /// **A schedule rather than a subscription, and that is the point.**
    /// The ledger is push-fed and publishes on every change, which covers
    /// every transition that HAPPENS — but "attached" decays into "not
    /// attached now" purely by the clock, with no event to redraw on. A pane
    /// bound only to the publisher would sit on "an agent is attached" for
    /// as long as nobody touched the window. `TimelineView` re-derives the
    /// reading on its own, and only while the page is actually on screen,
    /// which is a timer nobody has to remember to invalidate.
    private var presence: some View {
        TimelineView(.periodic(from: Date(), by: 5)) { context in
            let reading = AgentPresenceReading(
                model.combinedActivity(companions.activity),
                                               asOf: context.date)
            card {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: reading.symbol)
                        .font(.system(size: 22))
                        .foregroundStyle(tint(reading.tone))
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(reading.headline)
                            .font(.title3.weight(.semibold))
                        Text(reading.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if reading.showsCounters {
                            counters
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// Counts and clock times, which is all the ledger keeps. There is
    /// deliberately no "what did it last do" here — that is the list below,
    /// read from the audit stream, and putting it on the presence ledger
    /// instead is the failure its own header names.
    private var counters: some View {
        let activity = companions.activity
        return VStack(alignment: .leading, spacing: 2) {
            Divider().padding(.vertical, 2)
            counterRow("Standard Input calls",
                       "\(activity.totalRequests) since launch")
            counterRow("HTTP calls",
                       "\(model.httpRequests) since launch")
            counterRow("Standard Input processes",
                       activity.companions.count == 1
                           ? "1" : "\(activity.companions.count)")
            if activity.refusedPeers > 0 {
                /* The one thing about the boundary a person cannot infer
                   from anything else: something on this Mac running as
                   another user reached for the endpoint and was turned
                   away. Nothing identifies it — the gate exists to not
                   look. */
                counterRow("Rejected by the user check",
                           "\(activity.refusedPeers)")
            }
        }
    }

    private func counterRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .frame(width: 210, alignment: .leading)
            Text(value)
                .font(.system(.callout, design: .monospaced))
            Spacer(minLength: 0)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    // MARK: consent

    // MARK: the lane an agent is holding

    /// **The one thing an agent does that is not over when the call is.**
    ///
    /// Every other row on this page is history: the list below says what was
    /// done, in the past tense, because every other capability answers and is
    /// finished. A live stream is a bracket an agent holds open across calls,
    /// and while it is open the Macintosh is capturing its screen and the
    /// person's own Capture button does not work. An audit line saying a
    /// stream was started an hour ago cannot say whether it is still running,
    /// so this is a STATE and not an event, and it is drawn only when there
    /// is one.
    ///
    /// It is here as well as on the Screenshots page rather than instead of
    /// it: the Screenshots page is where somebody notices, and this is where
    /// somebody who came to ask what an agent is doing gets the answer
    /// without having to know which page a stream lives on.
    @ViewBuilder
    private var heldLane: some View {
        if listener.streamOrigin == .agent {
            card {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 22))
                        .foregroundStyle(.orange)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 6) {
                        /* The stream is of the machine being driven, not
                           of this one — this line used to say "this Mac's
                           screen", which named the wrong machine. */
                        Text("Agent streaming "
                             + "\(MachineNaming.possessive(nil)) screen")
                            .font(.title3.weight(.semibold))
                        Text(heldLaneDetail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var heldLaneDetail: String {
        var sentence = "Capturing continuously"
        if let interval = listener.streamMinIntervalMs, interval > 0 {
            /* Written as an interval rather than converted to a frame rate.
               It is a CEILING on the machine's work — the guest may be
               slower — and "up to 1 fps" invites reading it as a
               measurement of what is happening. */
            sentence += ", at most one frame every "
                + "\(interval) ms"
        }
        sentence += ". Shown on the Screenshots page; Stop Streaming ends "
            + "it regardless of origin. Also ended automatically when the "
            + "agent disconnects or stops "
            + "reading."
        return sentence
    }

    // MARK: consent

    /// The machine's own answer, one row per connected Mac. Read back, not
    /// offered — there is no control here by design.
    ///
    /// LIVE, not a connect-time snapshot: `agent.access` revises the answer
    /// on the link already up and lands in the same session-health field
    /// `hello.agent` filled, so these rows follow a switch thrown on the
    /// other machine. That matters more here than as a nicety — the value
    /// these rows display is the value the dispatch enforces, so a row that
    /// went stale would be this pane vouching for a permission the person
    /// had already withdrawn.
    private var consent: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Consent")
                    .font(.headline)
                Text("Set per machine, and changeable while connected. "
                        + "Changed on that machine, not here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if listener.guests.isEmpty {
                    Text("No \(MachineNaming.commonNoun) connected.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(listener.guests) { guest in
                        consentRow(AgentConsentReading(
                            machine: guest.label,
                            access: guest.agentAccess))
                    }
                }
            }
        }
    }

    private func consentRow(_ reading: AgentConsentReading) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: reading.symbol)
                .foregroundStyle(reading.isConsent ? .primary : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(reading.machine)
                        .font(.callout.weight(.semibold))
                    Text(reading.title)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text(reading.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    // MARK: the stream

    private var activity: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Activity")
                    .font(.headline)
                if model.events.isEmpty {
                    Text(emptyStreamSentence)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(model.events) { event in
                        eventRow(event)
                    }
                }
            }
        }
    }

    /// Two different silences. A stream that is empty because nothing ever
    /// attached is the resting state and is already explained above, so
    /// repeating it would be the pane saying the same thing twice; a stream
    /// that is empty while a companion HAS attached is a real and slightly
    /// surprising fact — something connected and asked for nothing this
    /// side records — and says so.
    private var emptyStreamSentence: String {
        model.combinedActivity(companions.activity).hasEverAttached
            ? "Agent connected; no calls yet. Every capability an agent "
                + "invokes is reported here."
            : "No agent calls."
    }

    private func eventRow(_ event: AgentActivityEvent) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol(event))
                .foregroundStyle(tint(event))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(event.title)
                        .font(.callout.weight(.medium))
                    if event.isDestructive {
                        Text("modifies the Mac")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Spacer(minLength: 0)
                    Text(Self.clock.string(from: event.at))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text(subtitle(event))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let reason = event.reason {
                    /* The projection's own refusal sentence, verbatim. It
                       is what the caller was told, and rewording it here
                       would leave the person and the agent reading two
                       different accounts of one refusal. */
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, 4)
    }

    /// The identifiers stay visible beside the phrase: the tool name is what
    /// a person will find in the log and in whatever client made the call,
    /// and the machine is the fact that says which Mac this happened to.
    private func subtitle(_ event: AgentActivityEvent) -> String {
        let face = event.face == .mcp ? "MCP" : "AppIntent"
        let machine = event.machine ?? "no machine"
        let outcome = event.outcome == .answered ? "answered" : "refused"
        return "\(face) · \(event.capability) · \(machine) · \(outcome)"
    }

    private func symbol(_ event: AgentActivityEvent) -> String {
        event.outcome == .refused
            ? "hand.raised.circle"
            : (event.isDestructive
                ? "exclamationmark.circle" : "checkmark.circle")
    }

    private func tint(_ event: AgentActivityEvent) -> Color {
        if event.outcome == .refused { return .orange }
        return event.isDestructive ? .orange : .secondary
    }

    private func tint(_ tone: AgentPresenceReading.Tone) -> Color {
        switch tone {
        case .resting: return .secondary
        case .attached: return .green
        case .working: return .green
        }
    }

    // MARK: the server

    /// **The one card on this page that is a control.**
    ///
    /// It is the server's state, its switch, and its socket path in one
    /// place, because they are one question: a person here either wants to
    /// know whether an agent can reach this Mac, or wants to change the
    /// answer. The path is beside the switch rather than in its own card
    /// because configuring a client and turning the thing on are the same
    /// errand.
    ///
    /// Stopping is deliberately not a confirmation prompt: it is reversible
    /// in one click and its consequence — no agent can reach this Mac — is
    /// the safe direction. Starting after a failure is worth retrying too,
    /// since the usual cause is another copy of NOW that has since quit.
    ///
    /// Whether each transport starts automatically at launch is a Settings
    /// tab now, not a switch on this card — it is checked once a launch and
    /// never mid-session, unlike everything else here.
    private var transports: some View {
        VStack(spacing: 12) {
            transportCard(
                title: "Standard Input",
                summary: "For MCP clients that launch a command. The New "
                    + "Old World executable runs in stdio mode and reaches "
                    + "this app over its same-user socket.",
                state: model.stdio,
                start: startStdio,
                stop: stopStdio,
                details: { endpoint in
                    stdioDetails(endpoint)
                },
                configuration: {
                    stdioConfiguration
                })
            transportCard(
                title: "HTTP",
                summary: "For clients that connect to a URL. Runs inside "
                    + "New Old World, binds to loopback only, and requires "
                    + "the private bearer token.",
                state: model.http,
                start: startHTTP,
                stop: stopHTTP,
                details: { _ in
                    httpDetails
                },
                configuration: {
                    httpConfiguration(isRunning: model.http.isRunning)
                })
        }
    }

    private func transportCard<Details: View, Configuration: View>(
        title: String,
        summary: String,
        state: MCPTransportState,
        start: (() -> Void)?,
        stop: (() -> Void)?,
        @ViewBuilder details: (String) -> Details,
        @ViewBuilder configuration: () -> Configuration
    ) -> some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center) {
                    Text(title).font(.headline)
                    Spacer(minLength: 12)
                    lifecycleButton(state: state, start: start, stop: stop)
                }
                HStack(spacing: 6) {
                    Image(systemName: state.isRunning
                            ? "circle.fill" : "circle")
                        .font(.caption2)
                        .foregroundStyle(state.isRunning
                            ? Color.green : .secondary)
                    Text(runningLine(state))
                        .font(.callout.weight(.medium))
                }
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                configuration()
                switch state {
                case .open(let endpoint):
                    details(endpoint)
                case .unavailable(let reason):
                    Text(reason)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .unopened:
                    Text("Not started.")
                        .font(.callout).foregroundStyle(.secondary)
                case .stopped:
                    Text("Stopped. Audit history is unchanged.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func runningLine(_ state: MCPTransportState) -> String {
        switch state {
        case .open: return "Running"
        case .unopened: return "Not started"
        case .stopped: return "Stopped"
        case .unavailable: return "Did not start"
        }
    }

    @ViewBuilder
    private func lifecycleButton(
        state: MCPTransportState,
        start: (() -> Void)?,
        stop: (() -> Void)?
    ) -> some View {
        if start != nil || stop != nil {
            ControlGroup {
                Button("Start") { start?() }
                    .disabled(state.isRunning || start == nil)
                Button("Stop") { stop?() }
                    .disabled(!state.isRunning || stop == nil)
            }
            .controlSize(.small)
        }
    }

    private var stdioConfiguration: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Client command")
                .font(.caption.weight(.medium))
            copyRow(label: "Command", value: stdioCommand)
            Text("Launched by each client on demand. Starting this "
                    + "transport opens the same-user bridge those client "
                    + "processes use.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func httpConfiguration(isRunning: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Loopback port") {
                TextField("Port", value: $settings.httpPort,
                          format: .number.grouping(.never))
                    .frame(width: 90)
                    .multilineTextAlignment(.trailing)
                    .disabled(isRunning)
            }
            copyRow(label: "URL", value: plannedHTTPEndpoint)
            Text(isRunning
                    ? "Stop HTTP before changing its port."
                    : "Reachable only from this Mac at 127.0.0.1.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func stdioDetails(_ socket: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            copyRow(label: "Private socket", value: socket)
            Text("Accepts only processes running as the current macOS "
                    + "user. No separately installed companion is "
                    + "launched.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var httpDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let token = model.httpBearerToken {
                Button("Copy Bearer Token") { copy(token) }
                    .controlSize(.small)
                    .help("Copy the private token. Never displayed or "
                          + "written to the log.")
            }
        }
    }

    private func copyRow(label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(label + ":").font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            Button("Copy") { copy(value) }.controlSize(.small)
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private var stdioCommand: String {
        let path = Bundle.main.executableURL?.path ?? "New Old World"
        return "\(path) --mcp-stdio"
    }

    private var plannedHTTPEndpoint: String {
        "http://127.0.0.1:\(settings.httpPort)/mcp"
    }

    // MARK: chrome

    private func card<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary.opacity(0.35),
                        in: RoundedRectangle(cornerRadius: 8))
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
