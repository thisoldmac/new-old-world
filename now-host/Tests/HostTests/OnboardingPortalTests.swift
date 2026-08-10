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
        try Data("macbinary-codekitten".utf8).write(to: temporary
            .appendingPathComponent("CodeKitten.bin"))

        let portal = OnboardingPortal(
            catalog: OnboardingAssetCatalog(
                roots: [temporary], writableRoot: temporary),
            setupImageBuilder: { host, port, _ in
                Data("setup-\(host)-\(port)".utf8)
            },
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
        XCTAssertTrue(html.contains("/now/codekitten.bin"))
        XCTAssertTrue(html.contains("href=\"/now/setup.img\""))
        XCTAssertTrue(html.contains("/now/setup.img.bin"))
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

        let codeKitten = try await fetch(endpointURL(
            endpoint, path: "/now/codekitten.bin"))
        XCTAssertEqual(codeKitten.status, 200)
        XCTAssertEqual(codeKitten.data, Data("macbinary-codekitten".utf8))
        XCTAssertEqual(codeKitten.contentType, "application/macbinary")

        let setup = try await fetch(endpointURL(
            endpoint, path: "/now/setup.img"))
        XCTAssertEqual(setup.status, 200)
        XCTAssertEqual(setup.data, Data("setup-127.0.0.1-5412".utf8))
        XCTAssertEqual(setup.contentType, "application/x-macbinary")
        XCTAssertNil(setup.contentDisposition)

        let setupEnvelope = try await fetch(endpointURL(
            endpoint, path: "/now/setup.img.bin"))
        XCTAssertEqual(setupEnvelope.status, 200)
        XCTAssertEqual(setupEnvelope.data,
                       Data("setup-127.0.0.1-5412".utf8))
        XCTAssertEqual(setupEnvelope.contentType, "application/macbinary")
        XCTAssertTrue(setupEnvelope.contentDisposition?.contains(
            "New Old World Setup.img.bin") == true)

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

    func testSelectionsRebuildAndDescribeTheImageActuallyBeingServed()
        async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dependencies = temporary.appendingPathComponent(
            "Dependencies", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dependencies, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data("app".utf8).write(to: temporary
            .appendingPathComponent("New Old World.bin"))
        try Data("codekitten".utf8).write(to: temporary
            .appendingPathComponent("CodeKitten.bin"))
        try Data("ext".utf8).write(to: temporary
            .appendingPathComponent("NOW Extension.bin"))
        try Data("carbon".utf8).write(to: dependencies
            .appendingPathComponent("CarbonLib.bin"))

        let portal = OnboardingPortal(
            catalog: OnboardingAssetCatalog(
                roots: [temporary], writableRoot: temporary),
            setupImageBuilder: { _, _, assets in
                Data(("codekitten=\(assets.codeKitten != nil);"
                     + "extension=\(assets.extensionComponent != nil);"
                     + "dependencies=\(assets.dependencies.count)").utf8)
            },
            advertisedAddress: { "127.0.0.1" })
        portal.start(wirePort: 5_250)
        let endpoint = try await runningEndpoint(portal)
        defer { portal.stop() }
        let first = try await readyImage(portal)
        XCTAssertEqual(first.includedItems,
                       ["New Old World", "Host settings", "Read Me First",
                        "CodeKitten", "NOW Extension", "CarbonLib 1.6.1"])

        let codeKitten = try XCTUnwrap(portal.assets.codeKitten)
        let extensionComponent = try XCTUnwrap(
            portal.assets.extensionComponent)
        let carbonLib = try XCTUnwrap(
            OnboardingDependencyCatalog.carbonLib.installedAsset(
                in: portal.assets))
        portal.setSelected(false, asset: codeKitten)
        portal.setSelected(false, asset: extensionComponent)
        portal.setSelected(false, asset: carbonLib)
        XCTAssertTrue(portal.hasPendingSetupImageChanges)
        _ = try await portal.rebuildSetupImage()
        XCTAssertFalse(portal.hasPendingSetupImageChanges)

        let download = try await fetch(endpointURL(
            endpoint, path: "/now/setup.img"))
        XCTAssertEqual(String(data: download.data, encoding: .utf8),
                       "codekitten=false;extension=false;dependencies=0")
        guard case .ready(let rebuilt) = portal.setupImageState else {
            return XCTFail("the rebuilt image was not published")
        }
        XCTAssertEqual(rebuilt.includedItems,
                       ["New Old World", "Host settings", "Read Me First"])
        XCTAssertEqual(rebuilt.transferByteCount,
                       Int64(download.data.count))

        let page = try await fetch(try XCTUnwrap(endpoint.pageURL))
        let html = try XCTUnwrap(String(data: page.data, encoding: .utf8))
        XCTAssertTrue(html.contains("Served image:"))
        XCTAssertTrue(html.contains("New Old World, Host settings, Read Me First"))
        XCTAssertFalse(html.contains("Contains:</b> NOW Extension"))
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

    private func readyImage(_ portal: OnboardingPortal) async throws
        -> OnboardingSetupImage {
        for _ in 0..<100 {
            if case .ready(let image) = portal.setupImageState { return image }
            if case .failed(let message) = portal.setupImageState {
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
        -> (data: Data, status: Int, contentType: String?,
            contentDisposition: String?) {
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        return (data, http.statusCode,
                http.value(forHTTPHeaderField: "Content-Type"),
                http.value(forHTTPHeaderField: "Content-Disposition"))
    }

    private enum TestError: Error {
        case timedOut
        case portalFailed
    }
}
