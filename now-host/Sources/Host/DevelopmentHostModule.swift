import SwiftUI

private enum DevelopmentHostModuleError: Error, CustomStringConvertible {
    case missingAgentService

    var description: String {
        "Development's host agent service is unavailable."
    }
}

@MainActor
final class DevelopmentHostModuleRuntime: HostModuleRuntime {
    let model: DevelopmentModel

    init(context: HostModuleContext) throws {
        guard let agentIntegration = context.agentIntegration else {
            throw DevelopmentHostModuleError.missingAgentService
        }
        model = DevelopmentModel(
            store: try? ProjectStore(),
            readEnvironment: {
                await agentIntegration.developmentEnvironment()
            },
            performDevelopment: { request in
                await agentIntegration.development(request)
            })
    }
}

@MainActor
enum DevelopmentHostModule {
    static let definition = HostModuleDefinition(
        descriptor: ModuleDescriptor(
            id: "development",
            title: "Development",
            symbol: "hammer",
            summary: "Projects, toolchains, builds and runs for "
                + "\(MachineNaming.simpleReference)",
            tier: .experimental),
        makeRuntime: { try DevelopmentHostModuleRuntime(context: $0) },
        makeView: { _, runtime in
            guard let runtime = runtime as? DevelopmentHostModuleRuntime else {
                return AnyView(ModuleUnavailableView(
                    reason: "The Development runtime has the wrong type."))
            }
            return AnyView(DevelopmentModuleView(model: runtime.model))
        })
}
