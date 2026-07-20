import Foundation
import XCTest
@testable import Host

/// The host's serving side. The guest reaches these paths on its own
/// initiative, so what they refuse matters as much as what they return.
@MainActor
final class HostShareTests: XCTestCase {
    private var root: URL!
    private var share: HostShare!

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("now-share-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "now.tests.\(UUID().uuidString)")!
        share = HostShare(defaults: defaults)
        share.root = root
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ name: String, _ text: String = "hello") throws {
        try text.data(using: .utf8)!
            .write(to: root.appendingPathComponent(name))
    }

    // MARK: - The boundary

    func testEmptyPathIsTheShareRoot() throws {
        XCTAssertEqual(try share.resolve("").path,
                       root.path)
    }

    func testParentSegmentIsRefused() {
        for path in ["..", "Docs::Notes", ":Docs", "Docs:", "Docs:..:.."] {
            XCTAssertThrowsError(try share.resolve(path),
                                 "\(path) should not resolve")
        }
    }

    func testAbsolutePathIsRefused() {
        XCTAssertThrowsError(try share.resolve("/etc:passwd"))
    }

    func testSymlinkOutOfTheShareIsRefused() throws {
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("now-outside-\(UUID().uuidString)")
        try "secret".data(using: .utf8)!.write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Link"), withDestinationURL: outside)
        XCTAssertThrowsError(try share.read(path: "Link", convertText: false))
    }

    // MARK: - Listing

    func testListingReportsFoldersAndSizes() throws {
        try write("Notes.txt", "hello")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Docs"),
            withIntermediateDirectories: false)
        let page = try share.list(path: "", cursor: 1, limit: 16)
        let byName = Dictionary(uniqueKeysWithValues:
            page.entries.map { ($0.name, $0) })
        XCTAssertEqual(byName["Docs"]?.isFolder, true)
        XCTAssertEqual(byName["Notes.txt"]?.isFolder, false)
        XCTAssertEqual(byName["Notes.txt"]?.dataBytes, 5)
        XCTAssertFalse(page.more)
    }

    func testListingPagesAndResumes() throws {
        for i in 0..<5 { try write("f\(i).txt") }
        let first = try share.list(path: "", cursor: 1, limit: 2)
        XCTAssertEqual(first.entries.count, 2)
        XCTAssertTrue(first.more)
        let second = try share.list(path: "", cursor: first.next, limit: 2)
        XCTAssertEqual(second.entries.count, 2)
        XCTAssertTrue(Set(first.entries.map(\.name))
            .isDisjoint(with: Set(second.entries.map(\.name))))
    }

    func testListingSkipsHiddenFiles() throws {
        try write(".hidden")
        try write("visible.txt")
        let page = try share.list(path: "", cursor: 1, limit: 16)
        XCTAssertEqual(page.entries.map(\.name), ["visible.txt"])
    }

    func testListingAFileIsRefused() throws {
        try write("Notes.txt")
        XCTAssertThrowsError(try share.list(path: "Notes.txt", cursor: 1,
                                            limit: 16))
    }

    func testListedNamesAreOnesTheGuestCanHold() throws {
        try write("A very long file name that HFS could never store.txt")
        let page = try share.list(path: "", cursor: 1, limit: 16)
        let name = try XCTUnwrap(page.entries.first?.name)
        XCTAssertLessThanOrEqual(name.utf8.count, 31)
        XCTAssertTrue(name.hasSuffix(".txt"), "the extension identifies it")
    }

    // MARK: - Reading

    func testReadConvertsLineEndingsForText() throws {
        try write("Notes.txt", "one\ntwo\n")
        let plan = try share.read(path: "Notes.txt", convertText: true)
        XCTAssertEqual(String(data: plan.bytes, encoding: .macOSRoman),
                       "one\rtwo\r")
        XCTAssertEqual(plan.container, "data")
    }

    func testReadLeavesBytesAloneWhenNotConverting() throws {
        try write("Notes.txt", "one\ntwo\n")
        let plan = try share.read(path: "Notes.txt", convertText: false)
        XCTAssertEqual(plan.bytes, "one\ntwo\n".data(using: .utf8))
    }

    func testReadingAMissingFileIsNotFound() {
        XCTAssertThrowsError(try share.read(path: "Nope", convertText: false)) {
            XCTAssertEqual(($0 as? HostShare.ShareError)?.code, "not-found")
        }
    }

    func testReadingAFolderIsRefused() throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Docs"),
            withIntermediateDirectories: false)
        XCTAssertThrowsError(try share.read(path: "Docs", convertText: false))
    }

    // MARK: - Writing

    func testDestinationIsInsideTheShare() throws {
        let url = try share.destination(name: "Sent.txt", path: "",
                                        overwrite: false)
        XCTAssertEqual(url.deletingLastPathComponent().path,
                       root.path)
    }

    func testDestinationRefusesAnExistingFile() throws {
        try write("Sent.txt")
        XCTAssertThrowsError(try share.destination(name: "Sent.txt", path: "",
                                                   overwrite: false)) {
            XCTAssertEqual(($0 as? HostShare.ShareError)?.code, "exists")
        }
        XCTAssertNoThrow(try share.destination(name: "Sent.txt", path: "",
                                               overwrite: true))
    }

    func testDestinationSanitizesTheIncomingName() throws {
        let url = try share.destination(name: "../../escape", path: "",
                                        overwrite: false)
        XCTAssertEqual(url.deletingLastPathComponent().path,
                       root.path)
        XCTAssertFalse(url.lastPathComponent.contains("/"))
        XCTAssertFalse(url.lastPathComponent.hasPrefix("."))
    }
}
