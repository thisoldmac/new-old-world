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
        let fileSystem = try FileManager.default.attributesOfFileSystem(
            forPath: mount.path)
        let free = try XCTUnwrap(
            fileSystem[.systemFreeSize] as? NSNumber).int64Value
        XCTAssertLessThan(free, 128 * 1_024)
    }

    func testSmallPayloadStillMakesAFormattableMinimumVolume()
        async throws {
        // A 68K-flavor payload is small enough that the fitting pass wants
        // a volume below newfs_hfs's 512 KB minimum; the floor must hold on
        // the shrink path, not only on the first estimate.
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let assets = temporary.appendingPathComponent(
            "assets", isDirectory: true)
        try FileManager.default.createDirectory(
            at: assets, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let applicationResources = Data(repeating: 9, count: 250_000)
        try XCTUnwrap(MacBinaryEncoder.data(
            name: "NOW-68K 0.7", type: "APPL", creator: "NOWo",
            dataFork: Data(repeating: 8, count: 21_000),
            resourceFork: applicationResources))
            .write(to: assets.appendingPathComponent("NOW-68K 0.7.bin"))
        try FileManager.default.createDirectory(
            at: assets.appendingPathComponent(
                "Dependencies", isDirectory: true),
            withIntermediateDirectories: true)
        let snapshot = OnboardingAssetCatalog(
            roots: [assets], writableRoot: assets).snapshot()
        XCTAssertNil(snapshot.extensionComponent,
                     "no extension fixture was written")
        XCTAssertEqual(snapshot.application68K?.fileName, "NOW-68K 0.7.bin")

        let encoded = try await ClassicSetupImageBuilder().build(
            host: "10.0.2.2", wirePort: 5_432, assets: snapshot,
            flavor: .m68k)
        let nativeImage = try MacBinaryFile.decode(encoded)
        XCTAssertEqual(nativeImage.name, "NOW-68K Setup.img")
        XCTAssertGreaterThanOrEqual(nativeImage.dataFork.count, 512 * 1_024)

        let raw = temporary.appendingPathComponent("setup.raw")
        try nativeImage.dataFork.write(to: raw)
        let mount = temporary.appendingPathComponent(
            "mount", isDirectory: true)
        try FileManager.default.createDirectory(
            at: mount, withIntermediateDirectories: true)
        let plist = try run("/usr/sbin/diskutil", [
            "image", "attach", "--plist", "--readOnly", "--nobrowse",
            "--mountPoint", mount.path, raw.path
        ])
        let device = try XCTUnwrap(deviceEntry(in: plist))
        defer { _ = try? run("/usr/sbin/diskutil", ["eject", device]) }
        let application = mount.appendingPathComponent("NOW-68K")
        XCTAssertEqual(try resourceFork(at: application),
                       applicationResources)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mount
            .appendingPathComponent("New Old World Prefs").path),
            "NOW-68K ships no preferences as a product property")
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
