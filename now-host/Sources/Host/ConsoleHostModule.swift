import SwiftUI

@MainActor
final class ConsoleHostModuleRuntime: HostModuleRuntime {
    let model: ConsoleModel
    let listener: GuestListener

    init(context: HostModuleContext) {
        listener = context.listener
        model = ConsoleModel(listener: context.listener)
    }

    func focus(on connection: GuestConnectionState) {
        model.focus(on: connection)
        if connection.key == nil {
            model.forgetGuest()
        }
    }

    func runHelp() {
        model.runHelp()
    }
}

/// Console's descriptor, state, lifecycle and view factory move as one static
/// unit. The application menu may ask its runtime to run Help, but it does not
/// own the console model or participate in its guest-focus lifecycle.
@MainActor
enum ConsoleHostModule {
    static let definition = HostModuleDefinition(
        descriptor: ModuleDescriptor(
            id: "console",
            title: "Console",
            symbol: "terminal",
            summary: "A command line on \(MachineNaming.simpleReference)"),
        makeRuntime: { ConsoleHostModuleRuntime(context: $0) },
        makeView: { _, runtime in
            guard let runtime = runtime as? ConsoleHostModuleRuntime else {
                return AnyView(ModuleUnavailableView(
                    reason: "The Console runtime has the wrong type."))
            }
            return AnyView(ConsoleModuleView(
                model: runtime.model,
                listener: runtime.listener))
        })
}
