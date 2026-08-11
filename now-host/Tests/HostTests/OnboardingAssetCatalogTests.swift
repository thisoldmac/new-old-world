import CryptoKit
import XCTest
@testable import Host

final class OnboardingAssetCatalogTests: XCTestCase {
    func testWritablePackagesOverrideBundledOnesAndAugmentDependencies()
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
        let digest = SHA256.hash(data: payload).map {
            String(format: "%02x", $0)
        }.joined()
        let manifest = DevelopmentStarterPackManifest(
            schema: "now.development-starter-pack/1",
            id: "classic-mac-development-starter", version: "1.0.0",
            artifact: artifact.lastPathComponent,
            artifactBytes: payload.count, artifactSHA256: digest,
            platforms: [.init(
                operatingSystem: "classic-mac-os", minimumVersion: "7.1",
                maximumVersion: "9.2.2", architectures: ["m68k", "powerpc"])],
            components: [.init(
                id: "apple-mpw-gm", version: "3.5-gm", purpose: "build",
                installBytes: 1,
                license: .init(name: "operator supplied",
                               redistribution: "unknown",
                               provenanceURL: "https://example.invalid/license"),
                qualification: .init(requiredItems: ["ToolServer"],
                                     probe: "mpw-v1"))])
        try JSONEncoder().encode(manifest).write(to: dependencies
            .appendingPathComponent("Development Starter Pack.manifest.json"))
        let snapshot = OnboardingAssetCatalog(
            roots: [temporary], writableRoot: temporary).snapshot()
        XCTAssertNoThrow(try DevelopmentStarterPackManifest.validate(in: snapshot))

        try Data("changed".utf8).write(to: artifact)
        let changed = OnboardingAssetCatalog(
            roots: [temporary], writableRoot: temporary).snapshot()
        XCTAssertThrowsError(try DevelopmentStarterPackManifest.validate(
            in: changed))
    }

    private func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
    }
}
