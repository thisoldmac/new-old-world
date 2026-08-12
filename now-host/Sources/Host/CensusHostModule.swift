import SwiftUI

@MainActor
final class CensusHostModuleRuntime: HostModuleRuntime {
    let model: CensusModuleModel

    init(context: HostModuleContext) {
        model = CensusModuleModel(listener: context.listener)
    }

    func focus(on connection: GuestConnectionState) {
        model.connection = connection
    }

    func guestLeft(_ key: GuestKey) {
        model.guestLeft(key)
    }
}

@MainActor
enum CensusHostModule {
    static let definition = HostModuleDefinition(
        descriptor: ModuleDescriptor(
            id: "census",
            title: "Hardware",
            symbol: "cpu",
            summary: "\(MachineNaming.properNoun)’s own account of its "
                + "hardware, probe by probe"),
        makeRuntime: { CensusHostModuleRuntime(context: $0) },
        makeView: { _, runtime in
            guard let runtime = runtime as? CensusHostModuleRuntime else {
                return AnyView(ModuleUnavailableView(
                    reason: "The Hardware runtime has the wrong type."))
            }
            return AnyView(CensusModuleView(model: runtime.model))
        })
}
