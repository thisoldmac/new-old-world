import XCTest
@testable import Host
import NOWAgentIntegration

/// The machine-facts capability's own coverage, aimed at the three things that
/// are genuinely its own: **the request that asks for every group, the order
/// the answer is put back into, and an unavailability that does not slander a
/// machine that can answer these questions another way.**
///
/// `gestalt` takes no arguments and answers six groups in one call, so almost
/// everything that could go wrong here is the host mis-stating what the
/// machine said — by asking a narrower question than it meant to, by
/// re-ordering, or by editing a row.
@MainActor
final class AgentIntegrationMachineFactsTests: XCTestCase {
    private final class Asked {
        var count = 0
        var lines: [String?] = []
        var args: [[String: CommandArg]?] = []
    }

    /// An abbreviated but shape-faithful answer from a PowerBook, in the
    /// guest's own wording (`now-guest-ppc/src/commands/commands.c ::
    /// now_gestalt_gather`). A dictionary, because that is what the transport
    /// hands the host — the guest's declared order is already gone here.
    private static let wholeMachine: [String: [[String]]] = [
        "snapshot": [
            ["Model", "PowerBook 1400c/166"],
            ["System", "Mac OS 9.1"],
            ["CPU", "PowerPC 603e"],
            ["Memory", "64 MB"],
            ["CarbonLib", "1.6"],
            ["Networking", "Open Transport"],
        ],
        "cpu": [
            ["Processor", "PowerPC 603e"],
            ["68K emulation", "68020"],
            ["FPU", "none"],
            ["Addressing", "32-bit"],
        ],
        "memory": [
            ["Physical RAM", "64 MB"],
            ["Logical RAM", "64 MB"],
            ["Virtual memory", "off"],
            ["Page size", "4096 bytes"],
        ],
        "os": [
            ["System", "Mac OS 9.1"],
            ["QuickDraw", "2.4"],
            ["AppleEvents", "yes"],
            ["Thread Manager", "yes"],
            ["CarbonLib", "1.6"],
        ],
        "network": [
            ["AppleTalk", "60"],
            ["Open Transport", "yes"],
        ],
        "hw": [
            ["FPU", "none"],
            ["Keyboard", "type 12"],
            ["Machine type", "id 310"],
            ["ROM size", "4096 KB"],
            ["ROM version", "$077D"],
        ],
    ]

    /// Answers `gestalt` from a closure, recording what was asked and — the
    /// point of the `lines` and `args` fields — HOW.
    private func installResponder(
        on guest: FakeGuest,
        asked: Asked = Asked(),
        answer: @escaping (Int) -> CommandResult?
    ) {
        guest.onMessage = { message in
            guard case .commandRequest(let request) = message,
                  request.name == "gestalt" else { return }
            asked.count += 1
            asked.lines.append(request.line)
            asked.args.append(request.args)
            guard let reply = answer(asked.count) else { return }
            try? guest.send(.commandResult(.init(
                id: request.id, ok: reply.ok, output: reply.output,
                error: reply.error)))
        }
    }

    private func ok(_ output: [String: [[String]]]) -> CommandResult {
        .init(id: 0, ok: true, output: output, error: nil)
    }

    private func report(
        _ result: AgentIntegrationGuestRowReportResult
    ) throws -> AgentIntegrationGuestRowReport {
        guard case .completed(let report) = result else {
            throw UnexpectedTestResult(
                description: "expected a completed report: \(result)")
        }
        XCTAssertEqual(report.verb, "gestalt")
        return report
    }

    // MARK: - The request: every group, because nothing narrowed it

