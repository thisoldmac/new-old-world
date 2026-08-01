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
        XCTAssertTrue(
            byName["Notes.txt"]?.identity?.range(
                of: "^[0-9a-f]{16}$",
                options: .regularExpression) != nil)
        XCTAssertEqual(
            byName["Notes.txt"]?.identity,
            try share.list(path: "", cursor: 1, limit: 16)
                .entries.first(where: { $0.name == "Notes.txt" })?.identity)
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

    /// The byte bound cuts a page short when the entries are heavy
    /// enough.
    ///
    /// The cap is lowered to force it. At the real 4096 a page of
    /// sixteen 31-character names does not come near the limit — the
    /// original failure was the GUEST's 1200-byte receive buffer, not
    /// this cap — so testing it at 4096 would assert a threshold that
    /// cannot be crossed, which is a test that passes for the wrong
    /// reason.
    func testAPageOfHeavyNamesIsCutShortByBytes() throws {
        for i in 0..<20 {
            // 31 characters, the most the other machine can hold, all
            // of them outside ASCII.
            try write(String(format: "%02d-", i)
                      + String(repeating: "\u{e9}", count: 28), "x")
        }
        share.maxListingBytes = 900
        let page = try share.list(path: "", cursor: 1, limit: 16)
        XCTAssertLessThan(page.entries.count, 16,
                          "heavy names must cut the page short of the count")
        XCTAssertFalse(page.entries.isEmpty, "and never to nothing")

        let encoded = try ControlMessageCodec.encode(.fileListing(
            FileListing(id: 1, path: "", entries: page.entries,
                        more: page.more, cursor: page.next, root: root.path)))
        XCTAssertLessThanOrEqual(encoded.count, 900,
                                 "and what it serves fits the cap it was given")

        // A single entry over the cap still goes: serving nothing would
        // stall the browse forever.
        share.maxListingBytes = 1
        XCTAssertEqual(try share.list(path: "", cursor: 1, limit: 16)
            .entries.count, 1)
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

    // MARK: - The name round trip

    /* A listing's name is the only spelling the other machine has, so
       every name a listing shows must work in a file.get, a mutation,
       and a destination — or the listing advertises files that cannot
       be reached. This was a live defect: names were mangled on the way
       out and looked up verbatim on the way back. */

    func testAListedNameFetchesTheFileItNames() throws {
        try write("A very long file name that HFS could never store.dat",
                  "the real bytes")
        let listed = try XCTUnwrap(
            try share.list(path: "", cursor: 1, limit: 16)
                .entries.first?.name)
        XCTAssertNotEqual(
            listed, "A very long file name that HFS could never store.dat")
        let plan = try share.read(path: listed, convertText: false)
        XCTAssertEqual(String(data: plan.bytes, encoding: .utf8),
                       "the real bytes")
        XCTAssertEqual(plan.name, listed,
                       "file.begin must carry the name the listing showed")
    }

    func testAListedFolderNameOpensTheFolderItNames() throws {
        let folder = "A very long folder name that HFS cannot hold either"
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(folder),
            withIntermediateDirectories: true)
        try "inside".data(using: .utf8)!.write(
            to: root.appendingPathComponent(folder)
                .appendingPathComponent("inner.dat"))
        let listed = try XCTUnwrap(
            try share.list(path: "", cursor: 1, limit: 16)
                .entries.first?.name)
        let page = try share.list(path: listed, cursor: 1, limit: 16)
        XCTAssertEqual(page.entries.map(\.name), ["inner.dat"])
        let plan = try share.read(path: listed + ":inner.dat",
                                  convertText: false)
        XCTAssertEqual(String(data: plan.bytes, encoding: .utf8), "inside")
    }

    func testAMutationOnAListedNameActsOnTheRealFile() throws {
        let real = "A very long file name that HFS could never store.dat"
        try write(real)
        let listed = try XCTUnwrap(
            try share.list(path: "", cursor: 1, limit: 16)
                .entries.first?.name)
        let landed = try share.move(from: listed, to: "kept.dat",
                                    overwrite: false)
        XCTAssertEqual(landed, "kept.dat")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(real).path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("kept.dat").path))
    }

    func testADecomposedNameOnDiskIsFetchableByItsComposedSpelling() throws {
        try write("cafe\u{301}.dat", "accented")
        let listed = try XCTUnwrap(
            try share.list(path: "", cursor: 1, limit: 16)
                .entries.first?.name)
        XCTAssertEqual(listed, "café.dat")
        let plan = try share.read(path: listed, convertText: false)
        XCTAssertEqual(String(data: plan.bytes, encoding: .utf8), "accented")
    }

    /// Where a mutation reports it landed must be the same spelling a
    /// listing of that folder would show — a real path the guest cannot
    /// spell is no use to it.
    func testAMutationResultIsSpelledTheWayAListingWouldShowIt() throws {
        try write("plain.dat")
        let long = "A destination folder with a name HFS cannot hold"
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(long),
            withIntermediateDirectories: true)
        let listedFolder = try XCTUnwrap(
            try share.list(path: "", cursor: 1, limit: 16)
                .entries.first(where: { $0.kind == "folder" })?.name)
        let landed = try share.move(
            from: "plain.dat", to: listedFolder + ":plain.dat",
            overwrite: false)
        XCTAssertEqual(landed, listedFolder + ":plain.dat")
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

