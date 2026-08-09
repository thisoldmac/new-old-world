import SwiftUI
import NOWAgentIntegration

/// The Connection page — **the link, and who is on it.**
///
/// One page from two. There were a "Connections" module in the list and a
/// "Connection" module in the footer, and the split did not survive being
/// read: the footer one owned the port and the state of the link, the list
/// one owned the roster of machines on that link, and each had to restate
/// the other's half to make sense of its own. The footer pane explained what
/// a connection was for; the list pane explained why it was empty by naming
/// the port. That is one subject asked twice.
///
/// So the page is ordered as one sentence. The header states the link and
/// the count in a single line — `snapshot.headline`, which is the only place
/// either fact is drawn. Then this Mac's side of it: the port, the switch,
/// the health of the session. Then who is on it: the machines, the one being
/// driven, the ones the host merely remembers. The listener's log last,
/// because it is the record rather than the state.
///
/// **The resting state is one Mac, or none.** A page that only made sense
/// with three connected would be the wrong page for this desk, so the
/// single-machine case is the plain one: one card, no chooser, no counts.
/// Zero connected reads as *idle* — the host is listening and nothing has
/// dialled in, which is what most of an afternoon looks like — and never as
/// a failure. The only red on this page is a listener that actually failed.
struct ConnectionsModuleView: View {
    @ObservedObject var model: ConnectionsModel
    @ObservedObject var settings: SettingsModel
    @ObservedObject var listener: GuestListener
    var onStart: () -> Void
    var onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ConnectionLinkSection(settings: settings,
                                          listener: listener,
                                          onStart: onStart,
                                          onStop: onStop)
                    wire
                    remembered
                    ConnectionListenerLog(listener: listener)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// The one line that answers both halves at once: whether the link is up
    /// and who came in over it. Drawn here and nowhere else — the link
    /// section below deliberately has no status line of its own, because
    /// when the two panes were separate they each had one and the two were
    /// worded differently.
    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Connection")
                .font(.largeTitle.weight(.semibold))
            Label(model.snapshot.headline, systemImage: indicator.symbol)
                .foregroundStyle(indicator.tint)
                .font(.callout)
            if let problem = model.renameProblem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 14)
    }

    /// Who is on the link. The second half of the page's one sentence, and
    /// the reason the first half has a port control at all.
    @ViewBuilder
    private var wire: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHead("On the wire", caption: wireCaption)
            if model.snapshot.isIdle {
                idle
            } else {
                ForEach(model.snapshot.connected) { row in
                    ConnectionCard(row: row, model: model)
                }
            }
        }
    }

    /// Says what the roster below is, in the number of machines actually in
    /// it — with two connected the interesting fact is which one everything
    /// goes to, and with one or none there is no choice to explain.
    private var wireCaption: String {
        guard model.snapshot.connected.count > 1 else {
            return "\(MachineNaming.properNounPlural) connected to "
                + "\(MachineNaming.thisMac) right now."
        }
        return "Every command, module and capture request goes to the "
            + "machine being driven. The others stay connected."
    }

    /// The same dot vocabulary the sidebar footer and the modules use, so
    /// one glance means the same thing wherever it lands.
    private var indicator: (symbol: String, tint: Color) {
        switch model.snapshot.state {
        case .failed: return ("exclamationmark.triangle", .red)
        case .idle: return ("circle", .secondary)
        case .listening:
            return model.snapshot.isIdle
                ? ("circle.dotted", .orange) : ("circle.fill", .green)
        case .connected:
            return model.snapshot.isIdle
                ? ("circle.dotted", .orange) : ("circle.fill", .green)
        }
    }

    /// Nothing connected. Stated as what has to happen next, so a person
    /// reads a waiting room rather than a broken machine.
    ///
    /// It no longer repeats which side dials — the link section directly
    /// above says that once, whether or not anything is connected. When
    /// these were two panes this card had to carry that sentence itself,
    /// because the pane that owned it was somewhere else in the sidebar.
    @ViewBuilder
    private var idle: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(idleTitle)
                .font(.title3.weight(.semibold))
            Text("Open NOW on the old machine and point it at "
                 + "\(MachineNaming.thisMac).")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            /* The addressing consequence, said once here rather than on
               every remembered row: with nothing connected an agent that
               names any machine is told there is nothing connected,
               which is a different sentence from "that machine is not
               connected". */
            Text("An agent addressing any machine right now is told that "
                 + "no \(MachineNaming.commonNoun) is connected.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var idleTitle: String {
        switch model.snapshot.state {
        case .failed: return "The listener stopped"
        case .idle: return "Not listening"
        case .listening, .connected:
            return "Waiting for \(MachineNaming.simpleReference)"
        }
    }

    /// Machines this host remembers but cannot reach. A product that lets
    /// you address a Mac by name has to admit which names it knows, or the
    /// person is left guessing whether `pb1400c` is a typo or an absence.
    @ViewBuilder
    private var remembered: some View {
        let rows = model.snapshot.known
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHead("Remembered", caption:
                    "Named here, not connected now. An agent that names "
                    + "one of these is refused, never answered by "
                    + "another machine.")
                ForEach(rows) { row in
                    RememberedRow(row: row)
                }
            }
        }
    }
}