    /// **The host sends no `line` and no `args`, and that is what makes the
    /// answer whole.**
    ///
    /// The contract's `gestalt` entry turns on this exact distinction: a typed
    /// call with no `line` returns every group, an empty `line` returns the
    /// snapshot alone, and `--cpu` returns one group. A host that sent a line
    /// would silently get a sixth of the answer it published a schema for, and
    /// nothing else in this suite could tell.
    func testTheHostAsksWithNoLineAndNoArgsSoEveryGroupComesBack()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let asked = Asked()
        installResponder(on: guest, asked: asked) { [self] _ in
            ok(Self.wholeMachine)
        }
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        let facts = try report(await adapter.machineFacts())

        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(
            asked.lines, [nil],
            "A line is what tells the guest a human is typing, and its "
                + "presence NARROWS the answer — empty means the snapshot "
                + "group alone. A projection must ask the typed way.")
        XCTAssertEqual(asked.args, [nil],
                       "gestalt declares args: {} — there is nothing to send.")
        XCTAssertEqual(facts.groups.count, 6)
    }

    // MARK: - Rendering, and not deciding

    /// **The groups come back in the contract's order, not alphabetically.**
    ///
    /// The transport loses the guest's order (`CommandResult.output` is a
    /// dictionary), so the order is restored here — and the sequence restored
    /// is the contract's own. Sorting names, which is what `tail` does with
    /// its two, would read `cpu, hw, memory, network, os, snapshot` and bury
    /// the summary the guest writes first.
    func testGroupsAreOrderedByTheContractRatherThanAlphabetically()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        installResponder(on: guest) { [self] _ in ok(Self.wholeMachine) }
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        let facts = try report(await adapter.machineFacts())

        XCTAssertEqual(
            facts.groups.map(\.name),
            AgentIntegrationMachineFactsPolicy.declaredGroupOrder)
        XCTAssertNotEqual(
            facts.groups.map(\.name),
            facts.groups.map(\.name).sorted(),
            "If these ever coincide the assertion above has stopped "
                + "proving anything.")
        XCTAssertNil(facts.note,
                     "Nothing was bounded, so nothing claims to have been.")
    }

    /// Rows cross back verbatim and in the guest's order inside each group.
    ///
    /// The wording is the assertion: a host that turned `Virtual memory: off`
    /// into a boolean, or `64 MB` into a number, would be answering a question
    /// about the machine out of its own state and would go stale the first
    /// time the guest reworded a row.
    func testRowsCrossBackVerbatimAndInTheGuestsOwnOrder() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        installResponder(on: guest) { [self] _ in ok(Self.wholeMachine) }
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        let facts = try report(await adapter.machineFacts())

        let hw = try XCTUnwrap(facts.groups.first { $0.name == "hw" })
        XCTAssertEqual(hw.rows.map(\.label),
                       Self.wholeMachine["hw"]?.map { $0[0] })
        XCTAssertEqual(hw.rows.map(\.value),
                       Self.wholeMachine["hw"]?.map { $0[1] })
        let memory = try XCTUnwrap(facts.groups.first { $0.name == "memory" })
        XCTAssertEqual(
            memory.rows.first { $0.label == "Virtual memory" }?.value, "off",
            "The guest's own word, carried. \"off\" is text a person reads; "
                + "a boolean would be this side deciding what it meant.")
    }

    /// **A group a newer guest grows is kept, and follows the ones this side
    /// knows.** A host holding a stale copy of a list must not silently drop
    /// what a machine said — the same reason the census refuses to enumerate
    /// probe names.
    func testAGroupThisHostHasNoOrderForIsKeptRatherThanDropped()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        var grown = Self.wholeMachine
        grown["video"] = [["Screen", "800 x 600, 8-bit"]]
        grown["audio"] = [["Sound", "16-bit"]]
        installResponder(on: guest) { [self] _ in ok(grown) }
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        let facts = try report(await adapter.machineFacts())

        XCTAssertEqual(
            facts.groups.map(\.name),
            AgentIntegrationMachineFactsPolicy.declaredGroupOrder
                + ["audio", "video"],
            "Unknown groups keep their content, follow the declared ones, "
                + "and are sorted among themselves so the answer is stable.")
    }

    // MARK: - The bounds, made visible

    /// A bound that bites says so, in the one field reserved for the edges of
    /// an answer — and the guest offers no note for this verb, so the sentence
    /// is attributed to the host in its own text.
    func testAnAnswerPastTheGroupBoundIsShortenedAndTheReportSaysSo()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        var many = Self.wholeMachine
        for extra in 1...5 {
            many["zz-extra-\(extra)"] = [["Row", "value"]]
        }
        installResponder(on: guest) { [self] _ in ok(many) }
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        let facts = try report(await adapter.machineFacts())

        XCTAssertEqual(facts.groups.count,
                       AgentIntegrationMachineFactsPolicy.maximumGroups)
        XCTAssertEqual(
            facts.note,
            AgentIntegrationMachineFactsPolicy.truncationNote(
                answered: many.count))
        XCTAssertEqual(
            facts.groups.map(\.name).prefix(6),
            AgentIntegrationMachineFactsPolicy.declaredGroupOrder.prefix(6),
            "The bound drops the TAIL, so the groups the contract declares "
                + "can never be the ones lost.")
    }

    /// Label and value are bounded to what the machine's own `GestaltRow` can
    /// hold, so a guest sending more cannot widen this side's answer past the
    /// number the schema publishes.
    func testLabelAndValueAreBoundedToTheGuestsOwnRowSize() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let policy = AgentIntegrationMachineFactsPolicy.self
        installResponder(on: guest) { [self] _ in
            ok(["snapshot": [[String(repeating: "L", count: 200),
                              String(repeating: "V", count: 500)]]])
        }
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        let facts = try report(await adapter.machineFacts())

        XCTAssertEqual(facts.groups.first?.rows.first?.label.count,
                       policy.maximumLabelScalars)
        XCTAssertEqual(facts.groups.first?.rows.first?.value.count,
                       policy.maximumValueScalars)
    }

    /// A one-cell row is rendered rather than dropped: the pair is the
    /// contract's shape, and a guest that sent one cell said the same thing
    /// twice rather than crashing this side.
    func testAOneCellRowIsRenderedRatherThanDropped() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        installResponder(on: guest) { [self] _ in
            ok(["snapshot": [["Model"]]])
        }
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        let facts = try report(await adapter.machineFacts())

        XCTAssertEqual(facts.groups.first?.rows.count, 1)
        XCTAssertEqual(facts.groups.first?.rows.first?.label, "Model")
        XCTAssertEqual(facts.groups.first?.rows.first?.value, "")
    }

    // MARK: - Refusals, and what silence is not

    /// A guest refusal stays a refusal and keeps the guest's own code — which
    /// is what a 68K guest answers here.
    func testAGuestRefusalKeepsItsOwnCodeAndClaimsNoFacts() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        installResponder(on: guest) { _ in
            .init(id: 0, ok: false, output: nil,
                  error: .init(code: "unknown-command",
                               message: "no command \"gestalt\" - see help"))
        }
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        guard case .refused(let failure) = await adapter.machineFacts() else {
            return XCTFail("a guest refusal must remain a refusal")
        }
        XCTAssertEqual(failure.code, "unknown-command")
        XCTAssertEqual(failure.message,
                       "no command \"gestalt\" - see help")
    }

    /// `ok` with no groups is refused, not reported as a machine with nothing
    /// to say about itself. The second cannot happen — the snapshot group's
    /// `Model` row is unconditional — so an empty answer means the reply did
    /// not arrive in the declared shape, which is not a fact about the Mac.
    func testAnOkAnswerWithNoGroupsIsRefusedRatherThanReportedAsEmpty()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        installResponder(on: guest) { [self] _ in ok([:]) }
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        guard case .refused(let failure) = await adapter.machineFacts() else {
            return XCTFail("an unshaped answer is not a set of facts")
        }
        XCTAssertEqual(failure.code, "now-machine-facts-invalid")
    }

    /// A guest that never answers inside the bound is refused with an outcome
    /// nobody knows — never reported as a machine that had nothing to say.
    func testAGuestThatNeverAnswersIsRefusedWithAnUnknownOutcome()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        installResponder(on: guest) { _ in nil }
        /* One stable token for the whole call: a fresh UUID per read would
           make the session look as though it had changed under the request,
           which is a DIFFERENT answer (unavailable) and would leave the
           timeout path untested. */
        let session = UUID()
        let facts = AgentIntegrationMachineFacts(
            listener: listener,
            currentSessionID: { session },
            commandTimeout: 0.2)

        guard case .refused(let failure) = await facts.read() else {
            return XCTFail("silence is not a set of facts")
        }
        XCTAssertEqual(failure.code, "now-machine-facts-outcome-unknown")
    }

    /// No guest, no answer about a guest — `unavailable`, not a refusal.
    func testADisconnectedGuestIsUnavailableRatherThanRefused() async {
        let disconnected = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"))
        let result = await AgentIntegrationHostAdapter(
            listener: disconnected).machineFacts()

        guard case .unavailable(let missing) = result else {
            return XCTFail("a disconnected guest cannot refuse anything")
        }
        XCTAssertEqual(missing.code, "now-guest-unavailable")
    }

    // MARK: - PowerPC only, and typed

    /// **Unavailability is derived from the guest's own command table.**
    ///
    /// The 68K guest has no `gestalt`, and this is how the surface says so:
    /// the same code, two command tables, opposite answers, with nothing
    /// reading a hello name. There is deliberately no reduced form for the
    /// guest that lacks the verb — a "gestalt from the census" would be a
    /// different answer wearing this one's name.
    func testTheToolIsUnavailableAgainstAGuestWhoseTableLacksTheVerb()
        async throws {
        for (commands, expected) in [
            (["help", "ps", "census"], AgentIntegrationCapabilityState
                .unavailable),
            (["help", "ps", "gestalt"], .available),
        ] as [([String], AgentIntegrationCapabilityState)] {
            let (listener, guest) = try await connectedListener()
            guest.onMessage = { message in
                switch message {
                case .commandRequest(let request)
                    where request.name == "help":
                    try? guest.send(.commandResult(.init(
                        id: request.id, ok: true,
                        output: ["help": commands.map { [$0, "a verb"] }],
                        error: nil)))
                /* The report probes two read-only families on its way to the
                   answer; answering them empty settles those probes at once
                   instead of spending their watchdogs to prove nothing about
                   a command table. */
                case .processList(let request):
                    try? guest.send(.processListing(.init(
                        id: request.id, processes: [], more: false,
                        cursor: nil)))
                case .fileList(let request):
                    try? guest.send(.fileListing(.init(
                        id: request.id, path: request.path, entries: [],
                        more: false, cursor: nil, root: nil)))
                default:
                    return
                }
            }
            let adapter = AgentIntegrationHostAdapter(listener: listener)

            let report = await adapter.sessionCapabilities()

            guard case .available(let value) = report else {
                guest.connection.cancel()
                listener.stop()
                return XCTFail("expected a capability report")
            }
            let tool = value.tools.first { $0.tool == "now_machine_facts" }
            XCTAssertEqual(tool?.state, expected,
                           "commands \(commands) should make the tool "
                               + "\(expected)")
            if expected == .unavailable {
                XCTAssertEqual(tool?.missing, ["gestalt"])
            }
            guest.connection.cancel()
            listener.stop()
        }
    }

    /// A command owes no `familyPolicy` row, and this pins the reasoning where
    /// it can be argued with.
    ///
    /// The gate in `MCPCoverageTests` catches the opposite mistake — a family
    /// requirement with no row — and cannot catch this one. A row here would
    /// mean the requirement had been mistaken for a message family, and would
    /// suggest the ledger could probe it, when a command's availability comes
    /// off `help` for free.
    func testTheCommandOwesNoFamilyPolicyRow() {
        XCTAssertEqual(
            MachineFactsProjection.requires,
            [AgentIntegrationCapabilityNames.gestaltCommand])
        XCTAssertEqual(
            MachineFactsProjection.exposes,
            [AgentIntegrationCapabilityNames.gestaltCommand],
            "The rows the guest gathered ARE the answer; nothing about "
                + "gestalt is consumed internally.")
        XCTAssertFalse(
            AgentIntegrationCapabilityLedger.familyPolicy.contains {
                $0.family == AgentIntegrationCapabilityNames.gestaltCommand
            },
            "gestalt is a command. A familyPolicy row would account for it "
                + "twice and imply the ledger could probe it.")
        XCTAssertTrue(
            AgentIntegrationCapabilityNames.all.contains(
                AgentIntegrationCapabilityNames.gestaltCommand),
            "The hand-maintained set is the review gate; a requirement "
                + "missing from it resolves against nothing.")
    }

    // MARK: - The projection's own bound, and what it publishes

    /// It takes nothing, and a caller sending anything is told so before a
    /// Macintosh is asked. Notably a group: the answer already contains every
    /// group, so a selector would be a narrower question this row does not
    /// serve.
    func testTheProjectionAcceptsNoArguments() async {
        let refused: [Any?] = [
            ["group": "cpu"],
            ["full": true],
            ["snapshot": true],
            "gestalt",
            [1, 2, 3],
        ]
        for raw in refused {
            let outcome = await MachineFactsProjection.invoke(
                .init(raw: raw), through: MachineFactsStubHost())
            guard case .invalidArguments(let message) = outcome else {
                return XCTFail(
                    "accepted \(String(describing: raw)) as arguments")
            }
            XCTAssertEqual(message, "now_machine_facts accepts no arguments")
        }
    }

    /// Absent and empty both pass, the host is asked once, and the guest's own
    /// words reach the caller.
    func testAnEmptyCallReachesTheHostAndTheRowsSurvive() async throws {
        for raw in [nil, [String: Any]()] as [Any?] {
            let host = MachineFactsStubHost()
            let outcome = await MachineFactsProjection.invoke(
                .init(raw: raw), through: host)

            guard case .value(let value) = outcome else {
                return XCTFail("an argument-free call should reach the host")
            }
            let calls = await host.calls
            XCTAssertEqual(calls, 1)
            let json = String(
                decoding: try value.encoded(using: JSONEncoder()),
                as: UTF8.self)
            XCTAssertTrue(json.contains("\"outcome\":\"completed\""))
            /* Without the model's slash: an encoder escapes "/" by default,
               which is the encoder's business rather than this row's. */
            XCTAssertTrue(json.contains("PowerBook 1400c"),
                          "The guest's own words reach the caller unedited.")
            XCTAssertNil(
                value.attachment,
                "This row answers in JSON; only capture attaches anything.")
        }
    }

    /// **The PowerPC-only sentence must not read as a mute machine.**
    ///
    /// The 68K guest samples most of these facts for its own panel and the
    /// census reports them on both guests; what is missing there is this
    /// VERB. A description that said "the 68K guest cannot report its CPU"
    /// would be false, and this is the assertion that keeps the wording
    /// honest — the one thing about this row a reader is most likely to
    /// mis-summarise.
    func testTheDescriptionSaysWhatIsMissingWithoutSlanderingTheMachine()
        throws {
        let descriptor = MachineFactsProjection.operationDescriptor.mcpToolDescriptor
        let description = try XCTUnwrap(
            descriptor["description"] as? String)
        XCTAssertTrue(
            description.contains("command table has no gestalt"),
            "The absence is the VERB's, and it is named as the guest's own "
                + "command table rather than as a limit of the machine.")
        XCTAssertTrue(
            description.contains("now_hardware_census"),
            "A caller told this is unavailable must be pointed at the "
                + "capability that answers the overlapping facts on every "
                + "guest, or the honest reading is that nobody can ask.")
        XCTAssertFalse(
            description.lowercased().contains("cannot report"),
            "That machine can report most of these facts — by another "
                + "route. Saying otherwise is the one sentence this row "
                + "must not contain.")
        let annotations = try XCTUnwrap(
            descriptor["annotations"] as? [String: Any])
        XCTAssertEqual(annotations["readOnlyHint"] as? Bool, true)
        XCTAssertEqual(annotations["destructiveHint"] as? Bool, false)
        XCTAssertNil(
            (descriptor["inputSchema"] as? [String: Any])?["required"],
            "Nothing is required because nothing is accepted.")
    }
}

