import CryptoKit
import Foundation

/// Which classic Mac the onboarding surface is serving. The PPC flavor is
/// the Carbon application with its CarbonLib dependency and companions; the
/// 68K flavor is NOW-68K alone plus the extension, which is 68K by nature.
/// CodeKitten and CarbonLib are Carbon and have no 68K meaning, and NOW-68K
/// ships no preferences as a product property (n68_devsettings.h), so the
/// 68K flavor offers no settings download either.
enum OnboardingGuestFlavor: String, CaseIterable, Identifiable {
    case powerpc
    case m68k

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .powerpc: return "PowerPC"
        case .m68k: return "68K"
        }
    }

    var applicationDisplayName: String {
        switch self {
        case .powerpc: return "New Old World"
        case .m68k: return "NOW-68K"
        }
    }
}

struct OnboardingAsset: Identifiable, Equatable {
    enum Kind: Equatable {
        case application
        case application68K
        case codeKitten
        case extensionComponent
        case dependency
    }

    let kind: Kind
    let fileURL: URL
    let byteCount: Int64

    var id: String { fileURL.standardizedFileURL.path }
    var fileName: String { fileURL.lastPathComponent }
}

struct OnboardingAssetSnapshot: Equatable {
    let application: OnboardingAsset?
    let application68K: OnboardingAsset?
    let codeKitten: OnboardingAsset?
    let extensionComponent: OnboardingAsset?
    let dependencies: [OnboardingAsset]

    init(application: OnboardingAsset?,
         application68K: OnboardingAsset? = nil,
         codeKitten: OnboardingAsset?,
         extensionComponent: OnboardingAsset?,
         dependencies: [OnboardingAsset]) {
        self.application = application
        self.application68K = application68K
        self.codeKitten = codeKitten
        self.extensionComponent = extensionComponent
        self.dependencies = dependencies
    }

    static let empty = OnboardingAssetSnapshot(
        application: nil, application68K: nil, codeKitten: nil,
        extensionComponent: nil, dependencies: [])

    func application(for flavor: OnboardingGuestFlavor) -> OnboardingAsset? {
        switch flavor {
        case .powerpc: return application
        case .m68k: return application68K
        }
    }

    var hasCarbonLib: Bool {
        OnboardingDependencyCatalog.carbonLib.installedAsset(in: self) != nil
    }
}

/// Operator-provided packages stay outside Git. A release can carry them in
/// `Contents/Resources/Onboarding`; Application Support augments that catalog
/// without silently replacing the signed release's guest components. The
/// environment override remains the explicit development escape hatch.
struct OnboardingAssetCatalog {
    static let environmentKey = "NOW_ONBOARDING_ASSETS"

    let roots: [URL]
    let writableRoot: URL
    var fileManager: FileManager = .default

    static func live(bundle: Bundle = .main,
                     fileManager: FileManager = .default,
                     environment: [String: String] =
                        ProcessInfo.processInfo.environment,
                     applicationSupportDirectory: URL? = nil)
        -> OnboardingAssetCatalog {
        if let path = environment[environmentKey], !path.isEmpty {
            let root = URL(fileURLWithPath: path, isDirectory: true)
            return OnboardingAssetCatalog(roots: [root],
                                           writableRoot: root,
                                           fileManager: fileManager)
        }

        let support = applicationSupportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory,
                                in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support",
                                        isDirectory: true)
        let writable = support
            .appendingPathComponent(ProductIdentity.displayName,
                                    isDirectory: true)
            .appendingPathComponent("Onboarding", isDirectory: true)
        var roots: [URL] = []
        if let resources = bundle.resourceURL {
            roots.append(resources.appendingPathComponent(
                "Onboarding", isDirectory: true))
        }
        roots.append(writable)
        return OnboardingAssetCatalog(roots: roots,
                                       writableRoot: writable,
                                       fileManager: fileManager)
    }

    func snapshot() -> OnboardingAssetSnapshot {
        OnboardingAssetSnapshot(
            application: firstAsset(
                named: ["New Old World.bin", "now-guest-ppc.bin"],
                kind: .application),
            // deploy-68k stamps versioned names ("NOW-68K 0.6.bin"), so the
            // 68K application also matches by prefix where the PPC one is
            // exact - the build-tree name stays accepted beside it.
            application68K: firstAsset(
                named: ["NOW-68K.bin", "now-guest-68k.bin"],
                kind: .application68K)
                ?? prefixedAsset(prefix: "NOW-68K ", suffix: ".bin",
                                 kind: .application68K),
            codeKitten: firstAsset(
                named: ["CodeKitten.bin", "codekitten.bin"],
                kind: .codeKitten),
            extensionComponent: firstAsset(
                named: ["NOW Extension.bin"],
                kind: .extensionComponent),
            dependencies: dependencyAssets())
    }

    @discardableResult
    func prepareWritableRoot() throws -> URL {
        try fileManager.createDirectory(at: writableRoot,
                                        withIntermediateDirectories: true)
        let dependencies = writableRoot.appendingPathComponent(
            "Dependencies", isDirectory: true)
        try fileManager.createDirectory(at: dependencies,
                                        withIntermediateDirectories: true)
        return writableRoot
    }

    @discardableResult
    func prepareDependenciesRoot() throws -> URL {
        try prepareWritableRoot()
        return writableRoot.appendingPathComponent(
            "Dependencies", isDirectory: true)
    }

    private func firstAsset(named candidates: [String],
                            kind: OnboardingAsset.Kind)
        -> OnboardingAsset? {
        for root in roots {
            for name in candidates {
                if let asset = asset(at: root.appendingPathComponent(name),
                                     kind: kind) {
                    return asset
                }
            }
        }
        return nil
    }

    private func prefixedAsset(prefix: String, suffix: String,
                               kind: OnboardingAsset.Kind)
        -> OnboardingAsset? {
        for root in roots {
            let urls = (try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey,
                                             .fileSizeKey],
                options: [.skipsHiddenFiles])) ?? []
            let match = urls.filter {
                $0.lastPathComponent.hasPrefix(prefix)
                    && $0.lastPathComponent.hasSuffix(suffix)
            }.sorted {
                // Highest version first, so a folder holding several
                // deploys offers the newest.
                $0.lastPathComponent.localizedStandardCompare(
                    $1.lastPathComponent) == .orderedDescending
            }.first
            if let match, let asset = asset(at: match, kind: kind) {
                return asset
            }
        }
        return nil
    }

    private func dependencyAssets() -> [OnboardingAsset] {
        var seen = Set<String>()
        var result: [OnboardingAsset] = []
        for root in roots {
            let directory = root.appendingPathComponent(
                "Dependencies", isDirectory: true)
            let urls = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey,
                                             .fileSizeKey],
                options: [.skipsHiddenFiles])) ?? []
            for url in urls.sorted(by: {
                $0.lastPathComponent.localizedStandardCompare(
                    $1.lastPathComponent) == .orderedAscending
            }) {
                let key = url.lastPathComponent.lowercased()
                guard !seen.contains(key),
                      !OnboardingDependencyCatalog.retiredFileNames
                          .contains(key),
                      let asset = asset(at: url, kind: .dependency)
                else { continue }
                seen.insert(key)
                result.append(asset)
            }
        }
        return result
    }

    private func asset(at url: URL, kind: OnboardingAsset.Kind)
        -> OnboardingAsset? {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else { return nil }
        return OnboardingAsset(kind: kind, fileURL: url,
                               byteCount: Int64(values.fileSize ?? 0))
    }
}

