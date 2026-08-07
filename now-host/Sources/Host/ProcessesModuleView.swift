import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The connected Mac's process table, read over the wire: the list on the
/// left, and everything about ONE process on the right.
///
/// The split is what lets the per-process controls stop being a bottom bar.
/// A row of buttons under a table names no subject — it is only ever "the
/// selection", read from a highlight several inches away — whereas beside
/// the process's own facts each button plainly belongs to the thing above
/// it. The pane also has somewhere to put a picture now, which is why a
/// capture no longer sends the reader to another page to find it.
struct ProcessesModuleView: View {
    @ObservedObject var model: ProcessesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            if model.canBrowse {
                HSplitView {
                    list
                        .frame(minWidth: 280, idealWidth: 380)
                    details
                        .frame(minWidth: 300)
                }
                .frame(maxHeight: .infinity)
            } else {
                disconnectedState
            }
            footer
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        // The pane opened after the Mac was already connected. A (re)connect
        // while it is open is the MODEL's to notice — it hears the state
        // change first and reads the new table itself. This used to be an
        // `.onChange(of: model.connection)` here as well, so every guest
        // switch fetched twice.
        .onAppear { if model.rows.isEmpty { model.refresh() } }
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

    /// What is left in the bottom bar once the per-process controls have
    /// moved: only the things that are about the TABLE — reading it again,
    /// how many rows it holds, and when it was read.
    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                model.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(!model.canBrowse || model.isLoading)

