import SwiftUI

private enum SettingsHostModuleError: Error, CustomStringConvertible {
    case missingServices

    var description: String {
        "The host connection services are unavailable."
    }
}

/// Owns the Connections page and its roster model. The listener, persisted
/// settings, and onboarding server remain application services because they
/// are active at launch and during app termination without the page open.
@MainActor
final class SettingsHostModuleRuntime: HostModuleRuntime {
    let model: ConnectionsModel
    let settings: SettingsModel
    let listener: GuestListener
    let onboarding: OnboardingPortal
    let localNetworkAccess: LocalNetworkAccessController
    let startListening: () -> Void
    let stopListening: () -> Void

    init(context: HostModuleContext) throws {
        guard let settings = context.settings,
              let onboarding = context.onboarding,
              let addressing = context.agentIntegration else {
            throw SettingsHostModuleError.missingServices
        }
        self.settings = settings
        self.onboarding = onboarding
        localNetworkAccess = context.localNetworkAccess
        listener = context.listener
        startListening = context.startListening
        stopListening = context.stopListening
        model = ConnectionsModel(
            listener: context.listener,
            addressing: addressing,
            select: context.selectGuest,
            basePort: { [settings] in settings.listenPort })
    }
}

@MainActor
enum SettingsHostModule {
    static let definition = HostModuleDefinition(
        descriptor: ModuleDescriptor(
            id: "settings",
            title: "Connections",
            symbol: "network",
            summary: "The port \(MachineNaming.thisMac) listens on, and "
                + "which \(MachineNaming.properNounPlural) are on it",
            placement: .footer,
            showsLinkStatus: true),
        makeRuntime: { try SettingsHostModuleRuntime(context: $0) },
        makeView: { _, runtime in
            guard let runtime = runtime as? SettingsHostModuleRuntime else {
                return AnyView(ModuleUnavailableView(
                    reason: "The Connections runtime has the wrong type."))
            }
            return AnyView(ConnectionsModuleView(
                model: runtime.model,
                settings: runtime.settings,
                listener: runtime.listener,
                onboarding: runtime.onboarding,
                localNetworkAccess: runtime.localNetworkAccess,
                onStart: runtime.startListening,
                onStop: runtime.stopListening))
        })
}
