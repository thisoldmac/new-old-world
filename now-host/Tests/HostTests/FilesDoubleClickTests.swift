import XCTest
@testable import Host

/// What a double-click in the browser does.
///
/// A file comes to the folder this Mac shares and opens here; a folder
/// navigates, and the path bar has to be right afterwards. The parts
/// worth pinning are the ones a person notices when they are wrong:
/// where the bytes landed, whether anything opened, and whether a click
/// that could not do its job said so instead of appearing to do nothing.
///
/// Opening is a seam (`FilesModuleModel.SystemOpen`) so these tests watch
/// the decision rather than launching applications on whoever is running
/// them.
@MainActor
final class FilesDoubleClickTests: XCTestCase {
    private var listener: GuestListener!
    private var model: FilesModuleModel!
    private var share: URL!
    private var downloads: URL!
    private var opened: [URL] = []
    private var revealed: [URL] = []
    private var canOpen = true

    override func setUp() async throws {
        listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"),
            timing: .init(idleTimeout: 60))
        listener.start(port: 0)
        try await waitUntil("listening") {
            if case .listening = self.listener.state { return true }
            return false
        }
        model = FilesModuleModel(
            listener: listener,
            defaults: UserDefaults(
                suiteName: "files.dbl.\(UUID().uuidString)")!)
        share = try temporaryDirectory()
        downloads = try temporaryDirectory()
        model.shareDirectory = share
        model.downloadDirectory = downloads
        opened = []
        revealed = []
        canOpen = true
        model.systemOpen = .init(
            open: { [weak self] url in
                self?.opened.append(url)
                return self?.canOpen ?? false
            },
            reveal: { [weak self] url in self?.revealed.append(url) })
    }

    override func tearDown() async throws {
        listener.stop()
        listener = nil
        model = nil
    }

    // MARK: - A file lands in the shared folder and opens

    func testAFileLandsInTheSharedFolderRatherThanTheDownloadsFolder()
        async throws {
        let guest = try await connectedGuest()
        model.openOnThisMac(row(named: "Read Me"))

        XCTAssertEqual(model.transfer?.opensWhenDone, true,
                       "the progress row has to be able to say what the "
                       + "wait is for")
        try await deliver("Read Me", to: guest, bytes: Data("hi\r".utf8))

        let landed = share.appendingPathComponent("Read Me")
        XCTAssertTrue(FileManager.default.fileExists(atPath: landed.path),
                      "the shared folder is the one place both machines "
                      + "already agree on")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: downloads.path), [],
            "a double-click is not a download")
        XCTAssertEqual(opened, [landed])
        XCTAssertTrue(revealed.isEmpty)
        XCTAssertNil(model.lastError)
        XCTAssertNil(model.lastNotice)
    }

    func testAFileThisMacCannotOpenIsRevealedAndSaidOutLoud()
        async throws {
        canOpen = false
        let guest = try await connectedGuest()
        model.openOnThisMac(row(named: "SimpleText"))
        try await deliver("SimpleText", to: guest, bytes: Data([0x00]),
                          container: "macbinary", fileType: "APPL")

        let landed = share.appendingPathComponent("SimpleText.bin")
        XCTAssertEqual(revealed, [landed],
                       "the transfer worked; the file is somewhere real "
                       + "and a person can be shown it")
        XCTAssertNil(model.lastError,
                     "nothing failed, so nothing is red")
        let notice = try XCTUnwrap(model.lastNotice)
        XCTAssertTrue(notice.contains("SimpleText.bin"))
        XCTAssertTrue(notice.contains(share.lastPathComponent),
                      "the notice names where it went: " + notice)
    }

    func testAnExistingFileInTheShareIsNeverOverwritten() async throws {
        let existing = share.appendingPathComponent("Read Me")
        try Data("mine\n".utf8).write(to: existing)
        let guest = try await connectedGuest()
        model.openOnThisMac(row(named: "Read Me"))
        try await deliver("Read Me", to: guest, bytes: Data("theirs\r".utf8))

        XCTAssertEqual(try String(contentsOf: existing), "mine\n",
                       "the shared folder is a real folder the other "
                       + "machine also reads")
        XCTAssertEqual(opened.first?.lastPathComponent, "Read Me (2)")
    }

    // MARK: - A folder still navigates

    func testAFolderNavigatesAndTheBarFollows() async throws {
        _ = try await connectedGuest()
        model.openOnThisMac(FileRow(
            entry: FileEntry(name: "System Folder", kind: "folder",
                             fileType: nil, creator: nil, dataBytes: nil,
                             rsrcBytes: nil, modified: nil),
            path: "System Folder"))

        XCTAssertNil(model.transfer, "a folder is not downloadable")
        XCTAssertEqual(model.breadcrumb, ["System Folder"])
        XCTAssertEqual(model.path, "System Folder")
        // The bar is the thing that says where the navigation landed.
        XCTAssertEqual(shownNames(model.pathItems).last, "System Folder")
        XCTAssertEqual(opened, [])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: share.path), [])
    }

    // MARK: - The wait, and how it ends

    func testASecondClickWhileOneIsInFlightSaysSoRatherThanDoingNothing()
        async throws {
        let guest = try await connectedGuest()
        model.openOnThisMac(row(named: "Big"))
        try await waitUntil("first get on the wire") {
            guest.received.contains {
                if case .fileGet = $0 { return true }
                return false
            }
        }

        model.openOnThisMac(row(named: "Other"))
        XCTAssertEqual(model.transfer?.name, "Big",
                       "the wire has one lane")
        XCTAssertEqual(model.lastError, "Another transfer is already "
                       + "running.",
                       "a click that quietly does nothing is the defect "
                       + "this feature was reported for")
        let gets = guest.received.filter {
            if case .fileGet = $0 { return true }
            return false
        }
        XCTAssertEqual(gets.count, 1)
    }

    func testACancelledDownloadOpensNothing() async throws {
        let guest = try await connectedGuest()
        model.openOnThisMac(row(named: "Big"))
        try await waitUntil("get sent") {
            guest.received.contains {
                if case .fileGet = $0 { return true }
                return false
            }
        }
        // The same cancel the progress row's button reaches, which is
        // what sends file.cancel on the wire.
        model.cancelTransfer()

        try await waitUntil("settled") { self.model.transfer == nil }
        XCTAssertEqual(opened, [], "stopping it is the point")
        XCTAssertEqual(revealed, [])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: share.path), [],
            "and nothing half-written is left in the shared folder")
    }

    // MARK: - Harness

    private func row(named name: String) -> FileRow {
        FileRow(entry: FileEntry(name: name, kind: "file",
                                 fileType: "TEXT", creator: "ttxt",
                                 dataBytes: 3, rsrcBytes: 0, modified: nil),
                path: name)
    }

    private func shownNames(_ items: [FilePathBar.Item]) -> [String] {
        items.compactMap {
            if case .crumb(let crumb) = $0 { return crumb.name }
            return nil
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    /// Plays the guest's half of one `file.get`.
    private func deliver(_ name: String, to guest: FakeGuest,
                         bytes: Data, container: String = "data",
                         fileType: String = "TEXT") async throws {
        var getId: Int?
        try await waitUntil("file.get for \(name)") {
            for message in guest.received {
                if case .fileGet(let get) = message, get.path == name {
                    getId = get.id
                    return true
                }
            }
            return false
        }
        let id = try XCTUnwrap(getId)
        try guest.send(.fileBegin(FileBegin(
            id: id, transfer: 21, name: name, container: container,
            bytes: bytes.count, dataBytes: bytes.count, rsrcBytes: 0,
            fileType: fileType, creator: "ttxt", modified: nil)))
        guest.sendRaw(try FrameCodec.encode(
            channel: .bulk, flags: [.end], transfer: 21, payload: bytes))
        try guest.send(.fileEnd(FileEnd(id: id, transfer: 21, ok: true,
                                        sendMs: 1)))
        try await waitUntil("transfer settled") {
            self.model.transfer == nil
        }
    }

    private struct WaitTimeout: Error { let what: String }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5,
                           _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting for \(what)")
                throw WaitTimeout(what: what)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func connectedGuest() async throws -> FakeGuest {
        let guest = FakeGuest(port: listener.boundPort ?? 0)
        guest.start()
        try guest.send(.hello(Hello(
            contract: Contract.revision, side: "guest", version: "0.1.0",
            name: "PowerBook 1400", os: "9.1", chunk: 8192)))
        try await waitUntil("connected") {
            if case .connected = self.listener.state { return true }
            return false
        }
        model.connection = .connected(named: "PowerBook 1400")
        return guest
    }
}
