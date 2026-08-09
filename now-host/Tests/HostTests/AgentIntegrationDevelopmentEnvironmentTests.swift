import XCTest
@testable import Host
import NOWAgentIntegration

@MainActor
final class AgentIntegrationDevelopmentEnvironmentTests: XCTestCase {
    private func installResponder(on guest: FakeGuest) {
        guest.onMessage = { message in
            guard case .commandRequest(let request) = message,
                  request.name == "development" else { return }
            try? guest.send(.commandResult(.init(
                id: request.id,
                ok: true,
                output: ["development": [
                    ["Projects", "chosen"],
                    ["Toolchain", "mpw--1-451"],
                    ["Version", "structural-1"],
                    ["Qualification", "qualified"],
                    ["ToolServer", "found"],
                    ["MrC", "found"],
                ]],
                error: nil)))
        }
    }

    func testAdapterReturnsQualifiedRowsWithoutAPath() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        installResponder(on: guest)
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        guard case .completed(let report) =
                await adapter.developmentEnvironment() else {
            return XCTFail("expected development report")
        }
        XCTAssertEqual(report.verb, "development")
        XCTAssertEqual(report.groups.map(\.name), ["development"])
        XCTAssertEqual(report.groups[0].rows[1], .init(
            label: "Toolchain", value: "mpw--1-451"))
        XCTAssertFalse(report.groups[0].rows.contains {
            $0.label.lowercased().contains("path")
                || $0.value.contains(":")
        })
    }

    func testProjectionRejectsEveryArgumentAndCallsTheFixedLane()
        async throws {
        let invalid = await DevelopmentEnvironmentProjection.invoke(
            .init(raw: ["path": "Macintosh HD:MPW"]),
            through: DevelopmentEnvironmentStub())
        guard case .invalidArguments = invalid else {
            return XCTFail("an agent-supplied path must be rejected")
        }

        let host = DevelopmentEnvironmentStub()
        let valid = await DevelopmentEnvironmentProjection.invoke(
            .init(raw: [:]), through: host)
        guard case .value = valid else {
            return XCTFail("expected a projected value")
        }
        let calls = await host.calls
        XCTAssertEqual(calls, 1)
    }
}

private actor DevelopmentEnvironmentStub: AgentIntegrationClient {
    private(set) var calls = 0

    func developmentEnvironment() async
        -> AgentIntegrationGuestRowReportResult {
        calls += 1
        return .completed(.init(
            verb: "development",
            groups: [.init(name: "development", rows: [])],
            observedAt: Date(timeIntervalSince1970: 1_800_000_000)))
    }

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
