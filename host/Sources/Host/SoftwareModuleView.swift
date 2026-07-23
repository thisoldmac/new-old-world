import SwiftUI

/// The connected Mac's installed software: the host face of the
/// software.* family. A domain picker over a table, a search field that
/// filters the rows already fetched, and Launch by the entry's path —
/// the mirror of the guest's own Software page.
struct SoftwareModuleView: View {
    @ObservedObject var model: SoftwareModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            if model.canBrowse {
                controls
                table
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
            case .connected(let name):
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
        .frame(maxHeight: .infinity)
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

                Divider().frame(height: 16)

                Button {
                    if let entry = model.selectedEntry {
                        model.launch(entry)
                    }
                } label: {
                    Label("Launch", systemImage: "arrow.up.forward.app")
                }
                .disabled(model.selectedEntry?.isLaunchable != true
                          || !model.canBrowse || model.actionInFlight)

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
