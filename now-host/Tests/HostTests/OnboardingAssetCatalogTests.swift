import CryptoKit
import XCTest
@testable import Host

final class OnboardingAssetCatalogTests: XCTestCase {
    func testDeclaredRootOrderSelectsComponentsAndDeduplicatesDependencies()
        throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let writable = temporary.appendingPathComponent("User",
                                                         isDirectory: true)
        let bundled = temporary.appendingPathComponent("Bundle",
                                                        isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try makeDirectory(writable.appendingPathComponent(
            "Dependencies", isDirectory: true))
        try makeDirectory(bundled.appendingPathComponent(
            "Dependencies", isDirectory: true))

        try Data("user-app".utf8).write(to: writable
            .appendingPathComponent("New Old World.bin"))
        try Data("bundled-app".utf8).write(to: bundled
            .appendingPathComponent("New Old World.bin"))
        try Data("codekitten".utf8).write(to: bundled
            .appendingPathComponent("codekitten.bin"))
        try Data("extension".utf8).write(to: bundled
            .appendingPathComponent("NOW Extension.bin"))
        try Data("carbon-user".utf8).write(to: writable
            .appendingPathComponent("Dependencies/CarbonLib 1.6.smi.bin"))
        try Data("carbon-bundle".utf8).write(to: bundled
            .appendingPathComponent("Dependencies/CarbonLib 1.6.smi.bin"))
        try Data("expander".utf8).write(to: bundled
            .appendingPathComponent("Dependencies/StuffIt Expander.bin"))

        let catalog = OnboardingAssetCatalog(
            roots: [writable, bundled], writableRoot: writable)
        let snapshot = catalog.snapshot()

        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(
            snapshot.application?.fileURL)), Data("user-app".utf8))
        XCTAssertEqual(snapshot.codeKitten?.fileName, "CodeKitten.bin")
        XCTAssertEqual(snapshot.codeKitten?.kind, .codeKitten)
        XCTAssertEqual(snapshot.extensionComponent?.fileName,
                       "NOW Extension.bin")
        XCTAssertEqual(snapshot.dependencies.map(\.fileName),
                       ["CarbonLib 1.6.smi.bin", "StuffIt Expander.bin"])
        XCTAssertTrue(snapshot.hasCarbonLib)
    }

    func testLiveCatalogUsesBundledComponentsAsReleaseBaseline() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let bundleRoot = temporary.appendingPathComponent(
            "New Old World.app", isDirectory: true)
        let contents = bundleRoot.appendingPathComponent(
            "Contents", isDirectory: true)
        let bundled = contents.appendingPathComponent(
            "Resources/Onboarding", isDirectory: true)
        let applicationSupport = temporary.appendingPathComponent(
            "Application Support", isDirectory: true)
        let writable = applicationSupport
            .appendingPathComponent("New Old World/Onboarding",
                                    isDirectory: true)
        try makeDirectory(bundled.appendingPathComponent(
            "Dependencies", isDirectory: true))
        try makeDirectory(writable.appendingPathComponent(
            "Dependencies", isDirectory: true))
        try Data(Self.bundleInfoPlist.utf8).write(to: contents
            .appendingPathComponent("Info.plist"))

        let bundledBuild = String(repeating: "b", count: 64)
        try writeUpdateArtifact(Data("bundled-app".utf8),
                                to: bundled.appendingPathComponent(
                                    "New Old World.bin"),
                                build: bundledBuild)
        try writeUpdateArtifact(Data("writable-app".utf8),
                                to: writable.appendingPathComponent(
                                    "New Old World.bin"),
                                build: String(repeating: "a", count: 64))
        try Data("bundled-extension".utf8).write(to: bundled
            .appendingPathComponent("NOW Extension.bin"))
        try Data("writable-extension".utf8).write(to: writable
            .appendingPathComponent("NOW Extension.bin"))
        try Data("bundled-carbon".utf8).write(to: bundled
            .appendingPathComponent("Dependencies/CarbonLib.bin"))
        try Data("writable-carbon".utf8).write(to: writable
            .appendingPathComponent("Dependencies/CarbonLib.bin"))
        try Data("operator-extra".utf8).write(to: writable
            .appendingPathComponent("Dependencies/Operator Extra.bin"))

        let bundle = try XCTUnwrap(Bundle(url: bundleRoot))
        let catalog = OnboardingAssetCatalog.live(
            bundle: bundle, environment: [:],
            applicationSupportDirectory: applicationSupport)
        let snapshot = catalog.snapshot()

        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(
            snapshot.application?.fileURL)), Data("bundled-app".utf8))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(
            snapshot.extensionComponent?.fileURL)),
            Data("bundled-extension".utf8))
        XCTAssertEqual(snapshot.dependencies.map(\.fileName),
                       ["CarbonLib.bin", "Operator Extra.bin"])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(
            snapshot.dependencies.first?.fileURL)),
            Data("bundled-carbon".utf8))
        XCTAssertEqual(UpdateProvider(snapshot: snapshot)
            .artifacts[.application]?.manifest.build, bundledBuild)
    }

    func testEnvironmentRootRemainsAnExplicitWholeCatalogOverride() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try makeDirectory(temporary)
        try Data("override-app".utf8).write(to: temporary
            .appendingPathComponent("New Old World.bin"))

        let catalog = OnboardingAssetCatalog.live(
            environment: [OnboardingAssetCatalog.environmentKey:
                            temporary.path])

        XCTAssertEqual(catalog.roots, [temporary])
        XCTAssertEqual(catalog.writableRoot, temporary)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(
            catalog.snapshot().application?.fileURL)),
            Data("override-app".utf8))
    }

    func testLegacyAbbreviatedExtensionNameIsNotAPackageAsset() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try makeDirectory(temporary)
        try Data("legacy-extension".utf8).write(to: temporary
            .appendingPathComponent("NowExt.bin"))

        let catalog = OnboardingAssetCatalog(
            roots: [temporary], writableRoot: temporary)

        XCTAssertNil(catalog.snapshot().extensionComponent)
    }

    func testPreparingTheOperatorStoreAlsoCreatesDependenciesFolder()
        throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let catalog = OnboardingAssetCatalog(
            roots: [temporary], writableRoot: temporary)

        XCTAssertEqual(try catalog.prepareWritableRoot(), temporary)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: temporary.appendingPathComponent("Dependencies").path,
            isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testStarterPackManifestBindsRelocatableArtifact() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let dependencies = temporary.appendingPathComponent(
            "Dependencies", isDirectory: true)
        try makeDirectory(dependencies)
        let payload = Data("portable-hfs-image".utf8)
        let artifact = dependencies.appendingPathComponent(
            "Development Starter Pack.img.bin")
        try payload.write(to: artifact)
        try writeStarterPackManifest(
            in: dependencies, artifact: artifact.lastPathComponent,
            payload: payload)
        let snapshot = OnboardingAssetCatalog(
            roots: [temporary], writableRoot: temporary).snapshot()
        let validated = try DevelopmentStarterPackManifest.validated(
            in: snapshot)
        XCTAssertEqual(validated?.components.first?.qualification.probe,
                       "structural-1")

        try Data("changed".utf8).write(to: artifact)
        let changed = OnboardingAssetCatalog(
            roots: [temporary], writableRoot: temporary).snapshot()
        XCTAssertThrowsError(try DevelopmentStarterPackManifest.validated(
            in: changed))
    }

    /// The manifest may only promise a qualification the guest performs:
    /// an unimplemented probe name, or item claims the named probe never
    /// measures, are refused even when the artifact digest matches.
    func testStarterPackManifestRefusesUnimplementedQualification() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let dependencies = temporary.appendingPathComponent(
            "Dependencies", isDirectory: true)
        try makeDirectory(dependencies)
        let payload = Data("portable-hfs-image".utf8)
        let artifact = dependencies.appendingPathComponent(
            "Development Starter Pack.img.bin")
        try payload.write(to: artifact)

        try writeStarterPackManifest(
            in: dependencies, artifact: artifact.lastPathComponent,
            payload: payload,
            qualification: .init(
                requiredItems: ["MPW Shell", "ToolServer",
                                "Interfaces&Libraries", "Tools"],
                probe: "mpw-toolserver-compile-link-launch-v1"))
        XCTAssertThrowsError(try DevelopmentStarterPackManifest.validated(
            in: OnboardingAssetCatalog(roots: [temporary],
                                       writableRoot: temporary).snapshot()))

        try writeStarterPackManifest(
            in: dependencies, artifact: artifact.lastPathComponent,
            payload: payload,
            qualification: .init(
                requiredItems: ["ToolServer", "Tools:MrC", "MPW Shell"],
                probe: "structural-1"))
        XCTAssertThrowsError(try DevelopmentStarterPackManifest.validated(
            in: OnboardingAssetCatalog(roots: [temporary],
                                       writableRoot: temporary).snapshot()))
    }

    /// The checked-in packaging template must promise only the probe the
    /// guest implements, and must stay unshippable (zero digest) so nobody
    /// can pass validation without an operator-measured artifact.
    func testCheckedInStarterPackTemplateMatchesImplementedProbe() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let template = repository.appendingPathComponent(
            "packaging/development-starter-pack/"
                + "Development Starter Pack.manifest.json")
        let manifest = try JSONDecoder().decode(
            DevelopmentStarterPackManifest.self,
            from: Data(contentsOf: template))
        XCTAssertEqual(manifest.schema, "now.development-starter-pack/1")
        XCTAssertFalse(manifest.components.isEmpty)
        for component in manifest.components {
            XCTAssertEqual(
                Set(component.qualification.requiredItems),
                DevelopmentStarterPackManifest.implementedProbes[
                    component.qualification.probe],
                "template promises a qualification the guest does not run")
            XCTAssertEqual(component.license.redistribution, "unknown")
        }
        XCTAssertEqual(manifest.artifactSHA256,
                       String(repeating: "0", count: 64))
        XCTAssertEqual(manifest.artifactBytes, 0)
    }

    private func writeStarterPackManifest(
        in dependencies: URL, artifact: String, payload: Data,
        qualification: DevelopmentStarterPackManifest.Component.Qualification
            = .init(requiredItems: ["ToolServer", "Tools:MrC"],
                    probe: "structural-1")) throws {
        let digest = SHA256.hash(data: payload).map {
            String(format: "%02x", $0)
        }.joined()
        let manifest = DevelopmentStarterPackManifest(
            schema: "now.development-starter-pack/1",
            id: "classic-mac-development-starter", version: "1.1.0",
            artifact: artifact,
            artifactBytes: payload.count, artifactSHA256: digest,
            platforms: [.init(
                operatingSystem: "classic-mac-os", minimumVersion: "8.6",
                maximumVersion: "9.2.2", architectures: ["powerpc"])],
            components: [.init(
                id: "apple-mpw-gm", version: "3.5-gm", purpose: "build",
                installBytes: 1,
                license: .init(name: "operator supplied",
                               redistribution: "unknown",
                               provenanceURL: "https://example.invalid/license"),
                qualification: qualification)])
        try JSONEncoder().encode(manifest).write(to: dependencies
            .appendingPathComponent("Development Starter Pack.manifest.json"))
    }

    private func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
    }

    private func writeUpdateArtifact(_ data: Data, to url: URL,
                                     build: String) throws {
        try data.write(to: url)
        let manifest: [String: Any] = [
            "schema": 1, "component": "application", "version": "0.2.0",
            "build": build,
            "sha256": SHA256.hash(data: data).map {
                String(format: "%02x", $0)
            }.joined(),
            "bytes": data.count, "channel": "development", "signed": false,
            "compatibility": [
                "continuityWire": ContinuityContract.version,
                "continuityTable": ContinuityContract.residentTableVersion,
                "resident": ContinuityContract.residentVersion,
            ],
        ]
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: url.appendingPathExtension("now-update.json"))
    }

    private static let bundleInfoPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
          "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>CFBundleIdentifier</key>
          <string>org.newoldworld.catalog-test</string>
          <key>CFBundleName</key>
          <string>New Old World</string>
          <key>CFBundlePackageType</key>
          <string>APPL</string>
        </dict>
        </plist>
        """
}
