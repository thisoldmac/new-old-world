import Foundation
import NOWAgentIntegration

/// Answers "what can the guest on the other end of this wire actually do",
/// without ever asking who it is.
///
/// NOW has two guests of very different completeness, and the companion
/// must work against whichever one dialled in. The tempting shortcut — read
/// the hello name, look up a table of that guest's abilities — has already
/// failed here once, in the direction nothing reports: `MetalQuitTests`
/// derived a guest's abilities from its hello name and went stale the same
/// afternoon that guest grew `process.list`, quietly UNDERSTATING its own
/// evidence. Nothing failed, because a test that expects less always
/// passes. So identity is not an input to anything in this file.
///
/// Two sources, matching the two kinds of capability
/// docs/command-parity.md already names:
///
/// **Commands** come from `help`, which both guests serve on the wire and
/// which returns that machine's own table. It is the same source the host
/// console's Tab completion uses, and it means a guest that grows a verb
/// becomes usable here with no companion release.
///
/// **Message families** are NOT in any table — `help` cannot see them, and
/// that gap is exactly how `ps` shipped wire-only. A family is therefore
/// established by asking:
///
/// - Every family request the host makes records its outcome as it settles
///   (`GuestListener.familyObservations`). Ordinary tool use is what
///   populates the ledger, so it gets sharper the more the session is used.
/// - This report additionally PROBES the read-only families it can settle
///   cheaply — `process.list` and `file.list` — by sending the same request
///   the tools send. A probe that costs the guest nothing to refuse and one
///   listing to serve is worth its price for a definite answer.
/// - It never probes a family whose smallest request CHANGES the guest.
///   `process.quit` and `file.put` stay `unproven` until real use settles
///   them. "I would have to quit something to find out whether I can quit
///   things" is not an acceptable way to answer a question.
/// - `software.list` is read-only but its first page is a whole-volume
///   sweep (~4 s on the PowerBook), so it is probed only on request. Note
///   the asymmetry that makes this cheap when it matters: a guest that does
///   NOT implement it refuses instantly; only the guest that does pays the
///   four seconds.
@MainActor
final class AgentIntegrationCapabilityLedger {
    /// One `help` table per connection. `help` is a live source, but it is
    /// not free and a guest's command table does not change mid-session.
    private struct CommandTableRecord {
        let sessionID: UUID
        let names: [String]?
    }

    private let listener: GuestListener
    private let currentSessionID: @MainActor () -> UUID?
    private let clock: @MainActor () -> Date
    private var commandTable: CommandTableRecord?

    init(listener: GuestListener,
         currentSessionID: @escaping @MainActor () -> UUID?,
         clock: @escaping @MainActor () -> Date = { Date() }) {
        self.listener = listener
        self.currentSessionID = currentSessionID
        self.clock = clock
    }

    func report(probeCostly: Bool = false) async
        -> AgentIntegrationSessionCapabilitiesResult {
        guard let sessionID = currentSessionID() else {
            commandTable = nil
            return .guestUnavailable
        }

        let names = await commandNames(sessionID: sessionID)
        guard currentSessionID() == sessionID else {
            return .guestUnavailable
        }

        await probeReadOnlyFamilies(sessionID: sessionID,
                                    includeCostly: probeCostly)
        guard currentSessionID() == sessionID else {
            return .guestUnavailable
        }

        let families = familyReport(probedCostly: probeCostly)
        return .available(.init(
            sessionID: sessionID,
            observedAt: clock(),
            commandTable: names,
            commandTableEvidence: names == nil
                ? .commandTableUnavailable : .commandTable,
            families: families,
            tools: toolReport(commandNames: names, families: families),
            probedCostly: probeCostly))
    }

    /// Forgets a connection's command table. The observations themselves
    /// live on the listener and are cleared with the connection.
    func forgetGuest() {
        commandTable = nil
    }

    // MARK: - Commands

