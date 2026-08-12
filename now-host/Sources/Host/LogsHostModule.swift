import SwiftUI

private enum LogsHostModuleError: Error, CustomStringConvertible {
    case missingService

    var description: String {
        "The host logging service is unavailable."
    }
}

/// Owns the Logs page's presentation boundary. The model remains an eager
/// application service because constructing it applies disk persistence before
/// the first event is written; the module runtime holds the page's reference.
@MainActor
final class LogsHostModuleRuntime: HostModuleRuntime {
    let model: LogsModel

    init(context: HostModuleContext) throws {
        guard let logs = context.logs else {
            throw LogsHostModuleError.missingService
        }
        model = logs
    }
}

@MainActor
enum LogsHostModule {
    static let definition = HostModuleDefinition(
        descriptor: ModuleDescriptor(
            id: "logs",
            title: "Logs",
            symbol: "text.alignleft",
            summary: "What \(MachineNaming.thisMac) has recorded happening",
            placement: .footer,
            tier: .debug),
        makeRuntime: { try LogsHostModuleRuntime(context: $0) },
        makeView: { _, runtime in
            guard let runtime = runtime as? LogsHostModuleRuntime else {
                return AnyView(ModuleUnavailableView(
                    reason: "The Logs runtime has the wrong type."))
            }
            return AnyView(LogsModuleView(
                model: runtime.model, log: runtime.model.log))
        })
}
