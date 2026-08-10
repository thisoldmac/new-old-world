import CryptoKit
import Foundation

/// The host owns publication; the guest owns whether and when to install.
/// Only artifacts with a generated, self-consistent sidecar enter this
/// catalog. Onboarding remains intentionally looser so a person can still
/// fetch an older hand-built package through the browser portal.
struct UpdateProvider {
    enum Component: String, Codable, CaseIterable, Sendable {
        case application
        case extensionComponent = "extension"
    }

    struct Manifest: Codable, Equatable, Sendable {
        let schema: Int
        let component: Component
        let version: String
        let build: String
        let sha256: String
        let bytes: Int
        let channel: String
        let signed: Bool
    }

    struct Artifact {
        let manifest: Manifest
        let url: URL
        let bytes: Data
        let crc32: UInt32

        var offer: UpdateOffer {
            UpdateOffer(
                component: manifest.component.rawValue,
                version: manifest.version,
                build: manifest.build,
                bytes: manifest.bytes,
                sha256: manifest.sha256,
                channel: manifest.channel,
                signed: manifest.signed,
                requiresRestart: manifest.component == .extensionComponent)
        }
    }

    let artifacts: [Component: Artifact]

    static func live(catalog: OnboardingAssetCatalog = .live())
        -> UpdateProvider {
        UpdateProvider(snapshot: catalog.snapshot())
    }

    init(snapshot: OnboardingAssetSnapshot) {
        var found: [Component: Artifact] = [:]
        for (component, asset) in [
            (Component.application, snapshot.application),
            (.extensionComponent, snapshot.extensionComponent),
        ] {
            guard let asset,
                  let artifact = Self.load(asset: asset,
                                           expected: component)
            else { continue }
            found[component] = artifact
        }
        artifacts = found
    }

    var offers: [UpdateOffer] {
        Component.allCases.compactMap { artifacts[$0]?.offer }
    }

    func artifact(for request: UpdateRequest) -> Artifact? {
        guard let component = Component(rawValue: request.component),
              let artifact = artifacts[component],
              artifact.manifest.build == request.build,
              artifact.manifest.sha256.lowercased()
                == request.sha256.lowercased() else { return nil }
        return artifact
    }

    private static func load(asset: OnboardingAsset,
                             expected: Component) -> Artifact? {
        let sidecar = asset.fileURL.appendingPathExtension("now-update.json")
        guard let manifestData = try? Data(contentsOf: sidecar),
              let manifest = try? JSONDecoder().decode(
                Manifest.self, from: manifestData),
              manifest.schema == 1,
              manifest.component == expected,
              !manifest.signed,
              Int64(manifest.bytes) == asset.byteCount,
              manifest.sha256.range(
                of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              manifest.build.range(
                of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              let bytes = try? Data(contentsOf: asset.fileURL),
              bytes.count == manifest.bytes,
              hex(SHA256.hash(data: bytes)) == manifest.sha256.lowercased()
        else { return nil }
        return Artifact(manifest: manifest, url: asset.fileURL,
                        bytes: bytes, crc32: TransferIdentity.crc32(bytes))
    }

    private static func hex<D: Sequence>(_ digest: D) -> String
        where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
