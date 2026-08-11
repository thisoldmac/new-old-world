import Foundation
import XCTest
@testable import Host

/// The share over a folder iCloud manages. What is not downloaded is a
/// hidden ".name.icloud" stub on disk; the other machine must see the
/// file it stands for, and a pull of one must start the download and
/// refuse honestly — never hang the wire on the weather.
///
/// The stubs here are fabricated: the tests prove the share's handling
/// of the on-disk shape, not iCloud itself. What only a signed-in Mac
/// can prove is listed in docs/open-issues.md, unverified until then.
@MainActor
final class HostShareCloudTests: XCTestCase {
    private var root: URL!
    private var share: HostShare!

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("now-cloud-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        let defaults = UserDefaults(
            suiteName: "now.tests.\(UUID().uuidString)")!
        share = HostShare(defaults: defaults)
        share.root = root
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A stand-in for what iCloud leaves behind: a hidden property list
    /// named for the file it promises.
    private func writeStub(for logical: String, bytes: Int) throws {
        let plist: [String: Any] = ["NSURLNameKey": logical,
                                    "NSURLFileSizeKey": bytes]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .binary, options: 0)
        try data.write(to: root.appendingPathComponent(
            ".\(logical).icloud"))
    }

    func testAPlaceholderListsUnderItsLogicalName() throws {
        try writeStub(for: "Report.txt", bytes: 12345)
        let page = try share.list(path: "", cursor: 1, limit: 16)
        let entry = try XCTUnwrap(page.entries.first)
        XCTAssertEqual(entry.name, "Report.txt")
        XCTAssertEqual(entry.kind, "file")
        XCTAssertEqual(entry.dataBytes, 12345,
                       "the size is the placeholder's promise")
        XCTAssertEqual(page.entries.count, 1,
                       "the stub itself is not a second entry")
    }

    func testAPlaceholderBesideItsRealFileListsOnce() throws {
        try writeStub(for: "Report.txt", bytes: 12345)
        try "downloaded".data(using: .utf8)!
            .write(to: root.appendingPathComponent("Report.txt"))
        let page = try share.list(path: "", cursor: 1, limit: 16)
        XCTAssertEqual(page.entries.map(\.name), ["Report.txt"])
        XCTAssertEqual(page.entries.first?.dataBytes, 10,
                       "the real file is the truth mid-download")
    }

    func testAStubThatDoesNotDecodeStillListsItsFile() throws {
        try "not a plist".data(using: .utf8)!
            .write(to: root.appendingPathComponent(".Odd.dat.icloud"))
        let page = try share.list(path: "", cursor: 1, limit: 16)
        XCTAssertEqual(page.entries.first?.name, "Odd.dat")
        XCTAssertEqual(page.entries.first?.dataBytes, 0,
                       "an unknown size is zero, not an invention")
    }

    func testOrdinaryHiddenFilesStayHidden() throws {
        try "junk".data(using: .utf8)!
            .write(to: root.appendingPathComponent(".DS_Store"))
        var flagged = root.appendingPathComponent("Flagged.dat")
        try "x".data(using: .utf8)!.write(to: flagged)
        var values = URLResourceValues()
        values.isHidden = true
        try flagged.setResourceValues(values)
        let page = try share.list(path: "", cursor: 1, limit: 16)
        XCTAssertTrue(page.entries.isEmpty,
                      "got \(page.entries.map(\.name))")
    }

    func testGettingAPlaceholderRefusesBusyWithTheReason() throws {
        try writeStub(for: "Report.txt", bytes: 12345)
        XCTAssertThrowsError(
            try share.read(path: "Report.txt", convertText: false)
        ) { error in
            let fault = HostShare.WireFault(error)
            XCTAssertEqual(fault.code, "busy")
            XCTAssertTrue(fault.reason.contains("iCloud"),
                          "the refusal names the weather: \(fault.reason)")
        }
    }

    /// The projection must look through the stub seam: a placeholder
    /// whose logical name HFS cannot hold lists mangled, and that
    /// mangled name must reach the placeholder — busy, never not-found.
    func testAMangledPlaceholderNameReachesItsFile() throws {
        let logical =
            "A very long promised name that HFS could never store.dat"
        try writeStub(for: logical, bytes: 7)
        let listed = try XCTUnwrap(
            try share.list(path: "", cursor: 1, limit: 16)
                .entries.first?.name)
        XCTAssertNotEqual(listed, logical)
        XCTAssertThrowsError(
            try share.read(path: listed, convertText: false)
        ) { error in
            XCTAssertEqual(HostShare.WireFault(error).code, "busy",
                           "not-found here means the name bridge "
                               + "did not see through the stub")
        }
    }
}
