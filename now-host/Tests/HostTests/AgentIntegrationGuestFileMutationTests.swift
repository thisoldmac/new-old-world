import XCTest
@testable import Host
import NOWAgentIntegration

/// The mutating guest-Files capability's own coverage, aimed at the things
/// that are genuinely its own: **what it refuses to ask for, and what a
/// destructive answer has to carry.**
///
/// The read-only rows in this family could be wrong and cost a caller a bad
/// answer. This one can be wrong and cost somebody a file, so most of what is
/// below is about the requests that never reach a Macintosh — an overwrite,
/// a path out of the share, a move into itself, a crossed key set — and about
/// the one field that makes a trash reversible.
@MainActor
final class AgentIntegrationGuestFileMutationTests: XCTestCase {

    // MARK: - What a caller may state

    /// Every refusal the projection owns, in one place, because the list IS
    /// the authority model: what cannot be said cannot be done.
    ///
    /// `overwrite` is in here deliberately. The contract's `file.move` has
    /// the flag and this surface has no spelling for it — a caller that asks
    /// is refused rather than quietly served without it, so nobody comes away
    /// believing they replaced something.
    func testTheProjectionRefusesEveryShapeItDoesNotOwn() async {
        let expected =
            "now_guest_files_mutate requires one bounded root-relative path and one of move (with toPath), trash, restore (with trashedAs) or mkdir"
        let long = String(repeating: "a", count: 224)
        let refused: [Any?] = [
            nil,
            [String: Any](),
            // No intention, or one nothing serves.
            ["path": "Lab:a"],
            ["mutation": "delete", "path": "Lab:a"],
            ["mutation": "prune", "path": "Lab:a"],
            // The root itself is not an item.
            ["mutation": "trash", "path": ""],
            ["mutation": "mkdir", "path": ""],
            // Bounds.
            ["mutation": "trash", "path": long],
            ["mutation": "move", "path": "Lab:a", "toPath": long],
            // Crossed key sets, each refused rather than ignored.
            ["mutation": "move", "path": "Lab:a"],
            ["mutation": "move", "path": "Lab:a", "toPath": "Lab:b",
             "trashedAs": "a"],
            ["mutation": "trash", "path": "Lab:a", "toPath": "Lab:b"],
            ["mutation": "mkdir", "path": "Lab:a", "trashedAs": "a"],
            ["mutation": "restore", "path": "Lab:a"],
            ["mutation": "restore", "path": "Lab:a", "trashedAs": "a",
             "toPath": "Lab:b"],
            // A move that is not a move.
            ["mutation": "move", "path": "Lab:a", "toPath": "Lab:a"],
            ["mutation": "move", "path": "Lab", "toPath": "Lab:inside"],
            // A trashed name is a NAME.
            ["mutation": "restore", "path": "Lab:a",
             "trashedAs": "Trash:a"],
            ["mutation": "restore", "path": "Lab:a",
             "trashedAs": String(repeating: "n", count: 32)],
            ["mutation": "restore", "path": "Lab:a", "trashedAs": ""],
            // Nothing else is a parameter of this call — least of all this.
            ["mutation": "move", "path": "Lab:a", "toPath": "Lab:b",
             "overwrite": true],
            ["mutation": "trash", "path": "Lab:a", "recursive": true],
            // Wrong types.
            ["mutation": 4, "path": "Lab:a"],
            ["mutation": "trash", "path": 4],
        ]
        for raw in refused {
            let outcome = await GuestFilesMutateProjection.invoke(
                .init(raw: raw), through: MutationStubHost())
            guard case .invalidArguments(let message) = outcome else {
                return XCTFail(
                    "accepted \(String(describing: raw)) as a mutation")
            }
            XCTAssertEqual(message, expected)
        }
    }

    /// The four accepted forms reach the host as themselves, with their own
    /// keys and nothing else's.
    func testEachIntentionReachesTheHostWithItsOwnKeys() async throws {
        let host = MutationStubHost()
        let calls: [[String: Any]] = [
            ["mutation": "move", "path": "Lab:a", "toPath": "Lab:Old:b"],
            ["mutation": "trash", "path": "Lab:a"],
            ["mutation": "restore", "path": "Lab:a", "trashedAs": "a 2"],
            ["mutation": "mkdir", "path": "Lab:New"],
        ]
        for call in calls {
            guard case .value = await GuestFilesMutateProjection.invoke(
                .init(raw: call), through: host) else {
                return XCTFail("refused \(call)")
            }
        }

        let asked = await host.asked
        XCTAssertEqual(asked.map(\.mutation),
                       [.move, .trash, .restore, .mkdir])
        XCTAssertEqual(asked[0].destinationPath, "Lab:Old:b")
        XCTAssertNil(asked[0].trashedAs)
        XCTAssertNil(asked[1].destinationPath)
        XCTAssertNil(asked[1].trashedAs)
        XCTAssertEqual(asked[2].path, "Lab:a")
        XCTAssertEqual(asked[2].trashedAs, "a 2")
        XCTAssertNil(asked[2].destinationPath)
        XCTAssertNil(asked[3].destinationPath)
    }

