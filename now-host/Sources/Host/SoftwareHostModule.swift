import SwiftUI

@MainActor
final class SoftwareHostModuleRuntime: HostModuleRuntime {
    let model: SoftwareModel

    init(context: HostModuleContext) {
        model = SoftwareModel(listener: context.listener)
    }

    func focus(on connection: GuestConnectionState) {
        model.connection = connection
    }

    func guestLeft(_ key: GuestKey) {
        model.guestLeft(key)
    }
}

@MainActor
enum SoftwareHostModule {
    static let definition = HostModuleDefinition(
        descriptor: ModuleDescriptor(
            id: "software",
            title: "Software",
            symbol: "shippingbox",
            summary: "What is installed on "
                + "\(MachineNaming.simpleReference), and launching it"),
        makeRuntime: { SoftwareHostModuleRuntime(context: $0) },
        makeView: { _, runtime in
            guard let runtime = runtime as? SoftwareHostModuleRuntime else {
                return AnyView(ModuleUnavailableView(
                    reason: "The Software runtime has the wrong type."))
            }
            return AnyView(SoftwareModuleView(model: runtime.model))
        })
}
