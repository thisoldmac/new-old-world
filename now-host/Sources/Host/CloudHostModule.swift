import SwiftUI

@MainActor
final class CloudHostModuleRuntime: HostModuleRuntime {
    let model: CloudModuleModel

    init(context: HostModuleContext) {
        model = CloudModuleModel(
            listener: context.listener, defaults: context.defaults)
    }
}

@MainActor
enum CloudHostModule {
    static let definition = HostModuleDefinition(
        descriptor: ModuleDescriptor(
            id: "icloud",
            title: "iCloud",
            symbol: "icloud",
            summary: "What of \(MachineNaming.thisMac)'s iCloud "
                + "\(MachineNaming.simpleReference) may browse",
            tier: .experimental),
        makeRuntime: { CloudHostModuleRuntime(context: $0) },
        makeView: { _, runtime in
            guard let runtime = runtime as? CloudHostModuleRuntime else {
                return AnyView(ModuleUnavailableView(
                    reason: "The iCloud runtime has the wrong type."))
            }
            return AnyView(CloudModuleView(model: runtime.model))
        })
}
