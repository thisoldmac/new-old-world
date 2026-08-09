import XCTest
@testable import NOWAgentIntegration

final class MirrorStateProjectionTests: XCTestCase {
    private var driveInputSchema: [String: Any] {
        (MirrorDriveProjection.mcpDescriptor["inputSchema"]
            as? [String: Any]) ?? [:]
    }

    func testFourRowsAreRegisteredTogetherAndReadOnly() {
        let names = HostProjectionCatalog.projections.map {
            $0.capability.rawValue
        }
        for name in ["now_semantic_ui_status", "now_semantic_ui_snapshot",
                     "now_semantic_ui_find", "now_semantic_ui_wait"] {
            XCTAssertEqual(names.filter { $0 == name }.count, 1)
        }
        for row in [
            MirrorStatusProjection.self as any HostProjection.Type,
            MirrorSnapshotProjection.self,
            MirrorFindProjection.self,
            MirrorWaitProjection.self,
        ] {
            let annotations = row.mcpDescriptor["annotations"]
                as? [String: Any]
            XCTAssertEqual(annotations?["readOnlyHint"] as? Bool, true)
            XCTAssertTrue(row.requires.isEmpty,
                          "state reads send no guest request")
        }
    }

    func testAllFourRowsUseTheSingleTypedReadLane() async throws {
        let client = MirrorReadRecordingClient()
        let cases: [(any HostProjection.Type, Any?)] = [
            (MirrorStatusProjection.self, nil),
            (MirrorSnapshotProjection.self, [:]),
            (MirrorFindProjection.self, ["query": "Finder"]),
            (MirrorWaitProjection.self,
             ["afterSnapshotID": 3, "timeoutMs": 25]),
        ]
        for (row, raw) in cases {
            guard case .value = await row.invoke(.init(raw: raw),
                                                 through: client) else {
                return XCTFail("\(row.capability) did not reach mirrorRead")
            }
        }
        let requests = await client.requests
        XCTAssertEqual(requests.map(\.intention),
                       [.status, .snapshot, .find, .wait])
        XCTAssertEqual(requests[2].query, "Finder")
        XCTAssertEqual(requests[3].afterSnapshotID, 3)
        XCTAssertEqual(requests[3].timeoutMs, 25)
    }

    func testLocalProtocolRoundTripsOneMirrorReadLane() throws {
        let read = AgentIntegrationMirrorReadRequest(
            intention: .wait, afterSnapshotID: 12, timeoutMs: 250)
        let request = AgentIntegrationLocalRequest.mirrorRead(read)
        let decoded = try AgentIntegrationLocalCodec.decodeRequest(
            AgentIntegrationLocalCodec.encode(request))
        XCTAssertEqual(decoded.operation, .mirrorRead)
        XCTAssertEqual(decoded.mirrorReadRequest, read)

        let value = AgentIntegrationMirrorReadValue(
            intention: .wait,
            current: .init(guest: "maxbook", session: "session",
                           snapshotID: 13, sequence: 4, digest: "abc",
                           baseComplete: true, sceneGeneration: 4,
                           contentGeneration: 1))
        let response = AgentIntegrationLocalResponse(
            requestID: request.requestID,
            mirrorReadResult: .init(value: value))
        let decodedResponse = try AgentIntegrationLocalCodec.decodeResponse(
            AgentIntegrationLocalCodec.encode(response))
        XCTAssertEqual(decodedResponse.mirrorReadResult?.value, value)
    }

    func testDrivePublishesTheExactGestureVocabulary() throws {
        let properties = try XCTUnwrap(
            driveInputSchema["properties"] as? [String: Any])
        let gesture = try XCTUnwrap(
            properties["gesture"] as? [String: Any])
        let published = Set(try XCTUnwrap(gesture["enum"] as? [String]))
        let expected: Set<String> = [
            "select", "close", "zoom", "activate", "menuItem", "hide",
            "hideOthers", "showAll", "key", "type", "finderOpen",
            "finderSelect", "finderDeselect", "dialogItem",
            "appleMenuItem", "cancel",
        ]

        XCTAssertEqual(published, expected,
                       "an unconstrained gesture string makes callers guess")
    }

