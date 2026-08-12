import SwiftUI

@MainActor
private final class NetworkingHostModuleRuntime: HostModuleRuntime {
    let model: NetworkingModel

    init(context: HostModuleContext) {
        model = NetworkingModel(listener: context.listener)
    }

    func focus(on connection: GuestConnectionState) {
        model.connection = connection
    }

    func guestLeft(_ key: GuestKey) {
        model.guestLeft(key)
    }
}

/// The statically linked composition root for Networking. Module metadata,
/// runtime ownership and view construction move together in this file; the
/// model and view remain separately testable implementation details.
@MainActor
enum NetworkingHostModule {
    static let definition = HostModuleDefinition(
        descriptor: ModuleDescriptor(
            id: "networking",
            title: "Networking",
            symbol: "network",
            summary: "What \(MachineNaming.simpleReference) says about "
                + "its link, address and network hardware",
            tier: .core),
        makeRuntime: { NetworkingHostModuleRuntime(context: $0) },
        makeView: { _, runtime in
            guard let runtime = runtime as? NetworkingHostModuleRuntime else {
                return AnyView(ModuleUnavailableView(
                    reason: "The Networking runtime has the wrong type."))
            }
            return AnyView(NetworkingModuleView(model: runtime.model))
        })
}
