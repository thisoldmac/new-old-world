import SwiftUI
import NOWAgentIntegration

/// Connections are an inventory on the left and the selected machine on the
/// right. A live row selection also moves the host's active request plane, so
/// the row, the sidebar guest menu, and every module always name one guest.
/// Remembered rows remain inspectable and removable but cannot be driven.
struct ConnectionsModuleView: View {
    @ObservedObject var model: ConnectionsModel
    @ObservedObject var settings: SettingsModel
    @ObservedObject var listener: GuestListener
    var onStart: () -> Void
    var onStop: () -> Void
    @State private var selectedID: String?
    @State private var adding = false

    var body: some View {
        HSplitView {
            connectionList
                .frame(minWidth: 210, idealWidth: 240, maxWidth: 300)
            detail
                .frame(minWidth: 460, maxWidth: .infinity,
                       maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { repairSelection() }
        .onChange(of: model.snapshot) { _ in repairSelection() }
        .onChange(of: listener.activeKey) { _ in
            guard !adding else { return }
            selectedID = model.snapshot.driving?.id
        }
    }

    private var connectionList: some View {
        VStack(spacing: 0) {
            List(selection: selection) {
                Section("Active") {
                    if model.snapshot.connected.isEmpty {
                        Text("No active connections")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.snapshot.connected) { row in
                            ConnectionListRow(row: row)
                                .tag(row.id)
                        }
                    }
                }
                if !model.snapshot.known.isEmpty {
                    Section("Remembered") {
                        ForEach(model.snapshot.known) { row in
                            ConnectionListRow(row: row)
                                .foregroundStyle(.secondary)
                                .tag(row.id)
                        }
                    }
                }
            }
            Divider()
            HStack(spacing: 4) {
                Button(action: beginAdding) {
                    Image(systemName: "plus")
                }
                .help("Add a guest")
                Button(action: removeSelection) {
                    Image(systemName: "minus")
                }
                .disabled(selectedRow == nil)
                .help("Remove the selected guest")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.bar)
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ConnectionLinkSection(
                        settings: settings, listener: listener,
                        onStart: onStart, onStop: onStop,
                        focusPort: adding,
                        selectedGuest: selectedRow?.key)
                    if let row = selectedRow {
                        ConnectionCard(row: row, model: model)
                        ConnectionListenerLog(
                            listener: listener,
                            sessionIDs: Set([
                                row.liveSessionID, row.lastSessionID
                            ].compactMap { $0 }))
                    } else {
                        addInstructions
                        ConnectionListenerLog(listener: listener)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Connections")
                .font(.largeTitle.weight(.semibold))
            Label(detailHeadline, systemImage: indicator.symbol)
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

    private var detailHeadline: String {
        if adding {
            return "Listen for a guest that is not attached yet"
        }
        guard let row = selectedRow else { return model.snapshot.headline }
        switch row.presence {
        case .driving: return "\(row.machineID) — attached to all modules"
        case .connected: return "\(row.machineID) — connected"
        case .known: return "\(row.machineID) — remembered, not connected"
        }
    }

    /// The same dot vocabulary the sidebar footer and the modules use, so
    /// one glance means the same thing wherever it lands.
    private var indicator: (symbol: String, tint: Color) {
        if let row = selectedRow {
            switch row.presence {
            case .driving: return ("circle.fill", .green)
            case .connected: return ("circle.fill", .secondary)
            case .known: return ("circle", .secondary)
            }
        }
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

    private var addInstructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add a Guest")
                .font(.title3.weight(.semibold))
            Text("Choose a port, start listening, then open NOW on the old "
                 + "machine and point it at \(MachineNaming.thisMac). It "
                 + "will appear under Active when its handshake completes.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var selection: Binding<String?> {
        Binding {
            selectedID
        } set: { id in
            adding = false
            selectedID = id
            guard let id,
                  let row = model.snapshot.rows.first(where: { $0.id == id }),
                  row.presence == .connected else { return }
            _ = model.drive(row)
        }
    }

    private var selectedRow: ConnectionRow? {
        guard let selectedID else { return nil }
        return model.snapshot.rows.first { $0.id == selectedID }
    }

    private func repairSelection() {
        guard !adding else { return }
        if selectedRow != nil { return }
        selectedID = model.snapshot.driving?.id ?? model.snapshot.rows.first?.id
    }

    private func beginAdding() {
        selectedID = nil
        adding = true
    }

    private func removeSelection() {
        guard let row = selectedRow, model.remove(row) else { return }
        selectedID = nil
        DispatchQueue.main.async { repairSelection() }
    }
}

private struct ConnectionListRow: View {
    let row: ConnectionRow

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: row.presence == .known
                  ? "desktopcomputer" : "desktopcomputer.and.macbook")
            VStack(alignment: .leading, spacing: 1) {
                Text(row.machineID)
                Text(row.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if row.presence == .driving {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .help("Attached to the host modules")
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
                Text(row.machineID)
                    .font(.title3.weight(.semibold).monospaced())
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

            Text(row.name)
                .foregroundStyle(.secondary)

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
        if row.presence != .known {
            HStack(spacing: 8) {
                if row.presence == .connected {
                    Button("Drive This One") { model.drive(row) }
                        .help("Every command, module and capture request "
                              + "goes to the machine chosen here. The "
                              + "others stay connected.")
                }
                Button(row.idIsAutoAssigned ? "Name…" : "Rename…") {
                    proposed = row.machineID
                    renaming = true
                }
                .help("The id an agent types to address this machine. "
                      + "Naming it is what makes it durable.")
            }
            .popover(isPresented: $renaming, arrowEdge: .bottom) {
                rename
            }
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
            Fact(row.presence == .known ? "Last seen" : "Connected",
                 value: row.since
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