    func testDrivePublishesEachGesturesRequiredArguments() throws {
        let allOf = try XCTUnwrap(
            driveInputSchema["allOf"] as? [[String: Any]])
        let alternatives = try XCTUnwrap(
            allOf.first?["oneOf"] as? [[String: Any]])
        var published: [String: Set<String>] = [:]
        for alternative in alternatives {
            let properties = try XCTUnwrap(
                alternative["properties"] as? [String: Any])
            let gesture = try XCTUnwrap(
                properties["gesture"] as? [String: Any])
            let name = try XCTUnwrap(gesture["const"] as? String)
            let required = Set(
                (alternative["required"] as? [String]) ?? [])
            published[name] = required.subtracting(["gesture"])
        }

        let expected: [String: Set<String>] = [
            "select": ["entityID"],
            "close": ["entityID"],
            "zoom": ["entityID"],
            "activate": ["entityID"],
            "menuItem": ["menuID", "itemIndex"],
            "hide": [],
            "hideOthers": [],
            "showAll": [],
            "key": ["keyCode"],
            "type": ["text"],
            "finderOpen": ["itemName"],
            "finderSelect": ["itemName"],
            "finderDeselect": [],
            "dialogItem": ["entityID", "itemIndex"],
            "appleMenuItem": ["itemName"],
            "cancel": [],
        ]
        XCTAssertEqual(published, expected,
                       "every gesture needs one exact required-argument branch")
    }

    func testDriveRefusesAMalformedKnownGestureBeforeTheHost() async {
        let outcome = await MirrorDriveProjection.invoke(
            .init(raw: ["gesture": "dialogItem"]),
            through: MirrorReadRecordingClient())
        guard case .invalidArguments(let message) = outcome else {
            return XCTFail("malformed dialogItem reached the host: \(outcome)")
        }
        XCTAssertTrue(message.contains("dialogItem"), message)
        XCTAssertTrue(message.contains("entityID"), message)
        XCTAssertTrue(message.contains("itemIndex"), message)
    }

    func testDriveRefusesArgumentsBelongingToAnotherGesture() async {
        let outcome = await MirrorDriveProjection.invoke(
            .init(raw: [
                "gesture": "dialogItem",
                "entityID": "window:process-a:window-b",
                "itemIndex": 1,
                "text": "Open",
            ]),
            through: MirrorReadRecordingClient())
        guard case .invalidArguments(let message) = outcome else {
            return XCTFail("dialogItem accepted type's text: \(outcome)")
        }
        XCTAssertTrue(message.contains("does not take text"), message)
        XCTAssertTrue(message.contains("Do not pass a now-element"), message)
    }
}

private actor MirrorReadRecordingClient: AgentIntegrationClient {
    private(set) var requests: [AgentIntegrationMirrorReadRequest] = []

    func mirrorRead(_ request: AgentIntegrationMirrorReadRequest) async
        -> AgentIntegrationMirrorReadResult {
        requests.append(request)
        return .init(value: .init(intention: request.intention,
                                  current: nil))
    }

    nonisolated func addressing(_ selector: String?)
        -> AgentIntegrationClient { self }
    func sessionHealth() async -> AgentIntegrationSessionHealthResult {
        .unavailable(.host)
    }
    func sessionCapabilities(probeCostly: Bool) async
        -> AgentIntegrationSessionCapabilitiesResult { .unavailable(.host) }
    func listProcesses() async -> AgentIntegrationProcessListResult {
        .unavailable(.host)
    }
    func launchSoftware(_ selection: AgentIntegrationLaunchSelection) async
        -> AgentIntegrationLaunchSoftwareResult { .unavailable(.host) }
    func requestQuit(reference: String) async
        -> AgentIntegrationQuitResult { .unavailable(.host) }
    func transferApprovedArtifact(receipt: String) async
        -> AgentIntegrationArtifactTransferResult { .unavailable(.host) }
    func guestFilesCapabilities() async
        -> AgentIntegrationGuestFileCapabilitiesResult {
        .hostUnavailable(.host)
    }
    func listGuestFiles(path: String, cursor: Int?) async
        -> AgentIntegrationGuestFileListResult { .hostUnavailable(.host) }
    func statGuestFile(path: String) async
        -> AgentIntegrationGuestFileStatResult { .hostUnavailable(.host) }
}
