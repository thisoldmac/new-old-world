import SwiftUI

@MainActor
final class WebHostModuleRuntime: HostModuleRuntime {
    let model: WebBridgeModel
    /// `{ context.showSettings(.web) }`, captured once at construction —
    /// the page's "Settings…" button for compatibility, safety and
    /// start-automatically, all moved to Settings.
    let openSettings: () -> Void
    private let service: WebWireService
    private weak var listener: GuestListener?

    init(context: HostModuleContext) {
        model = WebBridgeModel(defaults: context.defaults)
        service = WebWireService(model: model)
        listener = context.listener
        context.listener.webService = service
        openSettings = { context.showSettings(.web) }
    }

    func shutDown() {
        if listener?.webService === service { listener?.webService = nil }
        model.stop()
    }

    func guestLeft(_ key: GuestKey) {
        service.sessionClosed(key: key)
    }
}

@MainActor
enum WebHostModule {
    static let definition = HostModuleDefinition(
        descriptor: ModuleDescriptor(
            id: "web",
            title: "Web Proxy",
            symbol: "globe",
            summary: "Page translation for a browser on "
                + "\(MachineNaming.simpleReference)",
            tier: .experimental),
        makeRuntime: { WebHostModuleRuntime(context: $0) },
        makeView: { _, runtime in
            guard let runtime = runtime as? WebHostModuleRuntime else {
                return AnyView(ModuleUnavailableView(
                    reason: "The Web runtime has the wrong type."))
            }
            return AnyView(WebModuleView(model: runtime.model,
                                         openSettings: runtime.openSettings))
        })
}