    /// The four families are required TOGETHER, and all four are exposed.
    ///
    /// The pairing is the safety property: a row that required `trash`
    /// without `restore` would be able to remove something it could not put
    /// back. Stated as a test because it is the one requirement here that
    /// looks like over-declaration and is not.
    func testTheRowRequiresAndExposesTheWholeLane() {
        let names = AgentIntegrationCapabilityNames.self
        let lane = Set([names.fileMove, names.fileTrash,
                        names.fileRestore, names.fileMkdir])

        XCTAssertEqual(Set(GuestFilesMutateProjection.requires), lane)
        XCTAssertEqual(Set(GuestFilesMutateProjection.exposes), lane)
        XCTAssertTrue(lane.isSubset(of: AgentIntegrationCapabilityNames.all),
                      "A requirement outside `all` is a name no gate checks.")
    }

    /// A caller deciding whether to ask a human first reads the annotation.
    /// `destructiveHint` is true even though a trash is reversible, because
    /// "reversible by whoever kept the receipt" is not non-destructive.
    func testTheRowAnnouncesItselfAsDestructiveAndNotIdempotent() throws {
        let annotations = try XCTUnwrap(
            GuestFilesMutateProjection.mcpDescriptor["annotations"]
                as? [String: Any])

        XCTAssertEqual(annotations["readOnlyHint"] as? Bool, false)
        XCTAssertEqual(annotations["destructiveHint"] as? Bool, true)
        XCTAssertEqual(annotations["idempotentHint"] as? Bool, false)
    }

    // MARK: - What reaches the machine

    /// Both of a move's paths are composed beneath `guestRoot`, and the
    /// overwrite flag is absent from the wire.
    ///
    /// Two facts in one test on purpose: they are the same guarantee read
    /// from two ends — the caller cannot choose where in the volume a move
    /// happens, and cannot make it replace anything when it gets there.
    func testAMoveIsComposedBeneathTheRootAndNeverAsksToOverwrite()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let sessionID = UUID()
        let commands = service(listener: listener, root: "Lab",
                              sessionID: sessionID)
        let seen = Box<FileMove>()
        guest.onMessage = { message in
            guard case .fileMove(let request) = message else { return }
            seen.value = request
            try? guest.send(.fileResult(FileResult(
                id: request.id, ok: true, path: request.toPath)))
        }

        let response = await commands.mutate(try move("a", to: "Old:b"))

