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
        try Data("extension".utf8).write(to: bundled
            .appendingPathComponent("NowExt.bin"))
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
        XCTAssertEqual(snapshot.extensionComponent?.fileName, "NowExt.bin")
        XCTAssertEqual(snapshot.dependencies.map(\.fileName),
                       ["CarbonLib 1.6.smi.bin", "StuffIt Expander.bin"])
        XCTAssertTrue(snapshot.hasCarbonLib)
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

    private func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
    }
}
