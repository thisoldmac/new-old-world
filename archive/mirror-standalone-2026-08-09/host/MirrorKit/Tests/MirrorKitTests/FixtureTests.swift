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
///
/// ## The version stamp is checked apart from the scene
///
/// `Scene.version` is stamped by `SceneBuilder` from `IR.version`, a
/// compile-time constant — so pinning it inside each `.expected.json` pins
/// one fact once per fixture. When the IR major moved 1 → 2 on 2026-08-03
/// the corpus was not re-stamped, and the suite reported **seven scene
/// mismatches** for a single stale integer. Every other byte of every scene
/// matched; nothing in MirrorKit had regressed. Reading that as seven
/// broken scenes is exactly the wrong first move.
///
/// So the stamp is compared first, and on its own, with a message that says
/// what actually happened and what to do. The scene body is then compared
/// with the stamp removed from both sides, so a *real* regression is named
/// per-fixture and is never buried under a version diff.
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

        var produced = try canonicalize(JSONEncoder().encode(scene))
        var expected = try canonicalize(expectedData)

        // The stamp first, and alone. A corpus that predates an IR major is a
        // stale corpus, not seven broken scenes.
        let producedVersion = (produced as? [String: Any])?["version"] as? Int
        let expectedVersion = (expected as? [String: Any])?["version"] as? Int
        XCTAssertEqual(producedVersion, IR.version,
                       "\(name): SceneBuilder did not stamp IR.version")
        if expectedVersion != producedVersion {
            XCTFail("""
            \(name): the corpus predates IR v\(IR.version) \
            (this fixture is stamped v\(expectedVersion.map(String.init) ?? "?")).
            This is a STALE FIXTURE, not a scene regression. The scene body is \
            compared separately: if no "scene mismatch" is also reported for \
            this fixture, the stamp is the ONLY thing that moved and nothing \
            in MirrorKit has changed shape. Re-stamp the fixture then; \
            re-capture off a live guest only if the body really did move.
            """)
        }
        produced = withoutVersion(produced)
        expected = withoutVersion(expected)

        if !deepEqual(produced, expected) {
            XCTFail("""
            \(name): scene mismatch
            produced: \(prettyJSON(produced))
            expected: \(prettyJSON(expected))
            """)
        }
    }

    private func withoutVersion(_ value: Any) -> Any {
        guard var dict = value as? [String: Any] else { return value }
        dict.removeValue(forKey: "version")
        return dict
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
