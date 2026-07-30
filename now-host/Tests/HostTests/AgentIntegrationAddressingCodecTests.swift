import XCTest
@testable import Host
@testable import NOWAgentIntegration

/// The local codec's allowlists against the types they are supposed to
/// admit.
///
/// Two fields shipped that their own decoder refused — `guestSelector` on
/// the request and `notAddressed` on the response — because nothing ever
/// sent either one THROUGH the decoder. The last two tests here are the
/// general form of that check: they read the field list off the type with
/// a `Mirror`, so a field added later without a place in the allowlist
/// fails without anyone remembering to add a case.
///
/// Nothing in this file names a protocol version number; the addressing
/// field is orthogonal to the version, and a test that pins one would
/// break the next bump for no reason.
@MainActor
final class AgentIntegrationAddressingCodecTests: XCTestCase {
    private static let allowlistRejection =
        AgentIntegrationLocalTransportError.invalidMessage(
            "Local message does not match the schema")

    private func temporaryEndpoint() throws
        -> (AgentIntegrationEndpoint, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "nat-addr-\(UUID().uuidString.prefix(8))",
                isDirectory: true)
        return (AgentIntegrationEndpoint(
            directoryURL: root,
            socketURL: root.appendingPathComponent("host.sock")), root)
    }

    // MARK: - The request side, the way a companion writes it

    /// Hand-written JSON, not something this side encoded: a companion
    /// names a machine by composing the object itself, and a round trip
    /// through our own encoder would test one half twice.
    func testCompanionAuthoredRequestMayNameAMachine() throws {
        let requestID = UUID()
        let raw = try JSONSerialization.data(withJSONObject: [
            "version": AgentIntegrationLocalProtocol.version,
            "requestID": requestID.uuidString,
            "operation": "list_processes",
            "guestSelector": "pb1400c",
        ])

        let decoded = try AgentIntegrationLocalCodec.decodeRequest(raw)

        XCTAssertEqual(decoded.guestSelector, "pb1400c")
        XCTAssertEqual(decoded.requestID, requestID)
        XCTAssertEqual(decoded.operation, .listProcesses)
    }

    /// A session id is the other addressing form, and it goes through the
    /// same field: the codec must not develop an opinion about which one.
    func testCompanionAuthoredRequestMayNameASession() throws {
        let raw = try JSONSerialization.data(withJSONObject: [
            "version": AgentIntegrationLocalProtocol.version,
            "requestID": UUID().uuidString,
            "operation": "session_capabilities",
            "probeCostly": false,
            "guestSelector":
                "pb1400c-00000000-0000-0000-0000-000000000000",
        ])

        let decoded = try AgentIntegrationLocalCodec.decodeRequest(raw)

        XCTAssertEqual(
            decoded.guestSelector,
            "pb1400c-00000000-0000-0000-0000-000000000000")
    }

    /// Addressing is orthogonal to the operation, so every operation has
    /// to accept it — the top-level allowlist and the per-operation key
    /// set are two separate gates and the field must clear both.
    ///
    /// A new operation belongs in this list.
    func testEveryOperationAcceptsAGuestSelector() throws {
        let upload = AgentIntegrationGuestFileUploadBegin(
            destinationPath: "Macintosh HD:Lab:hello.txt",
            bytes: 4,
            sha256: String(repeating: "a", count: 64),
            container: "data",
            fileType: "TEXT",
            creator: "ttxt",
            modified: nil)
        let samples: [AgentIntegrationLocalRequest] = [
            .sessionHealth(),
            .sessionCapabilities(probeCostly: true),
            .processList(),
            .launchSoftware(.name("SimpleText")),
            .requestQuit(
                reference: "now-process-00000000-0000-0000-0000-000000000000"),
            .transferApprovedArtifact(
                receipt:
                    "now-artifact-00000000-0000-0000-0000-000000000000"),
            .guestFilesCapabilities(),
            .guestFilesList(path: "Macintosh HD:", cursor: nil),
            .guestFilesList(path: "Macintosh HD:", cursor: 2),
            .guestFilesStat(path: "Macintosh HD:Lab:hello.txt"),
            .guestFilesUploadBegin(upload),
            .guestFilesUploadAppend(
                uploadID: UUID(), offset: 0,
                base64: Data("hi".utf8).base64EncodedString()),
            .guestFilesUploadCommit(uploadID: UUID()),
        ]

        for sample in samples {
            var addressed = sample
            addressed.guestSelector = "pb1400c"
            let encoded = try AgentIntegrationLocalCodec.encode(addressed)
            let decoded = try? AgentIntegrationLocalCodec.decodeRequest(
                encoded)
            XCTAssertEqual(
                decoded?.guestSelector, "pb1400c",
                "\(sample.operation.rawValue) refused an addressed request")
        }
    }

    /// The unaddressed request is what every existing caller sends, and it
    /// must stay valid: absent means "the machine this host is driving".
    func testAnUnaddressedRequestStaysValid() throws {
        let raw = try JSONSerialization.data(withJSONObject: [
            "version": AgentIntegrationLocalProtocol.version,
            "requestID": UUID().uuidString,
            "operation": "list_processes",
        ])

        let decoded = try AgentIntegrationLocalCodec.decodeRequest(raw)

        XCTAssertNil(decoded.guestSelector)
    }

    // MARK: - The response side, the way a companion reads it

    /// Hand-written again: this is the refusal arriving from a host, and
    /// the companion has to be able to tell it from a broken message.
    func testCompanionCanReadTheAddressingRefusal() throws {
        let requestID = UUID()
        let raw = try JSONSerialization.data(withJSONObject: [
            "version": AgentIntegrationLocalProtocol.version,
            "requestID": requestID.uuidString,
            "notAddressed": [
                "code": "now-guest-not-addressed",
                "message": "q950 is connected, but this host is driving "
                    + "pb1400c. Connected: pb1400c, q950",
            ],
        ])

        let decoded = try AgentIntegrationLocalCodec.decodeResponse(raw)

        XCTAssertEqual(decoded.notAddressed?.code,
                       "now-guest-not-addressed")
        XCTAssertNil(decoded.error)
        XCTAssertNil(decoded.result)
        XCTAssertEqual(decoded.requestID, requestID)
    }

    /// The refusal is set INSTEAD of a result, not beside one: a response
    /// carrying both is malformed and must be refused as such.
    func testRefusalBesideAResultIsRejected() throws {
        let raw = try JSONSerialization.data(withJSONObject: [
            "version": AgentIntegrationLocalProtocol.version,
            "requestID": UUID().uuidString,
            "notAddressed": [
                "code": "now-guest-not-addressed",
                "message": "addressed elsewhere",
            ],
            "processListResult": [String: Any](),
        ])

        XCTAssertThrowsError(
            try AgentIntegrationLocalCodec.decodeResponse(raw)
        ) { error in
            XCTAssertEqual(
                error as? AgentIntegrationLocalTransportError,
                .invalidMessage(
                    "Response must contain exactly one result or error"))
        }
    }

    // MARK: - Through the socket, both halves at once

    /// The whole path: a companion-side client that says which machine it
    /// means, a host that will not answer for it, and a refusal that
    /// arrives as itself rather than as "invalid response".
    func testAddressedRequestIsRefusedAsARefusalOverTheSocket()
        async throws {
        let (endpoint, root) = try temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let refusal = AgentIntegrationUnavailable.notAddressed(
            asking: "q950", driving: "pb1400c",
            connected: ["pb1400c", "q950"])
        var seenSelector: String?
        var reachedOperation = false
        let server = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            handler: { request in
                seenSelector = request.guestSelector
                guard request.guestSelector == nil else {
                    return .notAddressed(refusal)
                }
                reachedOperation = true
                return .processList(.unavailable(.guest))
            })
        try server.start()
        defer { server.stop() }

        let client = try AgentIntegrationLocalClient(endpoint: endpoint)
            .addressing("q950")
        var thrown: Error?
        do {
            _ = try await client.listProcesses()
        } catch {
            thrown = error
        }

        XCTAssertEqual(seenSelector, "q950",
                       "the host never saw the machine the caller named")
        XCTAssertFalse(reachedOperation)
        XCTAssertEqual(
            thrown as? AgentIntegrationLocalTransportError,
            .notAddressed(refusal))
    }

    // MARK: - The allowlists against the types themselves

    /// Every field the request type can carry is admitted by the request
    /// allowlist.
    ///
    /// Derived from the type with a `Mirror` rather than a list written
    /// here, because the failure this covers is exactly the failure of
    /// remembering to update a second list: `guestSelector` was declared,
    /// encoded, and then refused by its own decoder for a week.
    func testRequestAllowlistAdmitsEveryFieldOnTheType() throws {
        let fields = Mirror(reflecting: AgentIntegrationLocalRequest
            .sessionHealth())
            .children
            .compactMap(\.label)
        XCTAssertTrue(fields.contains("guestSelector"))

        for field in fields
        where !["version", "requestID", "operation"].contains(field) {
            let raw = try JSONSerialization.data(withJSONObject: [
                "version": AgentIntegrationLocalProtocol.version,
                "requestID": UUID().uuidString,
                "operation": "list_processes",
                field: "probe",
            ])
            /* The per-operation key set may still refuse this — a
               list_processes request has no business carrying a file
               path. What it must NOT do is refuse the KEY as unknown. */
            do {
                _ = try AgentIntegrationLocalCodec.decodeRequest(raw)
            } catch {
                XCTAssertNotEqual(
                    error as? AgentIntegrationLocalTransportError,
                    Self.allowlistRejection,
                    "request allowlist does not admit \(field)")
            }
        }
    }

    /// The same check for the response, whose `notAddressed` was the
    /// second half of the same defect.
    func testResponseAllowlistAdmitsEveryFieldOnTheType() throws {
        let sample = AgentIntegrationLocalResponse(
            requestID: UUID(),
            notAddressed: .notAddressed(
                asking: "q950", driving: "pb1400c",
                connected: ["pb1400c"]))
        let fields = Mirror(reflecting: sample).children
            .compactMap(\.label)
        XCTAssertTrue(fields.contains("notAddressed"))

        for field in fields
        where !["version", "requestID"].contains(field) {
            let raw = try JSONSerialization.data(withJSONObject: [
                "version": AgentIntegrationLocalProtocol.version,
                "requestID": UUID().uuidString,
                field: [String: Any](),
            ])
            do {
                _ = try AgentIntegrationLocalCodec.decodeResponse(raw)
            } catch {
                XCTAssertNotEqual(
                    error as? AgentIntegrationLocalTransportError,
                    Self.allowlistRejection,
                    "response allowlist does not admit \(field)")
            }
        }
    }
}
