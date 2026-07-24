import XCTest
@testable import NOWAgentCompanion
@testable import NOWAgentIntegration

final class NOWAgentGuestFilesTests: XCTestCase {
    private func temporaryEndpoint() -> (AgentIntegrationEndpoint, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ngf-\(UUID().uuidString.prefix(8))",
                isDirectory: true)
        return (AgentIntegrationEndpoint(
            directoryURL: root,
            socketURL: root.appendingPathComponent("host.sock")), root)
    }

    private static func request(
        id: Int,
        method: String,
        params: [String: Any]? = nil
    ) throws -> Data {
        var object: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
        ]
        object["params"] = params
        return try JSONSerialization.data(withJSONObject: object)
    }

    private static func object(_ data: Data?) throws -> [String: Any] {
        let data = try XCTUnwrap(data)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func initializedServer(
        client: AgentIntegrationClient
    ) async throws -> NOWMCPServer {
        let server = NOWMCPServer(client: client)
        _ = await server.handle(try Self.request(
            id: 1,
            method: "initialize",
            params: [
                "protocolVersion": "2025-11-25",
                "capabilities": [:],
                "clientInfo": ["name": "tests", "version": "1"],
            ]))
        _ = await server.handle(try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "method": "notifications/initialized",
            ]))
        return server
    }

    func testCapabilitiesReturnsHostUnavailableWithoutLaunchingNOW()
        async throws {
        let (endpoint, root) = temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try await initializedServer(
            client: SocketAgentIntegrationClient(endpoint: endpoint))

        let response = try Self.object(await server.handle(try Self.request(
            id: 2,
            method: "tools/call",
            params: [
                "name": "now_guest_files_capabilities",
                "arguments": [:],
            ])))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let structured = try XCTUnwrap(
            result["structuredContent"] as? [String: Any])
        let unavailable = try XCTUnwrap(
            structured["unavailable"] as? [String: Any])

        XCTAssertEqual(structured["hostAvailable"] as? Bool, false)
        XCTAssertEqual(
            unavailable["code"] as? String, "now-host-unavailable")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testListProjectsOnlyBoundedRootRelativeResults() async throws {
        let observedAt = Date(timeIntervalSince1970: 1_000)
        let receipt = guestFileReceipt(.list, observedAt: observedAt)
        let listing = AgentIntegrationGuestFileListing(
            path: "Logs",
            entries: [.init(
                path: "Logs:today.txt",
                name: "today.txt",
                isFolder: false,
                fileType: "TEXT",
                creator: "ttxt",
                dataBytes: 42,
                resourceBytes: 3,
                modified: 3_500_000_000)],
            hasMore: true,
            nextCursor: 2,
            rootLabel: "Macintosh HD:",
            observedAt: observedAt)
        let client = RecordingGuestFilesClient(
            listResult: .completed(
                receipt: receipt, value: listing, failure: nil))
        let server = try await initializedServer(client: client)

        let response = try Self.object(await server.handle(try Self.request(
            id: 2,
            method: "tools/call",
            params: [
                "name": "now_guest_files_list",
                "arguments": ["path": "Logs", "cursor": 2],
            ])))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let structured = try XCTUnwrap(
            result["structuredContent"] as? [String: Any])
        let value = try XCTUnwrap(
            structured["value"] as? [String: Any])
        let entries = try XCTUnwrap(
            value["entries"] as? [[String: Any]])

        XCTAssertEqual(structured["hostAvailable"] as? Bool, true)
        XCTAssertEqual(value["path"] as? String, "Logs")
        XCTAssertEqual(entries.first?["path"] as? String,
                       "Logs:today.txt")
        XCTAssertEqual(entries.first?["resourceBytes"] as? Int, 3)
        let call = await client.lastListCall
        XCTAssertEqual(call?.path, "Logs")
        XCTAssertEqual(call?.cursor, 2)
    }

    func testListAndStatRejectMalformedArguments() async throws {
        let server = try await initializedServer(
            client: RecordingGuestFilesClient())
        let oversized = String(
            repeating: "x",
            count: AgentIntegrationGuestFilePolicy.maximumPathScalars + 1)
        let cases: [(String, [String: Any])] = [
            ("now_guest_files_list", ["path": oversized]),
            ("now_guest_files_list", ["cursor": 0]),
            ("now_guest_files_list", ["path": 42]),
            ("now_guest_files_list", ["path": "", "extra": true]),
            ("now_guest_files_stat", ["path": ""]),
            ("now_guest_files_stat", [:]),
        ]

        for (index, item) in cases.enumerated() {
            let response = try Self.object(await server.handle(
                try Self.request(
                    id: index + 2,
                    method: "tools/call",
                    params: [
                        "name": item.0,
                        "arguments": item.1,
                    ])))
            let error = try XCTUnwrap(
                response["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? Int, -32602)
        }
    }

    func testStatReturnsTypedNotFoundReceipt() async throws {
        let observedAt = Date(timeIntervalSince1970: 1_000)
        let receipt = guestFileReceipt(
            .stat, outcome: .notFound, observedAt: observedAt)
        let client = RecordingGuestFilesClient(
            statResult: .completed(
                receipt: receipt,
                value: nil,
                failure: .init(
                    code: "now-files-not-found",
                    message: "No exact item was observed at that path")))
        let server = try await initializedServer(client: client)

        let response = try Self.object(await server.handle(try Self.request(
            id: 2,
            method: "tools/call",
            params: [
                "name": "now_guest_files_stat",
                "arguments": ["path": "Missing"],
            ])))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let structured = try XCTUnwrap(
            result["structuredContent"] as? [String: Any])
        let failure = try XCTUnwrap(
            structured["failure"] as? [String: Any])
        let projectedReceipt = try XCTUnwrap(
            structured["receipt"] as? [String: Any])

        XCTAssertEqual(failure["code"] as? String,
                       "now-files-not-found")
        XCTAssertEqual(projectedReceipt["outcome"] as? String,
                       "notFound")
        let statPath = await client.lastStatPath
        XCTAssertEqual(statPath, "Missing")
    }

    func testUploadToolsForwardOnlyBoundedTypedArguments() async throws {
        let client = RecordingGuestFilesClient()
        let server = try await initializedServer(client: client)
        let uploadID = UUID()
        let digest = String(repeating: "a", count: 64)

        _ = await server.handle(try Self.request(
            id: 2,
            method: "tools/call",
            params: [
                "name": "now_guest_files_upload_begin",
                "arguments": [
                    "destinationPath": "Drops:hello.txt",
                    "bytes": 3,
                    "sha256": digest,
                    "container": "data",
                    "fileType": "TEXT",
                    "creator": "ttxt",
                ],
            ]))
        _ = await server.handle(try Self.request(
            id: 3,
            method: "tools/call",
            params: [
                "name": "now_guest_files_upload_append",
                "arguments": [
                    "uploadID": uploadID.uuidString,
                    "offset": 0,
                    "data": Data("abc".utf8).base64EncodedString(),
                ],
            ]))
        _ = await server.handle(try Self.request(
            id: 4,
            method: "tools/call",
            params: [
                "name": "now_guest_files_upload_commit",
                "arguments": ["uploadID": uploadID.uuidString],
            ]))

        let begin = await client.lastUploadBegin
        XCTAssertEqual(begin?.destinationPath, "Drops:hello.txt")
        XCTAssertEqual(begin?.bytes, 3)
        XCTAssertEqual(begin?.sha256, digest)
        XCTAssertEqual(begin?.fileType, "TEXT")
        let append = await client.lastUploadAppend
        XCTAssertEqual(append?.uploadID, uploadID)
        XCTAssertEqual(append?.offset, 0)
        XCTAssertEqual(append?.bytes, Data("abc".utf8))
        let commit = await client.lastUploadCommit
        XCTAssertEqual(commit, uploadID)
    }

    func testUploadToolsRejectMalformedOrUnboundedArguments()
        async throws {
        let server = try await initializedServer(
            client: RecordingGuestFilesClient())
        let uploadID = UUID().uuidString
        let digest = String(repeating: "a", count: 64)
        let cases: [(String, [String: Any])] = [
            ("now_guest_files_upload_begin", [
                "destinationPath": "Drops:x",
                "bytes": -1,
                "sha256": digest,
                "container": "data",
            ]),
            ("now_guest_files_upload_begin", [
                "destinationPath": "Drops:x",
                "bytes": 1,
                "sha256": "not-a-digest",
                "container": "data",
            ]),
            ("now_guest_files_upload_begin", [
                "destinationPath": "Drops:x",
                "bytes": 1,
                "sha256": String(repeating: "١", count: 64),
                "container": "data",
            ]),
            ("now_guest_files_upload_begin", [
                "destinationPath": "Drops:x",
                "bytes": 1,
                "sha256": digest,
                "container": "data",
                "modified": -1,
            ]),
            ("now_guest_files_upload_begin", [
                "destinationPath": "Drops:x",
                "bytes": 1,
                "sha256": digest,
                "container": "data",
                "fileType": "TOO-LONG",
            ]),
            ("now_guest_files_upload_append", [
                "uploadID": uploadID,
                "offset": 0,
                "data": "not base64!",
            ]),
            ("now_guest_files_upload_append", [
                "uploadID": uploadID,
                "offset": 0,
                "data": Data(repeating: 1, count: 8_193)
                    .base64EncodedString(),
            ]),
            ("now_guest_files_upload_commit", [
                "uploadID": "not-a-uuid",
            ]),
        ]

        for (index, item) in cases.enumerated() {
            let response = try Self.object(await server.handle(
                try Self.request(
                    id: index + 10,
                    method: "tools/call",
                    params: [
                        "name": item.0,
                        "arguments": item.1,
                    ])))
            let error = try XCTUnwrap(
                response["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? Int, -32602)
        }
    }

    private func guestFileReceipt(
        _ operation: AgentIntegrationGuestFileOperation,
        outcome: AgentIntegrationGuestFileOutcome = .success,
        observedAt: Date
    ) -> AgentIntegrationGuestFileReceipt {
        .init(
            commandID: UUID(),
            sessionID: UUID(),
            policyVersion: 1,
            operation: operation,
            startedAt: observedAt,
            completedAt: observedAt,
            outcome: outcome,
            wireRequestCount: 1)
    }
}

private actor RecordingGuestFilesClient: AgentIntegrationClient {
    struct ListCall: Equatable {
        let path: String
        let cursor: Int?
    }

    private(set) var lastListCall: ListCall?
    private(set) var lastStatPath: String?
    private(set) var lastUploadBegin:
        AgentIntegrationGuestFileUploadBegin?
    private(set) var lastUploadAppend:
        (uploadID: UUID, offset: Int, bytes: Data)?
    private(set) var lastUploadCommit: UUID?
    let listResult: AgentIntegrationGuestFileListResult
    let statResult: AgentIntegrationGuestFileStatResult

    init(
        listResult: AgentIntegrationGuestFileListResult =
            .hostUnavailable(.host),
        statResult: AgentIntegrationGuestFileStatResult =
            .hostUnavailable(.host)
    ) {
        self.listResult = listResult
        self.statResult = statResult
    }

    func sessionHealth() async -> AgentIntegrationSessionHealthResult {
        .hostUnavailable
    }

    func listProcesses() async -> AgentIntegrationProcessListResult {
        .guestUnavailable
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
        lastListCall = .init(path: path, cursor: cursor)
        return listResult
    }

    func statGuestFile(path: String) async
        -> AgentIntegrationGuestFileStatResult {
        lastStatPath = path
        return statResult
    }

    func beginGuestFileUpload(
        _ upload: AgentIntegrationGuestFileUploadBegin
    ) async -> AgentIntegrationGuestFileUploadStageResult {
        lastUploadBegin = upload
        return .hostUnavailable(.host)
    }

    func appendGuestFileUpload(
        uploadID: UUID, offset: Int, bytes: Data
    ) async -> AgentIntegrationGuestFileUploadStageResult {
        lastUploadAppend = (uploadID, offset, bytes)
        return .hostUnavailable(.host)
    }

    func commitGuestFileUpload(uploadID: UUID) async
        -> AgentIntegrationGuestFileUploadCommitResult {
        lastUploadCommit = uploadID
        return .hostUnavailable(.host)
    }
}
