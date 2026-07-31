import AppKit
import SwiftUI

/// The Agent page: what a companion agent is doing to this Mac, what it has
/// done, what the machine being driven has agreed to, and where the socket
/// is.
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
struct AgentActivityModuleView: View {
    @ObservedObject var model: AgentActivityModel
    @ObservedObject var companions: AgentCompanionModel
    @ObservedObject var listener: GuestListener

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 12) {
                    presence
                    heldLane
                    consent
                    activity
                    endpoint
                }
                .padding(12)
            }
        }
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Agent")
                .font(.headline)
            Text("What a companion agent has done to this Mac and the ones "
                    + "it is driving. Everything here also reaches the log; "
                    + "this is the same record, in front of you.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
            let reading = AgentPresenceReading(companions.activity,
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
            counterRow("Calls served",
                       "\(activity.totalRequests) since launch")
            counterRow("Companion processes",
                       activity.companions.count == 1
                           ? "1" : "\(activity.companions.count)")
            if activity.refusedPeers > 0 {
                /* The one thing about the boundary a person cannot infer
                   from anything else: something on this Mac running as
                   another user reached for the endpoint and was turned
                   away. Nothing identifies it — the gate exists to not
                   look. */
                counterRow("Turned away by the user check",
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
                        Text("An agent is streaming this Mac's screen")
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
        var sentence = "The screen is being captured continuously"
        if let interval = listener.streamMinIntervalMs, interval > 0 {
            /* Written as an interval rather than converted to a frame rate.
               It is a CEILING on the machine's work — the guest may be
               slower — and "up to 1 fps" invites reading it as a
               measurement of what is happening. */
            sentence += ", at most one frame every "
                + "\(interval) ms"
        }
        sentence += ". The Screenshots page shows it and its Stop Streaming "
            + "button ends it, whoever started it. New Old World also ends "
            + "it by itself if the agent that opened it goes away or stops "
            + "reading."
        return sentence
    }

    // MARK: consent

    /// The machine's own answer, one row per connected Mac. Read back, not
    /// offered — there is no control here by design.
    private var consent: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Text("What the other Mac has agreed to")
                    .font(.headline)
                Text("Each machine answers this for itself when it "
                        + "connects. It is changed on that machine, not "
                        + "here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if listener.guests.isEmpty {
                    Text("No Mac is connected, so none has answered.")
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
                Text("What an agent has done")
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
        companions.activity.hasEverAttached
            ? "A companion has connected but no call has been reported "
                + "yet. Every capability an agent invokes is reported here "
                + "as it happens."
            : "Nothing yet — no agent has invoked anything."
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
                        Text("changes the Mac")
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

    // MARK: endpoint

    /// Where the socket is, because somebody configuring a client needs it —
    /// and, when there is none, why. A path printed for an endpoint that
    /// failed to open would send that person looking for a file that is not
    /// there.
    private var endpoint: some View {
        card {
            VStack(alignment: .leading, spacing: 6) {
                Text("The endpoint")
                    .font(.headline)
                switch model.endpoint {
                case .open(let path):
                    Text("A companion reaches this Mac over a local socket "
                            + "here. Only processes running as you may use "
                            + "it; the check is the kernel's, not "
                            + "something a caller says about itself.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Text(path)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                path, forType: .string)
                        }
                        .controlSize(.small)
                    }
                case .unavailable(let reason):
                    Text("The local endpoint did not open, so no agent can "
                            + "reach this Mac at all. The rest of New Old "
                            + "World is unaffected — this surface is "
                            + "optional and its failure is never allowed "
                            + "to stop the app.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(reason)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .unopened:
                    Text("The local endpoint has not been started.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
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
