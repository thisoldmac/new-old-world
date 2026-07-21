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

    /// A page has to fit in a control frame. Sixteen long names plus
    /// their types and dates do not, and the receiver's answer to a
    /// message it cannot hold used to be dropping the connection.
    func testAPageFitsInAControlFrame() throws {
        // 31 characters is the most the other machine can hold, so this
        // is the worst real page: as many maximum-length names as fit.
        for i in 0..<40 {
            try write(String(format: "%02d", i)
                      + "-a-name-that-is-31-chars-lng", "x")
        }
        let page = try share.list(path: "", cursor: 1, limit: 16)
        XCTAssertFalse(page.entries.isEmpty)
        XCTAssertTrue(page.more, "40 files cannot be one page")

        let listing = FileListing(id: 1, path: "", entries: page.entries,
                                  more: page.more, cursor: page.next,
                                  root: root.path)
        let encoded = try ControlMessageCodec.encode(.fileListing(listing))
        XCTAssertLessThanOrEqual(encoded.count, 4096,
                                 "a listing must fit the control cap")

        // And the pages together still cover everything, in order.
        var seen: [String] = page.entries.map(\.name)
        var cursor = page.next
        var more = page.more
        while more {
            let next = try share.list(path: "", cursor: cursor, limit: 16)
            seen += next.entries.map(\.name)
            cursor = next.next
            more = next.more
            XCTAssertFalse(next.entries.isEmpty, "paging must make progress")
        }
        XCTAssertEqual(seen.count, 40)
        XCTAssertEqual(Set(seen).count, 40, "no entry served twice")
    }

    /// Names that leave ASCII are escaped to \\uXXXX and cost six bytes
    /// a character, so a page that fits when counted in entries can
    /// still not fit when counted in bytes. This is the case that made
    /// the byte bound necessary rather than theoretical.
    func testAPageOfHeavyNamesIsCutShortByBytes() throws {
        for i in 0..<20 {
            // 31 characters, the most the other machine can hold, all
            // of them outside ASCII.
            try write(String(format: "%02d-", i)
                      + String(repeating: "\u{e9}", count: 28), "x")
        }
        let page = try share.list(path: "", cursor: 1, limit: 16)
        XCTAssertLessThan(page.entries.count, 16,
                          "heavy names must cut the page short of the count")
        XCTAssertFalse(page.entries.isEmpty, "and never to nothing")

        let encoded = try ControlMessageCodec.encode(.fileListing(
            FileListing(id: 1, path: "", entries: page.entries,
                        more: page.more, cursor: page.next, root: root.path)))
        XCTAssertLessThanOrEqual(encoded.count, 4096)
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

    /// Replacing is recoverable: the person who said yes is at the
    /// other machine and cannot see what they are replacing.
    func testReplacingPutsTheOldFileInTheTrash() throws {
        try write("Sent.txt", "the original")
        let url = try share.destination(name: "Sent.txt", path: "",
                                        overwrite: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "the old file moved out of the way")
        try "the replacement".data(using: .utf8)!.write(to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8),
                       "the replacement")
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