            if model.isLoading {
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

    // MARK: - The details side

    /// One subject at a time, and never two panes deep: either the process,
    /// or a picture of it. The preview REPLACES the details rather than
    /// stacking under them, which is what makes the X a complete answer —
    /// there is exactly one thing to close and one place it returns to.
    @ViewBuilder
    private var details: some View {
        Group {
            if let shot = model.preview {
                preview(shot)
            } else {
                switch model.subject {
                case .nothing:
                    noSelection
                case .running(let entry):
                    detailBody(entry, stillRunning: true)
                case .gone(let entry):
                    detailBody(entry, stillRunning: false)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: .topLeading)
        .padding(.leading, 18)
    }

    private var noSelection: some View {
        VStack(spacing: 8) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("Select a process to see what it is and drive it.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            // With no process picked there is no other pane to carry a
            // failure, and the bottom bar is only about the table now.
            if let error = model.lastError, model.canBrowse {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detailBody(_ entry: ProcessEntry,
                            stillRunning: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name)
                        .font(.title2.weight(.semibold))
                    Text(entry.kindLabel)
                        .foregroundStyle(.secondary)
                }
                if !stillRunning {
                    /* The list repainted and this process was not in it. Say
                       that, rather than emptying the pane — an empty pane
                       reads as a lost selection, which is a bug, and this is
                       not one. The facts below are the last ones that were
                       true, and every control that would drive them is dark. */
                    Label("No longer running on "
                          + "\(MachineNaming.sentence(model.connection)). "
                          + "These are the last facts it reported.",
                          systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                facts(entry)
                Divider()
                controls(entry, stillRunning: stillRunning)
                if let error = model.lastError, model.canBrowse {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func facts(_ entry: ProcessEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fact("Kind", entry.kindLabel)
            if let signature = entry.signatureLabel {
                fact("Signature", signature)
            }
            if let size = entry.sizeLabel { fact("Partition", size) }
            fact("Frontmost", entry.front == true ? "Yes" : "No")
            if entry.isSelf == true {
                fact("This connection", "Yes — it is NOW itself")
            }
            // Absent, not zero: a responder that predates the field sends no
            // PSN, and that is exactly why the drive buttons are dark.
            fact("Serial number", entry.isDrivable
                 ? "\(entry.psnHigh ?? 0):\(entry.psnLow ?? 0)"
                 : "Not reported")
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
        }
    }

    /// The three drive verbs, one host→guest arrow, beside the process they
    /// drive. Enabled only when the selected process named itself with a PSN
    /// (an old guest that sends no PSN cannot be driven), is still in the
    /// last listing, and nothing else is in flight.
    ///
    /// **Bring to Front carries one more condition than the other two**, and
    /// it is a different kind of condition: whether fronting means anything
    /// for this process at all. A faceless background process has no windows
    /// and no menu bar, so there is nothing to bring forward — a fact about
    /// the item rather than about the Mac, which is why it comes from
    /// `GuestCapabilityGate` and not from a `kind == "background"` test
    /// written into this view.
    private func controls(_ entry: ProcessEntry,
                          stillRunning: Bool) -> some View {
        let enabled = entry.isDrivable && model.canBrowse
            && !model.actionInFlight && stillRunning
        // One decision, spent on the button and on the sentence beside it —
        // and none at all for a process that is no longer there, which is
        // not a case the gate has an opinion about.
        let front = (stillRunning ? entry : nil).map {
            model.bringToFrontGate($0)
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    model.bringToFront(entry)
                } label: {
                    Label("Bring to Front", systemImage: "arrow.up.forward.app")
                }
                .disabled(!enabled || front?.isEnabled == false)
                .help(front?.explanation
                      ?? "Bring this process to the front over there.")
                Button {
                    model.askToQuit(entry)
                } label: {
                    Label("Ask to Quit", systemImage: "xmark.circle")
                }
                // The guest refuses to quit itself, and says so in the row
                // (isSelf) before being asked. Disabling here turns a refusal
                // the human would have read as an error into a button that
                // was never offered.
                .disabled(!enabled || entry.isQuittable != true)
                if model.actionInFlight {
                    ProgressView().controlSize(.small)
                }
            }
            if let note = model.bringToFrontNote(for: entry) {
                /* Beside the button, not only in a tooltip. A greyed control
                   with nothing next to it is indistinguishable from a bug,
                   and this one is dark for a reason nothing else on the page
                   says out loud. */
                Label(note, systemImage: "minus.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            captureControls(entry, enabled: enabled)
        }
    }

    /// Depth beside the shutter, because it is the one setting that changes
    /// what comes back. `CaptureDepth` is the Screen module's own enum —
    /// there is one notion of bit depth in this app, chosen per page.
    private func captureControls(_ entry: ProcessEntry,
                                 enabled: Bool) -> some View {
        HStack(spacing: 10) {
            Button {
                model.screenshotApp(entry)
            } label: {
                Label("Screenshot App", systemImage: "camera")
            }
            .disabled(!enabled || model.isCapturing)
            Picker("Depth", selection: $model.captureDepth) {
                ForEach(CaptureDepth.allCases) { depth in
                    Text(depth.title).tag(depth)
                }
            }
            .labelsHidden()
            .frame(width: 100)
            .disabled(model.isCapturing)
            if model.isCapturing {
                ProgressView().controlSize(.small)
            }
        }
    }

    // MARK: - The preview state

    private func preview(_ shot: ScreenshotRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.previewOf ?? "Screenshot")
                        .font(.title3.weight(.semibold))
                    Text("\(shot.width) × \(shot.height) · "
                         + "\(shot.format.depth)-bit")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // On top of the picture's own corner in spirit, and first in
                // the reading order: the way back is never something a person
                // has to look for.
                Button {
                    model.dismissPreview()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close the screenshot and go back to the process")
                .keyboardShortcut(.cancelAction)
            }
            Image(decorative: shot.image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .border(Color.secondary.opacity(0.3))
            HStack(spacing: 10) {
                Button("Save as PNG…") { savePreview() }
                Button("Copy") { model.copyPreview() }
                Spacer()
                Text(shot.capturedAt,
                     format: .dateTime.hour().minute().second())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func savePreview() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = model.suggestedPreviewName
        if panel.runModal() == .OK, let url = panel.url {
            model.savePreview(to: url)
        }
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
