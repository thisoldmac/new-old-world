import XCTest
@testable import NOWAgentCompanion
import NOWAgentIntegration

@MainActor
final class SocketAttemptRefusalTests: XCTestCase {
    func testAttemptCollisionSurvivesTheCompanionBoundary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "nat-companion-\(UUID().uuidString.prefix(8))",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = AgentIntegrationEndpoint(
            directoryURL: root,
            socketURL: root.appendingPathComponent("host.sock"))
        let attempt = "31234567-89ab-cdef-0123-456789abcdef"
        let health = AgentIntegrationSessionHealth(
            state: .notListening,
            observedAt: Date(timeIntervalSince1970: 1_800_000_000),
            listeningPort: nil,
            sessionID: nil,
            guest: nil,
            failure: nil,
            compatibility: .init(
                hostBuild: "attempt-refusal-test",
                companionProtocol: AgentIntegrationLocalProtocol.version,
                projectionCatalogVersion:
                    HostProjectionRegistry.catalogVersion,
                projectionCatalogDigest:
                    HostProjectionRegistry.hostFaces.catalogDigest,
                schemaRevisions: []))
        var projectInvocations = 0
        var developmentInvocations = 0
        let server = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            handler: { request in
                switch request.operation {
                case .sessionHealth:
                    return .sessionHealth(.available(health))
                case .projects:
                    projectInvocations += 1
                    return .projects(.init(projects: []))
                case .development:
                    developmentInvocations += 1
                    return .development(.unavailable(.host))
                default:
                    return .sessionHealth(.hostUnavailable)
                }
            })
        try server.start()
        defer { server.stop() }
        let local = try AgentIntegrationLocalClient(endpoint: endpoint)
        _ = try await local.projects(.init(
            operation: .workspaceDiscard,
            workspaceID: "workspace-0123456789abcdef",
            attemptID: attempt))

        let result = await SocketAgentIntegrationClient(endpoint: endpoint)
            .development(.init(operation: .buildCancel, attemptID: attempt))

        guard case .unavailable(let refusal) = result else {
            return XCTFail("companion accepted a colliding attempt")
        }
        XCTAssertEqual(refusal.code, "attempt-collision")
        XCTAssertEqual(
            refusal.message,
            "This attempt ID is already bound to a different request.")
        XCTAssertEqual(projectInvocations, 1)
        XCTAssertEqual(developmentInvocations, 0,
                       "a colliding request must never reach the host lane")
    }
}
