import SwiftUI

struct HostRootView: View {
    let registry: ModuleRegistry
    @ObservedObject var state: HostAppState

    var body: some View {
        NavigationSplitView {
            List(registry.modules, selection: $state.selectedModuleID) { module in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(module.title)
                        Text(module.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                } icon: {
                    Image(systemName: module.symbol)
                }
                .tag(module.id)
                .padding(.vertical, 4)
            }
            .navigationTitle("Modules")
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
        } detail: {
            detail
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch state.selectedModuleID {
        case "screenshots":
            ScreenshotsModuleView(model: state.screenshots)
        case "console":
            ConsoleModuleView(model: state.console, listener: state.listener)
        case "settings":
            SettingsModuleView(settings: state.settings,
                               listener: state.listener,
                               onStart: { state.startListening() },
                               onStop: { state.stopListening() })
        default:
            VStack(spacing: 10) {
                Image(systemName: "questionmark.app")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("Module Unavailable")
                    .font(.title2.weight(.semibold))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
