import CryptoKit
import Foundation
import XCTest
@testable import Host

final class ClassicSetupImageBuilderTests: XCTestCase {
    func testBuilderMakesMountableForkPreservingSetupVolume() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let assets = temporary.appendingPathComponent(
            "assets", isDirectory: true)
        try FileManager.default.createDirectory(
            at: assets, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let applicationData = Data(repeating: 1, count: 1_180_130)
        let applicationResources = Data(repeating: 2, count: 5_287)
        try XCTUnwrap(MacBinaryEncoder.data(
            name: "New Old World", type: "APPL", creator: "NOWo",
            dataFork: applicationData,
            resourceFork: applicationResources))
            .write(to: assets.appendingPathComponent("New Old World.bin"))
        let codeKittenData = Data(repeating: 6, count: 620_000)
        let codeKittenResources = Data(repeating: 7, count: 6_888)
        try XCTUnwrap(MacBinaryEncoder.data(
            name: "codekitten", type: "APPL", creator: "O9ID",
            dataFork: codeKittenData,
            resourceFork: codeKittenResources))
            .write(to: assets.appendingPathComponent("CodeKitten.bin"))
        let extensionResources = Data(repeating: 3, count: 81_226)
        try XCTUnwrap(MacBinaryEncoder.data(
            name: "NowExt", type: "INIT", creator: "NOWx",
            dataFork: Data(), resourceFork: extensionResources))
            .write(to: assets.appendingPathComponent("NOW Extension.bin"))
        let dependencies = assets.appendingPathComponent(
            "Dependencies", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dependencies, withIntermediateDirectories: true)
        let carbonData = Data(repeating: 4, count: 3_521_726)
        let carbonResources = Data(repeating: 5, count: 602_358)
        try XCTUnwrap(MacBinaryEncoder.data(
            name: "CarbonLib", type: "INIT", creator: "cbon",
            dataFork: carbonData, resourceFork: carbonResources))
            .write(to: dependencies.appendingPathComponent("CarbonLib.bin"))
        try XCTUnwrap(MacBinaryEncoder.data(
            name: "CarbonLib_161.sit", type: "SIT5", creator: "SIT!",
            dataFork: Data([11]), resourceFork: Data()))
            .write(to: dependencies.appendingPathComponent(
                "CarbonLib_161.sit.bin"))
        let mpwData = Data(repeating: 8, count: 65_536)
        let mpwResources = Data(repeating: 9, count: 4_131)
        try XCTUnwrap(MacBinaryEncoder.data(
            name: "MPW-GM.img", type: "rohd", creator: "ddsk",
            dataFork: mpwData, resourceFork: mpwResources))
            .write(to: dependencies.appendingPathComponent("mpw-gm.img.bin"))
        let snapshot = OnboardingAssetCatalog(
            roots: [assets], writableRoot: assets).snapshot()

        let encoded = try await ClassicSetupImageBuilder().build(
            host: "10.0.2.2", wirePort: 5_432, assets: snapshot)
        let nativeImage = try MacBinaryFile.decode(encoded)
        XCTAssertEqual(nativeImage.name,
                       ClassicSetupImageBuilder.classicImageName)
        XCTAssertEqual(nativeImage.type, "rohd")
        XCTAssertEqual(nativeImage.creator, "ddsk")
        XCTAssertGreaterThan(nativeImage.dataFork.count, 5 * 1_024 * 1_024)
        XCTAssertLessThan(nativeImage.dataFork.count, 7 * 1_024 * 1_024)

        let raw = temporary.appendingPathComponent("setup.raw")
        try nativeImage.dataFork.write(to: raw)
        let mount = temporary.appendingPathComponent(
            "mount", isDirectory: true)
        // Xcode 16's diskutil requires an explicit mount point to exist;
        // newer diskutil versions create it as a convenience.
        try FileManager.default.createDirectory(
            at: mount, withIntermediateDirectories: true)
        let plist = try run("/usr/sbin/diskutil", [
            "image", "attach", "--plist", "--readOnly", "--nobrowse",
            "--mountPoint", mount.path, raw.path
        ])
        let device = try XCTUnwrap(deviceEntry(in: plist))
        defer { _ = try? run("/usr/sbin/diskutil", ["eject", device]) }

        let application = mount.appendingPathComponent("New Old World")
        XCTAssertEqual(try Data(contentsOf: application), applicationData)
        XCTAssertEqual(try resourceFork(at: application),
                       applicationResources)
        let codeKitten = mount.appendingPathComponent("CodeKitten")
        XCTAssertEqual(try Data(contentsOf: codeKitten), codeKittenData)
        XCTAssertEqual(try resourceFork(at: codeKitten),
                       codeKittenResources)
        let extensionComponent = mount.appendingPathComponent("NOW Extension")
        XCTAssertEqual(try resourceFork(at: extensionComponent),
                       extensionResources)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mount
            .appendingPathComponent("New Old World Prefs").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mount
            .appendingPathComponent("Read Me First").path))
        let carbonLib = mount.appendingPathComponent(
            "Dependencies/CarbonLib")
        XCTAssertEqual(try Data(contentsOf: carbonLib), carbonData)
        XCTAssertEqual(try resourceFork(at: carbonLib), carbonResources)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mount
            .appendingPathComponent(
                "Dependencies/CarbonLib_161.sit").path))
        // MPW rides the image as a real classic disk image, forks intact,
        // so Disk Copy on the guest can open it.
        let mpw = mount.appendingPathComponent("Dependencies/MPW-GM.img")
        XCTAssertEqual(try Data(contentsOf: mpw), mpwData)
        XCTAssertEqual(try resourceFork(at: mpw), mpwResources)
        let readMe = try String(
            data: Data(contentsOf:
                mount.appendingPathComponent("Read Me First")),
            encoding: .macOSRoman)
        XCTAssertTrue(try XCTUnwrap(readMe).contains("Register MPW Folder"))
        XCTAssertTrue(try XCTUnwrap(readMe)
            .contains("not the mounted image"),
            "the Read Me must say to register the copy on the hard disk")
        let fileSystem = try FileManager.default.attributesOfFileSystem(
            forPath: mount.path)
        let free = try XCTUnwrap(
            fileSystem[.systemFreeSize] as? NSNumber).int64Value
        XCTAssertLessThan(free, 128 * 1_024)
    }

    /// A refused starter pack must stop the build before any disk image
    /// work begins; a mismatched artifact is the cheapest such refusal.
    func testInvalidStarterPackBlocksImageProduction() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let dependencies = temporary.appendingPathComponent(
            "Dependencies", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dependencies, withIntermediateDirectories: true)
        try XCTUnwrap(MacBinaryEncoder.data(
            name: "New Old World", type: "APPL", creator: "NOWo",
            dataFork: Data([1]), resourceFork: Data()))
            .write(to: temporary.appendingPathComponent("New Old World.bin"))
        let declared = try XCTUnwrap(MacBinaryEncoder.data(
            name: "Development Starter Pack.img", type: "rohd",
            creator: "ddsk", dataFork: Data([2])))
        try starterPackManifest(artifact: "Development Starter Pack.img.bin",
                                payload: declared)
            .write(to: dependencies.appendingPathComponent(
                "Development Starter Pack.manifest.json"))
        try (declared + Data([0])).write(to: dependencies
            .appendingPathComponent("Development Starter Pack.img.bin"))
        let snapshot = OnboardingAssetCatalog(
            roots: [temporary], writableRoot: temporary).snapshot()

        do {
            _ = try await ClassicSetupImageBuilder().build(
                host: "10.0.2.2", wirePort: 5_432, assets: snapshot)
            XCTFail("a mismatched starter pack produced a setup image")
        } catch let error as ClassicSetupImageBuilder.BuildError {
            guard case .invalidStarterPack = error else {
                XCTFail("unexpected refusal: \(error)")
                return
            }
        }
    }

    private func starterPackManifest(artifact: String,
                                     payload: Data) throws -> Data {
        let digest = SHA256.hash(data: payload).map {
            String(format: "%02x", $0)
        }.joined()
        return try JSONEncoder().encode(DevelopmentStarterPackManifest(
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
                qualification: .init(
                    requiredItems: ["ToolServer", "Tools:MrC"],
                    probe: "structural-1"))]))
    }

    private func resourceFork(at url: URL) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath:
            url.path + "/..namedfork/rsrc"))
    }

    private func deviceEntry(in plist: Data) -> String? {
        guard let root = try? PropertyListSerialization.propertyList(
            from: plist, options: [], format: nil) as? [String: Any],
              let entities = root["system-entities"] as? [[String: Any]]
        else { return nil }
        return entities.compactMap { $0["dev-entry"] as? String }.first
    }

    @discardableResult
    private func run(_ executable: String, _ arguments: [String]) throws
        -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw TestError.command(String(data: stderr, encoding: .utf8)
                ?? executable)
        }
        return stdout
    }

    private enum TestError: Error {
        case command(String)
    }
}
