import SwiftUI

/// The machine shelf owns this hero. It summarizes the subject of its tabs
/// without pretending to be another registered module.
struct MachineOverviewView: View {
    @ObservedObject var monitor: GuestStatusMonitor
    let modules: [ModuleDescriptor]
    let selectModule: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                MachineOverviewHeader(status: monitor.status)
                MachineOverviewModuleGrid(
                    modules: modules,
                    selectModule: selectModule)
            }
            .padding(24)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { monitor.refresh() }
    }
}

private struct MachineOverviewHeader: View {
    let status: GuestStatus

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: status.isConnected
                  ? "desktopcomputer"
                  : "desktopcomputer.trianglebadge.exclamationmark")
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(status.isConnected
                                 ? Color.accentColor : Color.secondary)
                .frame(width: 54, height: 54)
                .background(.regularMaterial,
                            in: RoundedRectangle(cornerRadius: 13,
                                                 style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(status.machineShelfTitle)
                    .font(.largeTitle.weight(.semibold))
                Text(status.menuLine)
                    .foregroundStyle(.secondary)
                Text("Hardware, software, running processes, and diagnostics in one place.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 3)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .nowGlassPanel()
    }
}

private struct MachineOverviewModuleGrid: View {
    let modules: [ModuleDescriptor]
    let selectModule: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)],
                  spacing: 12) {
            ForEach(modules) { module in
                MachineOverviewModuleCard(module: module) {
                    selectModule(module.id)
                }
            }
        }
    }
}

private struct MachineOverviewModuleCard: View {
    let module: ModuleDescriptor
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: module.symbol)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(module.title)
                        .font(.headline)
                    Text(module.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 100,
                   alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5))
    }
}