/// The four change operations the guest can ask of this Mac. Every one
/// is reversible, because the asker is holding an undo stack — a
/// destructive answer here would be an undo that lies.
@MainActor
final class HostShareChangeTests: XCTestCase {
    private var root: URL!
    private var share: HostShare!

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("now-change-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "now.tests.\(UUID().uuidString)")!
        share = HostShare(defaults: defaults)
        share.root = root
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func write(_ name: String, _ text: String = "hello") throws -> URL {
        let url = root.appendingPathComponent(name)
        try text.data(using: .utf8)!.write(to: url)
        return url
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(
            atPath: root.appendingPathComponent(name).path)
    }

    // MARK: - Move and rename

    func testRenameInPlace() throws {
        try write("Old.txt", "contents")
        let landed = try share.move(from: "Old.txt", to: "New.txt",
                                    overwrite: false)
        XCTAssertEqual(landed, "New.txt")
        XCTAssertFalse(exists("Old.txt"))
        XCTAssertEqual(try String(contentsOf: root
            .appendingPathComponent("New.txt"), encoding: .utf8), "contents")
    }

    func testMoveIntoAFolderReportsWhereItLanded() throws {
        try write("Notes.txt")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Docs"),
            withIntermediateDirectories: false)
        let landed = try share.move(from: "Notes.txt", to: "Docs:Notes.txt",
                                    overwrite: false)
        XCTAssertEqual(landed, "Docs:Notes.txt",
                       "reported in the asker's spelling, with colons")
        XCTAssertTrue(exists("Docs/Notes.txt"))
    }

    func testMovingIntoAFolderThatIsNotThereIsRefused() throws {
        try write("Notes.txt")
        XCTAssertThrowsError(try share.move(from: "Notes.txt",
                                            to: "Nope:Notes.txt",
                                            overwrite: false)) {
            XCTAssertEqual(($0 as? HostShare.ShareError)?.code, "not-found")
        }
        XCTAssertTrue(exists("Notes.txt"), "and the source is untouched")
    }

    func testMoveOntoAnExistingNameNeedsOverwrite() throws {
        try write("A.txt", "a")
        try write("B.txt", "b")
        XCTAssertThrowsError(try share.move(from: "A.txt", to: "B.txt",
                                            overwrite: false)) {
            XCTAssertEqual(($0 as? HostShare.ShareError)?.code, "exists")
        }
        XCTAssertNoThrow(try share.move(from: "A.txt", to: "B.txt",
                                        overwrite: true))
        XCTAssertEqual(try String(contentsOf: root
            .appendingPathComponent("B.txt"), encoding: .utf8), "a")
    }

