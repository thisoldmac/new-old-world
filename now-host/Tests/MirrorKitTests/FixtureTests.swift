import XCTest
@testable import MirrorKit

/// Golden-fixture tests: real captured wire payloads → expected scenes.
///
/// Each fixture is a pair in `Fixtures/`:
///   <name>.raw.json      — capture envelope: {source, seq, screen,
///                          capturedAt, latencyMs?, bytes?, result}
///   <name>.expected.json — the scene `scene.py` (the port oracle) produced
///                          for that envelope, plus the Swift-side `version`.
///
/// Comparison is deep-equal after stripping JSON nulls: Python emits
/// explicit nulls for absent optionals, Swift's encoder omits them — the
/// same absence, two spellings.
final class FixtureTests: XCTestCase {

    func testAllFixtures() throws {
        let fixtures = try fixtureNames()
        XCTAssertFalse(fixtures.isEmpty, "no fixtures found — capture some")
        for name in fixtures.sorted() {
            try assertFixture(name)
        }
    }

    // MARK: - Machinery

    private func fixturesURL() throws -> URL {
        guard let url = Bundle.module.url(forResource: "Fixtures",
                                          withExtension: nil) else {
            throw XCTSkip("Fixtures resource directory missing")
        }
        return url
    }

    private func fixtureNames() throws -> [String] {
        let files = try FileManager.default
            .contentsOfDirectory(atPath: fixturesURL().path)
        return files.filter { $0.hasSuffix(".raw.json") }
            .map { String($0.dropLast(".raw.json".count)) }
    }

    private func assertFixture(_ name: String) throws {
        let dir = try fixturesURL()
        let rawData = try Data(contentsOf:
            dir.appendingPathComponent("\(name).raw.json"))
        let expectedData = try Data(contentsOf:
            dir.appendingPathComponent("\(name).expected.json"))
        let scene = try FixtureEnvelope.scene(from: rawData)

        let produced = try canonicalize(JSONEncoder().encode(scene))
        let expected = try canonicalize(expectedData)
        if !deepEqual(produced, expected) {
            XCTFail("""
            \(name): scene mismatch
            produced: \(prettyJSON(produced))
            expected: \(prettyJSON(expected))
            """)
        }
    }

    /// Parse JSON and strip nulls recursively so Python's explicit nulls and
    /// Swift's omitted optionals compare equal.
    private func canonicalize(_ data: Data) throws -> Any {
        stripNulls(try JSONSerialization.jsonObject(with: data))
    }

    private func stripNulls(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict where !(v is NSNull) {
                out[k] = stripNulls(v)
            }
            return out
        }
        if let list = value as? [Any] {
            return list.map(stripNulls)
        }
        return value
    }

    private func deepEqual(_ a: Any, _ b: Any) -> Bool {
        (a as? NSObject)?.isEqual(b) ?? false
    }

    private func prettyJSON(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys]) else { return "\(value)" }
        return String(decoding: data, as: UTF8.self)
    }
}
