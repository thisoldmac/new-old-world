import Foundation
import NOWAgentIntegration
import XCTest

final class NOWOperationCatalogTests: XCTestCase {
    func testTypedProjectionValuesPreserveNeutralDispositionBeforeErasure() {
        XCTAssertEqual(HostProjectionValue(
            AgentIntegrationProjectedResult<String>.completed("ok"))
            .disposition, .completed)
        XCTAssertEqual(HostProjectionValue(
            AgentIntegrationProjectedResult<String>.refused(.init(
                code: "declined", message: "declined")))
            .disposition, .refused)
        XCTAssertEqual(HostProjectionValue(
            AgentIntegrationProjectedResult<String>.unavailable(.host))
            .disposition, .unavailable)
        XCTAssertEqual(HostProjectionValue(
            AgentIntegrationLaunchSoftwareResult.refused(.init(
                code: "policy", message: "declined")))
            .disposition, .refused)
        XCTAssertEqual(HostProjectionValue(
            AgentIntegrationMirrorReadResult(unavailable: .host))
            .disposition, .unavailable)
        XCTAssertEqual(HostProjectionValue(
            ["ok": false], disposition: .failed).disposition, .failed)
    }

    func testGeneratedCLIMetadataMatchesNeutralInventory() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let document = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent(
                "contract/now-api.openapi.json"))) as? [String: Any])
        let published = try XCTUnwrap(
            document["x-now-cli-operation-metadata"] as? [[String: Any]])
        let derived = NOWOperationInventory.publicOperationMetadata().map {
            ["operationId": $0["operationId"]!, "effect": $0["effect"]!,
             "addressing": $0["addressing"]!, "rendering": "generic"]
        }
        let left = try JSONSerialization.data(
            withJSONObject: published, options: [.sortedKeys])
        let right = try JSONSerialization.data(
            withJSONObject: derived, options: [.sortedKeys])
        XCTAssertEqual(left, right)
    }
    func testEveryProjectionHasOneCompleteAdjudicationAndExposureDeclaration() {
        let entries = HostProjectionCatalog.projections.compactMap(
            NOWOperationInventory.entry(for:))
        XCTAssertEqual(entries.count, HostProjectionCatalog.projections.count)
        XCTAssertEqual(entries.count, 49)

        var direct = 0
        var compositions = 0
        var agentOnly = 0
        for entry in entries {
            XCTAssertEqual(Set(entry.exposures.keys), Set(NOWOperationFace.allCases),
                           "\(entry.capability) omits an exposure decision")
            switch entry.adjudication {
            case .publicOperation(let operationID):
                direct += 1
                XCTAssertEqual(
                    NOWOperationInventory.projectionCapability(
                        forPublicOperationID: operationID),
                    entry.capability)
                if case .planned = entry.exposures[.http] {
                    XCTFail("\(operationID) still has planned HTTP exposure")
                }
                if case .planned = entry.exposures[.cli] {
                    XCTFail("\(operationID) still has planned CLI exposure")
                }
            case .composition: compositions += 1
            case .agentOnly: agentOnly += 1
            }
            for face in [NOWOperationFace.http, .cli] {
                if case .notRendered(let reason) = entry.exposures[face] {
                    XCTAssertFalse(reason.isEmpty,
                                   "\(entry.capability) has an empty \(face) reason")
                }
            }
        }
        XCTAssertEqual(direct, 40)
        XCTAssertEqual(compositions, 3)
        XCTAssertEqual(agentOnly, 6)
        XCTAssertNil(NOWOperationInventory.projectionCapability(
            forPublicOperationID: "now_projects"))
    }

    func testTheCheckedOpenAPIIdentitySetMatchesTheAdjudicatedCatalog() {
        XCTAssertEqual(NOWAPIOperationIDs.apiMajor, 1)
        XCTAssertEqual(NOWAPIOperationIDs.schemaRevision, 6)
        XCTAssertEqual(NOWAPIOperationIDs.all,
                       NOWOperationInventory.publicOperationIDs)
    }

    /// Golden parity for the complete rendered MCP tools/list body. It is
    /// deliberately below the neutral seam: changing an MCP name, schema,
    /// hint, root type, guest selector, order, or extension changes this.
    func testNeutralCatalogRendersTheCapturedMCPToolSurfaceExactly() throws {
        let tools = NOWMCPToolRenderer.tools(for: .hostFaces)
        let data = try JSONSerialization.data(
            withJSONObject: tools, options: [.sortedKeys])
        XCTAssertEqual(Self.fnv1a(data), "43b50cd743217432")
    }

    private static func fnv1a(_ data: Data) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}
