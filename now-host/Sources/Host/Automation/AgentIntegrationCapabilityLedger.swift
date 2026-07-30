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

    /// One message family the report accounts for, and the evidence to
    /// state about it when nothing has been observed.
    struct FamilyPolicy {
        let family: String
        /// The evidence when this session observed nothing in the family —
        /// for a probed one, that the probe never settled; for an unprobed
        /// one, the policy that declined to ask.
        let unobserved: AgentIntegrationCapabilityEvidence
        /// True when `report(probeCostly: true)` pays for this family, so
        /// on that path an unobserved answer is `probed` rather than the
        /// policy above.
        let probedOnRequest: Bool

        init(_ family: String,
             _ unobserved: AgentIntegrationCapabilityEvidence,
             probedOnRequest: Bool = false) {
            self.family = family
            self.unobserved = unobserved
            self.probedOnRequest = probedOnRequest
        }
    }

    /// Every message family this report accounts for, in report order.
    ///
    /// **A projection requiring a family absent from this list is switched
    /// off against every guest, silently.** `state(of:)` below looks a
    /// requirement up here first and falls through to the COMMAND table,
    /// which cannot contain a message family — `help` does not list them —
    /// so the miss reads as "the guest does not have it" rather than as
    /// "nobody declared it", and no test of the projection itself can
    /// notice. That is what
    /// `MCPCoverageTests.testEveryFamilyRequirementHasALedgerRow` gates:
    /// add a family requirement without a row here and it fails naming
    /// both the capability and the family.
    ///
    /// It is a declaration rather than a derivation from the registry's
    /// requirements on purpose. The probe policy in the second column is
    /// real knowledge about what a request costs the machine, it is not
    /// recoverable from a requirement string, and deriving the row set
    /// while defaulting that column would trade a named failure for a
    /// quietly mislabelled one.
    nonisolated static let familyPolicy: [FamilyPolicy] = {
        let names = AgentIntegrationCapabilityNames.self
        return [
            .init(names.processList, .probed),
            .init(names.fileList, .probed),
            .init(names.softwareList, .notProbedCostly,
                  probedOnRequest: true),
            .init(names.processQuit, .notProbedMutating),
            /* Mutating for the same reason quit is, even though it is the
               gentler of the two drive verbs: probing it would move a
               window on somebody's screen to answer a question nobody
               asked. Unproven leaves the capability callable, which is the
               honest state. */
            .init(names.processFront, .notProbedMutating),
            .init(names.filePut, .notProbedMutating),
            /* The pull direction, and NOT probed for capture's reason
               rather than quit's: `file.get` changes nothing on the
               machine, but the smallest request in the family is a whole
               file off a classic disk holding the connection's one
               transfer lane while it crosses. There is also nothing to
               name — a probe would have to invent a path and would then be
               settling the family with a not-found. Unproven leaves the
               capability callable, and a guest that does not implement it
               answers `not-implemented` on the first real call, which is
               what moves this row to unavailable in the guest's own
               words. */
            .init(names.fileGet, .notProbedCostly),
            /* Mutating in the sharpest possible sense: the smallest request
               in this family ENDS somebody's transfer. There is also nothing
               to read back — the contract gives `file.cancel` no reply — so a
               probe could not settle the question even at that price, and
               would answer it by destroying the evidence. Unproven leaves the
               capability callable, which is the honest state. */
            .init(names.fileCancel, .notProbedMutating),
            /* The four catalog mutations. Mutating in the plainest sense —
               the smallest request in each of these families moves, trashes,
               restores or creates something on somebody's disk — so none of
               them is probed and all four read `unproven` until a real call
               settles them. Unproven leaves the capability callable, which is
               the honest state: a guest that does not serve them refuses
               instantly, `GuestListener.sendChange` records that refusal,
               and the first real call is what turns the row `unavailable` —
               which is a fact the guest supplied rather than a guess about
               which guest is on the wire. */
            .init(names.fileMove, .notProbedMutating),
            .init(names.fileTrash, .notProbedMutating),
            .init(names.fileRestore, .notProbedMutating),
            .init(names.fileMkdir, .notProbedMutating),
            /* Read-only, and NOT probed — the reason is `software.list`'s
               rather than `process.quit`'s. A capture costs the guest a
               whole screen grab and holds the connection's only transfer
               lane while it does; spending that to answer a question nobody
               asked would take the lane out from under whoever is streaming.
               Note the honest consequence, which is narrower than the other
               costly family's: the capture lane does not record a family
               observation either (`GuestListener.requestCapture` is not
               wrapped, and `CaptureFailure` carries a sentence rather than
               the guest's typed code), so this reads `unproven` on every
               guest until that changes. Unproven is the truthful answer and
               leaves the capability callable; it is docs/open-issues.md
               material rather than something to paper over here. */
            .init(names.captureRequest, .notProbedCostly),
        ]
    }()

    private func familyReport(probedCostly: Bool)
        -> [AgentIntegrationFamilyCapability] {
        Self.familyPolicy.map { policy in
            family(policy.family,
                   whenUnproven: probedCostly && policy.probedOnRequest
                       ? .probed : policy.unobserved)
        }
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
                    // The fall-through that makes `familyPolicy` load-bearing:
                    // a message family reaching here is absent from every
                    // command table by construction, so it resolves
                    // `unavailable` for the rest of the connection's life.
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

        // One row per registered projection, and no list of tool names
        // here at all. A projection declares the guest capabilities it
        // cannot work without and the sentence to use when it has them;
        // this report derives the rest. The names used to be typed twice —
        // once in the companion's tool enum and once in a literal here —
        // which is two places for a capability to exist in only one of.
        return HostProjectionRegistry.hostFaces.projections.map {
            tool($0.capability.rawValue, $0.requires, $0.availabilityNote)
        }
    }
}
