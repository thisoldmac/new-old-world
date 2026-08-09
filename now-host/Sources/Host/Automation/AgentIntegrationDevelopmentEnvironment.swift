import Foundation
import NOWAgentIntegration

/// Reads the guest-owned development registration without learning either
/// selected HFS path. The guest performs qualification; this side only
/// bounds and carries its rows.
@MainActor
final class AgentIntegrationDevelopmentEnvironment {
    private enum CommandOutcome {
        case result(CommandResult)
        case timedOut
    }

    static let commandTimeout: TimeInterval = 15

    private let listener: GuestListener
    private let currentSessionID: @MainActor () -> UUID?
    private let commandTimeout: TimeInterval
    private let clock: @MainActor () -> Date

    init(listener: GuestListener,
         currentSessionID: @escaping @MainActor () -> UUID?,
         commandTimeout: TimeInterval =
            AgentIntegrationDevelopmentEnvironment.commandTimeout,
         clock: @escaping @MainActor () -> Date = { Date() }) {
        self.listener = listener
        self.currentSessionID = currentSessionID
        self.commandTimeout = commandTimeout
        self.clock = clock
    }

    func read() async -> AgentIntegrationGuestRowReportResult {
        guard let sessionID = currentSessionID() else {
            return .unavailable(.guest)
        }
        let outcome = await run()
        guard currentSessionID() == sessionID else {
            return .unavailable(.init(
                code: "now-development-outcome-unknown",
                message: "The paired guest changed while its development environment was being read"))
        }
        switch outcome {
        case .timedOut:
            return .refused(.init(
                code: "now-development-outcome-unknown",
                message: "The paired guest did not answer the development environment in time"))
        case .result(let result) where !result.ok:
            return .refused(.init(
                code: bounded(result.error?.code ?? "development-failed",
                    AgentIntegrationDevelopmentEnvironmentPolicy
                        .maximumFailureCodeScalars),
                message: bounded(result.error?.message
                    ?? "The paired guest refused the development environment",
                    AgentIntegrationDevelopmentEnvironmentPolicy
                        .maximumMessageScalars)))
        case .result(let result):
            guard let rows = result.output?[
                AgentIntegrationDevelopmentEnvironmentPolicy.group]
            else {
                return .refused(.init(
                    code: "now-development-invalid",
                    message: "The paired guest answered without its development rows"))
            }
            let policy = AgentIntegrationDevelopmentEnvironmentPolicy.self
            let rendered = rows.prefix(policy.maximumRows).map { cells in
                AgentIntegrationGuestRow(
                    label: bounded(cells.first ?? "",
                                   policy.maximumLabelScalars),
                    value: bounded(cells.count > 1 ? cells.last ?? "" : "",
                                   policy.maximumValueScalars))
            }
            return .completed(.init(
                verb: policy.verb,
                groups: [.init(name: policy.group, rows: rendered)],
                note: rows.count > policy.maximumRows
                    ? "The host bounded the guest's development rows."
                    : nil,
                observedAt: clock()))
        }
    }

    private func run() async -> CommandOutcome {
        await withCheckedContinuation { continuation in
            var settled = false
            var timeoutTask: Task<Void, Never>?
            listener.runCommand(
                AgentIntegrationDevelopmentEnvironmentPolicy.verb
            ) { result in
                guard !settled else { return }
                settled = true
                timeoutTask?.cancel()
                continuation.resume(returning: .result(result))
            }
            timeoutTask = Task { @MainActor in
                try? await Task.sleep(
                    nanoseconds: UInt64(commandTimeout * 1_000_000_000))
                guard !Task.isCancelled, !settled else { return }
                settled = true
                continuation.resume(returning: .timedOut)
            }
        }
    }

    private func bounded(_ value: String, _ scalars: Int) -> String {
        AgentIntegrationBoundedText.prefix(value, scalars: scalars)
    }
}
