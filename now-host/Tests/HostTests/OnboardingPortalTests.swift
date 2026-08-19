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
            setupImageBuilder: { host, port, _, _ in
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
        XCTAssertTrue(html.contains("href=\"/now/setup.img.bin\""),
                      "the recommended link carries the .bin suffix classic "
                      + "browsers map to their MacBinary decoder")
        XCTAssertTrue(html.contains("/now/settings.bin"))
        XCTAssertTrue(html.contains("CarbonLib 1.6 Installer"))
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
        XCTAssertEqual(setup.contentType, "application/macbinary",
                       "one MacBinary type on every route: the x- variant "
                       + "is a spelling some classic browsers do not know")

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
            setupImageBuilder: { _, _, assets, _ in
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
                        "CodeKitten", "NOW Extension", "CarbonLib 1.6 Installer"])

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

    func test68KFlavorServesNOW68KWithoutSettingsCodeKittenOrCarbonLib()
        async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data("macbinary-app".utf8).write(to: temporary
            .appendingPathComponent("New Old World.bin"))
        // The versioned deploy stamp is the name a lab folder actually
        // holds, so the prefix match is what this test exercises.
        try Data("macbinary-68k".utf8).write(to: temporary
            .appendingPathComponent("NOW-68K 0.6.bin"))
        try Data("macbinary-codekitten".utf8).write(to: temporary
            .appendingPathComponent("CodeKitten.bin"))
        try Data("macbinary-ext".utf8).write(to: temporary
            .appendingPathComponent("NOW Extension.bin"))

        let portal = OnboardingPortal(
            catalog: OnboardingAssetCatalog(
                roots: [temporary], writableRoot: temporary),
            setupImageBuilder: { _, _, assets, flavor in
                let payload = Data(("flavor=\(flavor.rawValue);"
                    + "app=\(assets.application(for: flavor)?.fileName ?? "none")")
                    .utf8)
                return MacBinaryEncoder.data(
                    name: "NOW-68K Setup.img", type: "dImg",
                    creator: "dCpy", dataFork: payload) ?? payload
            },
            advertisedAddress: { "127.0.0.1" })
        portal.start(wirePort: 5_412)
        let endpoint = try await runningEndpoint(portal)
        defer { portal.stop() }
        _ = try await readyImage(portal)

        portal.guestFlavor = .m68k
        XCTAssertTrue(portal.hasPendingSetupImageChanges,
                      "a flavor switch must mark the served image stale")
        let image = try await portal.rebuildSetupImage()
        XCTAssertEqual(image.fileName, "NOW-68K Setup.img")
        XCTAssertEqual(image.includedItems,
                       ["NOW-68K", "Read Me First", "NOW Extension"])

        let page = try await fetch(try XCTUnwrap(endpoint.pageURL))
        let html = try XCTUnwrap(String(data: page.data, encoding: .utf8))
        XCTAssertTrue(html.contains("NOW-68K"))
        XCTAssertTrue(html.contains("into Host and"))
        XCTAssertFalse(html.contains("/now/settings.bin"),
                       "NOW-68K ships no preferences as a product property")
        XCTAssertFalse(html.contains("/now/codekitten.bin"))
        XCTAssertFalse(html.contains("CarbonLib"))

        let app = try await fetch(endpointURL(endpoint,
                                              path: "/now/application.bin"))
        XCTAssertEqual(app.data, Data("macbinary-68k".utf8),
                       "application.bin serves the active flavor's guest")

        // The plain route serves the BARE container - the fork-blind
        // save path - while .bin keeps the typed MacBinary envelope.
        let served = try await fetch(endpointURL(
            endpoint, path: "/now/setup.img"))
        XCTAssertEqual(String(data: served.data, encoding: .utf8),
                       "flavor=m68k;app=NOW-68K 0.6.bin")
        XCTAssertEqual(served.contentType, "application/octet-stream")
        XCTAssertTrue(served.contentDisposition?.contains(
            "NOW-68K Setup.img") == true)
        let envelope = try await fetch(endpointURL(
            endpoint, path: "/now/setup.img.bin"))
        XCTAssertNotEqual(envelope.data, served.data,
                          "the envelope route keeps its 128-byte header")
        XCTAssertTrue(envelope.contentDisposition?.contains(
            "NOW-68K Setup.img.bin") == true)

        portal.guestFlavor = .powerpc
        _ = try await portal.rebuildSetupImage()
        let ppc = try await fetch(endpointURL(endpoint,
                                              path: "/now/application.bin"))
        XCTAssertEqual(ppc.data, Data("macbinary-app".utf8))
    }

    func testPreferredPortIsUsedAndFallsBackWhenHeld() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let catalog = OnboardingAssetCatalog(
            roots: [temporary], writableRoot: temporary)
        let preferred: UInt16 = 5_281

        let first = OnboardingPortal(
            catalog: catalog, preferredPort: preferred,
            advertisedAddress: { "127.0.0.1" })
        first.start(wirePort: 5_250)
        let held = try await runningEndpoint(first)
        defer { first.stop() }
        XCTAssertEqual(held.httpPort, preferred,
                       "a free preferred port is taken as-is")
        XCTAssertEqual(held.pageURL?.absoluteString,
                       "http://127.0.0.1:\(preferred)/",
                       "the advertised URL is the root - nothing to type "
                       + "after the port")

        let second = OnboardingPortal(
            catalog: catalog, preferredPort: preferred,
            advertisedAddress: { "127.0.0.1" })
        second.start(wirePort: 5_250)
        let fallback = try await runningEndpoint(second)
        defer { second.stop() }
        XCTAssertNotEqual(fallback.httpPort, preferred,
                          "a held preferred port falls back, not fails")
        let page = try await fetch(try XCTUnwrap(fallback.pageURL))
        XCTAssertEqual(page.status, 200)
    }

    /// A guest browser that aborts mid-transfer (MacWeb does, with an
    /// RST) must cost one connection, not the process: an unhandled
    /// SIGPIPE from the write loop kills the app with no crash report.
    /// Under the defect this test dies with the whole test runner.
    func testPeerAbortMidTransferDoesNotKillTheServer() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data("macbinary-app".utf8).write(to: temporary
            .appendingPathComponent("New Old World.bin"))
        let big = Data(count: 8 * 1_024 * 1_024)
        let portal = OnboardingPortal(
            catalog: OnboardingAssetCatalog(
                roots: [temporary], writableRoot: temporary),
            setupImageBuilder: { _, _, _, _ in big },
            advertisedAddress: { "127.0.0.1" })
        portal.start(wirePort: 5_250)
        let endpoint = try await runningEndpoint(portal)
        defer { portal.stop() }
        _ = try await readyImage(portal)

        // Raw socket: request the big body, read a sliver, then abort
        // with an RST (SO_LINGER 0) while megabytes are still queued.
        // OFF the main actor: XCTest async bodies run there, and the
        // server routes requests there - a blocking read here would
        // deadlock the test against the very server it exercises.
        let port = endpoint.httpPort
        let aborted = await Task.detached { () -> Bool in
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self,
                                          capacity: 1) {
                    connect(fd, $0,
                            socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else { return false }
            let request = "GET /now/setup.img HTTP/1.0\r\n\r\n"
            _ = request.withCString { Darwin.write(fd, $0, strlen($0)) }
            var sliver = [UInt8](repeating: 0, count: 1_024)
            _ = read(fd, &sliver, sliver.count)
            var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
            setsockopt(fd, SOL_SOCKET, SO_LINGER, &linger,
                       socklen_t(MemoryLayout<Darwin.linger>.size))
            return true
        }.value
        XCTAssertTrue(aborted, "the abort client could not even connect")

        // Give the write loop time to hit the dead socket, then prove
        // the server survived by fetching normally.
        try await Task.sleep(nanoseconds: 300_000_000)
        let page = try await fetch(try XCTUnwrap(endpoint.pageURL))
        XCTAssertEqual(page.status, 200)
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