/// Answers one report and counts the calls. Everything else says "no host",
/// which is what the client protocol's defaults are for.
private actor MachineFactsStubHost: AgentIntegrationClient {
    private(set) var calls = 0

    func machineFacts() async -> AgentIntegrationGuestRowReportResult {
        calls += 1
        return .completed(.init(
            verb: "gestalt",
            groups: [
                .init(name: "snapshot", rows: [
                    .init(label: "Model", value: "PowerBook 1400c/166"),
                    .init(label: "System", value: "Mac OS 9.1"),
                ]),
                .init(name: "hw", rows: [
                    .init(label: "ROM version", value: "$077D"),
                ]),
            ],
            observedAt: Self.moment))
    }

    /// Fixed so an encode round trip cannot drift on sub-second precision.
    private static let moment = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Everything else answers "no host"

    func sessionHealth() async -> AgentIntegrationSessionHealthResult {
        .unavailable(.host)
    }

    func sessionCapabilities(probeCostly: Bool) async
        -> AgentIntegrationSessionCapabilitiesResult {
        .unavailable(.host)
    }

    func listProcesses() async -> AgentIntegrationProcessListResult {
        .unavailable(.host)
    }

    func launchSoftware(_ selection: AgentIntegrationLaunchSelection) async
        -> AgentIntegrationLaunchSoftwareResult {
        .unavailable(.host)
    }

    func requestQuit(reference: String) async
        -> AgentIntegrationQuitResult {
        .unavailable(.host)
    }

    func transferApprovedArtifact(receipt: String) async
        -> AgentIntegrationArtifactTransferResult {
        .unavailable(.host)
    }

    func guestFilesCapabilities() async
        -> AgentIntegrationGuestFileCapabilitiesResult {
        .hostUnavailable(.host)
    }

    func listGuestFiles(path: String, cursor: Int?) async
        -> AgentIntegrationGuestFileListResult {
        .hostUnavailable(.host)
    }

    func statGuestFile(path: String) async
        -> AgentIntegrationGuestFileStatResult {
        .hostUnavailable(.host)
    }

    func catalogSearch() async -> AgentIntegrationGuestRowReportResult {
        .unavailable(.host)
    }
}
