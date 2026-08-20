import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Hardware dossier: the guest's census, run and read from this Mac. A
/// probe list on the left, the selected probe's rows on the right. It mirrors
/// the guest's own Hardware page - the same probes, the same [name, raw,
/// meaning] rows - but native to macOS, and it only ever requests.
struct CensusModuleView: View {
    @ObservedObject var model: CensusModuleModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.isConnected {
                HSplitView {
                    probeList
                        .frame(minWidth: 200, idealWidth: 240, maxWidth: 340)
                    detail
                        .frame(minWidth: 320, maxWidth: .infinity)
                }
            } else {
                disconnected
            }
        }
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hardware")
                        .font(.headline)
                    Text("Passive hardware census of "
                         + "\(MachineNaming.sentence(model.connection)).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isSweeping {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 4)
                }
                Button {
                    dumpROM()
                } label: {
                    Label("Dump ROM", systemImage: "memorychip")
                }
                .disabled(!model.isConnected || model.romDumpState.isRunning)
                Button {
                    model.runAll()
                } label: {
                    Label("Run Census", systemImage: "play.fill")
                }
                .disabled(!model.isConnected || model.isSweeping)
            }
            romDumpStatus
        }
        .padding(12)
    }

    @ViewBuilder
    private var romDumpStatus: some View {
        switch model.romDumpState {
        case .idle:
            EmptyView()
        case .writing:
            // No wire signal exists for this phase (a synchronous guest-side
            // File Manager read) — indeterminate is the honest picture.
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Reading the ROM into the guest Files share…")
            }
            .font(.caption).foregroundStyle(.secondary)
        case .transferring:
            VStack(alignment: .leading, spacing: 2) {
                if let progress = model.romDumpProgress, progress.expected > 0 {
                    ProgressView(value: progress.fraction)
                        .frame(maxWidth: 260)
                    Text("Transferring the ROM to this Mac… "
                         + byteCaption(progress))
                } else {
                    ProgressView().frame(maxWidth: 260)
                    Text("Transferring the ROM to this Mac…")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        case .saved(let url):
            HStack(spacing: 6) {
                Label("Saved \(url.lastPathComponent)",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .buttonStyle(.link)
            }
            .font(.caption)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red)
        }
    }

    /// "1.2/4.0 MB" — `received`/`expected` are already bytes.
    private func byteCaption(_ progress: GuestListener.CaptureProgress) -> String {
        let mb = 1_048_576.0
        return String(format: "%.1f/%.1f MB",
                      Double(progress.received) / mb, Double(progress.expected) / mb)
    }

    /// `NSSavePanel` for destination + filename, then hands off to
    /// `dumpROM(to:)`. One artifact shape (raw `.bin`) — no format picker.
    private func dumpROM() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.data]
        panel.directoryURL = model.romDumpDirectory
        panel.nameFieldStringValue = model.suggestedROMDumpURL.lastPathComponent
        if panel.runModal() == .OK, let url = panel.url {
            model.dumpROM(to: url)
        }
    }

    // MARK: probe list

    private var probeList: some View {
        List(selection: $model.selection) {
            ForEach(model.probes) { state in
                probeRow(state)
                    .tag(state.id)
            }
        }
        .listStyle(.sidebar)
    }

    private func probeRow(_ state: CensusProbeState) -> some View {
        HStack(spacing: 8) {
            OutcomeBadge(outcome: state.outcome, running: state.isRunning)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.probe.title)
                Text(subtitle(state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func subtitle(_ state: CensusProbeState) -> String {
        if state.isRunning { return "running…" }
        guard let outcome = state.outcome else { return "not run yet" }
        if outcome == "present" || outcome == "partial" {
            let n = state.rows.count
            let word = n == 1 ? "row" : "rows"
            return state.total.map { "\(n) of \($0) \(word)" } ?? "\(n) \(word)"
        }
        return state.note ?? outcome
    }

    // MARK: detail

    @ViewBuilder
    private var detail: some View {
        if let id = model.selection, let state = model.state(id: id) {
            VStack(alignment: .leading, spacing: 0) {
                detailHeader(state)
                Divider()
                detailBody(state)
            }
        } else {
            emptyState(symbol: "sidebar.left", title: "No probe selected",
                       message: "Select a probe for its rows.")
        }
    }

    private func detailHeader(_ state: CensusProbeState) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(state.probe.title).font(.headline)
                Text(state.probe.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.run(probeID: state.id)
            } label: {
                Label(state.hasRun ? "Rerun" : "Run", systemImage: "arrow.clockwise")
            }
            .disabled(!model.isConnected || state.isRunning)
        }
        .padding(12)
    }

    @ViewBuilder
    private func detailBody(_ state: CensusProbeState) -> some View {
        if state.isRunning && state.rows.isEmpty {
            ProgressView("Running \(state.probe.title)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !state.hasRun {
            VStack(spacing: 12) {
                emptyState(symbol: "play.circle", title: "Not run yet",
                           message: state.probe.summary)
                Button("Run \(state.probe.title)") { model.run(probeID: state.id) }
                    .disabled(!model.isConnected)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if state.rows.isEmpty {
            emptyState(symbol: "tray", title: outcomeTitle(state.outcome),
                       message: state.note ?? "The probe returned no rows.")
        } else {
            rowsTable(state)
        }
    }

    /// The project's plain empty-state: a glyph, a title, a sentence. Kept
    /// local so it works on macOS 13 (ContentUnavailableView is 14+).
    private func emptyState(symbol: String, title: String,
                            message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func rowsTable(_ state: CensusProbeState) -> some View {
        let items = state.rows.enumerated().map { RowItem(id: $0.offset, cells: $0.element) }
        let cols = state.probe.columns
        return Table(items) {
            TableColumn(cols.first ?? "Field") { Text($0.cell(0)) }
            TableColumn(cols.count > 1 ? cols[1] : "Raw") {
                Text($0.cell(1)).font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            TableColumn(cols.count > 2 ? cols[2] : "Meaning") { Text($0.cell(2)) }
        }
    }

    private func outcomeTitle(_ outcome: String?) -> String {
        switch outcome {
        case "absent": return "Absent"
        case "refused": return "Refused"
        case "failed": return "Failed"
        case "partial": return "Partial"
        default: return "No rows"
        }
    }

    private var disconnected: some View {
        emptyState(
            symbol: "cable.connector.slash",
            title: "No \(MachineNaming.properNoun) Connected",
            message: "The \(MachineNaming.commonNoun) connects to "
                + "\(MachineNaming.thisMac); this side only listens. The "
                + "census can be run once connected.")
    }
}

/// A row for the Table: rows arrive as [String] triples; this wraps one with
/// an identity and safe cell access (a caption row leaves raw/meaning empty).
private struct RowItem: Identifiable {
    let id: Int
    let cells: [String]
    func cell(_ i: Int) -> String { i < cells.count ? cells[i] : "" }
}

/// The outcome vocabulary as a dot: present is settled, absent is the machine
/// saying no, refused is us declining, failed is a fault. Never conflated.
private struct OutcomeBadge: View {
    let outcome: String?
    let running: Bool

    var body: some View {
        if running {
            ProgressView().controlSize(.small).scaleEffect(0.6)
        } else {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .font(.system(size: 11, weight: .semibold))
        }
    }

    private var symbol: String {
        switch outcome {
        case "present": return "checkmark.circle.fill"
        case "partial": return "circle.lefthalf.filled"
        case "absent": return "minus.circle"
        case "refused": return "hand.raised.circle"
        case "failed": return "exclamationmark.triangle.fill"
        case nil: return "circle.dotted"
        default: return "circle"
        }
    }

    private var color: Color {
        switch outcome {
        case "present": return .green
        case "partial": return .yellow
        case "absent": return .secondary
        case "refused": return .orange
        case "failed": return .red
        default: return .secondary
        }
    }
}
