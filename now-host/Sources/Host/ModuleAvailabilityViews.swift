import SwiftUI

/// Adds the shell's connection explanation without changing module ownership.
struct ModuleAvailabilityShell<Content: View>: View {
    let presentation: ModuleAvailabilityPresentation
    let moduleTitle: String
    let status: GuestStatus
    let showConnections: () -> Void
    let startListening: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        switch presentation.shellTreatment {
        case .none:
            content()
        case .staleBanner:
            VStack(spacing: 0) {
                ModuleOfflineBanner(showConnections: showConnections)
                content()
            }
        case .unavailable:
            ModuleUnavailableView(
                moduleTitle: moduleTitle,
                status: status,
                showConnections: showConnections,
                startListening: startListening)
        }
    }
}

private struct ModuleOfflineBanner: View {
    let showConnections: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .foregroundStyle(.secondary)
            Text("No Mac connected. Saved information remains visible where "
                 + "this module has it; live actions are unavailable.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Connections", action: showConnections)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct ModuleUnavailableView: View {
    let moduleTitle: String
    let status: GuestStatus
    let showConnections: () -> Void
    let startListening: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "cable.connector.slash")
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
            Text("Connect a Mac for \(moduleTitle)")
                .font(.title2.weight(.semibold))
            Text("This page asks the selected Mac directly, so it has no "
                 + "offline information to show.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            recoveryButton
        }
        .padding(28)
        .nowGlassPanel()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var recoveryButton: some View {
        switch status {
        case .notListening:
            Button("Start Listening", action: startListening)
                .buttonStyle(.borderedProminent)
        case .waiting, .failed:
            Button("Connections", action: showConnections)
                .buttonStyle(.borderedProminent)
        case .connected:
            EmptyView()
        }
    }
}
