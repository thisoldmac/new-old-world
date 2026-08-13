import SwiftUI

struct GuestUpdateSection: View {
    let row: ConnectionRow
    @ObservedObject var model: ConnectionsModel
    @State private var confirmation: UpdateProvider.Component?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Software Updates")
                .font(.title3.weight(.semibold))
            Text("This host can replace only exact, validated artifacts "
                 + "from its bundled update catalog.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            GuestUpdateRow(row: row, component: .application,
                           model: model, onInstall: confirm)
            Divider()
            GuestUpdateRow(row: row, component: .extensionComponent,
                           model: model, onInstall: confirm)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .alert(confirmationTitle, isPresented: confirmationPresented) {
            Button("Replace", role: .destructive, action: installConfirmed)
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: {
            Text(confirmationMessage)
        }
    }

    private func confirm(_ component: UpdateProvider.Component) {
        confirmation = component
    }

    private var confirmationPresented: Binding<Bool> {
        Binding {
            confirmation != nil
        } set: { shown in
            if !shown { confirmation = nil }
        }
    }

    private var confirmationTitle: String {
        confirmation == .extensionComponent
            ? "Replace NOW Extension?" : "Replace the Guest App?"
    }

    private var confirmationMessage: String {
        if confirmation == .extensionComponent {
            return "The current Extension will be retained under an inert "
                + "recovery name. The new one becomes active only after "
                + "you restart the guest Mac."
        }
        return "The running guest app will be exchanged with the bundled "
            + "copy. It will quit and relaunch after installation finishes."
    }

    private func installConfirmed() {
        guard let component = confirmation else { return }
        confirmation = nil
        model.installUpdate(for: row, component: component)
    }
}

private struct GuestUpdateRow: View {
    let row: ConnectionRow
    let component: UpdateProvider.Component
    @ObservedObject var model: ConnectionsModel
    let onInstall: (UpdateProvider.Component) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(statusColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if case .replacement = availability {
                    Button(buttonTitle) { onInstall(component) }
                        .disabled(row.presence != .driving || isPending)
                }
            }
            if let notice = model.updateNotice(for: row,
                                               component: component) {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if row.presence == .connected,
                      case .replacement = availability {
                Text("Drive this Mac before installing its update.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var availability: UpdateProvider.Availability {
        model.updateAvailability(for: row, component: component)
    }

    private var isPending: Bool {
        model.updateIsPending(for: row, component: component)
    }

    private var title: String {
        component == .application ? "Guest application" : "NOW Extension"
    }

    private var buttonTitle: String {
        component == .application ? "Replace Guest App…"
                                  : "Replace NOW Extension…"
    }

    private var status: String {
        switch availability {
        case .unavailable:
            return "No validated artifact is bundled with this host."
        case .unknown(let offer):
            return "Host has \(offer.version) build "
                + "\(offer.build.prefix(12)); the guest did not report "
                + "an identity this host can compare."
        case .current(let offer):
            return "Matches host \(offer.version) build "
                + String(offer.build.prefix(12)) + "."
        case .hostOlder(let offer):
            return "Guest is newer than host artifact \(offer.version); "
                + "downgrade is not offered."
        case .replacement(let offer):
            return "Different build available: \(offer.version) build "
                + String(offer.build.prefix(12)) + "."
        }
    }

    private var statusColor: Color {
        if case .replacement = availability { return .orange }
        return .secondary
    }
}
