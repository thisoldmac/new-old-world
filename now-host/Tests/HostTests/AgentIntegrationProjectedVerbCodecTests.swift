import XCTest
@testable import NOWAgentIntegration

/// The eleven verbs P1a added, against their own codec.
///
/// The batch's whole risk is that one large commit lands with no
/// capability's tests covering it, so these cover the part that is
/// actually here: the serialization, the per-operation key sets, and the
/// honest answer the dispatch gives until each capability is wired.
///
/// Two rules shape the file. The request cases are decoded from
/// HAND-AUTHORED JSON wherever the point is that a decode branch admits
/// something — a round trip through our own encoder would test one half
/// twice, which is how `guestSelector` came to be encoded by a codec that
/// refused it. And the response-side guard is derived from the type with a
/// `Mirror`, so a twelfth result field cannot be admitted-but-uncounted the
/// way it could if this file listed the fields itself.
enum AgentIntegrationProjectedVerbSamples {
    static let processReference =
        "now-process-00000000-0000-0000-0000-000000000000"

    /// One request per shape P1a can produce — fourteen, for eleven
    /// operations, because the mutation lane has four intentions and the
    /// two paginated reads have a page and a continuation.
    ///
    /// Shared with `AgentIntegrationAddressingCodecTests`' per-operation
    /// selector sweep rather than written out twice: two lists is how the
    /// second one gets forgotten.
    static let projected: [AgentIntegrationLocalRequest] = [
        .census(),
        .census(probe: "volumes", cursor: 16),
        .softwareInventory(domain: .apps),
        .softwareInventory(domain: .extensions, cursor: 11),
        .guestFileDownload(path: "Macintosh HD:Lab:hello.txt"),
        .bringToFront(reference: processReference),
        .guestFileMove(path: "Macintosh HD:Lab:a",
                       toPath: "Macintosh HD:Lab:b"),
        .guestFileTrash(path: "Macintosh HD:Lab:a"),
        .guestFileRestore(trashedAs: "a", toPath: "Macintosh HD:Lab:a"),
        .guestFileMakeDirectory(path: "Macintosh HD:Lab:new"),
        .transferCancel(),
        .guestLogTail(),
        .guestLogTail(lines: 40),
        .machineFacts(),
        .catalogSearch(),
        .revealItem(target: "SimpleText"),
        .diagnostics(probe: .vprobe),
        .diagnostics(probe: .shotdiag),
        .diagnostics(probe: .putstat),
    ]

    /// Every P1a operation, so a test can assert it covered all of them
    /// rather than however many samples someone remembered to write.
    static let operations: Set<AgentIntegrationLocalRequest.Operation> = [
        .census, .softwareInventory, .guestFileDownload, .bringToFront,
        .guestFileMutation, .transferCancel, .guestLogTail, .machineFacts,
        .catalogSearch, .revealItem, .diagnostics,
    ]
}

@MainActor
final class AgentIntegrationProjectedVerbCodecTests: XCTestCase {
    private typealias Samples = AgentIntegrationProjectedVerbSamples