    private func commandNames(sessionID: UUID) async -> [String]? {
        if let commandTable, commandTable.sessionID == sessionID {
            return commandTable.names
        }
        let result = await runHelp()
        guard currentSessionID() == sessionID else { return nil }
        // The first column of `help`'s list form is the command names —
        // the one structural promise that output makes (contract, `help`).
        // Everything else in there is prose for a human.
        let names: [String]? = {
            guard result.ok, let rows = result.output?["help"] else {
                return nil
            }
            let parsed = rows.compactMap { $0.first }
                .filter { name in
                    !name.isEmpty && name != "..."
                        && name.allSatisfy { $0.isLetter || $0.isNumber }
                }
            return parsed.isEmpty ? nil : parsed.sorted()
        }()
        commandTable = .init(sessionID: sessionID, names: names)
        return names
    }

    /// `runCommand` carries no watchdog — the console lives with that,
    /// because a human watching a dead prompt can see it. Nothing is
    /// watching this one, so it gets its own bound: an unanswered `help`
    /// settles as "no command table", which is a truthful thing to report
    /// and leaves the families to speak for themselves.
    private func runHelp() async -> CommandResult {
        await withCheckedContinuation { continuation in
            // Whichever arrives first wins; the loser must not resume a
            // continuation twice, which is a crash rather than a bug.
            let gate = OnceGate()
            listener.runCommand("help", line: "") { result in
                guard gate.claim() else { return }
                continuation.resume(returning: result)
            }
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.helpTimeout
            ) {
                guard gate.claim() else { return }
                continuation.resume(returning: CommandResult(
                    id: 0, ok: false, output: nil,
                    error: .init(
                        code: "timeout",
                        message: "The guest did not answer help")))
            }
        }
    }

    private static let helpTimeout: TimeInterval = 10

    /// Both claimants run on the main actor, so a plain flag is enough.
    @MainActor
    private final class OnceGate {
        private var taken = false

        func claim() -> Bool {
            guard !taken else { return false }
            taken = true
            return true
        }
    }

    // MARK: - Families

    private func probeReadOnlyFamilies(sessionID: UUID,
                                       includeCostly: Bool) async {
        if listener.familyObservations[
            AgentIntegrationCapabilityNames.processList] == nil {
            _ = await withCheckedContinuation { continuation in
                listener.listProcesses(cursor: nil) {
                    continuation.resume(returning: $0)
                }
            }
            guard currentSessionID() == sessionID else { return }
        }
        if listener.familyObservations[
            AgentIntegrationCapabilityNames.fileList] == nil {
            _ = await withCheckedContinuation { continuation in
                listener.listFiles(path: "", cursor: nil) {
                    continuation.resume(returning: $0)
                }
            }
            guard currentSessionID() == sessionID else { return }
        }
        guard includeCostly,
              listener.familyObservations[
                AgentIntegrationCapabilityNames.softwareList] == nil
        else { return }
        _ = await withCheckedContinuation { continuation in
            listener.listSoftware(domain: "apps", cursor: nil) {
                continuation.resume(returning: $0)
            }
        }
    }

    private func familyReport(probedCostly: Bool)
        -> [AgentIntegrationFamilyCapability] {
        let names = AgentIntegrationCapabilityNames.self
        return [
            family(names.processList, whenUnproven: .probed),
            family(names.fileList, whenUnproven: .probed),
            family(names.softwareList,
                   whenUnproven: probedCostly ? .probed : .notProbedCostly),
            family(names.processQuit, whenUnproven: .notProbedMutating),
            family(names.filePut, whenUnproven: .notProbedMutating),
        ]
    }

    /// `whenUnproven` is the evidence to report when nothing was observed
    /// — which for a probed family means the probe itself never settled,
    /// and for an unprobed one means the policy that declined to ask.
    private func family(
        _ name: String,
        whenUnproven: AgentIntegrationCapabilityEvidence
    ) -> AgentIntegrationFamilyCapability {
        guard let observation = listener.familyObservations[name] else {
            return .init(family: name, state: .unproven,
                         evidence: whenUnproven)
        }
        if observation.served {
            return .init(
                family: name, state: .available,
                evidence: whenUnproven == .probed ? .probed : .observedInUse,
                observedAt: observation.observedAt)
        }
        let code = observation.code ?? "unknown"
        // A guest that refused with a typed "I do not implement that" has
        // answered the question. Any other failure — a Toolbox error, a
        // malformed reply — says nothing about the family, so the state
        // stays unproven rather than becoming a false negative.
        guard AgentIntegrationCapabilityNames.isRefusal(code) else {
            return .init(family: name, state: .unproven,
                         evidence: whenUnproven,
                         refusalCode: code,
                         refusalMessage: observation.message,
                         observedAt: observation.observedAt)
        }
        return .init(
            family: name, state: .unavailable,
            evidence: whenUnproven == .probed ? .probed : .refusedInUse,
            refusalCode: code,
            refusalMessage: observation.message,
            observedAt: observation.observedAt)
    }

    // MARK: - Tools

    /// Each tool is exactly as available as the capabilities it projects.
    /// A tool whose safety model cannot stand up against this guest is
    /// UNAVAILABLE, in typed form, and that is a complete answer — never a
    /// weaker version of the tool that skips the part it cannot do.
    private func toolReport(
        commandNames: [String]?,
        families: [AgentIntegrationFamilyCapability]
    ) -> [AgentIntegrationToolCapability] {
        let names = AgentIntegrationCapabilityNames.self
        let byName = Dictionary(
            uniqueKeysWithValues: families.map { ($0.family, $0) })

        func state(of requirements: [String])
            -> (AgentIntegrationCapabilityState, [String]) {
            var missing: [String] = []
            var worst = AgentIntegrationCapabilityState.available
            for requirement in requirements {
                let current: AgentIntegrationCapabilityState
                if let family = byName[requirement] {
                    current = family.state
                } else if let commandNames {
                    current = commandNames.contains(requirement)
                        ? .available : .unavailable
                } else {
                    current = .unproven
                }
                guard current != .available else { continue }
                missing.append(requirement)
                if current == .unavailable { worst = .unavailable }
                else if worst != .unavailable { worst = .unproven }
            }
            return (worst, missing)
        }

        func tool(_ name: String, _ requires: [String], _ note: String)
            -> AgentIntegrationToolCapability {
            let (resolved, missing) = state(of: requires)
            let reason: String
            switch resolved {
            case .available:
                reason = note
            case .unavailable:
                reason = "The connected guest does not serve "
                    + missing.joined(separator: ", ")
                    + ", so this tool is unavailable against it."
            case .unproven:
                reason = "Nothing has established whether the connected "
                    + "guest serves " + missing.joined(separator: ", ")
                    + "; calling this tool will settle it, and it answers "
                    + "with the guest's own refusal if it cannot."
            }
            return .init(tool: name, state: resolved, requires: requires,
                         missing: missing, reason: reason)
        }

        return [
            .init(tool: "now_session_health", state: .available,
                  requires: [], missing: [],
                  reason: "Reads host-owned listener state and sends the "
                      + "guest no message, so it is available whatever the "
                      + "guest implements."),
            .init(tool: "now_session_capabilities", state: .available,
                  requires: [], missing: [],
                  reason: "This report."),
            tool("now_list_processes", [names.processList],
                 "The connected guest serves process.list."),
            // Quit needs the family, not the `quit` COMMAND. A guest with
            // a `quit` verb and no process.quit cannot support the
            // opaque-reference/PSN-revalidation model this tool is built
            // on, and the fix is never to relax the model to fit.
            tool("now_request_quit", [names.processList, names.processQuit],
                 "The connected guest serves process.list and "
                     + "process.quit."),
            // Both halves matter: the `launch` command alone is not
            // enough, because "launch exactly one exact match from the
            // current catalog" is the entire safety story and there is no
            // catalog without software.list.
            tool("now_launch_software",
                 [names.softwareList, names.launchCommand],
                 "The connected guest serves software.list and launch."),
            tool("now_transfer_approved_artifact", [names.filePut],
                 "The connected guest accepts a host-driven put."),
            tool("now_guest_files_capabilities", [names.fileList],
                 "The connected guest serves file.list."),
            tool("now_guest_files_list", [names.fileList],
                 "The connected guest serves file.list."),
            tool("now_guest_files_stat", [names.fileList],
                 "The connected guest serves file.list."),
            tool("now_guest_files_upload_begin", [],
                 "Reserves private host disk and sends the guest no "
                     + "message, so staging is available regardless; the "
                     + "commit is where the guest's put lane is needed."),
            tool("now_guest_files_upload_append", [],
                 "Accepts bytes into a private host stage and sends the "
                     + "guest no message."),
            tool("now_guest_files_upload_commit", [names.filePut],
                 "The connected guest accepts a host-driven put."),
        ]
    }
}
