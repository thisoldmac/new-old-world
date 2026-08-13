import CryptoKit
import Foundation
import XCTest
@testable import Host

final class UpdateProviderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "now-update-provider-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testValidatedSidecarPublishesExactArtifact() throws {
        let bytes = Data("classic artifact".utf8)
        let asset = try makeAsset(name: "New Old World.bin", bytes: bytes,
                                  component: "application",
                                  build: Self.build)
        let provider = UpdateProvider(snapshot: .init(
            application: asset, codeKitten: nil,
            extensionComponent: nil, dependencies: []))

        XCTAssertEqual(provider.offers, [UpdateOffer(
            component: "application", version: "0.1.0",
            build: Self.build, bytes: bytes.count,
            sha256: Self.sha256(bytes), channel: "development",
            signed: false, requiresRestart: false)])
        XCTAssertEqual(provider.artifact(for: .init(
            id: 4, component: "application",
            build: Self.build, sha256: Self.sha256(bytes)))?.bytes,
            bytes)
    }

    func testRequestDigestMustStillNameThePublishedArtifact() throws {
        let bytes = Data("classic artifact".utf8)
        let asset = try makeAsset(name: "New Old World.bin", bytes: bytes,
                                  component: "application",
                                  build: Self.build)
        let provider = UpdateProvider(snapshot: .init(
            application: asset, codeKitten: nil,
            extensionComponent: nil, dependencies: []))

        XCTAssertNil(provider.artifact(for: .init(
            id: 4, component: "application", build: Self.build,
            sha256: String(repeating: "0", count: 64))))
    }

    func testChangedBytesFailClosedInsteadOfAdvertisingStaleIdentity()
        throws {
        let asset = try makeAsset(
            name: "NOW Extension.bin", bytes: Data("first".utf8),
            component: "extension", build: Self.build)
        try Data("tampered".utf8).write(to: asset.fileURL)

        let provider = UpdateProvider(snapshot: .init(
            application: nil, codeKitten: nil,
            extensionComponent: asset, dependencies: []))
        XCTAssertTrue(provider.offers.isEmpty)
    }

    func testBareSignedClaimFailsClosedWithoutSignatureVerification() throws {
        let asset = try makeAsset(
            name: "New Old World.bin", bytes: Data("release".utf8),
            component: "application", build: Self.build, signed: true)

        let provider = UpdateProvider(snapshot: .init(
            application: asset, codeKitten: nil,
            extensionComponent: nil, dependencies: []))
        XCTAssertTrue(provider.offers.isEmpty)
    }

    func testApplicationAvailabilityUsesVersionAndExactBuild() throws {
        let bytes = Data("application".utf8)
        let asset = try makeAsset(name: "New Old World.bin", bytes: bytes,
                                  component: "application",
                                  build: Self.build)
        let provider = UpdateProvider(snapshot: .init(
            application: asset, codeKitten: nil,
            extensionComponent: nil, dependencies: []))

        guard case .current = provider.availability(
            for: .application, installedVersion: "0.1.0",
            installedBuild: Self.build) else {
            return XCTFail("the exact build should be current")
        }
        guard case .replacement = provider.availability(
            for: .application, installedVersion: "0.1.0",
            installedBuild: String(repeating: "a", count: 64)) else {
            return XCTFail("a same-version scratch build should be replaceable")
        }
        guard case .hostOlder = provider.availability(
            for: .application, installedVersion: "0.2.0",
            installedBuild: Self.build) else {
            return XCTFail("the host must not offer a downgrade")
        }
    }

    func testExtensionAvailabilityComparesTheResidentABIPrefix() throws {
        let bytes = Data("extension".utf8)
        let asset = try makeAsset(name: "NOW Extension.bin", bytes: bytes,
                                  component: "extension",
                                  build: Self.build, version: "1.2")
        let provider = UpdateProvider(snapshot: .init(
            application: nil, codeKitten: nil,
            extensionComponent: asset, dependencies: []))

        guard case .current = provider.availability(
            for: .extensionComponent, installedVersion: "1.2",
            installedBuild: String(Self.build.prefix(40))) else {
            return XCTFail("the table's 160-bit prefix should match")
        }
        guard case .unknown = provider.availability(
            for: .extensionComponent, installedVersion: nil,
            installedBuild: nil) else {
            return XCTFail("an unreported resident must remain unknown")
        }
        guard case .replacement = provider.availability(
            for: .extensionComponent, installedVersion: "1.2",
            installedBuild: String(Self.build.prefix(12))) else {
            return XCTFail("a truncated resident identity is not proof of a match")
        }
    }

    @MainActor
    func testHostApprovalCrossesAsABooleanOnTheUpdateCommand() async throws {
        let bytes = Data("application".utf8)
        let asset = try makeAsset(name: "New Old World.bin", bytes: bytes,
                                  component: "application",
                                  build: Self.build)
        let provider = UpdateProvider(snapshot: .init(
            application: asset, codeKitten: nil,
            extensionComponent: nil, dependencies: []))
        let listener = GuestListener(
            identity: .init(version: "test", name: "Test Host"),
            timing: .init(idleTimeout: 60), updateProvider: provider)
        listener.start(port: 0)
        defer { listener.stop() }

        try await waitUntil("listener") {
            if case .listening = listener.state { return true }
            return false
        }
        let guest = FakeGuest(port: try XCTUnwrap(listener.boundPort))
        defer { guest.connection.cancel() }
        var receivedCommand: CommandRequest?
        guest.onMessage = { message in
            guard case .commandRequest(let command) = message else { return }
            receivedCommand = command
            try? guest.send(.commandResult(.init(id: command.id, ok: true)))
        }
        guest.start()
        try guest.send(.hello(.init(
            contract: Contract.revision, side: "guest", version: "0.1.0",
            build: String(repeating: "a", count: 64), name: "PowerBook",
            os: "9.1", chunk: 8192)))
        try await waitUntil("guest") { listener.activeKey != nil }

        var commandResult: CommandResult?
        listener.installUpdate(
            .application, for: try XCTUnwrap(listener.activeKey),
            installedVersion: "0.1.0",
            installedBuild: String(repeating: "a", count: 64)) {
                commandResult = $0
            }
        try await waitUntil("update command") { commandResult != nil }

        XCTAssertEqual(receivedCommand?.name, "update")
        XCTAssertEqual(receivedCommand?.args?["component"],
                       .text("application"))
        XCTAssertEqual(receivedCommand?.args?["hostApproved"], .flag(true))
        XCTAssertEqual(commandResult?.ok, true)
    }

    private func makeAsset(name: String, bytes: Data,
                           component: String, build: String,
                           version: String = "0.1.0",
                           signed: Bool = false) throws
        -> OnboardingAsset {
        let url = root.appendingPathComponent(name)
        try bytes.write(to: url)
        let manifest: [String: Any] = [
            "schema": 1, "component": component, "version": version,
            "build": build, "sha256": Self.sha256(bytes),
            "bytes": bytes.count, "channel": "development",
            "signed": signed,
        ]
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: url.appendingPathExtension("now-update.json"))
        return OnboardingAsset(
            kind: component == "application" ? .application
                                               : .extensionComponent,
            fileURL: url, byteCount: Int64(bytes.count))
    }

    private static func sha256(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    private func waitUntil(_ what: String, timeout: TimeInterval = 5,
                           _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting for \(what)")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private static let build = String(repeating: "b", count: 64)
}
