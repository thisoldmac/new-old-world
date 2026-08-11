import XCTest

final class TestSkipPolicyTests: XCTestCase {
    /// These suites use only committed fixtures and in-process fakes. A skip
    /// here cannot mean "the environment is unavailable"; it can only hide a
    /// result that the test did not expect.
    func testDeterministicSuitesDoNotSkipUnexpectedResults() throws {
        let files = [
            "AgentIntegrationArtifactTests.swift",
            "AgentIntegrationCapabilityTests.swift",
            "AgentIntegrationCatalogSearchTests.swift",
            "AgentIntegrationDiagnosticsTests.swift",
            "AgentIntegrationFrontTests.swift",
            "AgentIntegrationMachineFactsTests.swift",
            "AgentIntegrationQuitTests.swift",
            "ContractMessageTests.swift",
            "MirrorDecodeCostTests.swift",
            "MirrorQuitModalTests.swift",
        ]
        let root = GateSource.repoRoot
            .appendingPathComponent("now-host/Tests/HostTests")

        for file in files {
            let source = try String(
                contentsOf: root.appendingPathComponent(file),
                encoding: .utf8)
            XCTAssertFalse(
                source.contains("throw XCTSkip"),
                "\(file) is deterministic; unexpected behavior must fail, "
                    + "not skip")
        }
    }
}
