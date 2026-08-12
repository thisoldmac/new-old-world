import SwiftUI

@MainActor
final class DiagnosticsHostModuleRuntime: HostModuleRuntime {
    let model: DiagnosticsModel

    init(context: HostModuleContext) {
        model = DiagnosticsModel(listener: context.listener)
    }

    func focus(on connection: GuestConnectionState) {
        model.connection = connection
    }

    func guestLeft(_ key: GuestKey) {
        model.guestLeft(key)
    }
}

@MainActor
enum DiagnosticsHostModule {
    static let definition = HostModuleDefinition(
        descriptor: ModuleDescriptor(
            id: "diagnostics",
            title: "Diagnostics",
            symbol: "stethoscope",
            summary: "Measure \(MachineNaming.possessive(nil)) screen "
                + "reads and file transfers",
            tier: .debug),
        makeRuntime: { DiagnosticsHostModuleRuntime(context: $0) },
        makeView: { _, runtime in
            guard let runtime = runtime as? DiagnosticsHostModuleRuntime else {
                return AnyView(ModuleUnavailableView(
                    reason: "The Diagnostics runtime has the wrong type."))
            }
            return AnyView(DiagnosticsModuleView(model: runtime.model))
        })
}
