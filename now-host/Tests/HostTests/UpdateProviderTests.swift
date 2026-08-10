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

    private func makeAsset(name: String, bytes: Data,
                           component: String, build: String,
                           signed: Bool = false) throws
        -> OnboardingAsset {
        let url = root.appendingPathComponent(name)
        try bytes.write(to: url)
        let manifest: [String: Any] = [
            "schema": 1, "component": component, "version": "0.1.0",
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

    private static let build = String(repeating: "b", count: 64)
}