    func testMoveOutOfTheShareIsRefused() throws {
        try write("Notes.txt")
        XCTAssertThrowsError(try share.move(from: "Notes.txt",
                                            to: "..:Notes.txt",
                                            overwrite: false))
        XCTAssertTrue(exists("Notes.txt"))
    }

    // MARK: - Trash and restore

    func testTrashReportsTheNameItLandedUnder() throws {
        try write("Notes.txt", "first")
        let landed = try share.trash(path: "Notes.txt")
        XCTAssertFalse(exists("Notes.txt"))
        XCTAssertFalse(landed.isEmpty)

        // The round trip an undo makes.
        let back = try share.restore(trashedAs: landed, to: "Notes.txt")
        XCTAssertEqual(back, "Notes.txt")
        XCTAssertEqual(try String(contentsOf: root
            .appendingPathComponent("Notes.txt"), encoding: .utf8), "first")
    }

    /// Two files with the same name from different folders: the Trash
    /// renames the second, and recording the name we ASKED for rather
    /// than the one it got would eventually put the wrong file back.
    func testTwoFilesOfTheSameNameRestoreToTheRightPlaces() throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("One"),
            withIntermediateDirectories: false)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Two"),
            withIntermediateDirectories: false)
        try "from one".data(using: .utf8)!
            .write(to: root.appendingPathComponent("One/Same.txt"))
        try "from two".data(using: .utf8)!
            .write(to: root.appendingPathComponent("Two/Same.txt"))

        let first = try share.trash(path: "One:Same.txt")
        let second = try share.trash(path: "Two:Same.txt")
        XCTAssertNotEqual(first, second,
                          "the Trash cannot hold two of the same name")

        try share.restore(trashedAs: second, to: "Two:Same.txt")
        try share.restore(trashedAs: first, to: "One:Same.txt")
        XCTAssertEqual(try String(contentsOf: root
            .appendingPathComponent("One/Same.txt"), encoding: .utf8),
                       "from one")
        XCTAssertEqual(try String(contentsOf: root
            .appendingPathComponent("Two/Same.txt"), encoding: .utf8),
                       "from two")
    }

    func testRestoringSomethingNoLongerInTheTrashIsNotFound() {
        XCTAssertThrowsError(try share.restore(trashedAs: "Gone.txt",
                                               to: "Gone.txt")) {
            XCTAssertEqual(($0 as? HostShare.ShareError)?.code, "not-found")
        }
    }

    func testRestoringOverSomethingIsRefused() throws {
        try write("Notes.txt", "original")
        let landed = try share.trash(path: "Notes.txt")
        try write("Notes.txt", "a new one in its place")
        XCTAssertThrowsError(try share.restore(trashedAs: landed,
                                               to: "Notes.txt")) {
            XCTAssertEqual(($0 as? HostShare.ShareError)?.code, "exists")
        }
        XCTAssertEqual(try String(contentsOf: root
            .appendingPathComponent("Notes.txt"), encoding: .utf8),
                       "a new one in its place")
    }

    // MARK: - New folders

    func testMakeFolderAndItsParents() throws {
        let landed = try share.makeFolder(path: "Docs:2026:July")
        XCTAssertEqual(landed, "Docs:2026:July")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Docs/2026/July").path,
            isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testMakingAFolderThatIsAlreadyThereIsNotAFailure() throws {
        try share.makeFolder(path: "Docs")
        XCTAssertNoThrow(try share.makeFolder(path: "Docs"))
    }

    func testAFolderCannotReplaceAFile() throws {
        try write("Docs")
        XCTAssertThrowsError(try share.makeFolder(path: "Docs")) {
            XCTAssertEqual(($0 as? HostShare.ShareError)?.code, "exists")
        }
    }

    func testMakingAFolderOutsideTheShareIsRefused() {
        XCTAssertThrowsError(try share.makeFolder(path: "..:Escape"))
    }
}
