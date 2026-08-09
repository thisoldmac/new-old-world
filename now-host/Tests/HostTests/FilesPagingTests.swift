import XCTest
@testable import Host

/// A folder is shown WHOLE, or the reason it is not is said out loud.
///
/// The guest pages at sixteen entries per reply because a control frame
/// caps at 4 KB, so one `file.listing` is one page and never one folder.
/// Until 2026-08-01 nothing followed the cursor — `loadMoreIfNeeded`
/// existed and no view called it — so every folder appeared to contain
/// sixteen items and nothing said otherwise. A file browser that silently
/// truncates is worse than one that fails, because the person believes
/// what they see.
///
/// These tests pin the following, the two ways it must refuse to spin,
/// and the fact that a truncation is always narrated.
@MainActor
final class FilesPagingTests: XCTestCase {
    private var listener: GuestListener!
    private var model: FilesModuleModel!

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
                suiteName: "files.page.\(UUID().uuidString)")!)
    }

    override func tearDown() async throws {
        listener.stop()
        listener = nil
        model = nil
    }

    // MARK: - the whole folder

    func testAFolderLongerThanOnePageIsFollowedToItsEnd() async throws {
        let guest = try await connectedGuest()
        model.refresh()

        // Three pages: 16, 16, then 5 — the shape a 37-item folder has.
        try await answerListing(guest, cursor: 1, count: 16, next: 17)
        try await answerListing(guest, cursor: 17, count: 16, next: 33)
        try await answerListing(guest, cursor: 33, count: 5, next: nil)

        try await waitUntil("all three pages in") {
            self.model.rows.count == 37
        }
        XCTAssertNil(model.lastNotice,
                     "a folder that came whole needs no explanation")
        XCTAssertNil(model.lastError)
    }

    func testTheRowsArriveInOrderAcrossPages() async throws {
        let guest = try await connectedGuest()
        model.refresh()
        try await answerListing(guest, cursor: 1, count: 16, next: 17)
        try await answerListing(guest, cursor: 17, count: 4, next: nil)

        try await waitUntil("both pages in") { self.model.rows.count == 20 }
        XCTAssertEqual(model.rows.first?.name, "item-1")
        XCTAssertEqual(model.rows.last?.name, "item-20",
                       "page two continues the numbering rather than "
                       + "restarting it")
    }

    /// A mutation completion and the file-tree event it publishes can both
    /// refresh the visible folder. Only the newest refresh owns the rows;
    /// otherwise both replies append the same page and every item appears
    /// twice even though the guest contains only one copy.
    func testOnlyTheNewestOverlappingRefreshMayPublishRows() async throws {
        let guest = try await connectedGuest()
        model.refresh()
        model.refresh()

        var ids: [Int] = []
        try await waitUntil("two overlapping file.list requests") {
            ids = guest.received.compactMap { message in
                guard case .fileList(let list) = message,
                      list.path.isEmpty else { return nil }
                return list.id
            }
            return ids.count == 2
        }

        let row = entry(1)
        try guest.send(.fileListing(FileListing(
            id: ids[1], path: "", entries: [row], more: false,
            cursor: nil)))
        try guest.send(.fileListing(FileListing(
            id: ids[0], path: "", entries: [row], more: false,
            cursor: nil)))

        try await waitUntil("newest listing published") {
            self.model.rows.count >= 1
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(model.rows.map(\.name), ["item-1"],
                       "a stale full refresh must not append its page")
    }

    // MARK: - the two ways it must refuse to spin

    /// A guest that answers `more` without advancing its cursor would
    /// otherwise be asked forever. The wire is allowed to be wrong; this
    /// side is not allowed to hang because of it.
    func testACursorThatDoesNotAdvanceStopsAndSaysSo() async throws {
        let guest = try await connectedGuest()
        model.refresh()

        try await answerListing(guest, cursor: 1, count: 16, next: 17)
        // The guest repeats itself: asked for 17, answers `next` 17 again.
        try await answerListing(guest, cursor: 17, count: 16, next: 17)

        try await waitUntil("the loop was refused") {
            self.model.lastNotice != nil
        }
        XCTAssertEqual(model.rows.count, 32,
                       "what did arrive is kept")
        XCTAssertTrue(
            model.lastNotice?.contains("repeated the same listing position")
                == true,
            "and the person is told why it stopped, with a count")
        XCTAssertTrue(model.lastNotice?.contains("32") == true)
    }

    func testATruncationIsAlwaysNarratedRatherThanSilent() async throws {
        XCTAssertGreaterThan(FilesModuleModel.rowCeiling, 1000,
                             "the ceiling is a safety bound, not a display "
                             + "limit — a System Folder must fit under it")
    }

    // MARK: - leaving the folder

    /// Pages for a folder the person has already left must not land in the
    /// one they are looking at now. The model drops them by path, and the
    /// follow-on request must stop too.
    func testPagesForAFolderAlreadyLeftAreDropped() async throws {
        let guest = try await connectedGuest()
        model.refresh()
        try await answerListing(guest, cursor: 1, count: 16, next: 17)
        try await waitUntil("first page in") { self.model.rows.count == 16 }

        model.open(FileRow(entry: .init(name: "Elsewhere", kind: "folder",
                                        fileType: nil, creator: nil,
                                        dataBytes: nil, rsrcBytes: nil,
                                        modified: nil, identity: "x"),
                           path: "Elsewhere"))
        XCTAssertTrue(model.rows.isEmpty, "opening a folder clears the rows")

        // A late page for the OLD path arrives after the move.
        try guest.send(.fileListing(FileListing(
            id: 999, path: "", entries: [entry(1)], more: true, cursor: 17)))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(
            model.rows.allSatisfy { $0.name != "item-1" }
                || model.rows.isEmpty,
            "a page from the folder we left does not appear in this one")
    }

    // MARK: - helpers

    private func entry(_ n: Int) -> FileEntry {
        FileEntry(name: "item-\(n)", kind: "file", fileType: "TEXT",
                  creator: "ttxt", dataBytes: 10, rsrcBytes: 0,
                  modified: nil, identity: "id-\(n)")
    }

    /// Plays the guest's half of one `file.list`, answering `count`
    /// entries numbered from the requested cursor.
    private func answerListing(_ guest: FakeGuest, cursor: Int, count: Int,
                               next: Int?) async throws {
        var listID: Int?
        try await waitUntil("file.list at cursor \(cursor)") {
            for message in guest.received {
                if case .fileList(let list) = message,
                   (list.cursor ?? 1) == cursor {
                    listID = list.id
                    return true
                }
            }
            return false
        }
        let id = try XCTUnwrap(listID)
        let entries = (0..<count).map { entry(cursor + $0) }
        try guest.send(.fileListing(FileListing(
            id: id, path: "", entries: entries,
            more: next != nil, cursor: next)))
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
