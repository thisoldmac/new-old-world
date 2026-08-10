import Foundation

struct OnboardingAsset: Identifiable, Equatable {
    enum Kind: Equatable {
        case application
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
    let codeKitten: OnboardingAsset?
    let extensionComponent: OnboardingAsset?
    let dependencies: [OnboardingAsset]

    static let empty = OnboardingAssetSnapshot(
        application: nil, codeKitten: nil, extensionComponent: nil,
        dependencies: [])

    var hasCarbonLib: Bool {
        OnboardingDependencyCatalog.carbonLib.installedAsset(in: self) != nil
    }
}

/// Operator-provided packages stay outside Git. A release can carry them in
/// `Contents/Resources/Onboarding`; a local install can add or replace them
/// in Application Support without changing the signed application.
struct OnboardingAssetCatalog {
    static let environmentKey = "NOW_ONBOARDING_ASSETS"

    let roots: [URL]
    let writableRoot: URL
    var fileManager: FileManager = .default

    static func live(bundle: Bundle = .main,
                     fileManager: FileManager = .default,
                     environment: [String: String] =
                        ProcessInfo.processInfo.environment)
        -> OnboardingAssetCatalog {
        if let path = environment[environmentKey], !path.isEmpty {
            let root = URL(fileURLWithPath: path, isDirectory: true)
            return OnboardingAssetCatalog(roots: [root],
                                           writableRoot: root,
                                           fileManager: fileManager)
        }

        let support = fileManager.urls(for: .applicationSupportDirectory,
                                       in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support",
                                        isDirectory: true)
        let writable = support
            .appendingPathComponent(ProductIdentity.displayName,
                                    isDirectory: true)
            .appendingPathComponent("Onboarding", isDirectory: true)
        var roots = [writable]
        if let resources = bundle.resourceURL {
            roots.append(resources.appendingPathComponent(
                "Onboarding", isDirectory: true))
        }
        return OnboardingAssetCatalog(roots: roots,
                                       writableRoot: writable,
                                       fileManager: fileManager)
    }

    func snapshot() -> OnboardingAssetSnapshot {
        OnboardingAssetSnapshot(
            application: firstAsset(
                named: ["New Old World.bin", "now-guest-ppc.bin"],
                kind: .application),
            codeKitten: firstAsset(
                named: ["CodeKitten.bin", "codekitten.bin"],
                kind: .codeKitten),
            extensionComponent: firstAsset(
                named: ["NOW Extension.bin", "NowExt.bin"],
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