/// One connected machine: its three identities, what it is, and the two
/// things a person can do to it.
private struct ConnectionCard: View {
    let row: ConnectionRow
    @ObservedObject var model: ConnectionsModel

    @State private var renaming = false
    @State private var proposed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.label)
                    .font(.title3.weight(.semibold))
                if row.presence == .driving {
                    Badge(text: "Driving", tint: .accentColor)
                }
                if row.idIsAutoAssigned {
                    Badge(text: "Unnamed", tint: .secondary,
                          help: "The host assigned this id. It addresses "
                              + "the machine; it says nothing about it. "
                              + "Name it and the id becomes yours.")
                }
                if !row.idIsAnchored {
                    Badge(text: "Id is a guess", tint: .orange,
                          help: "This machine reached the host from an "
                              + "address that cannot tell two machines "
                              + "apart "
                              + "(loopback, so every emulated guest). The "
                              + "id surviving a reconnection is a guess. "
                              + "Use the session id when it must be exact.")
                }
                Spacer(minLength: 8)
                controls
            }

            if row.name != row.label {
                Text("Reported as \(row.name)")
                    .foregroundStyle(.secondary)
            }

            identities

            facts

            addressing
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(row.presence == .driving
                          ? Color.accentColor.opacity(0.5) : .clear))
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 8) {
            if row.presence == .connected {
                /* The person's half of what an agent does by naming a
                   machine. An agent asserts which Mac it means; a person
                   points the window at one. Same seam underneath. */
                /* "Drive This Mac" read as the Mac the app is running
                   on — the one machine the button cannot mean. */
                Button("Drive This One") { model.drive(row) }
                    .help("Every command, module and capture request goes "
                          + "to the machine chosen here. The others stay "
                          + "connected.")
            }
            Button(row.idIsAutoAssigned ? "Name…" : "Rename…") {
                proposed = row.machineID
                renaming = true
            }
            .help("The id an agent types to address this machine. Naming "
                  + "it is what makes it durable.")
        }
        .popover(isPresented: $renaming, arrowEdge: .bottom) {
            rename
        }
    }

    private var rename: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Machine id")
                .font(.headline)
            Text("Letters, numbers and hyphens. This is what a person or "
                 + "an agent types to reach this machine.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 280, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            TextField("machine-id", text: $proposed)
                .frame(width: 280)
                .onSubmit { commit() }
            HStack {
                Spacer()
                Button("Cancel") { renaming = false }
                Button("Name") { commit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(proposed.isEmpty)
            }
        }
        .padding(16)
    }

    private func commit() {
        if model.rename(row, to: proposed) { renaming = false }
    }

    /// The three identities, side by side and labelled, because the whole
    /// point is that they are not interchangeable.
    private var identities: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14,
             verticalSpacing: 4) {
            GridRow {
                /* Not "this Mac": on the one page that lists several
                   machines, that phrase means the Mac the app is running
                   on, which is the one machine this label cannot mean. */
                FieldLabel("Machine id", help:
                    "Stable. What you type to reach this machine, and what "
                    + "follows it across a reconnection.")
                Copyable(row.machineID)
            }
            if let session = row.liveSessionID {
                GridRow {
                    FieldLabel("Session id", help:
                        "This connection only. A caller holding it after "
                        + "this machine reconnects is told the session ended, "
                        + "rather than being answered by its successor.")
                    Copyable(session)
                }
            }
            GridRow {
                FieldLabel("Address", help:
                    "Where the host saw this machine. Authoritative for "
                    + "which socket, useless as a name.")
                Text(row.address).font(.callout.monospaced())
            }
        }
    }

    private var facts: some View {
        HStack(spacing: 14) {
            Fact("Connected", value: row.since
                .formatted(date: .omitted, time: .standard))
            if let version = row.version {
                Fact("Version", value: version)
            }
            if let build = row.build {
                Fact("Build", value: build)
            }
            if let os = row.operatingSystem {
                Fact("OS", value: os)
            }
            Fact("Agent access", value: Self.access(row.agentAccess))
        }
        .font(.callout)
    }

    /// Nil is "this build never said", which is not consent and is not a
    /// refusal — the wire keeps silence and "no" apart on purpose, so the
    /// page does too.
    private static func access(_ access: AgentIntegrationGuestAccess?)
        -> String {
        switch access {
        case .none: return "not stated"
        case .disabled: return "refused"
        case .readOnly: return "read-only"
        case .fullAccess: return "full"
        case .unrecognized(let raw): return "unrecognised (\(raw))"
        }
    }

    /// What an agent is told when it names this machine — the host's own
    /// answer, read back to the person whose Mac it is.
    private var addressing: some View {
        VStack(alignment: .leading, spacing: 4) {
            AddressingLine(prefix: "By machine id",
                           addressing: row.byMachineID)
            if let session = row.bySessionID {
                AddressingLine(prefix: "By session id", addressing: session)
            }
        }
        .padding(.top, 2)
    }
}