    private func temporaryEndpoint() throws
        -> (AgentIntegrationEndpoint, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "nat-p1a-\(UUID().uuidString.prefix(8))",
                isDirectory: true)
        return (AgentIntegrationEndpoint(
            directoryURL: root,
            socketURL: root.appendingPathComponent("host.sock")), root)
    }

    private func requestObject(
        _ operation: String,
        _ fields: [String: Any] = [:]
    ) throws -> Data {
        var object: [String: Any] = [
            "version": AgentIntegrationLocalProtocol.version,
            "requestID": UUID().uuidString,
            "operation": operation,
        ]
        for (key, value) in fields { object[key] = value }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func assertRefused(
        _ operation: String,
        _ fields: [String: Any],
        _ because: String,
        line: UInt = #line
    ) throws {
        let raw = try requestObject(operation, fields)
        XCTAssertThrowsError(
            try AgentIntegrationLocalCodec.decodeRequest(raw),
            because, line: line)
    }

    // MARK: - The samples cover the operations

    /// The sample list is the input to most of this file, so it is worth one
    /// test that it is not quietly missing an operation.
    func testTheSamplesCoverEveryProjectedOperation() {
        XCTAssertEqual(
            Set(Samples.projected.map(\.operation)),
            Samples.operations)
    }

    // MARK: - Every request encodes and decodes

    func testEveryProjectedRequestSurvivesTheCodec() throws {
        for sample in Samples.projected {
            let encoded = try AgentIntegrationLocalCodec.encode(sample)
            let decoded = try AgentIntegrationLocalCodec.decodeRequest(
                encoded)
            XCTAssertEqual(
                decoded, sample,
                "\(sample.operation.rawValue) did not survive a round trip")
        }
    }

    /// The same, addressed. Redundant with the addressing file's sweep on
    /// purpose: that one asserts the selector arrives, this one asserts the
    /// rest of the request still does with it present.
    func testEveryProjectedRequestSurvivesAddressed() throws {
        for sample in Samples.projected {
            var addressed = sample
            addressed.guestSelector = "pb1400c"
            let encoded = try AgentIntegrationLocalCodec.encode(addressed)
            let decoded = try AgentIntegrationLocalCodec.decodeRequest(
                encoded)
            XCTAssertEqual(decoded, addressed)
        }
    }

    // MARK: - Companion-authored requests, not ours

    func testCompanionAuthoredCensusRequestIsAdmitted() throws {
        let decoded = try AgentIntegrationLocalCodec.decodeRequest(
            try requestObject("census", ["censusProbe": "identity"]))
        XCTAssertEqual(decoded.operation, .census)
        XCTAssertEqual(decoded.censusProbe, "identity")
        XCTAssertNil(decoded.censusCursor)
    }

    /// Zero is a legal census cursor — "start the probe over" — and is NOT a
    /// legal software cursor. Two adjacent paginated reads with different
    /// floors is exactly the kind of thing one shared helper would have
    /// flattened, so both halves are asserted.
    func testCensusAcceptsCursorZeroAndSoftwareDoesNot() throws {
        let census = try AgentIntegrationLocalCodec.decodeRequest(
            try requestObject(
                "census", ["censusProbe": "volumes", "censusCursor": 0]))
        XCTAssertEqual(census.censusCursor, 0)

        try assertRefused(
            "software_inventory",
            ["softwareDomain": "apps", "softwareCursor": 0],
            "the software inventory has no page zero")
    }

    func testCompanionAuthoredSoftwareRequestIsAdmitted() throws {
        let decoded = try AgentIntegrationLocalCodec.decodeRequest(
            try requestObject(
                "software_inventory",
                ["softwareDomain": "cdevs", "softwareCursor": 4]))
        XCTAssertEqual(decoded.softwareDomain, .cdevs)
        XCTAssertEqual(decoded.softwareCursor, 4)
    }

    func testCompanionAuthoredMutationsAreAdmitted() throws {
        let move = try AgentIntegrationLocalCodec.decodeRequest(
            try requestObject("guest_file_mutation", [
                "guestFileMutation": "move",
                "guestFilePath": "Macintosh HD:Lab:a",
                "guestFileDestinationPath": "Macintosh HD:Lab:b",
            ]))
        XCTAssertEqual(move.guestFileMutation, .move)
        XCTAssertEqual(move.guestFileDestinationPath,
                       "Macintosh HD:Lab:b")

        let restore = try AgentIntegrationLocalCodec.decodeRequest(
            try requestObject("guest_file_mutation", [
                "guestFileMutation": "restore",
                "guestFilePath": "Macintosh HD:Lab:a",
                "guestFileTrashName": "a",
            ]))
        XCTAssertEqual(restore.guestFileTrashName, "a")

        for intention in ["trash", "mkdir"] {
            let decoded = try AgentIntegrationLocalCodec.decodeRequest(
                try requestObject("guest_file_mutation", [
                    "guestFileMutation": intention,
                    "guestFilePath": "Macintosh HD:Lab:a",
                ]))
            XCTAssertNil(decoded.guestFileDestinationPath)
            XCTAssertNil(decoded.guestFileTrashName)
        }
    }

    func testCompanionAuthoredArgumentlessVerbsAreAdmitted() throws {
        for operation in ["transfer_cancel", "machine_facts",
                          "catalog_search", "guest_log_tail"] {
            let decoded = try AgentIntegrationLocalCodec.decodeRequest(
                try requestObject(operation))
            XCTAssertEqual(decoded.operation.rawValue, operation)
        }
    }

    func testCompanionAuthoredDiagnosticsNamesItsProbe() throws {
        for probe in AgentIntegrationDiagnosticProbe.allCases {
            let decoded = try AgentIntegrationLocalCodec.decodeRequest(
                try requestObject(
                    "diagnostics", ["diagnosticProbe": probe.rawValue]))
            XCTAssertEqual(decoded.diagnosticProbe, probe)
        }
    }

    // MARK: - The strict decoder admits exactly what it should

    /// A field that belongs to another operation is REFUSED, not ignored.
    /// The key-set equality is what does this, and it is the reason the new
    /// branches do not each restate a list of nils.
    func testAForeignFieldIsRefusedOnEveryProjectedOperation() throws {
        /* Keys that belong to a PRE-P1a operation and to no projected one,
           so the sweep can apply all of them to all of the samples.
           Projected-on-projected pollution is checked below by name — the
           first draft of this test used `logLineCount` here and failed
           correctly, because a bare `guest_log_tail` may carry it. */
        let foreign: [String: Any] = [
            "approvalReceipt":
                "now-artifact-00000000-0000-0000-0000-000000000000",
            "probeCostly": true,
            "guestFileCursor": 2,
        ]
        for sample in Samples.projected {
            let encoded = try AgentIntegrationLocalCodec.encode(sample)
            guard let object = try JSONSerialization.jsonObject(
                with: encoded) as? [String: Any] else {
                return XCTFail("a request did not encode as an object")
            }
            for (key, value) in foreign where object[key] == nil {
                var polluted = object
                polluted[key] = value
                let raw = try JSONSerialization.data(
                    withJSONObject: polluted)
                XCTAssertThrowsError(
                    try AgentIntegrationLocalCodec.decodeRequest(raw),
                    "\(sample.operation.rawValue) accepted a \(key) it has "
                        + "no use for")
            }
        }
    }

    /// And one projected operation carrying another's field, by name — the
    /// half the sweep above cannot do generically, because a field legal on
    /// one projected operation is legal there in every sample of it.
    func testOneProjectedOperationsFieldIsRefusedOnAnother() throws {
        try assertRefused(
            "census",
            ["censusProbe": "identity", "revealTarget": "SimpleText"],
            "a census reveals nothing")
        try assertRefused(
            "reveal_item",
            ["revealTarget": "SimpleText", "logLineCount": 5],
            "a reveal reads no log")
        try assertRefused(
            "machine_facts", ["diagnosticProbe": "vprobe"],
            "Gestalt is not a diagnostics probe")
        try assertRefused(
            "diagnostics",
            ["diagnosticProbe": "vprobe", "censusCursor": 1],
            "a diagnostics run does not paginate")
        try assertRefused(
            "transfer_cancel",
            ["guestFilePath": "Macintosh HD:Lab:a"],
            "a cancel names no file — the lane holds one transfer")
        try assertRefused(
            "guest_file_download",
            ["guestFilePath": "Macintosh HD:Lab:a",
             "guestFileMutation": "move"],
            "a download mutates nothing")
    }

    func testARequiredFieldMissingIsRefused() throws {
        try assertRefused("census", [:], "a census names its probe")
        try assertRefused("software_inventory", [:],
                          "an inventory names its domain")
        try assertRefused("guest_file_download", [:],
                          "a download names a path")
        try assertRefused("bring_to_front", [:],
                          "a front names its reference")
        try assertRefused("guest_file_mutation",
                          ["guestFilePath": "Macintosh HD:Lab:a"],
                          "a mutation says which one it is")
        try assertRefused("reveal_item", [:], "a reveal names its target")
        try assertRefused("diagnostics", [:],
                          "a diagnostics request names its probe")
    }

    func testEmptyAndOversizeSelectionsAreRefused() throws {
        try assertRefused("census", ["censusProbe": ""],
                          "an empty probe names nothing")
        try assertRefused("reveal_item", ["revealTarget": ""],
                          "an empty target names nothing")
        try assertRefused(
            "reveal_item",
            ["revealTarget": String(repeating: "x", count: 256)],
            "a target past the bound is refused here, not on the guest")
        try assertRefused("guest_file_download", ["guestFilePath": ""],
                          "an empty path names nothing")
        try assertRefused(
            "guest_file_download",
            ["guestFilePath": String(repeating: "x", count: 224)],
            "a path past the guest-files bound is refused")
    }

    /// The guest ring holds at most 2000 lines, so a request for more is
    /// refused HERE — a walk of round trips to a 68030 to be told the same
    /// thing is a cost with no information in it. The bound moved from one
    /// page's 40 to the ring's size when `tail` learned to page (v13).
    func testAnOversizeLogTailIsRefused() throws {
        let most = AgentIntegrationGuestLogPolicy.maximumLineCount
        let admitted = try AgentIntegrationLocalCodec.decodeRequest(
            try requestObject("guest_log_tail", ["logLineCount": most]))
        XCTAssertEqual(admitted.logLineCount, most)

        try assertRefused("guest_log_tail", ["logLineCount": most + 1],
                          "\(most + 1) lines is past the ring's own size")
        try assertRefused("guest_log_tail", ["logLineCount": 0],
                          "zero lines is not a request")
        try assertRefused("guest_log_tail", ["logArea": "continuity"],
                          "a tag wider than the 6-character field can "
                              + "never match a line")
    }

    func testANegativeCensusCursorIsRefused() throws {
        try assertRefused(
            "census", ["censusProbe": "volumes", "censusCursor": -1],
            "there is no page before the first")
    }

    /// Each intention's second path is required by exactly one of them and
    /// refused on the others. A move with no destination and a restore with
    /// no trash name are requests nothing can serve, and a trash carrying a
    /// destination is a caller who thinks it is a move.
    func testTheMutationIntentionsDoNotShareEachOthersFields() throws {
        try assertRefused("guest_file_mutation", [
            "guestFileMutation": "move",
            "guestFilePath": "Macintosh HD:Lab:a",
        ], "a move with nowhere to go")
        try assertRefused("guest_file_mutation", [
            "guestFileMutation": "restore",
            "guestFilePath": "Macintosh HD:Lab:a",
        ], "a restore with no name from the Trash")
        try assertRefused("guest_file_mutation", [
            "guestFileMutation": "trash",
            "guestFilePath": "Macintosh HD:Lab:a",
            "guestFileDestinationPath": "Macintosh HD:Lab:b",
        ], "a trash is not a move")
        try assertRefused("guest_file_mutation", [
            "guestFileMutation": "mkdir",
            "guestFilePath": "Macintosh HD:Lab:a",
            "guestFileTrashName": "a",
        ], "a mkdir has nothing to do with the Trash")
        try assertRefused("guest_file_mutation", [
            "guestFileMutation": "move",
            "guestFilePath": "Macintosh HD:Lab:a",
            "guestFileDestinationPath": "Macintosh HD:Lab:b",
            "guestFileTrashName": "a",
        ], "a move carrying both second paths")
    }

    /// The reference vocabulary is `requestQuit`'s, deliberately — so an
    /// arbitrary string is refused here exactly as it is there.
    func testBringToFrontRefusesAnythingButAProcessReference() throws {
        let admitted = try AgentIntegrationLocalCodec.decodeRequest(
            try requestObject(
                "bring_to_front",
                ["processReference": Samples.processReference]))
        XCTAssertEqual(admitted.processReference,
                       Samples.processReference)

        try assertRefused("bring_to_front",
                          ["processReference": "SimpleText"],
                          "a name is not a process reference")
    }

    // MARK: - Every result case survives the response codec

    private func responses() -> [(String, AgentIntegrationLocalResponse)] {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let report = AgentIntegrationGuestRowReport(
            verb: "gestalt",
            groups: [.init(name: "cpu", rows: [
                .init(label: "Processor", value: "603ev"),
            ])],
            note: nil,
            observedAt: now)
        let receipt = AgentIntegrationGuestFileReceipt(
            commandID: UUID(),
            sessionID: nil,
            policyVersion: 1,
            operation: .download,
            startedAt: now,
            completedAt: now,
            outcome: .success,
            wireRequestCount: 3,
            affectedPaths: ["Macintosh HD:Lab:hello.txt"])
        let mutationReceipt = AgentIntegrationGuestFileReceipt(
            commandID: UUID(),
            sessionID: nil,
            policyVersion: 1,
            operation: .trash,
            startedAt: now,
            completedAt: now,
            outcome: .success,
            wireRequestCount: 1)
        let id = UUID()
        return [
            ("census", .init(requestID: id, censusResult: .completed(
                .init(probe: "identity",
                      outcome: .partial,
                      columns: ["Fact", "Raw", "Meaning"],
                      rows: [["Model", "0x1F2", "PowerBook 1400c"]],
                      hasMore: true,
                      nextCursor: 16,
                      total: 32,
                      note: "the PowerPC path reads 20 bytes",
                      observedAt: now)))),
            ("census refused", .init(
                requestID: id,
                censusResult: .refused(.init(
                    code: "unknown-probe", message: "no such probe")))),
            ("software", .init(
                requestID: id,
                softwareInventoryResult: .completed(
                    .init(domain: .apps,
                          entries: [.init(name: "SimpleText",
                                          path: "Macintosh HD:SimpleText",
                                          fileType: "APPL",
                                          creator: "ttxt",
                                          sizeK: -1,
                                          disabled: false,
                                          running: true,
                                          version: "1.4")],
                          hasMore: false,
                          nextCursor: nil,
                          note: nil,
                          observedAt: now)))),
            ("download", .init(
                requestID: id,
                guestFileDownloadResult: .completed(
                    receipt: receipt,
                    value: .init(guestPath: "Macintosh HD:Lab:hello.txt",
                                 hostPath: "/tmp/hello.txt",
                                 bytes: 4,
                                 container: "macbinary",
                                 crc32: 42,
                                 resumeToken: "t",
                                 elapsedMs: 900),
                    failure: nil))),
            ("front", .init(
                requestID: id,
                bringToFrontResult: .completed(
                    .init(reference: Samples.processReference,
                          name: "SimpleText",
                          outcome: .unconfirmed,
                          revalidatedAt: now,
                          observedAt: now)))),
            ("mutation", .init(
                requestID: id,
                guestFileMutationResult: .completed(
                    receipt: mutationReceipt,
                    value: .init(mutation: .trash,
                                 path: nil,
                                 trashedAs: "hello.txt",
                                 observedAt: now),
                    failure: nil))),
            ("cancel", .init(
                requestID: id,
                transferCancelResult: .completed(
                    .init(outcome: .nothingToCancel,
                          direction: nil,
                          hostLaneFree: true,
                          note: "no transfer was in flight",
                          observedAt: now)))),
            ("log tail", .init(
                requestID: id, guestLogTailResult: .completed(.init(
                    lines: ["21:04:11 wire   connected to 10.0.1.7"],
                    requested: 200,
                    matching: 1,
                    shown: "1 of 1",
                    area: nil,
                    ringCapacity: 2000,
                    guestFile: nil,
                    pages: 1,
                    observedAt: now)))),
            ("machine facts", .init(
                requestID: id, machineFactsResult: .completed(report))),
            ("catalog search", .init(
                requestID: id, catalogSearchResult: .completed(report))),
            ("reveal", .init(
                requestID: id, revealItemResult: .completed(report))),
            ("diagnostics", .init(
                requestID: id, diagnosticsResult: .unavailable(.guest))),
            ("not implemented", .init(
                requestID: id,
                notImplemented: .notWired("machine_facts"))),
        ]
    }

    func testEveryProjectedResponseSurvivesTheCodec() throws {
        for (name, response) in responses() {
            let encoded = try AgentIntegrationLocalCodec.encode(response)
            let decoded = try AgentIntegrationLocalCodec.decodeResponse(
                encoded)
            XCTAssertEqual(decoded, response,
                           "\(name) did not survive a round trip")
        }
    }

    /// One response, one answer — still true with twelve more fields
    /// counted. Derived with a `Mirror` so a thirteenth field admitted by
    /// the allowlist and left out of the count fails HERE, which is the
    /// defect this pair of gates exists to prevent.
    func testEveryResponseFieldIsCountedByTheExactlyOneGuard() throws {
        let sample = AgentIntegrationLocalResponse(
            requestID: UUID(), notImplemented: .notWired("census"))
        let fields = Mirror(reflecting: sample).children
            .compactMap(\.label)
        XCTAssertTrue(fields.contains("notImplemented"))
        XCTAssertTrue(fields.contains("censusResult"))

        for field in fields
        where !["version", "requestID", "processListResult"]
            .contains(field) {
            let raw = try JSONSerialization.data(withJSONObject: [
                "version": AgentIntegrationLocalProtocol.version,
                "requestID": UUID().uuidString,
                "processListResult": [String: Any](),
                field: [String: Any](),
            ])
            XCTAssertThrowsError(
                try AgentIntegrationLocalCodec.decodeResponse(raw),
                "\(field) is admitted but not counted as a result"
            ) { error in
                XCTAssertEqual(
                    error as? AgentIntegrationLocalTransportError,
                    .invalidMessage(
                        "Response must contain exactly one result or error"),
                    "\(field) beside a result was refused for the wrong "
                        + "reason")
            }
        }
    }

    // MARK: - The unwired answer, over the socket

    /// The state this commit actually ships: the verb reaches the host, the
    /// host says nothing serves it, and the client raises that as itself.
    ///
    /// A typed refusal and not an empty success, which is the whole point —
    /// an empty `softwareInventory` would read as a fact about the Mac, and
    /// whoever wires it would be debugging a machine that answered fine.
    func testAnUnwiredVerbAnswersNotImplementedOverTheSocket()
        async throws {
        let (endpoint, root) = try temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        var seen: [AgentIntegrationLocalRequest.Operation] = []
        let server = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            handler: { request in
                seen.append(request.operation)
                /* The same answer App.swift's dispatch gives, and the
                   reason this is a stand-in rather than the shipped closure
                   is that the closure is built inside the app's own
                   startup — every test on this surface stands one up the
                   same way. */
                return .notImplemented(
                    .notWired(request.operation.rawValue))
            })
        try server.start()
        defer { server.stop() }
        let client = try AgentIntegrationLocalClient(endpoint: endpoint)

        var thrown: Error?
        do {
            _ = try await client.machineFacts()
        } catch {
            thrown = error
        }

        XCTAssertEqual(seen, [.machineFacts])
        XCTAssertEqual(
            thrown as? AgentIntegrationLocalTransportError,
            .notImplemented(.notWired("machine_facts")))
    }

    /// And the code it carries, because a projection's adapter will read it
    /// and a face may show it.
    func testTheUnwiredRefusalNamesItselfAndTheOperation() {
        let pending = AgentIntegrationUnavailable.notWired("catalog_search")
        XCTAssertEqual(pending.code, "now-capability-not-wired")
        XCTAssertTrue(pending.message.contains("catalog_search"))
    }
}
