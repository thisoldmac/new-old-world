import SwiftUI

private enum ChatHostModuleError: Error, CustomStringConvertible {
    case missingServices

    var description: String {
        "Chat's host services are unavailable."
    }
}

@MainActor
final class ChatHostModuleRuntime: HostModuleRuntime {
    let model: ChatModuleModel
    private let listener: GuestListener

    init(context: HostModuleContext) throws {
        guard let agentIntegration = context.agentIntegration,
              let guestFiles = context.guestFiles else {
            throw ChatHostModuleError.missingServices
        }
        listener = context.listener
        model = ChatModuleModel(
            agentIntegration: agentIntegration,
            guestFiles: guestFiles,
            agentActivity: context.agentActivity,
            guestScreen: context.guestScreen,
            defaults: context.defaults,
            chatStore: try? ChatStore())
        listener.chatService = model.wireService
    }

    func shutDown() {
        listener.chatService = nil
    }
}

@MainActor
enum ChatHostModule {
    static let definition = HostModuleDefinition(
        descriptor: ModuleDescriptor(
            id: "chat",
            title: "Chat",
            symbol: "bubble.left.and.bubble.right",
            summary: "A model with access to "
                + "\(MachineNaming.simpleReference)",
            tier: .experimental),
        makeRuntime: { try ChatHostModuleRuntime(context: $0) },
        makeView: { _, runtime in
            guard let runtime = runtime as? ChatHostModuleRuntime else {
                return AnyView(ModuleUnavailableView(
                    reason: "The Chat runtime has the wrong type."))
            }
            return AnyView(ChatModuleView(model: runtime.model))
        })
}
