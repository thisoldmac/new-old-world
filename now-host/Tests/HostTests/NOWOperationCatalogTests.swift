import Foundation
import NOWAgentIntegration
import XCTest

final class NOWOperationCatalogTests: XCTestCase {
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
            case .publicOperation: direct += 1
            case .composition: compositions += 1
            case .agentOnly: agentOnly += 1
            }
        }
        XCTAssertEqual(direct, 40)
        XCTAssertEqual(compositions, 3)
        XCTAssertEqual(agentOnly, 6)
    }

    func testTheCheckedOpenAPIIdentitySetMatchesTheAdjudicatedCatalog() {
        XCTAssertEqual(NOWAPIOperationIDs.apiMajor, 1)
        XCTAssertEqual(NOWAPIOperationIDs.schemaRevision, 4)
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
