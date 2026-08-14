import SwiftUI

private enum LogsHostModuleError: Error, CustomStringConvertible {
    case missingServices

    var description: String {
        "The host logging or continuity service is unavailable."
    }
}

/// Owns the Logs page's presentation boundary. The model remains an eager
/// application service because constructing it applies disk persistence before
/// the first event is written; the module runtime holds the page's reference.
@MainActor
final class LogsHostModuleRuntime: HostModuleRuntime {
    let model: LogsModel
    let continuity: MirrorContinuityController

    init(context: HostModuleContext) throws {
        guard let logs = context.logs, let continuity = context.continuity else {
            throw LogsHostModuleError.missingServices
        }
        model = logs
        self.continuity = continuity
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
                model: runtime.model, log: runtime.model.log,
                continuity: runtime.continuity))
        })
}
