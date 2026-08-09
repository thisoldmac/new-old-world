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
        try XCTUnwrap(MacBinaryEncoder.data(
            name: "New Old World", type: "APPL", creator: "NOWo",
            dataFork: Data([1, 2, 3]), resourceFork: Data([4, 5])))
            .write(to: assets.appendingPathComponent("New Old World.bin"))
        try XCTUnwrap(MacBinaryEncoder.data(
            name: "NowExt", type: "INIT", creator: "NOWx",
            dataFork: Data(), resourceFork: Data([6, 7, 8])))
            .write(to: assets.appendingPathComponent("NOW Extension.bin"))
        let snapshot = OnboardingAssetCatalog(
            roots: [assets], writableRoot: assets).snapshot()

        let encoded = try await ClassicSetupImageBuilder().build(
            host: "10.0.2.2", wirePort: 5_432, assets: snapshot)
        let nativeImage = try MacBinaryFile.decode(encoded)
        XCTAssertEqual(nativeImage.name,
                       ClassicSetupImageBuilder.classicImageName)
        XCTAssertEqual(nativeImage.type, "rohd")
        XCTAssertEqual(nativeImage.creator, "ddsk")

        let raw = temporary.appendingPathComponent("setup.raw")
        try nativeImage.dataFork.write(to: raw)
        let mount = temporary.appendingPathComponent(
            "mount", isDirectory: true)
        let plist = try run("/usr/sbin/diskutil", [
            "image", "attach", "--plist", "--readOnly", "--nobrowse",
            "--mountPoint", mount.path, raw.path
        ])
        let device = try XCTUnwrap(deviceEntry(in: plist))
        defer { _ = try? run("/usr/sbin/diskutil", ["eject", device]) }

        let application = mount.appendingPathComponent("New Old World")
        XCTAssertEqual(try Data(contentsOf: application), Data([1, 2, 3]))
        XCTAssertEqual(try resourceFork(at: application), Data([4, 5]))
        let extensionComponent = mount.appendingPathComponent("NOW Extension")
        XCTAssertEqual(try resourceFork(at: extensionComponent),
                       Data([6, 7, 8]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mount
            .appendingPathComponent("New Old World Prefs").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mount
            .appendingPathComponent("Read Me First").path))
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
