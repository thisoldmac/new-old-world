import XCTest
@testable import Host
@testable import NOWAgentIntegration

@MainActor
final class AgentIntegrationDevelopmentTests: XCTestCase {
    func testGuestImportNamesNoncanonicalProjectDocumentIdentity() {
        XCTAssertNil(AgentIntegrationDevelopmentControl
            .projectDocumentIdentityProblem(
                type: "TEXT", creator: "NOWD", finderFlags: 0,
                resourceBytes: 0))
        XCTAssertEqual(AgentIntegrationDevelopmentControl
            .projectDocumentIdentityProblem(
                type: "TEXT", creator: "MPS ", finderFlags: 0,
                resourceBytes: 0),
            "Project.ckp must be TEXT/NOWD with zero Finder flags and an empty resource fork.")
        XCTAssertNotNil(AgentIntegrationDevelopmentControl
            .projectDocumentIdentityProblem(
                type: "TEXT", creator: "NOWD", finderFlags: 0x4000,
                resourceBytes: 0))
        XCTAssertNotNil(AgentIntegrationDevelopmentControl
            .projectDocumentIdentityProblem(
                type: "TEXT", creator: "NOWD", finderFlags: 0,
                resourceBytes: 1))
    }

    func testRequestVocabularyHasNoPathOrCommandEscape() {
        let project = String(repeating: "a", count: 32)
        let attempt = "01234567-89ab-cdef-0123-456789abcdef"
        XCTAssertTrue(AgentIntegrationDevelopmentRequest(
            operation: .buildStart, projectID: project,
            attemptID: attempt).isWellFormed)
        XCTAssertFalse(AgentIntegrationDevelopmentRequest(
            operation: .buildStart, projectID: "Macintosh HD:Lab").isWellFormed)
        XCTAssertTrue(AgentIntegrationDevelopmentRequest(
            operation: .run,
            productRef: "product-0123456789abcdef",
            attemptID: attempt).isWellFormed)
        XCTAssertTrue(AgentIntegrationDevelopmentRequest(
            operation: .test,
            productRef: "product-0123456789abcdef",
            attemptID: attempt).isWellFormed)
        XCTAssertFalse(AgentIntegrationDevelopmentRequest(
            operation: .run, projectID: project,
            productRef: "product-0123456789abcdef").isWellFormed)
        XCTAssertTrue(AgentIntegrationDevelopmentRequest(
            operation: .importGuest, projectID: project,
            attemptID: attempt).isWellFormed)
        XCTAssertTrue(AgentIntegrationDevelopmentRequest(
            operation: .catalog).isWellFormed)
        XCTAssertTrue(AgentIntegrationDevelopmentRequest(
            operation: .promote,
            candidateID: "candidate-0123456789abcdef",
            attemptID: attempt).isWellFormed)
        XCTAssertEqual(DevelopmentProjection.acceptedArguments,
                       ["operation", "projectID", "workspaceID",
                        "candidateID", "productRef", "attemptID"])
        XCTAssertEqual(DevelopmentProjection.authorityDomain,
                       .hostProjectsAndGuest)
        let descriptor = DevelopmentProjection.mcpDescriptor
        let schema = descriptor["inputSchema"] as? [String: Any]
        let branches = schema?["oneOf"] as? [[String: Any]] ?? []
        let operations = branches.compactMap { branch in
            let properties = branch["properties"] as? [String: Any]
            let operation = properties?["operation"] as? [String: Any]
            return operation?["const"] as? String
        }
        XCTAssertFalse(operations.contains("open-in-codekitten"),
                       "IDE handoff is an explicit human action, not agent authority")
        XCTAssertEqual(operations.filter { $0 == "build-start" }.count, 2,
                       "project and candidate builds are exclusive schema branches")
        XCTAssertTrue(branches.allSatisfy {
            ($0["additionalProperties"] as? Bool) == false
        }, "every Development operation must reject sibling fields")
    }

    func testAdapterMapsTypedTestToClosedGuestCommand() async throws {
        let (listener, guest) = try await connectedListener()
        defer { guest.connection.cancel(); listener.stop() }
        let product = "product-0123456789abcdef"
        guest.onMessage = { message in
            guard case .commandRequest(let request) = message,
                  request.name == "development-test" else { return }
            XCTAssertEqual(request.args?["productRef"], .text(product))
            try? guest.send(.commandResult(.init(
                id: request.id, ok: true,
                output: ["development-test": [
                    ["Schema", "ckproject.test-receipt/1"],
                    ["State", "succeeded"],
                ]], error: nil)))
        }
        let adapter = AgentIntegrationHostAdapter(listener: listener)
        guard case .completed(let report) = await adapter.development(.init(
            operation: .test, productRef: product,
            attemptID: "01234567-89ab-cdef-0123-456789abcdef")) else {
            return XCTFail("expected a typed test receipt")
        }
        XCTAssertEqual(report.verb, "development-test")
        XCTAssertEqual(report.groups[0].rows.first?.value,
                       "ckproject.test-receipt/1")
    }