/// A machine the host remembers and cannot reach.
private struct RememberedRow: View {
    let row: ConnectionRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.machineID)
                    .font(.callout.weight(.semibold).monospaced())
                Text(row.name)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("last seen \(row.since.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            AddressingLine(prefix: "By machine id",
                           addressing: row.byMachineID)
            if let session = row.bySessionID {
                AddressingLine(prefix: "By session id", addressing: session)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6)))
    }
}

/// One addressing outcome, in the host's own words.
///
/// The sentence is quoted rather than paraphrased: it is exactly what the
/// agent on the other side was handed, and a person comparing the two must
/// not have to translate.
private struct AddressingLine: View {
    let prefix: String
    let addressing: ConnectionAddressing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(tint)
            Text("\(prefix): \(summary)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help(addressing.message ?? "This host answers for this machine.")
    }

    private var summary: String {
        switch addressing.outcome {
        case .answered: return "answered"
        case .notAddressed:
            return "refused — \(MachineNaming.thisMac) is driving another "
                + MachineNaming.commonNoun
        case .notConnected: return "refused — not connected"
        case .sessionEnded: return "refused — that session has ended"
        case .noGuestConnected:
            return "refused — no \(MachineNaming.commonNoun) is connected"
        case .unrecognised(let code): return "refused — \(code)"
        }
    }

    private var symbol: String {
        addressing.outcome == .answered
            ? "checkmark.circle" : "minus.circle"
    }

    private var tint: Color {
        addressing.outcome == .answered ? .green : .secondary
    }
}

private struct Badge: View {
    let text: String
    let tint: Color
    var help: String? = nil

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.18)))
            .foregroundStyle(tint)
            .help(help ?? text)
    }
}

private struct FieldLabel: View {
    let text: String
    let help: String

    init(_ text: String, help: String) {
        self.text = text
        self.help = help
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .help(help)
    }
}

/// A handle a person will have to type somewhere else, so it can be taken
/// rather than transcribed.
private struct Copyable: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.callout.monospaced())
                .textSelection(.enabled)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Copy")
        }
    }
}

private struct Fact: View {
    let label: String
    let value: String

    init(_ label: String, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
        }
    }
}
