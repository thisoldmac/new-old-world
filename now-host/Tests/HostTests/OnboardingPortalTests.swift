import Foundation
import XCTest
@testable import Host

@MainActor
final class OnboardingPortalTests: XCTestCase {
    func testPortalServesTheClassicPageApplicationAndPersonalizedSettings()
        async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let application = temporary
            .appendingPathComponent("New Old World.bin")
        try Data("macbinary-app".utf8).write(to: application)

        let portal = OnboardingPortal(
            catalog: OnboardingAssetCatalog(
                roots: [temporary], writableRoot: temporary),
            advertisedAddress: { "127.0.0.1" })
        portal.start(wirePort: 5_412)
        let endpoint = try await runningEndpoint(portal)
        defer { portal.stop() }

        let page = try await fetch(try XCTUnwrap(endpoint.pageURL))
        XCTAssertEqual(page.status, 200)
        let html = try XCTUnwrap(String(data: page.data, encoding: .utf8))
        XCTAssertTrue(html.contains("192") == false,
                      "the page uses the interface that accepted this request")
        XCTAssertTrue(html.contains("127.0.0.1:5412"))
        XCTAssertTrue(html.contains("/now/application.bin"))
        XCTAssertTrue(html.contains("/now/settings.bin"))
        XCTAssertTrue(html.contains("CarbonLib 1.6.1"))
        XCTAssertTrue(html.contains("macintoshgarden.org/apps/carbonlib"))
        XCTAssertFalse(html.contains("/now/archive.sit"))
        XCTAssertFalse(html.contains("<script"))

        let app = try await fetch(endpointURL(endpoint,
                                              path: "/now/application.bin"))
        XCTAssertEqual(app.status, 200)
        XCTAssertEqual(app.data, Data("macbinary-app".utf8))
        XCTAssertEqual(app.contentType, "application/macbinary")

        let settings = try await fetch(endpointURL(
            endpoint, path: "/now/settings.bin"))
        XCTAssertEqual(settings.status, 200)
        let bytes = [UInt8](settings.data)
        XCTAssertEqual(String(bytes: bytes[128..<132], encoding: .ascii),
                       "NOWp")
        XCTAssertEqual(UInt16(bytes[134]) << 8 | UInt16(bytes[135]), 5_412)
        XCTAssertEqual(String(
            bytes: bytes[136..<200].prefix(while: { $0 != 0 }),
            encoding: .ascii), "127.0.0.1")
    }

    func testPortalRefusesUnknownRoutesAndMutationMethods() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let portal = OnboardingPortal(
            catalog: OnboardingAssetCatalog(
                roots: [temporary], writableRoot: temporary),
            advertisedAddress: { "127.0.0.1" })
        portal.start(wirePort: 5_250)
        let endpoint = try await runningEndpoint(portal)
        defer { portal.stop() }

        let missing = try await fetch(endpointURL(
            endpoint, path: "/now/../../etc/passwd"))
        XCTAssertEqual(missing.status, 404)

        var request = URLRequest(url: endpointURL(endpoint, path: "/now"))
        request.httpMethod = "POST"
        request.httpBody = Data("no".utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 405)
    }

    private func runningEndpoint(_ portal: OnboardingPortal) async throws
        -> OnboardingEndpoint {
        for _ in 0..<100 {
            if let endpoint = portal.endpoint { return endpoint }
            if case .failed(let message) = portal.state {
                XCTFail(message)
                throw TestError.portalFailed
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw TestError.timedOut
    }

    private func endpointURL(_ endpoint: OnboardingEndpoint, path: String)
        -> URL {
        URL(string: "http://127.0.0.1:\(endpoint.httpPort)\(path)")!
    }

    private func fetch(_ url: URL) async throws
        -> (data: Data, status: Int, contentType: String?) {
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        return (data, http.statusCode,
                http.value(forHTTPHeaderField: "Content-Type"))
    }

    private enum TestError: Error {
        case timedOut
        case portalFailed
    }
}
