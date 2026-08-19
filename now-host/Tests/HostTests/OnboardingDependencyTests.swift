import Foundation
import XCTest
@testable import Host

@MainActor
final class OnboardingDependencyTests: XCTestCase {
    func testCatalogEnumeratesKnownAndOperatorProvidedDependencies() throws {
        let temporary = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let dependencies = temporary.appendingPathComponent(
            "Dependencies", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dependencies, withIntermediateDirectories: true)
        try Data("carbon".utf8).write(to: dependencies
            .appendingPathComponent("CarbonLib_1.6.smi.bin"))
        try Data("expander".utf8).write(to: dependencies
            .appendingPathComponent("StuffIt Expander 5.5.bin"))

        let snapshot = OnboardingAssetCatalog(
            roots: [temporary], writableRoot: temporary).snapshot()

        XCTAssertEqual(OnboardingDependencyCatalog.all.map(\.displayName),
                       ["CarbonLib 1.6 Installer"])
        XCTAssertEqual(OnboardingDependencyCatalog.carbonLib
            .installedAsset(in: snapshot)?.fileName,
            "CarbonLib_1.6.smi.bin")
        XCTAssertEqual(OnboardingDependencyCatalog.additionalAssets(
            in: snapshot).map(\.fileName), ["StuffIt Expander 5.5.bin"])
    }

    func testNativeKnownDependencyReplacesItsArchiveRepresentation() throws {
        let temporary = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let dependencies = temporary.appendingPathComponent(
            "Dependencies", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dependencies, withIntermediateDirectories: true)
        try Data("native".utf8).write(to: dependencies
            .appendingPathComponent("CarbonLib.bin"))
        try Data("archive".utf8).write(to: dependencies
            .appendingPathComponent("CarbonLib_1.5.smi_.sit.bin"))
        try Data("other".utf8).write(to: dependencies
            .appendingPathComponent("Other Package.bin"))

        let snapshot = OnboardingAssetCatalog(
            roots: [temporary], writableRoot: temporary).snapshot()

        XCTAssertEqual(OnboardingDependencyCatalog.carbonLib
            .installedAsset(in: snapshot)?.fileName, "CarbonLib.bin")
        XCTAssertEqual(OnboardingDependencyCatalog.additionalAssets(
            in: snapshot).map(\.fileName), ["Other Package.bin"])
        XCTAssertEqual(OnboardingDependencyCatalog.setupAssets(
            in: snapshot).map(\.fileName),
            ["CarbonLib.bin", "Other Package.bin"])
    }

    func testAcquisitionVerifiesThenWrapsStuffItInMacBinary() async throws {
        let temporary = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let payload = Data("stuffit-payload".utf8)
        let dependency = fixtureDependency(payload: payload)
        let acquirer = OnboardingDependencyAcquirer { url in
            XCTAssertEqual(url, dependency.downloadURL)
            return payload
        }
        let catalog = OnboardingAssetCatalog(
            roots: [temporary], writableRoot: temporary)

        let destination = try await acquirer.acquire(
            dependency, catalog: catalog)
        let bytes = [UInt8](try Data(contentsOf: destination))

        XCTAssertEqual(destination.lastPathComponent, "Package.sit.bin")
        XCTAssertEqual(String(bytes: bytes[2..<13], encoding: .macOSRoman),
                       "Package.sit")
        XCTAssertEqual(String(bytes: bytes[65..<69], encoding: .ascii),
                       "SIT5")
        XCTAssertEqual(String(bytes: bytes[69..<73], encoding: .ascii),
                       "SIT!")
        XCTAssertEqual(UInt32(bytes[83]) << 24
            | UInt32(bytes[84]) << 16
            | UInt32(bytes[85]) << 8
            | UInt32(bytes[86]), UInt32(payload.count))
        XCTAssertEqual(Data(bytes[128..<(128 + payload.count)]), payload)
    }

    func testAcquisitionRefusesChecksumMismatchWithoutWriting() async throws {
        let temporary = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let expected = Data("expected".utf8)
        let acquirer = OnboardingDependencyAcquirer { _ in
            Data("tampered".utf8)
        }
        let catalog = OnboardingAssetCatalog(
            roots: [temporary], writableRoot: temporary)

        do {
            _ = try await acquirer.acquire(
                fixtureDependency(payload: expected), catalog: catalog)
            XCTFail("a mismatched package must not be admitted")
        } catch let error as OnboardingDependencyAcquirer.AcquisitionError {
            guard case .checksumMismatch = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary
            .appendingPathComponent("Dependencies/Package.sit.bin").path))
    }

    /// A desk that downloaded the superseded 1.6.1 .sit under the old
    /// pin must heal itself: the stale file is neither the installed
    /// entry nor an additional asset, so Get reappears and fetches the
    /// official installer.
    func testRetiredArtifactNoLongerMasksTheCurrentPin() throws {
        let temporary = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let dependencies = temporary.appendingPathComponent(
            "Dependencies", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dependencies, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: dependencies
            .appendingPathComponent("CarbonLib_161.sit.bin"))

        let snapshot = OnboardingAssetCatalog(
            roots: [temporary], writableRoot: temporary).snapshot()
        XCTAssertNil(OnboardingDependencyCatalog.carbonLib
            .installedAsset(in: snapshot),
            "the retired repack must not read as installed")
        XCTAssertTrue(OnboardingDependencyCatalog.additionalAssets(
            in: snapshot).isEmpty,
            "nor be offered as an operator-provided extra")
    }

    private func fixtureDependency(payload: Data) -> OnboardingDependency {
        OnboardingDependency(
            id: "fixture", displayName: "Fixture", detail: "Test package",
            downloadFileName: "Package.sit.bin",
            acceptedNameFragments: ["package.sit"],
            downloadURL: URL(string: "https://example.invalid/package.sit")!,
            sourcePageURL: URL(string: "https://example.invalid/")!,
            expectedSHA1: OnboardingDependencyAcquirer.sha1Hex(payload),
            delivery: .macBinary(classicName: "Package.sit",
                                 type: "SIT5", creator: "SIT!"))
    }

    private func makeTemporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
