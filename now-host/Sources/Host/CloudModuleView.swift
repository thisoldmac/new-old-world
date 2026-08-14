import SwiftUI

/// What of this Mac's iCloud the classic Mac may browse. One row per
/// service from the provider registry — the same report a guest gets
/// from cloud.services, drawn for the person who can change it.
struct CloudModuleView: View {
    @ObservedObject var model: CloudModuleModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.services) { service in
                        row(service)
                        Divider()
                    }
                    footnote
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        }
        .onAppear { model.refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("iCloud").font(.headline)
                Spacer()
                Button("Refresh") { model.refresh() }
            }
            Text("What of \(MachineNaming.thisMac)'s iCloud "
                 + "\(MachineNaming.simpleReference) may browse. "
                 + "Each service answers on the wire exactly as it reads "
                 + "here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    @ViewBuilder
    private func row(_ service: CloudServiceEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol(for: service.service))
                .frame(width: 20)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(service.label).font(.body.weight(.medium))
                    stateBadge(service.state)
                }
                if let detail = service.detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            controls(service)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func controls(_ service: CloudServiceEntry) -> some View {
        if service.service == "drive" {
            /* The same toggle as every other row. Its semantics are the
               share: on points Sharing at iCloud Drive, off puts back
               the folder that was shared before. */
            Toggle("", isOn: Binding(
                get: { model.driveShared },
                set: { model.setDriveShared($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!model.driveAvailable)
        } else if model.hasSwitch(service.service) {
            HStack(spacing: 8) {
                if model.canRequestAccess(service.service) {
                    Button("Grant Access…") {
                        model.requestAccess(service.service)
                    }
                }
                if model.canOpenPrivacySettings(service.service) {
                    Button("Open Settings…") {
                        model.openPrivacySettings(service.service)
                    }
                }
                Toggle("", isOn: Binding(
                    get: { model.isEnabled(service.service) },
                    set: { model.setEnabled(service.service, $0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }

    private func stateBadge(_ state: String) -> some View {
        Text(state)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(badgeColor(state).opacity(0.15))
            .foregroundStyle(badgeColor(state))
            .clipShape(Capsule())
    }

    private func badgeColor(_ state: String) -> Color {
        switch state {
        case "serving": return .green
        case "off": return .gray
        case "no-access": return .orange
        default: return .red
        }
    }

    private func symbol(for service: String) -> String {
        switch service {
        case "drive": return "icloud"
        case "photos": return "photo.on.rectangle"
        case "contacts": return "person.crop.circle"
        default: return "questionmark.circle"
        }
    }

    private var footnote: some View {
        Text("Serving is per-service and answers any "
             + "\(MachineNaming.commonNoun) connected. "
             + "Drive travels through the file share. Photo download size "
             + "and destination belong to \(MachineNaming.simpleReference); "
             + "this Mac only provides the connection and macOS access.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
    }
}
