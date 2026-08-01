import XCTest
@testable import MirrorKit

/// Desktop-icon normalizer tests against a captured `list` of the Desktop
/// Folder (fixture 08) — the semantic icon layer (fdLocation), not pixels.
final class DesktopItemsTests: XCTestCase {

    private func listResult() throws -> [String: Any] {
        guard let url = Bundle.module.url(forResource: "Fixtures",
                                          withExtension: nil) else {
            throw XCTSkip("Fixtures missing")
        }
        let data = try Data(contentsOf:
            url.appendingPathComponent("08-list-desktop.json"))
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func testNormalizesPositionsAndKinds() throws {
        let items = SceneBuilder.desktopItems(from: try listResult())
        XCTAssertFalse(items.isEmpty)
        // Every item has a real hand-placed position on this guest.
        XCTAssertTrue(items.allSatisfy { $0.placed })

        let hd = items.first { $0.name == "HELLO_CLAUDE.txt" }!
        XCTAssertEqual(hd.kind, "file")
        XCTAssertEqual(hd.type, "TEXT")
        XCTAssertFalse(hd.alias)
        XCTAssertTrue(hd.x > 0 && hd.y > 0)

        let folder = items.first { $0.name == "TBTRunner" }!
        XCTAssertEqual(folder.kind, "folder")

        let app = items.first { $0.name == "HelloWorld" }!
        XCTAssertEqual(app.type, "APPL")
    }

    func testAliasFlagDetected() throws {
        let items = SceneBuilder.desktopItems(from: try listResult())
        // The desktop aliases (Browse the Internet, Mail, …) carry fdIsAlias.
        let browse = items.first { $0.name == "Browse the Internet" }!
        XCTAssertTrue(browse.alias)
        // A plain document is not an alias.
        let doc = items.first { $0.name == "From Claude.txt" }!
        XCTAssertFalse(doc.alias)
    }

    func testUnplacedAndInvisibleHandling() {
        // {0,0} → unplaced (Finder auto-arranges; we don't invent a spot).
        // fdInvisible (0x4000) → dropped entirely.
        let result: [String: Any] = ["items": [
            ["name": "auto", "kind": "file", "loc": ["h": 0, "v": 0],
             "flags": 0],
            ["name": "hidden", "kind": "file", "loc": ["h": 40, "v": 40],
             "flags": 0x4000],
            ["name": "placed", "kind": "file", "loc": ["h": 40, "v": 40],
             "flags": 0],
        ]]
        let items = SceneBuilder.desktopItems(from: result)
        XCTAssertEqual(items.map(\.name), ["auto", "placed"])  // hidden dropped
        XCTAssertFalse(items[0].placed)                        // auto unplaced
        XCTAssertTrue(items[1].placed)
    }
}
