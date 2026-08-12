import SwiftUI

@MainActor
final class WebHostModuleRuntime: HostModuleRuntime {
    let model: WebBridgeModel

    init(context: HostModuleContext) {
        model = WebBridgeModel(defaults: context.defaults)
    }

    func shutDown() {
        model.stop()
    }
}

@MainActor
enum WebHostModule {
    static let definition = HostModuleDefinition(
        descriptor: ModuleDescriptor(
            id: "web",
            title: "Web",
            symbol: "globe",
            summary: "Translate modern pages for a browser on "
                + "\(MachineNaming.simpleReference)",
            tier: .experimental),
        makeRuntime: { WebHostModuleRuntime(context: $0) },
        makeView: { _, runtime in
            guard let runtime = runtime as? WebHostModuleRuntime else {
                return AnyView(ModuleUnavailableView(
                    reason: "The Web runtime has the wrong type."))
            }
            return AnyView(WebModuleView(model: runtime.model))
        })
}