    func testCatalogUsesBoundedGuestProjectVocabulary() async throws {
        let (listener, guest) = try await connectedListener()
        defer { guest.connection.cancel(); listener.stop() }
        guest.onMessage = { message in
            guard case .commandRequest(let request) = message,
                  request.name == "development-project" else { return }
            XCTAssertEqual(request.args?["action"], .text("catalog"))
            try? guest.send(.commandResult(.init(
                id: request.id, ok: true,
                output: ["development-project": [
                    ["Project", String(repeating: "a", count: 32)
                        + "|Memory Meter"],
                    ["Next", "-1"],
                ]], error: nil)))
        }
        let adapter = AgentIntegrationHostAdapter(listener: listener)
        guard case .completed(let report) = await adapter.development(.init(
            operation: .catalog)) else {
            return XCTFail("expected guest project catalog")
        }
        XCTAssertEqual(report.groups[0].rows.first?.label, "Project")
    }

    func testDevelopmentRequestAndResultSurviveLocalCodec() throws {
        let operation = AgentIntegrationDevelopmentRequest(
            operation: .buildStart,
            projectID: String(repeating: "b", count: 32),
            attemptID: "01234567-89ab-cdef-0123-456789abcdef")
        let request = AgentIntegrationLocalRequest.development(operation)
        XCTAssertEqual(try AgentIntegrationLocalCodec.decodeRequest(
            AgentIntegrationLocalCodec.encode(request)), request)

        let result = AgentIntegrationGuestRowReportResult.completed(.init(
            verb: "development-build",
            groups: [.init(name: "development-build", rows: [
                .init(label: "State", value: "running"),
            ])], observedAt: Date(timeIntervalSince1970: 1_800_000_000)))
        let response = AgentIntegrationLocalResponse(
            requestID: request.requestID, developmentResult: result)
        XCTAssertEqual(try AgentIntegrationLocalCodec.decodeResponse(
            AgentIntegrationLocalCodec.encode(response)), response)
    }

    func testAdapterMapsOnlyTypedOperationToGuestCommand() async throws {
        let (listener, guest) = try await connectedListener()
        defer { guest.connection.cancel(); listener.stop() }
        guest.onMessage = { message in
            guard case .commandRequest(let request) = message,
                  request.name == "development-build" else { return }
            XCTAssertEqual(request.args?["action"], .text("start"))
            XCTAssertEqual(request.args?["projectID"],
                           .text(String(repeating: "c", count: 32)))
            try? guest.send(.commandResult(.init(
                id: request.id, ok: true,
                output: ["development-build": [
                    ["Job", "build-0123456789abcdef"],
                    ["State", "running"],
                ]], error: nil)))
        }
        let adapter = AgentIntegrationHostAdapter(listener: listener)
        guard case .completed(let report) = await adapter.development(.init(
            operation: .buildStart,
            projectID: String(repeating: "c", count: 32),
            attemptID: "01234567-89ab-cdef-0123-456789abcdef")) else {
            return XCTFail("expected guest Development rows")
        }
        XCTAssertEqual(report.verb, "development-build")
        XCTAssertEqual(report.groups[0].rows.last?.value, "running")
    }

    func testHumanCodeKittenHandoffPollsAfterCooperativeLaunch() async throws {
        let (listener, guest) = try await connectedListener()
        defer { guest.connection.cancel(); listener.stop() }
        let projectID = String(repeating: "d", count: 32)
        var calls = 0
        guest.onMessage = { message in
            guard case .commandRequest(let request) = message,
                  request.name == "development-open" else { return }
            calls += 1
            XCTAssertEqual(request.args?["projectID"], .text(projectID))
            let state = calls == 1 ? "launching" : "dispatched"
            try? guest.send(.commandResult(.init(
                id: request.id, ok: true,
                output: ["development-open": [
                    ["Project", projectID],
                    ["State", state],
                ]], error: nil)))
        }
        let adapter = AgentIntegrationHostAdapter(listener: listener)
        guard case .completed(let report) = await adapter.development(.init(
            operation: .openInCodeKitten, projectID: projectID,
            attemptID: "01234567-89ab-cdef-0123-456789abcdef")) else {
            return XCTFail("expected a settled CodeKitten handoff")
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(report.groups[0].rows.last?.value, "dispatched")
    }
}
