import SwiftUI

@MainActor
final class ProcessesHostModuleRuntime: HostModuleRuntime {
    let model: ProcessesModel

    init(context: HostModuleContext) {
        model = ProcessesModel(listener: context.listener)
    }

    func focus(on connection: GuestConnectionState) {
        model.connection = connection
    }

    func guestLeft(_ key: GuestKey) {
        model.guestLeft(key)
    }
}

@MainActor
enum ProcessesHostModule {
    static let definition = HostModuleDefinition(
        descriptor: ModuleDescriptor(
            id: "processes",
            title: "Processes",
            symbol: "cpu",
            summary: "Running processes on "
                + "\(MachineNaming.simpleReference)"),
        makeRuntime: { ProcessesHostModuleRuntime(context: $0) },
        makeView: { _, runtime in
            guard let runtime = runtime as? ProcessesHostModuleRuntime else {
                return AnyView(ModuleUnavailableView(
                    reason: "The Processes runtime has the wrong type."))
            }
            return AnyView(ProcessesModuleView(model: runtime.model))
        })
}
