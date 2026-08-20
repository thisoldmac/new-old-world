import Foundation
import NOWAgentIntegration

/// The single public command policy. HTTP parses the request and this service
/// binds it to one exact live session before touching the guest command lane.
/// The listener remains the command implementation and watchdog owner.
@MainActor
final class NOWAPIConsoleCommandService {
    nonisolated static let maximumCommandNameBytes = 96
    nonisolated static let maximumArgumentCount = 32
    nonisolated static let maximumArgumentNameBytes = 96
    nonisolated static let maximumArgumentTextBytes = 4 * 1024
    nonisolated static let maximumArgumentLineBytes = 4 * 1024
    nonisolated static let maximumOutputBytes = 64 * 1024

    private let driver: any NOWAPICommandDriving
    private var commandTable: (sessionID: String, names: Set<String>)?

    init(driver: any NOWAPICommandDriving) {
        self.driver = driver
    }

    func execute(
        guestID: String, request: NOWAPIConsoleCommandRequest,
        completion: @escaping (NOWAPIConsoleCommandOutcome) -> Void
    ) {
        guard let guest = driver.apiCommandGuest(id: guestID) else {
            completion(failure(
                guestID: guestID, sessionID: nil, .disconnected,
                code: "guest_disconnected",
                message: "That guest is not connected.", reach: "guest"))
            return
        }
        guard guest.isActive else {
            completion(failure(
                guestID: guestID, sessionID: guest.sessionID, .refused,
                code: "guest_not_addressed",
                message: "That guest is connected but is not the guest the host is driving.",
                reach: "guest"))
            return
        }
        if let access = guest.agentAccess,
           !HostConsentCeiling.ceiling(for: access).permits(.fullAccess) {
            completion(failure(
                guestID: guestID, sessionID: guest.sessionID, .refused,
                code: "guest_access_refused",
                message: "The guest has not granted full control access.",
                reach: "guest"))
            return
        }

        let run: (Set<String>) -> Void = { [weak self] names in
            guard let self else { return }
            guard names.contains(request.command) else {
                completion(self.failure(
                    guestID: guestID, sessionID: guest.sessionID,
                    .unadvertised, code: "command_unadvertised",
                    message: "The addressed guest did not advertise that command.",
                    reach: "guest"))
                return
            }
            self.run(request, for: guest, completion: completion)
        }

        if let commandTable, commandTable.sessionID == guest.sessionID {
            run(commandTable.names)
            return
        }
        driver.apiRunScheduledCommand(
            "help", arguments: nil, argumentLine: "",
            purpose: .command("API command table"), workClass: .foreground
        ) { [weak self] result in
            guard let self else { return }
            guard self.sameActiveSession(guest) else {
                completion(self.failure(
                    guestID: guestID, sessionID: guest.sessionID,
                    .disconnected, code: "session_changed",
                    message: "The addressed guest session changed while its command table was loading.",
                    reach: "session"))
                return
            }
            guard result.ok else {
                completion(self.outcome(
                    for: result, guest: guest,
                    fallbackCode: "command_table_unavailable"))
                return
            }
            let names = Set((result.output?["help"] ?? [])
                .compactMap(\.first)
                .filter { name in
                    name != "..."
                        && NOWAPIConsoleCommandHTTPCodec.isValidCommandName(name)
                })
            guard !names.isEmpty else {
                completion(self.failure(
                    guestID: guestID, sessionID: guest.sessionID, .failed,
                    code: "command_table_invalid",
                    message: "The addressed guest returned no usable command table.",
                    reach: "guest"))
                return
            }
            self.commandTable = (guest.sessionID, names)
            run(names)
        }
    }

