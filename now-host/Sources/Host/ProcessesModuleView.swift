import SwiftUI

/// The connected Mac's process table, read over the wire. Read-only for
/// now — bringing a process forward or asking it to quit is the guest's
/// own page's job until process.front/.quit cross the wire.
struct ProcessesModuleView: View {
    @ObservedObject var model: ProcessesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            if model.canBrowse {
                list
            } else {
                disconnectedState
            }
            footer
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { if model.rows.isEmpty { model.refresh() } }
        // Refill the pane whenever the Mac (re)connects while it is open,
        // rather than waiting for a manual Refresh. On a first connect the
        // table is empty; on a reconnect after a redeploy the model has
        // already dropped the stale rows — so either way this reads the new
        // guest's table. onAppear covers a pane opened after the Mac was
        // already connected, and the two never both fire for one connect,
        // so there is no double fetch.
        .onChange(of: model.connection) { connection in
            if connection.canCapture { model.refresh() }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Processes")
                    .font(.largeTitle.weight(.semibold))
                Text("What is running on "
                     + "\(MachineNaming.sentence(model.connection)).")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch model.connection {
            case .connected(let name, _):
                Label(name, systemImage: "circle.fill")
                    .foregroundStyle(.green)
            case .connecting:
                Label("Connecting", systemImage: "circle.dotted")
                    .foregroundStyle(.orange)
            case .disconnected:
                Label("No \(MachineNaming.properNoun) Connected", systemImage: "circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var list: some View {
        List(selection: $model.selection) {
            ForEach(ProcessesModel.Group.allCases, id: \.self) { group in
                let rows = model.rows(in: group)
                if !rows.isEmpty {
                    Section(group.title) {
                        ForEach(rows) { entry in
                            ProcessRow(entry: entry).tag(entry.id)
                        }
                    }
                }
            }
        }
        .overlay {
            if model.rows.isEmpty {
                emptyState
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if model.isLoading {
                ProgressView()
                Text("Reading the process table…")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: model.lastError == nil
                      ? "cpu" : "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text(model.lastError ?? "Nothing is running.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 420)
    }

    private var disconnectedState: some View {
        VStack(spacing: 12) {
            Image(systemName: "cpu")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("No \(MachineNaming.properNoun) Connected")
                .font(.title2.weight(.semibold))
            Text("The \(MachineNaming.commonNoun) dials "
                 + "\(MachineNaming.thisMac); its running processes "
                 + "appear here once it does.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.lastError, model.canBrowse {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let note = model.bringToFrontNote(for: model.selectedEntry) {
                /* Beside the buttons, not only in a tooltip. A greyed control
                   with nothing next to it is indistinguishable from a bug,
                   and this one is dark for a reason nothing else on the page
                   says out loud. */
                Label(note, systemImage: "minus.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Button {
                    model.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(!model.canBrowse || model.isLoading)

                Divider().frame(height: 16)
                actionButtons

                if model.actionInFlight || model.isLoading {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if !model.rows.isEmpty {
                    Text(countLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The three drive verbs, one host→guest arrow. Enabled only when a
    /// process is selected that named itself with a PSN (an old guest that
    /// sends no PSN cannot be driven), and nothing else is in flight.
    ///
    /// **Bring to Front carries one more condition than the other two**, and
    /// it is a different kind of condition: whether fronting means anything
    /// for the selected process at all. A faceless background process has no
    /// windows and no menu bar, so there is nothing to bring forward — a fact
    /// about the item rather than about the Mac, which is why it comes from
    /// `GuestCapabilityGate` and not from a `kind == "background"` test
    /// written into this view.
    private var actionButtons: some View {
        let entry = model.selectedEntry
        let enabled = entry?.isDrivable == true
            && model.canBrowse && !model.actionInFlight
        let front = entry.map { model.bringToFrontGate($0) }
        return Group {
            Button {
                if let entry { model.bringToFront(entry) }
            } label: {
                Label("Bring to Front", systemImage: "arrow.up.forward.app")
            }
            .disabled(front?.isEnabled == false)
            .help(front?.explanation
                  ?? "Bring the selected process to the front over there.")
            Button {
                if let entry { model.askToQuit(entry) }
            } label: {
                Label("Ask to Quit", systemImage: "xmark.circle")
            }
            // The guest refuses to quit itself, and says so in the row
            // (isSelf) before being asked. Disabling here turns a refusal
            // the human would have read as an error into a button that
            // was never offered.
            .disabled(!enabled || entry?.isQuittable != true)
            Button {
                if let entry { model.screenshotApp(entry) }
            } label: {
                Label("Screenshot App", systemImage: "camera")
            }
        }
        .disabled(!enabled)
    }

    /// A snapshot's honest caption: how many, and that it is a snapshot.
    /// A process list is stale the instant it is read, so the readout
    /// says "as of", never implies it is live.
    private var countLine: String {
        let n = model.rows.count
        var line = "\(n) process\(n == 1 ? "" : "es")"
        if let at = model.fetchedAt {
            line += " · as of \(Self.time.string(from: at))"
        }
        return line
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .medium
        f.dateStyle = .none
        return f
    }()
}

/// One process, the way a person scans it: name and whether it is front,
/// then the quieter facts — kind, its two 4CCs, and how much of the
/// machine it was given.
private struct ProcessRow: View {
    let entry: ProcessEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 20)
                .foregroundStyle(entry.front == true ? Color.accentColor
                                                      : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(entry.name)
                    if entry.front == true {
                        Text("Front")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.18),
                                        in: Capsule())
                    }
                    // The row this connection is talking to. It is also
                    // the one that cannot be quit, so the badge is what
                    // explains the disabled button rather than leaving a
                    // person to click it and read a refusal.
                    if entry.isSelf == true {
                        Text("NOW")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.18),
                                        in: Capsule())
                    }
                }
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let size = entry.sizeLabel {
                Text(size)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch entry.kind {
        case "finder": return "macwindow.on.rectangle"
        case "background": return "gearshape"
        default: return "app"
        }
    }

    /// The kind, and the signature if the server sent one — joined so a
    /// row without 4CCs (the host's own list) does not show a stray dot.
    private var caption: String? {
        [entry.kindLabel, entry.signatureLabel]
            .compactMap { $0 }
            .joined(separator: "  ·  ")
    }
}
