import Foundation
import XCTest
@testable import Host

final class MachineOverviewTests: XCTestCase {
    func testCaptionedHardwareRowsBecomeNamedSections() {
        let rows = [
            ["Machine", "", ""],
            ["   Model", "", "PowerBook 1400c"],
            ["   Processor", "", "PowerPC 603e"],
            ["Memory", "", ""],
            ["   Installed RAM", "", "64 MB"],
        ]

        let sections = MachineOverviewPresentation.factSections(from: rows)

        XCTAssertEqual(sections.map(\.title), ["Machine", "Memory"])
        XCTAssertEqual(sections[0].facts.map(\.label), ["Model", "Processor"])
        XCTAssertEqual(sections[0].facts.map(\.value),
                       ["PowerBook 1400c", "PowerPC 603e"])
        XCTAssertEqual(sections[1].facts.first?.value, "64 MB")
    }

    func testFlat68KHardwareRowsRemainOneOverview() {
        let sections = MachineOverviewPresentation.factSections(from: [
            ["Model", "", "Macintosh SE/30"],
            ["Memory", "", "8 MB"],
            ["System", "", "7.1"],
        ])

        XCTAssertEqual(sections.count, 1)
        XCTAssertNil(sections[0].title)
        XCTAssertEqual(sections[0].facts.map(\.label),
                       ["Model", "Memory", "System"])
    }

    func testRunningApplicationsExcludeBackgroundAndLeadWithFrontmost() {
        let applications = MachineOverviewPresentation.applications(from: [
            process("Helper", kind: "background"),
            process("SimpleText", kind: "application"),
            process("Finder", kind: "finder", front: true),
        ])

        XCTAssertEqual(applications.map(\.process.name), ["Finder", "SimpleText"])
    }

    func testApplicationIdentityDistinguishesDuplicateLegacyRows() {
        let applications = MachineOverviewPresentation.applications(from: [
            process("Untitled", kind: "application"),
            process("Untitled", kind: "application"),
        ])

        XCTAssertEqual(Set(applications.map(\.id)).count, 2)
    }

    func testCustomPhotosAreStoredPerStableGuestID() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "machine-photo-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.deletingLastPathComponent().appendingPathComponent(
            "source-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: source) }
        try tinyPNG.write(to: source)
        let store = try GuestPhotoStore(root: root)
        let first = try XCTUnwrap(GuestID("pb1400c"))
        let second = try XCTUnwrap(GuestID("q950"))

        XCTAssertNotNil(try store.importPhoto(from: source, for: first))
        XCTAssertNil(store.loadPhoto(for: second))
        XCTAssertNotNil(store.loadPhoto(for: first))
        XCTAssertNotEqual(store.photoURL(for: first), store.photoURL(for: second))
    }

    func testInvalidPhotoIsRejectedWithoutCreatingAStoredFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "machine-photo-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.deletingLastPathComponent().appendingPathComponent(
            "source-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: source) }
        try Data("not an image".utf8).write(to: source)
        let store = try GuestPhotoStore(root: root)
        let guest = try XCTUnwrap(GuestID("pb1400c"))

        XCTAssertThrowsError(try store.importPhoto(from: source, for: guest))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.photoURL(for: guest).path))
    }

    func testOverviewUsesSharedModuleModelsInsteadOfNavigationCards() throws {
        let source = try GateSource.hostSwift(
            "now-host/Sources/Host/MachineOverviewView.swift")

        XCTAssertTrue(source.contains("CensusHostModuleRuntime.self"))
        XCTAssertTrue(source.contains("ProcessesHostModuleRuntime.self"))
        XCTAssertTrue(source.contains("GuestPhotoModel"))
        XCTAssertFalse(source.contains("MachineOverviewModuleGrid"))
        XCTAssertFalse(source.contains("selectModule"))
    }

    private func process(_ name: String, kind: String, front: Bool = false)
        -> ProcessEntry {
        ProcessEntry(name: name, kind: kind, front: front)
    }

    private var tinyPNG: Data {
        Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    }
}
