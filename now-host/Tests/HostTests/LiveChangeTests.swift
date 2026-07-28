import XCTest
@testable import Host

/// Drives a REAL classic Mac through the whole change surface: opt-in,
/// because it needs the machine on the other end and the host app not
/// holding the port.
///
///     NOW_LIVE=1 swift test --filter LiveChangeTests
///
/// What this is actually for: every claim in this feature that cannot be
/// checked on this side of the wire. That the volume's Trash is where
/// FindFolder says it is. That an item moved into it can be moved back
/// out. That a second delete of the same name lands under a different
/// one rather than failing. None of that is provable in a unit test —
/// it is a claim about a file system on another machine.
@MainActor
final class LiveChangeTests: XCTestCase {
    private var listener: GuestListener!
    /// Everything happens inside one folder we make, so a failure part
    /// way through leaves nothing of ours anywhere else.
    private let root = "NOW Change Test"

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["NOW_LIVE"] != nil,
                          "set NOW_LIVE=1 to run against a real machine")
        let port = env["NOW_LIVE_PORT"].flatMap { UInt16($0) } ?? 5250
        listener = GuestListener(
            identity: .init(version: "0.1-live", name: "Change Harness"))
        listener.start(port: port)
        print("=== waiting for a Mac on port \(port) ===")
    }

    override func tearDown() async throws {
        listener?.stop()
        listener = nil
    }

    private func waitForGuest(_ seconds: TimeInterval = 120) async throws
        -> String {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if case .connected(let name) = listener.state {
                try await Task.sleep(nanoseconds: 500_000_000)
                return name
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw XCTSkip("no Mac connected")
    }

    // MARK: - Wire helpers, each failing loudly rather than returning nil

    private func mkdir(_ path: String) async throws -> FileResult {
        try await change { self.listener.makeFolder(path: path,
                                                    completion: $0) }
    }

    private func move(_ from: String, _ to: String) async throws
        -> FileResult {
        try await change { self.listener.moveFile(from: from, to: to,
                                                  completion: $0) }
    }

    private func trash(_ path: String) async throws -> FileResult {
        try await change { self.listener.trashFile(path: path,
                                                   completion: $0) }
    }

    private func restore(_ trashedAs: String, _ to: String) async throws
        -> FileResult {
        try await change { self.listener.restoreFile(trashedAs: trashedAs,
                                                     to: to, completion: $0) }
    }

    private func change(
        _ call: (@escaping (Result<FileResult,
                                   GuestListener.FileFailure>) -> Void) -> Void)
        async throws -> FileResult {
        try await withCheckedThrowingContinuation { continuation in
            call { result in
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }

    private func names(in path: String) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            listener.listFiles(path: path) { result in
                switch result {
                case .success(let listing):
                    continuation.resume(
                        returning: listing.entries.map(\.name))
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// The whole arc in order, because these operations are only
    /// meaningful against each other: a restore is only a restore if the
    /// listing shows the item back where it started.
    func testTheChangeSurfaceAgainstARealVolume() async throws {
        let name = try await waitForGuest()
        print("=== connected: \(name) ===")

        // Clean slate, tolerating a leftover from a failed earlier run.
        _ = try? await trash(root)

        _ = try await mkdir(root)
        var top = try await names(in: "")
        XCTAssertTrue(top.contains(root),
                      "the new folder should be listed in the share")

        _ = try await mkdir("\(root):Inner")
        _ = try await mkdir("\(root):Notes")

        // A rename is a move that keeps its folder.
        _ = try await move("\(root):Notes", "\(root):Renamed")
        var listed = try await names(in: root)
        XCTAssertTrue(listed.contains("Renamed"), "renamed item missing")
        XCTAssertFalse(listed.contains("Notes"), "old name still listed")

        // A move that keeps its name but changes its folder.
        _ = try await move("\(root):Renamed", "\(root):Inner:Renamed")
        listed = try await names(in: root)
        XCTAssertFalse(listed.contains("Renamed"),
                       "moved item still in the old folder")
        var inner = try await names(in: "\(root):Inner")
        XCTAssertTrue(inner.contains("Renamed"),
                      "moved item not in the new folder")

        // Moving onto something that exists is refused, not silent.
        _ = try await mkdir("\(root):Renamed")
        do {
            _ = try await move("\(root):Inner:Renamed", "\(root):Renamed")
            XCTFail("a colliding move should have been refused")
        } catch let error as GuestListener.FileFailure {
            XCTAssertEqual(error.code, "exists")
        }

        // Missing parents are not invented.
        do {
            _ = try await move("\(root):Renamed",
                               "\(root):Nowhere:Renamed")
            XCTFail("a move into a missing folder should have been refused")
        } catch let error as GuestListener.FileFailure {
            XCTAssertEqual(error.code, "not-found")
        }

        // The claim this whole test exists for: the Trash is real, and
        // an item can come back out of it.
        let trashed = try await trash("\(root):Renamed")
        let landedAs = try XCTUnwrap(trashed.trashedAs,
                                     "trash must report where it landed")
        print("=== trashed as \"\(landedAs)\" ===")
        listed = try await names(in: root)
        XCTAssertFalse(listed.contains("Renamed"),
                       "trashed item still listed in the share")

        _ = try await restore(landedAs, "\(root):Renamed")
        listed = try await names(in: root)
        XCTAssertTrue(listed.contains("Renamed"),
                      "restored item did not come back")

        // Two items of the same name deleted from different folders: the
        // second must land under a different name, not fail.
        let firstTrash = try await trash("\(root):Renamed")
        let secondTrash = try await trash("\(root):Inner:Renamed")
        let first = try XCTUnwrap(firstTrash.trashedAs)
        let second = try XCTUnwrap(secondTrash.trashedAs)
        print("=== same name twice: \"\(first)\" then \"\(second)\" ===")
        XCTAssertNotEqual(first, second,
                          "the second delete must not reuse the name")

        // And both come back, to different places.
        _ = try await restore(first, "\(root):Renamed")
        _ = try await restore(second, "\(root):Inner:Renamed")
        listed = try await names(in: root)
        inner = try await names(in: "\(root):Inner")
        XCTAssertTrue(listed.contains("Renamed"))
        XCTAssertTrue(inner.contains("Renamed"))

        // Restoring something the Trash no longer holds says so.
        do {
            _ = try await restore("NOW No Such Item", "\(root):Ghost")
            XCTFail("restoring a missing item should have been refused")
        } catch let error as GuestListener.FileFailure {
            XCTAssertEqual(error.code, "not-found")
        }

        // Leave the volume as we found it.
        _ = try await trash(root)
        top = try await names(in: "")
        XCTAssertFalse(top.contains(root), "test folder left behind")
        print("=== change surface verified on \(name) ===")
    }
}
