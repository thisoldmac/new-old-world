import Foundation
import NOWAgentIntegration

/// Drives only the guest's closed Development commands. Project and product
/// references cross; HFS paths and rendered MPW scripts do not.
@MainActor
final class AgentIntegrationDevelopmentControl {
    private let listener: GuestListener
    private let currentSessionID: @MainActor () -> UUID?

    init(listener: GuestListener,
         currentSessionID: @escaping @MainActor () -> UUID?) {
        self.listener = listener
        self.currentSessionID = currentSessionID
    }

    func perform(_ request: AgentIntegrationDevelopmentRequest) async
        -> AgentIntegrationGuestRowReportResult {
        guard request.isWellFormed else {
            return .refused(.init(code: "now-development-invalid-request",
                                  message: "The Development operation has invalid opaque references."))
        }
        guard let sessionID = currentSessionID() else {
            return .unavailable(.guest)
        }
        let route: (verb: String, group: String, args: [String: String])
        switch request.operation {
        case .buildStart:
            route = ("development-build", "development-build",
                     ["action": "start", "projectID": request.projectID!])
        case .buildStatus:
            route = ("development-build", "development-build",
                     ["action": "status"])
        case .buildCancel:
            route = ("development-build", "development-build",
                     ["action": "cancel"])
        case .run:
            route = ("development-run", "development-run",
                     ["productRef": request.productRef!])
        case .openInCodeKitten:
            route = ("development-open", "development-open",
                     ["projectID": request.projectID!])
        }
        let result: CommandResult = await withCheckedContinuation { continuation in
            listener.runCommand(route.verb, args: route.args) {
                continuation.resume(returning: $0)
            }
        }
        guard currentSessionID() == sessionID else {
            return .refused(.init(
                code: "now-development-outcome-unknown",
                message: "The paired guest changed while the Development operation was settling."))
        }
        guard result.ok else {
            return .refused(.init(
                code: AgentIntegrationBoundedText.prefix(
                    result.error?.code ?? "development-failed", scalars: 64),
                message: AgentIntegrationBoundedText.prefix(
                    result.error?.message ?? "The paired guest refused Development.",
                    scalars: 256)))
        }
        guard let cells = result.output?[route.group] else {
            return .refused(.init(code: "now-development-invalid",
                                  message: "The paired guest returned no Development rows."))
        }
        let rows = cells.prefix(16).map {
            AgentIntegrationGuestRow(
                label: AgentIntegrationBoundedText.prefix($0.first ?? "", scalars: 64),
                value: AgentIntegrationBoundedText.prefix(
                    $0.count > 1 ? $0.last ?? "" : "", scalars: 2_048))
        }
        return .completed(.init(
            verb: route.verb,
            groups: [.init(name: route.group, rows: rows)],
            note: cells.count > 16 ? "The host bounded the Development receipt." : nil,
            observedAt: Date()))
    }
}
