import XCTest
@testable import NOWAgentCompanion
@testable import NOWAgentIntegration

final class NOWAgentCompanionTests: XCTestCase {
    private func temporaryEndpoint() -> (AgentIntegrationEndpoint, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "nct-\(UUID().uuidString.prefix(8))",
                isDirectory: true)
        return (AgentIntegrationEndpoint(
            directoryURL: root,
            socketURL: root.appendingPathComponent("host.sock")), root)
    }

    private static func request(id: Int, method: String,
                                params: [String: Any]? = nil) throws -> Data {
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
        let server = NOWMCPServer(client: client, audit: AuditSinkSpy())
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

    func testListsOnlyApprovedBoundedTools() async throws {
        let server = try await initializedServer(
            client: StubAgentIntegrationClient())

        let response = try Self.object(await server.handle(
            try Self.request(id: 2, method: "tools/list", params: [:])))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])

        /* The expectation is the catalog, in catalog order — not a second
           copy of it. This is still a two-sided check: the left side is
           what NOWMCPServer rendered and the right side is the registry, so
           a renderer that dropped, reordered, renamed or duplicated a row
           fails here. What it no longer does is fail merely because a row
           was added, which is the edit every new capability was paying.

           It is not the approval gate the name suggests, and never could
           be: HostFaceParityTests.testTheMCPFaceIsDerivedFromTheRenderers-
           OwnLoop establishes that a row cannot opt out of the MCP face, so
           registering a projection IS exposing it. The review is therefore
           the catalog row itself, in reviewed source, together with the
           row's own `faces` declaration. */
        XCTAssertEqual(
            tools.compactMap { $0["name"] as? String },
            HostProjectionCatalog.projections.map {
                $0.capability.rawValue
            })
        let processTool = try XCTUnwrap(tools.first {
            $0["name"] as? String == "now_list_processes"
        })
        let output = try XCTUnwrap(
            processTool["outputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(
            output["properties"] as? [String: Any])
        let snapshot = try XCTUnwrap(
            properties["snapshot"] as? [String: Any])
        let snapshotProperties = try XCTUnwrap(
            snapshot["properties"] as? [String: Any])
        let processes = try XCTUnwrap(
            snapshotProperties["processes"] as? [String: Any])

        XCTAssertEqual(processes["maxItems"] as? Int, 48)
        XCTAssertNotNil(snapshotProperties["freshness"])
        XCTAssertNotNil(snapshotProperties["referenceAuthority"])
        let launchTool = try XCTUnwrap(tools.first {
            $0["name"] as? String == "now_launch_software"
        })
        let launchAnnotations = try XCTUnwrap(
            launchTool["annotations"] as? [String: Any])
        XCTAssertEqual(launchAnnotations["readOnlyHint"] as? Bool, false)
        XCTAssertEqual(launchAnnotations["destructiveHint"] as? Bool, false)
        let launchOutput = try XCTUnwrap(
            launchTool["outputSchema"] as? [String: Any])
        let variants = try XCTUnwrap(
            launchOutput["oneOf"] as? [[String: Any]])
        XCTAssertEqual(variants.count, 5)
        let outcomes = variants.compactMap { variant -> String? in
            let properties = variant["properties"] as? [String: Any]
            let outcome = properties?["outcome"] as? [String: Any]
            return outcome?["const"] as? String
        }
        XCTAssertEqual(Set(outcomes), Set([
            "launched", "unavailable", "ambiguous", "notFound", "refused",
        ]))
        XCTAssertTrue(variants.allSatisfy {
            ($0["required"] as? [String])?.count == 2
                && ($0["additionalProperties"] as? Bool) == false
        })
        let quitTool = try XCTUnwrap(tools.first {
            $0["name"] as? String == "now_request_quit"
        })
        let quitAnnotations = try XCTUnwrap(
            quitTool["annotations"] as? [String: Any])
        XCTAssertEqual(quitAnnotations["readOnlyHint"] as? Bool, false)
        XCTAssertEqual(quitAnnotations["destructiveHint"] as? Bool, true)
        let quitOutput = try XCTUnwrap(
            quitTool["outputSchema"] as? [String: Any])
        let quitVariants = try XCTUnwrap(
            quitOutput["oneOf"] as? [[String: Any]])
        let quitOutcomes = quitVariants.compactMap { variant -> String? in
            let properties = variant["properties"] as? [String: Any]
            let outcome = properties?["outcome"] as? [String: Any]
            return outcome?["const"] as? String
        }
        XCTAssertEqual(Set(quitOutcomes), Set([
            "requestSent", "unavailable", "stale", "notFound", "refused",
        ]))
        let artifactTool = try XCTUnwrap(tools.first {
            $0["name"] as? String == "now_transfer_approved_artifact"
        })
        let artifactInput = try XCTUnwrap(
            artifactTool["inputSchema"] as? [String: Any])
        let artifactProperties = try XCTUnwrap(
            artifactInput["properties"] as? [String: Any])
        XCTAssertEqual(Set(artifactProperties.keys),
                       ["approvalReceipt", "guest"])
        let artifactAnnotations = try XCTUnwrap(
            artifactTool["annotations"] as? [String: Any])
        XCTAssertEqual(artifactAnnotations["destructiveHint"] as? Bool, true)
        let guestFileTools = tools.filter {
            ($0["name"] as? String)?.hasPrefix(
                "now_guest_files_") == true
        }
        /* Derived, not counted. This assertion was three literals — 6, 3
           and 3 — and every capability joining the family had to edit a
           test named for something else, which is the papercut P0.1
           collapsed everywhere it found it and missed here. What the
           check is really for is the ANNOTATIONS below: the read side is
           read-only-hinted, the upload side is not, and the mutation side
           is destructive. So the counts are now the registry's own, and the
           partition is asserted to be a partition rather than to be a
           particular size. */
        let registeredGuestFileTools = HostProjectionCatalog.projections
            .filter {
                $0.capability.rawValue.hasPrefix("now_guest_files_")
            }
        XCTAssertEqual(guestFileTools.count,
                       registeredGuestFileTools.count)
        /* Three groups, and the third arrived with the mutation row: "not an
           upload" stopped meaning "read-only" the moment this family could
           change the catalog, and a filter that still said so would have
           asserted `readOnlyHint: true` of a tool that trashes things. */
        let guestFileMutateTools = guestFileTools.filter {
            ($0["name"] as? String) == "now_guest_files_mutate"
        }
        let guestFileUploadTools = guestFileTools.filter {
            ($0["name"] as? String ?? "").contains("_upload_")
        }
        let guestFileReadTools = guestFileTools.filter { tool in
            let name = tool["name"] as? String ?? ""
            return !name.contains("_upload_")
                && name != "now_guest_files_mutate"
        }
        XCTAssertFalse(guestFileReadTools.isEmpty)
        XCTAssertFalse(guestFileUploadTools.isEmpty)
        XCTAssertEqual(guestFileMutateTools.count, 1)
        XCTAssertEqual(
            guestFileReadTools.count + guestFileUploadTools.count
                + guestFileMutateTools.count,
            guestFileTools.count)
        XCTAssertTrue(guestFileMutateTools.allSatisfy {
            let annotations = $0["annotations"] as? [String: Any]
            return annotations?["readOnlyHint"] as? Bool == false
                && annotations?["destructiveHint"] as? Bool == true
                && annotations?["idempotentHint"] as? Bool == false
                && annotations?["openWorldHint"] as? Bool == false
        })
        XCTAssertTrue(guestFileReadTools.allSatisfy {
            let annotations = $0["annotations"] as? [String: Any]
            return annotations?["readOnlyHint"] as? Bool == true
                && annotations?["destructiveHint"] as? Bool == false
                && annotations?["openWorldHint"] as? Bool == false
        })
        XCTAssertTrue(guestFileUploadTools.allSatisfy {
            let annotations = $0["annotations"] as? [String: Any]
            return annotations?["readOnlyHint"] as? Bool == false
                && annotations?["destructiveHint"] as? Bool == false
                && annotations?["openWorldHint"] as? Bool == false
        })
        let guestFileList = try XCTUnwrap(guestFileTools.first {
            $0["name"] as? String == "now_guest_files_list"
        })
        let guestFileInput = try XCTUnwrap(
            guestFileList["inputSchema"] as? [String: Any])
        let guestFileProperties = try XCTUnwrap(
            guestFileInput["properties"] as? [String: Any])
        let guestPath = try XCTUnwrap(
            guestFileProperties["path"] as? [String: Any])
        XCTAssertEqual(
            guestPath["maxLength"] as? Int,
            AgentIntegrationGuestFilePolicy.maximumPathScalars)
        let guestFileOutput = try XCTUnwrap(
            guestFileList["outputSchema"] as? [String: Any])
        XCTAssertEqual(
            (guestFileOutput["oneOf"] as? [[String: Any]])?.count, 2)
    }

    func testHostAbsentReturnsTypedUnavailableWithoutLaunchingIt()
        async throws {
        let (endpoint, root) = temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try await initializedServer(
            client: SocketAgentIntegrationClient(endpoint: endpoint))

        let response = try Self.object(await server.handle(try Self.request(
            id: 2,
            method: "tools/call",
            params: ["name": "now_session_health", "arguments": [:]])))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let structured = try XCTUnwrap(
            result["structuredContent"] as? [String: Any])
        let unavailable = try XCTUnwrap(
            structured["unavailable"] as? [String: Any])

        XCTAssertEqual(structured["available"] as? Bool, false)
        XCTAssertEqual(unavailable["code"] as? String,
                       "now-host-unavailable")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testProcessListReturnsTypedHostUnavailableWithoutLaunchingIt()
        async throws {
        let (endpoint, root) = temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try await initializedServer(
            client: SocketAgentIntegrationClient(endpoint: endpoint))

        let response = try Self.object(await server.handle(try Self.request(
            id: 2,
            method: "tools/call",
            params: ["name": "now_list_processes", "arguments": [:]])))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let structured = try XCTUnwrap(
            result["structuredContent"] as? [String: Any])
        let unavailable = try XCTUnwrap(
            structured["unavailable"] as? [String: Any])

        XCTAssertEqual(structured["available"] as? Bool, false)
        XCTAssertEqual(unavailable["code"] as? String,
                       "now-host-unavailable")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testLaunchReturnsTypedHostUnavailableWithoutLaunchingNOW()
        async throws {
        let (endpoint, root) = temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try await initializedServer(
            client: SocketAgentIntegrationClient(endpoint: endpoint))

        let response = try Self.object(await server.handle(try Self.request(
            id: 2,
            method: "tools/call",
            params: [
                "name": "now_launch_software",
                "arguments": ["name": "SimpleText"],
            ])))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let structured = try XCTUnwrap(
            result["structuredContent"] as? [String: Any])
        let unavailable = try XCTUnwrap(
            structured["unavailable"] as? [String: Any])

        XCTAssertEqual(structured["outcome"] as? String, "unavailable")
        XCTAssertEqual(unavailable["code"] as? String,
                       "now-host-unavailable")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testQuitReturnsTypedHostUnavailableWithoutLaunchingNOW()
        async throws {
        let (endpoint, root) = temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try await initializedServer(
            client: SocketAgentIntegrationClient(endpoint: endpoint))
        let reference =
            "now-process-00000000-0000-0000-0000-000000000000"

        let response = try Self.object(await server.handle(try Self.request(
            id: 2,
            method: "tools/call",
            params: [
                "name": "now_request_quit",
                "arguments": ["reference": reference],
            ])))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let structured = try XCTUnwrap(
            result["structuredContent"] as? [String: Any])
        let unavailable = try XCTUnwrap(
            structured["unavailable"] as? [String: Any])

        XCTAssertEqual(structured["outcome"] as? String, "unavailable")
        XCTAssertEqual(unavailable["code"] as? String,
                       "now-host-unavailable")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testArtifactTransferReturnsHostUnavailableWithoutLaunchingNOW()
        async throws {
        let (endpoint, root) = temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try await initializedServer(
            client: SocketAgentIntegrationClient(endpoint: endpoint))
        let receipt =
            "now-artifact-00000000-0000-0000-0000-000000000000"

        let response = try Self.object(await server.handle(try Self.request(
            id: 2,
            method: "tools/call",
            params: [
                "name": "now_transfer_approved_artifact",
                "arguments": ["approvalReceipt": receipt],
            ])))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let structured = try XCTUnwrap(
            result["structuredContent"] as? [String: Any])
        let unavailable = try XCTUnwrap(
            structured["unavailable"] as? [String: Any])

        XCTAssertEqual(structured["outcome"] as? String, "unavailable")
        XCTAssertEqual(unavailable["code"] as? String,
                       "now-host-unavailable")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testMalformedJSONReturnsParseError() async throws {
        let server = NOWMCPServer(
            client: StubAgentIntegrationClient(), audit: AuditSinkSpy())

        let response = try Self.object(
            await server.handle(Data("{nope".utf8)))
        let error = try XCTUnwrap(response["error"] as? [String: Any])

        XCTAssertEqual(error["code"] as? Int, -32700)
        XCTAssertTrue(response["id"] is NSNull)
    }

    func testFractionalRequestIDReturnsInvalidRequest() async throws {
        let server = NOWMCPServer(
            client: StubAgentIntegrationClient(), audit: AuditSinkSpy())
        let data = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 1.5,
            "method": "ping",
        ])

        let response = try Self.object(await server.handle(data))
        let error = try XCTUnwrap(response["error"] as? [String: Any])

        XCTAssertEqual(error["code"] as? Int, -32600)
        XCTAssertTrue(response["id"] is NSNull)
    }

    func testSessionHealthRejectsArguments() async throws {
        let server = try await initializedServer(
            client: StubAgentIntegrationClient())

        let response = try Self.object(await server.handle(try Self.request(
            id: 2,
            method: "tools/call",
            params: [
                "name": "now_session_health",
                "arguments": ["path": "/tmp"],
            ])))
        let error = try XCTUnwrap(response["error"] as? [String: Any])

        XCTAssertEqual(error["code"] as? Int, -32602)
    }

    @MainActor
    func testToolCallTraversesThePrivateSocket() async throws {
        let (endpoint, root) = temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let observedAt = Date(timeIntervalSince1970: 1_000)
        let health = AgentIntegrationSessionHealth(
            state: .notListening,
            observedAt: observedAt,
            listeningPort: nil,
            sessionID: nil,
            guest: nil,
            failure: nil)
        let localServer = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            handler: { request in
                switch request.operation {
                case .sessionHealth:
                    return .sessionHealth(.available(health))
                default:
                    /* This fixture is about one operation reaching the
                       far end of a real socket. The rest answered a typed
                       unavailable case by case, which made every new
                       operation an edit here; NOWAgentAuditTests next door
                       already used a `default:` for the same reason. A
                       fixture that reached an operation it had not handled
                       would decode the wrong response and fail. */
                    return .processList(.guestUnavailable)
                }
            })
        try localServer.start()
        defer { localServer.stop() }
        let server = try await initializedServer(
            client: SocketAgentIntegrationClient(endpoint: endpoint))

        let response = try Self.object(await server.handle(try Self.request(
            id: 2,
            method: "tools/call",
            params: ["name": "now_session_health", "arguments": [:]])))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let structured = try XCTUnwrap(
            result["structuredContent"] as? [String: Any])
        let returned = try XCTUnwrap(
            structured["health"] as? [String: Any])

        XCTAssertEqual(structured["available"] as? Bool, true)
        XCTAssertEqual(returned["state"] as? String, "notListening")
    }

    func testConcurrentSessionHealthCallsAllReturn() async throws {
        let server = try await initializedServer(
            client: StubAgentIntegrationClient())

        let responses = try await withThrowingTaskGroup(
            of: [String: Any].self
        ) { group in
            for id in 2..<10 {
                group.addTask {
                    try Self.object(await server.handle(
                        try Self.request(
                            id: id,
                            method: "tools/call",
                            params: [
                                "name": "now_session_health",
                                "arguments": [:],
                            ])))
                }
            }
            var values: [[String: Any]] = []
            for try await value in group { values.append(value) }
            return values
        }

        XCTAssertEqual(responses.count, 8)
        XCTAssertTrue(responses.allSatisfy { $0["result"] != nil })
    }

    func testProcessListReturnsBoundedQuitEligibleSnapshot()
        async throws {
        let process = AgentIntegrationObservedProcess(
            reference: "now-process-opaque",
            name: "Finder",
            kind: .finder,
            code: "FNDR",
            creator: "MACS",
            sizeKB: 4096,
            front: true)
        let snapshot = AgentIntegrationProcessSnapshot(
            sessionID: UUID(),
            observedAt: Date(timeIntervalSince1970: 1_000),
            freshness: .pointInTime,
            referenceAuthority: .cooperativeQuit,
            processes: [process])
        let server = try await initializedServer(
            client: StubAgentIntegrationClient(
                processResult: .available(snapshot)))

        let response = try Self.object(await server.handle(try Self.request(
            id: 2,
            method: "tools/call",
            params: ["name": "now_list_processes", "arguments": [:]])))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let structured = try XCTUnwrap(
            result["structuredContent"] as? [String: Any])
        let returned = try XCTUnwrap(
            structured["snapshot"] as? [String: Any])
        let processes = try XCTUnwrap(
            returned["processes"] as? [[String: Any]])
        let first = try XCTUnwrap(processes.first)

        XCTAssertEqual(structured["available"] as? Bool, true)
        XCTAssertEqual(returned["freshness"] as? String, "pointInTime")
        XCTAssertEqual(returned["referenceAuthority"] as? String,
                       "cooperativeQuit")
        XCTAssertEqual(first["reference"] as? String,
                       "now-process-opaque")
        XCTAssertNil(first["psnHigh"])
        XCTAssertNil(first["psnLow"])
        XCTAssertNil(first["path"])
    }

    func testProcessListRejectsArguments() async throws {
        let server = try await initializedServer(
            client: StubAgentIntegrationClient())

        let response = try Self.object(await server.handle(try Self.request(
            id: 2,
            method: "tools/call",
            params: [
                "name": "now_list_processes",
                "arguments": ["includePaths": true],
            ])))
        let error = try XCTUnwrap(response["error"] as? [String: Any])

        XCTAssertEqual(error["code"] as? Int, -32602)
    }

    /// **A consent denial does not wear the invalid-params code.**
    ///
    /// An agent that reads -32602 retries with different arguments, and
    /// these arguments were fine. So the denial arrives under its own code
    /// with typed `data`, which is how a caller tells "the owner said no"
    /// from "the machine cannot" without reading either sentence —
    /// incapacity comes back as a successful RESULT whose payload says
    /// `unavailable`, never as an error.
    ///
    /// Verified by mutation: rendering it as -32602 with no `data` fails
    /// here on both assertions.
    func testAConsentDenialIsItsOwnErrorWithTypedData() async throws {
        var client = StubAgentIntegrationClient()
        client.healthResult = .available(.init(
            state: .connected,
            observedAt: Date(timeIntervalSince1970: 0),
            listeningPort: 1400, sessionID: nil,
            guest: .init(name: "pb1400c", version: "0.1.0",
                         agentAccess: .disabled,
                         operatingSystem: "Mac OS 9.1", connectedAt: nil,
                         lastTraffic: nil, quietFor: nil,
                         pingsAnswered: nil, framesReceived: nil),
            failure: nil))
        let server = try await initializedServer(client: client)

        let response = try Self.object(await server.handle(try Self.request(
            id: 2,
            method: "tools/call",
            params: ["name": "now_list_processes", "arguments": [:]])))
        let error = try XCTUnwrap(response["error"] as? [String: Any])

        XCTAssertEqual(error["code"] as? Int,
                       HostProjectionConsentDenial.jsonRPCCode)
        let data = try XCTUnwrap(error["data"] as? [String: Any])
        XCTAssertEqual(data["kind"] as? String, "consent")
        XCTAssertEqual(data["reason"] as? String, "machine-declines")
        XCTAssertEqual(data["machineAnswer"] as? String, "disabled")
        XCTAssertEqual(data["requiredTier"] as? String, "read-only")
    }

    func testLaunchRequiresExactlyOneBoundedOpaqueSelection()
        async throws {
        let server = try await initializedServer(
            client: StubAgentIntegrationClient())
        let invalidArguments: [[String: Any]] = [
            [:],
            ["name": "SimpleText", "reference": "now-software-opaque"],
            ["path": "HD:Apps:SimpleText"],
            ["name": String(repeating: "x", count: 32)],
        ]

        for (offset, arguments) in invalidArguments.enumerated() {
            let response = try Self.object(await server.handle(
                try Self.request(
                    id: 20 + offset,
                    method: "tools/call",
                    params: [
                        "name": "now_launch_software",
                        "arguments": arguments,
                    ])))
            let error = try XCTUnwrap(response["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? Int, -32602)
        }
    }

    func testLaunchReturnsStructuredAmbiguityWithoutPaths() async throws {
        let result = AgentIntegrationLaunchSoftwareResult.ambiguous(.init(
            code: "now-software-ambiguous",
            message: "More than one exact application match is current",
            matchCount: 2,
            candidates: [
                .init(reference: "now-software-one",
                      name: "SimpleText", version: "1.4",
                      type: "APPL", creator: "ttxt", running: false),
                .init(reference: "now-software-two",
                      name: "SimpleText", version: "1.3",
                      type: "APPL", creator: "ttxt", running: false),
            ]))
        let server = try await initializedServer(
            client: StubAgentIntegrationClient(launchResult: result))

        let response = try Self.object(await server.handle(try Self.request(
            id: 2,
            method: "tools/call",
            params: [
                "name": "now_launch_software",
                "arguments": ["name": "SimpleText"],
            ])))
        let encodedResponse = await server.handle(try Self.request(
                id: 3,
                method: "tools/call",
                params: [
                    "name": "now_launch_software",
                    "arguments": ["name": "SimpleText"],
                ]))
        let encoded = String(
            decoding: try XCTUnwrap(encodedResponse), as: UTF8.self)
        let resultObject = try XCTUnwrap(
            response["result"] as? [String: Any])
        let structured = try XCTUnwrap(
            resultObject["structuredContent"] as? [String: Any])

        XCTAssertEqual(structured["outcome"] as? String, "ambiguous")
        XCTAssertFalse(encoded.contains("\"path\""))
        XCTAssertFalse(encoded.contains("HD:"))
    }

    func testQuitRequiresOneValidOpaqueProcessReference() async throws {
        let server = try await initializedServer(
            client: StubAgentIntegrationClient())
        let invalidArguments: [[String: Any]] = [
            [:],
            ["reference": "42"],
            ["reference":
                "now-process-00000000-0000-0000-0000-000000000000",
             "psnLow": 42],
            ["psnHigh": 0, "psnLow": 42],
            ["path": "HD:Apps:SimpleText"],
        ]

        for (offset, arguments) in invalidArguments.enumerated() {
            let response = try Self.object(await server.handle(
                try Self.request(
                    id: 40 + offset,
                    method: "tools/call",
                    params: [
                        "name": "now_request_quit",
                        "arguments": arguments,
                    ])))
            let error = try XCTUnwrap(response["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? Int, -32602)
        }
    }

    func testQuitReceiptClaimsRequestSentWithoutPSNPathOrExit()
        async throws {
        let reference =
            "now-process-00000000-0000-0000-0000-000000000000"
        let receipt = AgentIntegrationQuitReceipt(
            sessionID: UUID(),
            snapshotObservedAt: Date(timeIntervalSince1970: 1_000),
            revalidatedAt: Date(timeIntervalSince1970: 1_001),
            acknowledgedAt: Date(timeIntervalSince1970: 1_002),
            process: .init(
                reference: reference,
                name: "SimpleText",
                kind: .application,
                code: "APPL",
                creator: "ttxt"),
            guestMessage:
                "Cooperative quit request acknowledged by the paired guest")
        let server = try await initializedServer(
            client: StubAgentIntegrationClient(
                quitResult: .requestSent(receipt)))

        let encodedResponse = await server.handle(try Self.request(
            id: 2,
            method: "tools/call",
            params: [
                "name": "now_request_quit",
                "arguments": ["reference": reference],
            ]))
        let response = try Self.object(encodedResponse)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let structured = try XCTUnwrap(
            result["structuredContent"] as? [String: Any])
        let encoded = String(
            decoding: try XCTUnwrap(encodedResponse), as: UTF8.self)

        XCTAssertEqual(structured["outcome"] as? String, "requestSent")
        XCTAssertFalse(encoded.contains("\"psn"))
        XCTAssertFalse(encoded.contains("\"path\""))
        XCTAssertFalse(encoded.contains("exited"))
    }

    func testArtifactTransferRequiresOnlyAValidApprovalReceipt()
        async throws {
        let server = try await initializedServer(
            client: StubAgentIntegrationClient())
        let valid =
            "now-artifact-00000000-0000-0000-0000-000000000000"
        let invalidArguments: [[String: Any]] = [
            [:],
            ["approvalReceipt": "42"],
            ["approvalReceipt": valid, "path": "/tmp/secret"],
            ["path": "/tmp/secret"],
            ["approvalReceipt": valid, "destination": "Lab:CodeKitten"],
        ]

        for (offset, arguments) in invalidArguments.enumerated() {
            let response = try Self.object(await server.handle(
                try Self.request(
                    id: 70 + offset,
                    method: "tools/call",
                    params: [
                        "name": "now_transfer_approved_artifact",
                        "arguments": arguments,
                    ])))
            let error = try XCTUnwrap(response["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? Int, -32602)
        }
    }

    func testArtifactDeliveryReceiptIsBoundedAndClaimsNoHashProof()
        async throws {
        let approvalReceipt =
            "now-artifact-00000000-0000-0000-0000-000000000000"
        let digest = String(repeating: "a", count: 64)
        let delivery = AgentIntegrationArtifactDeliveryReceipt(
            transferID: UUID(),
            sessionID: UUID(),
            approvedAt: Date(timeIntervalSince1970: 1_000),
            redeemedAt: Date(timeIntervalSince1970: 1_001),
            acknowledgedAt: Date(timeIntervalSince1970: 1_002),
            name: "Agent Note.txt",
            source: .init(sha256: digest, bytes: 12),
            handedToNOW: .init(sha256: digest, bytes: 12),
            container: "data",
            conversion: nil,
            guestAcknowledgedWrite: true,
            destinationBytesVerified: false,
            guestMessage:
                "The paired guest acknowledged writing the approved artifact")
        let server = try await initializedServer(
            client: StubAgentIntegrationClient(
                artifactResult: .delivered(delivery)))

        let encodedResponse = await server.handle(try Self.request(
            id: 2,
            method: "tools/call",
            params: [
                "name": "now_transfer_approved_artifact",
                "arguments": ["approvalReceipt": approvalReceipt],
            ]))
        let response = try Self.object(encodedResponse)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let structured = try XCTUnwrap(
            result["structuredContent"] as? [String: Any])
        let returned = try XCTUnwrap(
            structured["delivered"] as? [String: Any])
        let encoded = String(
            decoding: try XCTUnwrap(encodedResponse), as: UTF8.self)

        XCTAssertEqual(structured["outcome"] as? String, "delivered")
        XCTAssertEqual(returned["guestAcknowledgedWrite"] as? Bool, true)
        XCTAssertEqual(returned["destinationBytesVerified"] as? Bool, false)
        XCTAssertFalse(encoded.contains("\"path\""))
        XCTAssertFalse(encoded.contains("CodeKitten"))
        XCTAssertFalse(encoded.contains(approvalReceipt))
    }

    func testConcurrentProcessListCallsAllReturn() async throws {
        let server = try await initializedServer(
            client: StubAgentIntegrationClient())

        let responses = try await withThrowingTaskGroup(
            of: [String: Any].self
        ) { group in
            for id in 2..<10 {
                group.addTask {
                    try Self.object(await server.handle(
                        try Self.request(
                            id: id,
                            method: "tools/call",
                            params: [
                                "name": "now_list_processes",
                                "arguments": [:],
                            ])))
                }
            }
            var values: [[String: Any]] = []
            for try await value in group { values.append(value) }
            return values
        }

        XCTAssertEqual(responses.count, 8)
        XCTAssertTrue(responses.allSatisfy { $0["result"] != nil })
    }

    func testStdioFramerBoundsAnOversizedRequest() {
        var framer = BoundedMCPLineFramer()
        let data = Data(repeating: 0x41,
                        count: NOWMCPServer.maximumMessageBytes + 1)
            + Data([0x0A])

        let events = framer.append(data)

        XCTAssertEqual(events.count, 1)
        guard case .oversized = events[0] else {
            return XCTFail("expected one bounded oversized event")
        }
    }

}

private struct StubAgentIntegrationClient: AgentIntegrationClient {
    var healthResult: AgentIntegrationSessionHealthResult = .hostUnavailable
    var processResult: AgentIntegrationProcessListResult = .guestUnavailable
    var launchResult: AgentIntegrationLaunchSoftwareResult = .unavailable(.host)
    var quitResult: AgentIntegrationQuitResult = .unavailable(.host)
    var artifactResult: AgentIntegrationArtifactTransferResult =
        .unavailable(.host)
    var guestFileCapabilitiesResult:
        AgentIntegrationGuestFileCapabilitiesResult =
            .hostUnavailable(.host)
    var guestFileListResult: AgentIntegrationGuestFileListResult =
        .hostUnavailable(.host)
    var guestFileStatResult: AgentIntegrationGuestFileStatResult =
        .hostUnavailable(.host)

    var sessionCapabilitiesResult:
        AgentIntegrationSessionCapabilitiesResult = .unavailable(.host)

    func sessionHealth() async -> AgentIntegrationSessionHealthResult {
        healthResult
    }

    func sessionCapabilities(probeCostly: Bool) async
        -> AgentIntegrationSessionCapabilitiesResult {
        sessionCapabilitiesResult
    }

    func listProcesses() async -> AgentIntegrationProcessListResult {
        processResult
    }

    func launchSoftware(_ selection: AgentIntegrationLaunchSelection) async
        -> AgentIntegrationLaunchSoftwareResult {
        launchResult
    }

    func requestQuit(reference: String) async
        -> AgentIntegrationQuitResult {
        quitResult
    }

    func transferApprovedArtifact(receipt: String) async
        -> AgentIntegrationArtifactTransferResult {
        artifactResult
    }

    func guestFilesCapabilities() async
        -> AgentIntegrationGuestFileCapabilitiesResult {
        guestFileCapabilitiesResult
    }

    func listGuestFiles(path: String, cursor: Int?) async
        -> AgentIntegrationGuestFileListResult {
        guestFileListResult
    }

    func statGuestFile(path: String) async
        -> AgentIntegrationGuestFileStatResult {
        guestFileStatResult
    }
}
