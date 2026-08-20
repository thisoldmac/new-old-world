import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The machine shelf owns this hero. It reads the same guest-scoped models as
/// the full Hardware and Processes tabs, turning their current snapshots into
/// a useful first page without introducing another polling owner.
struct MachineOverviewView: View {
    @ObservedObject var monitor: GuestStatusMonitor
    let state: HostAppState

    var body: some View {
        if let census = state.moduleRuntime(
            for: CensusHostModule.definition.descriptor.id,
            as: CensusHostModuleRuntime.self)?.model,
           let processes = state.moduleRuntime(
            for: ProcessesHostModule.definition.descriptor.id,
            as: ProcessesHostModuleRuntime.self)?.model {
            MachineOverviewContent(
                monitor: monitor,
                connection: state.currentConnection,
                census: census,
                processes: processes)
        } else {
            ModuleUnavailableView(
                reason: "The machine overview could not load its data sources.")
        }
    }
}

private struct MachineOverviewContent: View {
    @ObservedObject var monitor: GuestStatusMonitor
    let connection: GuestConnectionState
    @ObservedObject var census: CensusModuleModel
    @ObservedObject var processes: ProcessesModel
    @StateObject private var photo = GuestPhotoModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                MachineOverviewHeader(
                    status: monitor.status,
                    guest: connection.key?.machine,
                    photo: photo)
                MachineHardwareSummary(probe: overviewProbe)
                MachineApplicationsSummary(
                    applications: applications,
                    isLoading: processes.isLoading,
                    error: processes.lastError,
                    isConnected: processes.canBrowse)
            }
            .padding(24)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: connection.key?.machine) {
            monitor.refresh()
            photo.focus(on: connection.key?.machine)
            loadSnapshotsIfNeeded()
        }
    }

    private var overviewProbe: CensusProbeState? {
        census.state(id: "overview")
    }

    private var applications: [MachineOverviewApplication] {
        MachineOverviewPresentation.applications(from: processes.rows)
    }

    private func loadSnapshotsIfNeeded() {
        if let overviewProbe,
           !overviewProbe.hasRun, !overviewProbe.isRunning,
           census.isConnected {
            census.run(probeID: overviewProbe.id)
        }
        if processes.canBrowse, processes.rows.isEmpty,
           !processes.isLoading {
            processes.refresh()
        }
    }
}

private struct MachineOverviewHeader: View {
    let status: GuestStatus
    let guest: GuestID?
    @ObservedObject var photo: GuestPhotoModel

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            MachinePhotoView(image: photo.image, connected: status.isConnected)
                .frame(width: 180, height: 128)

            VStack(alignment: .leading, spacing: 7) {
                Text(status.machineShelfTitle)
                    .font(.largeTitle.weight(.semibold))
                Text(status.menuLine)
                    .foregroundStyle(.secondary)
                Text("Current state, from the data in the tabs above.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)

                HStack(spacing: 8) {
                    Button(photo.image == nil
                           ? "Choose Photo…" : "Change Photo…") {
                        choosePhoto()
                    }
                    .disabled(guest == nil)
                    if photo.image != nil {
                        Button("Remove", role: .destructive) {
                            photo.removePhoto()
                        }
                    }
                }
                .padding(.top, 5)

                if let error = photo.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .nowGlassPanel()
    }

    private func choosePhoto() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Photo for This Mac"
        panel.prompt = "Choose Photo"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        photo.importPhoto(from: url)
    }
}

private struct MachinePhotoView: View {
    let image: NSImage?
    let connected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                VStack(spacing: 8) {
                    Image(systemName: connected
                          ? "desktopcomputer" : "desktopcomputer.trianglebadge.exclamationmark")
                        .font(.system(size: 38, weight: .medium))
                    Text("Add a photo")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.separator.opacity(0.45), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(image == nil
                            ? "No custom Mac photo" : "Custom Mac photo")
    }
}

private struct MachineHardwareSummary: View {
    let probe: CensusProbeState?

    var body: some View {
        MachineOverviewCard(title: "Hardware Overview", symbol: "cpu") {
            if let probe, probe.isRunning {
                MachineOverviewLoadingRow(label: "Reading hardware…")
            } else if let probe, !probe.rows.isEmpty {
                let sections = MachineOverviewPresentation.factSections(
                    from: probe.rows)
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(sections) { section in
                        MachineHardwareFactSection(section: section)
                    }
                }
            } else if let note = probe?.note, !note.isEmpty {
                MachineOverviewEmptyState(text: note)
            } else {
                MachineOverviewEmptyState(
                    text: "Connect \(MachineNaming.simpleReference) for "
                        + "its hardware overview.")
            }
        }
    }
}

private struct MachineHardwareFactSection: View {
    let section: MachineOverviewFactSection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = section.title {
                Text(title)
                    .font(.headline)
            }
            ForEach(section.facts) { fact in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(fact.label)
                        .foregroundStyle(.secondary)
                        .frame(width: 120, alignment: .leading)
                    Text(fact.value)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .font(.callout)
            }
        }
    }
}

private struct MachineApplicationsSummary: View {
    let applications: [MachineOverviewApplication]
    let isLoading: Bool
    let error: String?
    let isConnected: Bool

    var body: some View {
        MachineOverviewCard(title: "Running Applications",
                            symbol: "macwindow") {
            if isLoading && applications.isEmpty {
                MachineOverviewLoadingRow(label: "Reading processes…")
            } else if !applications.isEmpty {
                VStack(spacing: 0) {
                    ForEach(applications) { application in
                        MachineApplicationRow(process: application.process)
                        if application.id != applications.last?.id {
                            Divider()
                        }
                    }
                }
            } else if let error, !error.isEmpty {
                MachineOverviewEmptyState(text: error)
            } else {
                MachineOverviewEmptyState(text: isConnected
                    ? "No foreground applications reported."
                    : "Connect \(MachineNaming.simpleReference) for its "
                        + "running applications.")
            }
        }
    }
}

private struct MachineApplicationRow: View {
    let process: ProcessEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: process.kind == "finder"
                  ? "macwindow" : "app")
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            Text(process.name)
                .lineLimit(1)
            if process.front ?? false {
                Text("Frontmost")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.secondary.opacity(0.12)))
            }
            Spacer(minLength: 0)
            if let size = process.sizeKB {
                Text("\(size.formatted()) KB")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }
}

private struct MachineOverviewCard<Content: View>: View {
    let title: LocalizedStringKey
    let symbol: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol)
                .font(.title3.weight(.semibold))
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
        }
    }
}

private struct MachineOverviewLoadingRow: View {
    let label: LocalizedStringKey

    var body: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small)
            Text(label).foregroundStyle(.secondary)
        }
    }
}

private struct MachineOverviewEmptyState: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