    private func run(
        _ request: NOWAPIConsoleCommandRequest, for guest: NOWAPICommandGuest,
        completion: @escaping (NOWAPIConsoleCommandOutcome) -> Void
    ) {
        driver.apiRunScheduledCommand(
            request.command, arguments: request.arguments,
            argumentLine: request.argumentLine,
            purpose: .command("API " + request.command),
            workClass: .foreground
        ) { [weak self] result in
            guard let self else { return }
            guard self.sameActiveSession(guest) else {
                completion(self.failure(
                    guestID: guest.id, sessionID: guest.sessionID,
                    .disconnected, code: "session_changed",
                    message: "The addressed guest session changed while the command was running.",
                    reach: "session"))
                return
            }
            completion(self.outcome(for: result, guest: guest))
        }
    }

    private func outcome(
        for result: CommandResult, guest: NOWAPICommandGuest,
        fallbackCode: String = "command_failed"
    ) -> NOWAPIConsoleCommandOutcome {
        if result.ok {
            guard let encoded = try? JSONEncoder().encode(result),
                  encoded.count <= Self.maximumOutputBytes else {
                return failure(
                    guestID: guest.id, sessionID: guest.sessionID, .failed,
                    code: "command_output_too_large",
                    message: "The guest command result exceeded the API output limit.",
                    reach: "guest")
            }
            return .init(
                guestID: guest.id, sessionID: guest.sessionID,
                disposition: .completed, output: result.output,
                outputObjects: result.outputObjects, error: nil)
        }
        let code = result.error?.code ?? fallbackCode
        let disposition: NOWAPIConsoleCommandOutcome.Disposition
        switch code {
        case "timeout": disposition = .timedOut
        case "not-connected", "disconnected", "session-changed":
            disposition = .disconnected
        case "unknown-command": disposition = .unadvertised
        default: disposition = .failed
        }
        return failure(
            guestID: guest.id, sessionID: guest.sessionID, disposition,
            code: code,
            message: bounded(result.error?.message ?? "The guest command failed."),
            reach: "guest")
    }

    private func sameActiveSession(_ guest: NOWAPICommandGuest) -> Bool {
        guard let current = driver.apiCommandGuest(id: guest.id) else {
            return false
        }
        return current.sessionID == guest.sessionID && current.isActive
    }

    private func failure(
        guestID: String, sessionID: String?,
        _ disposition: NOWAPIConsoleCommandOutcome.Disposition,
        code: String, message: String, reach: String
    ) -> NOWAPIConsoleCommandOutcome {
        .init(
            guestID: guestID, sessionID: sessionID,
            disposition: disposition, output: nil, outputObjects: nil,
            error: .init(code: code, message: bounded(message), reach: reach))
    }

    private func bounded(_ value: String) -> String {
        String(value.prefix(1_024))
    }
}

struct NOWAPICommandGuest: Equatable, Sendable {
    let id: String
    let sessionID: String
    let isActive: Bool
    let agentAccess: AgentIntegrationGuestAccess?
}

@MainActor
protocol NOWAPICommandDriving: AnyObject {
    func apiCommandGuest(id: String) -> NOWAPICommandGuest?
    func apiRunScheduledCommand(
        _ name: String, arguments: [String: CommandArg]?,
        argumentLine: String?, purpose: GuestWorkPurpose,
        workClass: GuestWorkClass,
        completion: @escaping (CommandResult) -> Void)
}

extension GuestListener: NOWAPICommandDriving {
    func apiCommandGuest(id: String) -> NOWAPICommandGuest? {
        guard let guest = guests.first(where: { $0.id.slug == id }) else {
            return nil
        }
        return .init(id: guest.id.slug, sessionID: guest.sessionID,
                     isActive: guest.isActive,
                     agentAccess: guest.agentAccess)
    }

    func apiRunScheduledCommand(
        _ name: String, arguments: [String: CommandArg]?,
        argumentLine: String?, purpose: GuestWorkPurpose,
        workClass: GuestWorkClass,
        completion: @escaping (CommandResult) -> Void
    ) {
        runScheduledCommand(
            name, typed: arguments, line: argumentLine,
            purpose: purpose, workClass: workClass,
            completion: completion)
    }
}
