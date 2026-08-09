import XCTest
@testable import Host
@testable import NOWAgentIntegration

@MainActor
final class AgentIntegrationDevelopmentTests: XCTestCase {
    func testRequestVocabularyHasNoPathOrCommandEscape() {
        let project = String(repeating: "a", count: 32)
        XCTAssertTrue(AgentIntegrationDevelopmentRequest(
            operation: .buildStart, projectID: project).isWellFormed)
        XCTAssertFalse(AgentIntegrationDevelopmentRequest(
            operation: .buildStart, projectID: "Macintosh HD:Lab").isWellFormed)
        XCTAssertTrue(AgentIntegrationDevelopmentRequest(
            operation: .run,
            productRef: "product-0123456789abcdef").isWellFormed)
        XCTAssertFalse(AgentIntegrationDevelopmentRequest(
            operation: .run, projectID: project,
            productRef: "product-0123456789abcdef").isWellFormed)
        XCTAssertTrue(AgentIntegrationDevelopmentRequest(
            operation: .importGuest, projectID: project).isWellFormed)
        XCTAssertTrue(AgentIntegrationDevelopmentRequest(
            operation: .promote,
            candidateID: "candidate-0123456789abcdef").isWellFormed)
        XCTAssertEqual(DevelopmentProjection.acceptedArguments,
                       ["operation", "projectID", "workspaceID",
                        "candidateID", "productRef"])
        XCTAssertEqual(DevelopmentProjection.authorityDomain,
                       .hostProjectsAndGuest)
    }

    func testDevelopmentRequestAndResultSurviveLocalCodec() throws {
        let operation = AgentIntegrationDevelopmentRequest(
            operation: .buildStart,
            projectID: String(repeating: "b", count: 32))
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
            projectID: String(repeating: "c", count: 32))) else {
            return XCTFail("expected guest Development rows")
        }
        XCTAssertEqual(report.verb, "development-build")
        XCTAssertEqual(report.groups[0].rows.last?.value, "running")
    }
}