        let sent = try XCTUnwrap(seen.value)
        XCTAssertEqual(sent.path, "Lab:a")
        XCTAssertEqual(sent.toPath, "Lab:Old:b")
        XCTAssertNil(sent.overwrite,
                     "The agent lane has no spelling for overwrite, so the "
                         + "flag must not appear on the wire at all.")
        XCTAssertEqual(response.receipt.outcome, .success)
        XCTAssertEqual(response.receipt.operation, .move)
        XCTAssertEqual(response.receipt.wireRequestCount, 1)
        XCTAssertEqual(response.receipt.affectedPaths, ["a"])
        XCTAssertEqual(response.receipt.sessionID, sessionID)
        XCTAssertEqual(response.value?.path, "Old:b",
                       "The answer is in the caller's root-relative "
                           + "vocabulary, not the volume's.")
    }

    /// A trash carries back the name the Trash gave it — and that name is
    /// the only thing a restore takes, which is why it is the one field this
    /// suite checks twice.
    func testATrashAnswersWithTheNameTheTrashGaveItAndNoPath()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let commands = service(listener: listener, root: "Lab")
        let seen = Box<FileTrash>()
        guest.onMessage = { message in
            guard case .fileTrash(let request) = message else { return }
            seen.value = request
            try? guest.send(.fileResult(FileResult(
                id: request.id, ok: true, trashedAs: "Notes 2")))
        }

        let response = await commands.mutate(
            try request(.trash(path: "Notes")))

        XCTAssertEqual(seen.value?.path, "Lab:Notes")
        XCTAssertEqual(response.receipt.operation, .trash)
        XCTAssertEqual(response.value?.trashedAs, "Notes 2")
        XCTAssertNil(response.value?.path,
                     "The Trash is not below guestRoot, so there is no "
                         + "root-relative path to report.")
    }

    /// A guest that reports no trashed name is reported honestly: the
    /// trashing happened and nothing on this surface can undo it.
    func testATrashWithNoReportedNameStaysSuccessWithNoUndoKey()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let commands = service(listener: listener)
        guest.onMessage = { message in
            guard case .fileTrash(let request) = message else { return }
            try? guest.send(.fileResult(FileResult(
                id: request.id, ok: true)))
        }

        let response = await commands.mutate(
            try request(.trash(path: "Notes")))

        XCTAssertEqual(response.receipt.outcome, .success)
        XCTAssertNil(response.value?.trashedAs)
    }

    /// A restore names the item by what the Trash calls it and the path it
    /// is going back to. The name travels verbatim — it is the guest's own
    /// string and rewriting it would put something else back.
    func testARestoreCarriesTheTrashNameVerbatimAndTheDestinationScoped()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let commands = service(listener: listener, root: "Lab")
        let seen = Box<FileRestore>()
        guest.onMessage = { message in
            guard case .fileRestore(let request) = message else { return }
            seen.value = request
            try? guest.send(.fileResult(FileResult(
                id: request.id, ok: true, path: request.toPath)))
        }

        let response = await commands.mutate(
            try request(.restore(trashedAs: "Notes 2", toPath: "Notes")))

        XCTAssertEqual(seen.value?.trashedAs, "Notes 2")
        XCTAssertEqual(seen.value?.toPath, "Lab:Notes")
        XCTAssertEqual(response.receipt.operation, .restore)
        XCTAssertEqual(response.value?.path, "Notes")
    }

    /// A collision is the guest's answer, given atomically, and it arrives as
    /// `conflict` with the guest's own reason — never as a replacement.
    func testACollisionIsAConflictCarryingTheGuestsOwnReason() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let commands = service(listener: listener)
        guest.onMessage = { message in
            guard case .fileMkdir(let request) = message else { return }
            try? guest.send(.fileResult(FileResult(
                id: request.id, ok: false, code: "exists",
                reason: "io-error -48")))
        }

        let response = await commands.mutate(
            try request(.makeFolder(path: "New")))

        XCTAssertEqual(response.receipt.outcome, .conflict)
        XCTAssertNil(response.value)
        XCTAssertEqual(response.failure?.code, "now-files-exists")
        XCTAssertEqual(response.failure?.message, "io-error -48",
                       "The File Manager's own number is the only thing "
                           + "that makes such a failure debuggable from "
                           + "this side of the wire.")
    }

    /// An item that is not there is `notFound`; a guest that names no code at
    /// all is `failed` under the File Manager's own default, not `notFound`
    /// and not a success.
    func testAMissingItemAndAnUnexplainedRefusalAreDifferentOutcomes()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let commands = service(listener: listener)
        var code: String? = "not-found"
        guest.onMessage = { message in
            guard case .fileTrash(let request) = message else { return }
            try? guest.send(.fileResult(FileResult(
                id: request.id, ok: false, code: code)))
        }

        let missing = await commands.mutate(
            try request(.trash(path: "Gone")))
        XCTAssertEqual(missing.receipt.outcome, .notFound)

        code = nil
        let unexplained = await commands.mutate(
            try request(.trash(path: "Gone")))
        XCTAssertEqual(unexplained.receipt.outcome, .failed)
        XCTAssertEqual(unexplained.failure?.code, "now-files-io-error",
                       "An answer with no code is the listener's io-error "
                           + "default, which means attempted-and-broken "
                           + "rather than declined.")
    }

    /// A path the share cannot express is refused **before** anything is
    /// sent, and the receipt says so: zero wire requests.
    func testAnEscapingPathIsRefusedWithoutReachingTheGuest() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let commands = service(listener: listener, root: "Lab")
        let sent = Box<Int>()
        sent.value = 0
        guest.onMessage = { _ in sent.value = (sent.value ?? 0) + 1 }

        for path in ["..:Escape", "Lab:..:Escape", ":Absolute"] {
            let response = await commands.mutate(
                try request(.trash(path: path)))
            XCTAssertEqual(response.receipt.outcome, .refused, path)
            XCTAssertEqual(response.failure?.code, "now-files-path-invalid")
            XCTAssertEqual(response.receipt.wireRequestCount, 0)
        }
        XCTAssertEqual(sent.value, 0,
                       "A path that cannot be composed beneath the root is "
                           + "this host's refusal, not a question for the "
                           + "other machine.")
    }

    /// No paired guest is `unavailable` with a receipt, not a thrown error
    /// and not a silence.
    func testNoPairedGuestIsATypedUnavailableReceipt() async {
        let listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"))
        let commands = GuestFilesCommandService(
            listener: listener,
            policy: policy(root: ""),
            currentSessionID: { nil },
            audit: { _, _ in })

        guard let ask = AgentIntegrationGuestFileMutationRequest.trash(
            path: "Notes") else {
            return XCTFail("expected a valid trash")
        }
        let response = await commands.mutate(ask)

        XCTAssertEqual(response.receipt.outcome, .unavailable)
        XCTAssertEqual(response.failure?.code, "now-guest-unavailable")
        XCTAssertEqual(response.receipt.wireRequestCount, 0)
    }

    /// The Files log carries the path and the outcome — the half of rule 3
    /// that covers a headless call. The dispatch's own audit event names the
    /// capability and deliberately carries no path, so if this line did not
    /// exist a person at the machine could see that an agent changed
    /// something and never see what.
    func testEveryMutationIsLoggedWithItsPathAndItsOutcome() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        var lines: [String] = []
        let sessionID = UUID()
        let commands = GuestFilesCommandService(
            listener: listener,
            policy: policy(root: "Lab"),
            currentSessionID: { sessionID },
            audit: { _, line in lines.append(line) })
        guest.onMessage = { message in
            guard case .fileTrash(let request) = message else { return }
            try? guest.send(.fileResult(FileResult(
                id: request.id, ok: true, trashedAs: "Notes")))
        }

        _ = await commands.mutate(try request(.trash(path: "Notes")))

        XCTAssertTrue(lines.contains {
            $0.contains("guestFiles.trash") && $0.contains("started")
                && $0.contains("Notes")
        }, "\(lines)")
        XCTAssertTrue(lines.contains {
            $0.contains("guestFiles.trash") && $0.contains("success")
        }, "\(lines)")
    }

    // MARK: - Availability follows the guest's own answer

    /// **The PPC-only fact, expressed without anything reading which guest
    /// it is.** A guest that refuses `file.trash` in ordinary use turns the
    /// whole row `unavailable` in the capability report — because the four
    /// families are required together and the listener records the refusal
    /// the first time one is asked for.
    ///
    /// This is the test that makes the 68K answer a complete answer rather
    /// than a smaller tool: nothing here inspects a hello name, and the same
    /// code against a guest that serves the family reports the opposite.
    func testAGuestRefusingTheLaneMakesTheWholeRowUnavailable()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let commands = service(listener: listener)
        guest.onMessage = { message in
            switch message {
            case .fileTrash(let request):
                try? guest.send(.error(.init(
                    id: request.id, code: "not-implemented",
                    message: "unsupported message type")))
            case .fileList(let request):
                try? guest.send(.fileListing(FileListing(
                    id: request.id, path: "", entries: [], more: false,
                    cursor: nil, root: "Macintosh HD:")))
            /* The report's own traffic, answered so this test measures the
               ledger's derivation rather than three guest watchdogs. */
            case .commandRequest(let request):
                try? guest.send(.commandResult(CommandResult(
                    id: request.id, ok: true,
                    output: ["help": [["ls", "a verb"]]], error: nil)))
            case .processList(let request):
                try? guest.send(.processListing(ProcessListing(
                    id: request.id, processes: [], more: false,
                    cursor: nil)))
            default:
                break
            }
        }

        let refused = await commands.mutate(
            try request(.trash(path: "Notes")))
        XCTAssertEqual(refused.receipt.outcome, .refused)
        XCTAssertEqual(refused.failure?.code, "now-files-not-implemented")

        let adapter = AgentIntegrationHostAdapter(listener: listener)
        guard case .available(let report) =
                await adapter.sessionCapabilities() else {
            return XCTFail("expected a capability report")
        }
        let trash = report.families.first {
            $0.family == AgentIntegrationCapabilityNames.fileTrash
        }
        XCTAssertEqual(trash?.state, .unavailable)
        XCTAssertEqual(trash?.evidence, .refusedInUse)
        let row = report.tools.first {
            $0.tool == "now_guest_files_mutate"
        }
        XCTAssertEqual(row?.state, .unavailable)
        XCTAssertTrue(
            row?.missing.contains(
                AgentIntegrationCapabilityNames.fileTrash) == true,
            "The refused family is named in `missing`, which is what the "
                + "caller-facing sentence is composed from.")
        /* The other three are `unproven`, not `unavailable` — nothing has
           asked them — and they appear in `missing` because a requirement
           that is not AVAILABLE is missing. One refusal is enough to take
           the row down, and it does so without anything claiming to know
           the other three: the whole lane is required, so one absent family
           is a complete answer. */
        XCTAssertEqual(
            report.families.filter {
                GuestFilesMutateProjection.requires.contains($0.family)
                    && $0.state == .unproven
            }.count, 3)
    }

    /// Before anything asks, the row is `unproven` rather than `unavailable`
    /// — and it stays that way, because none of the four is ever probed.
    /// Asserted by counting: a capability report must move nothing on
    /// anybody's disk.
    func testTheCapabilityReportNeverProbesAMutatingFamily() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let mutations = Box<Int>()
        mutations.value = 0
        guest.onMessage = { message in
            switch message {
            case .fileMove, .fileTrash, .fileRestore, .fileMkdir:
                mutations.value = (mutations.value ?? 0) + 1
            case .fileList(let request):
                try? guest.send(.fileListing(FileListing(
                    id: request.id, path: "", entries: [], more: false,
                    cursor: nil, root: "Macintosh HD:")))
            /* The report's own traffic, answered so this test measures the
               ledger's derivation rather than three guest watchdogs. */
            case .commandRequest(let request):
                try? guest.send(.commandResult(CommandResult(
                    id: request.id, ok: true,
                    output: ["help": [["ls", "a verb"]]], error: nil)))
            case .processList(let request):
                try? guest.send(.processListing(ProcessListing(
                    id: request.id, processes: [], more: false,
                    cursor: nil)))
            case .softwareList(let request):
                try? guest.send(.softwareListing(SoftwareListing(
                    id: request.id, domain: request.domain, entries: [],
                    more: false, cursor: nil, note: nil)))
            default:
                break
            }
        }

        let adapter = AgentIntegrationHostAdapter(listener: listener)
        guard case .available(let report) =
                await adapter.sessionCapabilities(probeCostly: true) else {
            return XCTFail("expected a capability report")
        }

        XCTAssertEqual(mutations.value, 0,
                       "\"I would have to trash something to find out "
                           + "whether I can trash things\" is not an answer.")
        for family in GuestFilesMutateProjection.requires {
            let stated = report.families.first { $0.family == family }
            XCTAssertEqual(stated?.state, .unproven, family)
            XCTAssertEqual(stated?.evidence, .notProbedMutating, family)
        }
        XCTAssertEqual(
            report.tools.first { $0.tool == "now_guest_files_mutate" }?.state,
            .unproven)
    }

    // MARK: - Helpers

    /// A reference box, because `guest.onMessage` is a non-escaping-looking
    /// closure that outlives the statement it is written in.
    private final class Box<Value> {
        var value: Value?
    }

    private func policy(root: String = "") -> GuestFileAccessPolicy {
        let suite = "GuestFileMutation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(root, forKey: GuestFileAccessPolicy.rootKey)
        defaults.set(1, forKey: GuestFileAccessPolicy.versionKey)
        return GuestFileAccessPolicy(defaults: defaults)
    }

    private func service(listener: GuestListener,
                         root: String = "",
                         sessionID: UUID = UUID())
        -> GuestFilesCommandService {
        GuestFilesCommandService(
            listener: listener,
            policy: policy(root: root),
            currentSessionID: { sessionID },
            audit: { _, _ in })
    }

    /// Unwraps one of the failable initialisers, so a test that meant to
    /// exercise the wire cannot silently exercise the validator instead.
    private func request(
        _ built: AgentIntegrationGuestFileMutationRequest?
    ) throws -> AgentIntegrationGuestFileMutationRequest {
        try XCTUnwrap(built)
    }

    private func move(_ path: String, to destination: String) throws
        -> AgentIntegrationGuestFileMutationRequest {
        try request(.move(path: path, toPath: destination))
    }
}

/// Records the mutations it was asked for and answers one success. Everything
/// else says "no host", which is what the protocol's defaults are for.
private actor MutationStubHost: AgentIntegrationClient {
    private(set) var asked: [AgentIntegrationGuestFileMutationRequest] = []

    func mutateGuestFile(
        _ mutation: AgentIntegrationGuestFileMutationRequest
    ) async -> AgentIntegrationGuestFileMutationResult {
        asked.append(mutation)
        return .completed(
            receipt: .init(
                commandID: UUID(),
                sessionID: nil,
                policyVersion: 1,
                operation: .trash,
                startedAt: Self.moment,
                completedAt: Self.moment,
                outcome: .success,
                wireRequestCount: 1,
                affectedPaths: [mutation.path]),
            value: .init(mutation: mutation.mutation,
                         path: mutation.destinationPath ?? mutation.path,
                         trashedAs: nil,
                         observedAt: Self.moment),
            failure: nil)
    }

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
}
