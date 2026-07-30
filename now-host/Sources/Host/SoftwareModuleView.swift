import SwiftUI

/// The connected Mac's installed software: the host face of the
/// software.* family. A domain picker and a search field over a split
/// view — the inventory table on the left, the selected item's detail
/// and its actions on the right — mirroring the guest's own Software
/// page. Launch and Show in Finder both act by the entry's path, the
/// listing's launch key, so the guest's name-ambiguity refusal can
/// never fire from this page.
struct SoftwareModuleView: View {
    @ObservedObject var model: SoftwareModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            if model.canBrowse {
                controls
                HSplitView {
                    table
                        .frame(minWidth: 320, idealWidth: 440,
                               maxWidth: .infinity)
                    detail
                        .frame(minWidth: 260, idealWidth: 300,
                               maxWidth: 460)
                }
                .frame(maxHeight: .infinity)
                footer
            } else {
                disconnectedState
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { if model.rows.isEmpty { model.refresh() } }
        .onChange(of: model.connection) { connection in
            if connection.canCapture { model.refresh() }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Software")
                    .font(.largeTitle.weight(.semibold))
                Text("What is installed on \(model.connection.peerLabel).")
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
                Label("No Mac Connected", systemImage: "circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Show", selection: $model.domain) {
                ForEach(SoftwareModel.Domain.allCases) { domain in
                    Text(domain.label).tag(domain)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            Spacer()
            TextField("Search", text: $model.search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
        }
    }

    // MARK: list

    private var table: some View {
        Table(model.visibleRows, selection: $model.selection) {
            TableColumn("Name") { entry in
                Text(entry.name)
            }
            TableColumn("Version") { entry in
                Text(entry.version ?? "–")
                    .foregroundStyle(entry.version == nil
                                     ? .secondary : .primary)
            }
            .width(min: 60, ideal: 70, max: 110)
            TableColumn("Size") { entry in
                Text(entry.sizeLabel ?? "")
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 70, max: 110)
            TableColumn("State") { entry in
                Text(entry.stateLabel)
                    .foregroundStyle(entry.running == true
                                     ? Color.green : .secondary)
            }
            .width(min: 60, ideal: 70, max: 110)
        }
        .overlay {
            if model.visibleRows.isEmpty {
                emptyState
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if model.isLoading {
                ProgressView()
                Text(model.domain == .apps
                     ? "Sweeping the disk for applications…"
                     : "Reading the \(model.domain.label)…")
                    .foregroundStyle(.secondary)
            } else if !model.search.isEmpty {
                Text("Nothing matches “\(model.search)”.")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: model.lastError == nil
                      ? "shippingbox" : "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text(model.lastError ?? "Nothing here.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 420)
    }

    // MARK: detail

    @ViewBuilder private var detail: some View {
        if let entry = model.selectedEntry {
            detailBody(entry)
        } else {
            detailEmpty
        }
    }

    private func detailBody(_ entry: SoftwareEntry) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                if let kind = entry.kindLabel {
                    Text(kind)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                factRow("Version", entry.version ?? "—")
                factRow("Size", entry.sizeLabel ?? "—")
                factRow("State", entry.stateLabel.isEmpty
                        ? "—" : entry.stateLabel)
                factColumn("Where", entry.path.isEmpty
                           ? "The Mac could not name this item’s path; it "
                             + "cannot be launched or revealed from here."
                           : entry.path)
            }
            Spacer(minLength: 0)
            detailActions(entry)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: .topLeading)
        .padding(16)
    }

    private func detailActions(_ entry: SoftwareEntry) -> some View {
        HStack(spacing: 10) {
            Button {
                model.launch(entry)
            } label: {
                Label("Launch", systemImage: "arrow.up.forward.app")
            }
            .disabled(!entry.isLaunchable || !model.canBrowse
                      || model.actionInFlight)

            Button {
                model.reveal(entry)
            } label: {
                Label("Show in Finder", systemImage: "magnifyingglass")
            }
            .disabled(!entry.isRevealable || !model.canBrowse
                      || model.actionInFlight)

            if model.actionInFlight {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var detailEmpty: some View {
        VStack(spacing: 8) {
            Image(systemName: "hand.point.up.left")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("Select an item to see its version, size, and where it "
                 + "lives — and to launch it or show it in the Finder.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
        }
    }

    private func factColumn(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var disconnectedState: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("No Mac Connected")
                .font(.title2.weight(.semibold))
            Text("The other Mac dials this one; what is installed on it "
                 + "appears here once it does.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.lastError, model.canBrowse {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let action = model.lastAction {
                Label(action, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let rows = model.sweepCost {
                sweepCostRows(rows)
            }
            if let note = model.note {
                // The listing's honest edge (a truncated inventory,
                // an unknown domain) in the guest's own words.
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button {
                    model.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(!model.canBrowse || model.isLoading)

                // What building the Applications list COSTS this Mac, as
                // opposed to what is in it. Expensive on purpose — the
                // guest sweeps its whole catalog twice — so it is a
                // deliberate click rather than part of Refresh.
                Button {
                    model.measureCatalogSearch()
                } label: {
                    Label("Measure Sweep Cost", systemImage: "stopwatch")
                }
                .disabled(!model.canBrowse || model.isLoading
                          || model.actionInFlight)
                .help("Times a whole-disk search for applications on the "
                      + "connected Mac — cold, then warm. Takes seconds, "
                      + "and up to 20 seconds per pass on a slow disk.")

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
    }

    /// The last sweep measurement, verbatim. Label and value as the Mac
    /// wrote them and in its order — including the rows that say the volume
    /// has no CatSearch, or that the sweep gave up before finishing, which
    /// are the cases where the answer is narrower rather than shorter.
    private func sweepCostRows(
        _ rows: [SoftwareModel.SweepRow]
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.label)
                        .frame(width: 96, alignment: .leading)
                        .foregroundStyle(.secondary)
                    Text(row.value)
                        .textSelection(.enabled)
                }
                .font(.system(.caption, design: .monospaced))
            }
        }
    }

    /// "8 of 205 · as of 14:02" — the search-narrowed count over the
    /// whole, and that the inventory is a snapshot.
    private var countLine: String {
        let shown = model.visibleRows.count
        let total = model.rows.count
        var line = shown == total
            ? "\(total) item\(total == 1 ? "" : "s")"
            : "\(shown) of \(total) shown"
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