struct DevelopmentStarterPackManifest: Codable, Equatable {
    struct Platform: Codable, Equatable {
        let operatingSystem: String
        let minimumVersion: String
        let maximumVersion: String
        let architectures: [String]
    }

    struct Component: Codable, Equatable {
        struct License: Codable, Equatable {
            let name: String
            let redistribution: String
            let provenanceURL: String
        }
        struct Qualification: Codable, Equatable {
            let requiredItems: [String]
            let probe: String
        }
        let id: String
        let version: String
        let purpose: String
        let installBytes: Int
        let license: License
        let qualification: Qualification
    }

    let schema: String
    let id: String
    let version: String
    let artifact: String
    let artifactBytes: Int
    let artifactSHA256: String
    let platforms: [Platform]
    let components: [Component]

    static func validate(in snapshot: OnboardingAssetSnapshot) throws {
        let manifests = snapshot.dependencies.filter {
            let name = $0.fileName.lowercased()
            return name.hasSuffix("starter-pack.manifest.json")
                || name.hasSuffix("starter pack.manifest.json")
        }
        guard manifests.count <= 1 else {
            throw ClassicSetupImageBuilder.BuildError.invalidStarterPack(
                "More than one starter-pack manifest is installed.")
        }
        guard let asset = manifests.first else { return }
        let manifest = try JSONDecoder().decode(
            Self.self, from: Data(contentsOf: asset.fileURL))
        guard manifest.schema == "now.development-starter-pack/1",
              !manifest.id.isEmpty, !manifest.version.isEmpty,
              !manifest.platforms.isEmpty, !manifest.components.isEmpty,
              URL(fileURLWithPath: manifest.artifact).lastPathComponent
                == manifest.artifact,
              manifest.artifactSHA256.count == 64,
              manifest.artifactSHA256.allSatisfy({
                  $0.isHexDigit && !$0.isUppercase
              }),
              manifest.components.allSatisfy({
                  !$0.id.isEmpty && !$0.version.isEmpty
                    && $0.installBytes > 0
                    && !$0.license.name.isEmpty
                    && ["allowed", "forbidden", "unknown"]
                        .contains($0.license.redistribution)
                    && URL(string: $0.license.provenanceURL)?.scheme != nil
                    && !$0.qualification.requiredItems.isEmpty
                    && !$0.qualification.probe.isEmpty
              }),
              let payload = snapshot.dependencies.first(where: {
                  $0.fileName == manifest.artifact
              }) else {
            throw ClassicSetupImageBuilder.BuildError.invalidStarterPack(
                "The starter-pack manifest is malformed or its artifact is absent.")
        }
        let bytes = try Data(contentsOf: payload.fileURL,
                             options: [.mappedIfSafe])
        let digest = SHA256.hash(data: bytes).map {
            String(format: "%02x", $0)
        }.joined()
        guard bytes.count == manifest.artifactBytes,
              digest == manifest.artifactSHA256 else {
            throw ClassicSetupImageBuilder.BuildError.invalidStarterPack(
                "The starter-pack artifact does not match its manifest.")
        }
    }
}
