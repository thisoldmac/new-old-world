import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import Host

@MainActor
final class FilePromiseExportTests: XCTestCase {
    private func entry(_ name: String, folder: Bool = false) -> FileEntry {
        FileEntry(name: name, kind: folder ? "folder" : "file",
                  fileType: folder ? nil : "TEXT", creator: "ttxt",
                  dataBytes: folder ? nil : 4, rsrcBytes: folder ? nil : 0,
                  modified: nil, identity: name)
    }

    private func row(_ name: String, folder: Bool = false,
                     path: String? = nil) -> FileRow {
        FileRow(entry: entry(name, folder: folder), path: path ?? name)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-promise-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    func testFolderRowsPromiseFoldersRatherThanText() {
        XCTAssertEqual(GuestFilePromiseType.type(
            for: row("Project", folder: true)), .folder)
    }

    func testMultiplePromisesUseTheSingleTransferLaneInOrder() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var started: [String] = []
        var pending: [(Result<Void, Error>) -> Void] = []
        let exporter = GuestFilePromiseExporter(
            listPage: { _, _, done in
                done(.failure(TestFailure.unexpectedList))
            },
            fetchFile: { row, _, done in
                started.append(row.name)
                pending.append(done)
            })
        var completed: [String] = []

        exporter.enqueue(
            row("One"), to: root.appendingPathComponent("One")) { result in
                if case .success = result { completed.append("One") }
            }
        exporter.enqueue(
            row("Two"), to: root.appendingPathComponent("Two")) { result in
                if case .success = result { completed.append("Two") }
            }

        XCTAssertEqual(started, ["One"],
                       "the second promise must wait for the first")
        pending.removeFirst()(.success(()))
        XCTAssertEqual(started, ["One", "Two"])
        XCTAssertEqual(completed, ["One"])
        pending.removeFirst()(.success(()))
        XCTAssertEqual(completed, ["One", "Two"])
    }

    func testAFolderPromiseBuildsTheWholeRecursiveTree() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Project")
        let listings: [String: [FileEntry]] = [
            "Project": [entry("Read Me"), entry("Source", folder: true)],
            "Project:Source": [entry("main.c"),
                               entry("Empty", folder: true)],
            "Project:Source:Empty": [],
        ]
        let exporter = GuestFilePromiseExporter(
            listPage: { path, cursor, done in
                XCTAssertNil(cursor)
                guard let entries = listings[path] else {
                    done(.failure(TestFailure.unknownPath(path)))
                    return
                }
                done(.success(FileListing(
                    id: 1, path: path, entries: entries,
                    more: false, cursor: nil)))
            },
            fetchFile: { row, url, done in
                do {
                    try Data(row.name.utf8).write(to: url)
                    done(.success(()))
                } catch {
                    done(.failure(error))
                }
            })
        var result: Result<Void, Error>?

        exporter.enqueue(row("Project", folder: true), to: destination) {
            result = $0
        }

        guard case .success = try XCTUnwrap(result) else {
            return XCTFail("folder promise failed: \(String(describing: result))")
        }
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("Read Me"),
                       encoding: .utf8),
            "Read Me")
        XCTAssertEqual(
            try String(contentsOf: destination
                .appendingPathComponent("Source/main.c"), encoding: .utf8),
            "main.c")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("Source/Empty").path,
            isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue, "empty folders must survive")
    }

    func testAFailedFolderPromiseRemovesItsPartialTree() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Project")
        let exporter = GuestFilePromiseExporter(
            listPage: { path, _, done in
                done(.success(FileListing(
                    id: 1, path: path, entries: [self.entry("Half")],
                    more: false, cursor: nil)))
            },
            fetchFile: { _, url, done in
                try? Data("partial".utf8).write(to: url)
                done(.failure(TestFailure.transferFailed))
            })
        var result: Result<Void, Error>?

        exporter.enqueue(row("Project", folder: true), to: destination) {
            result = $0
        }

        guard case .failure = try XCTUnwrap(result) else {
            return XCTFail("a failed child transfer reported success")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path),
                       "a partial folder must not look complete")
    }

    func testARefusedFolderPromiseDoesNotDeleteAnExistingFolder() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Project")
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: false)
        let sentinel = destination.appendingPathComponent("Keep")
        try Data("mine".utf8).write(to: sentinel)
        let exporter = GuestFilePromiseExporter(
            listPage: { _, _, done in
                done(.failure(TestFailure.unexpectedList))
            },
            fetchFile: { _, _, done in
                done(.failure(TestFailure.transferFailed))
            })
        var result: Result<Void, Error>?

        exporter.enqueue(row("Project", folder: true), to: destination) {
            result = $0
        }

        guard case .failure = try XCTUnwrap(result) else {
            return XCTFail("an existing destination accepted the promise")
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("mine".utf8),
                       "cleanup must only remove a folder it created")
    }

    private enum TestFailure: LocalizedError {
        case unexpectedList
        case unknownPath(String)
        case transferFailed

        var errorDescription: String? {
            switch self {
            case .unexpectedList: return "unexpected listing"
            case .unknownPath(let path): return "unknown path \(path)"
            case .transferFailed: return "transfer failed"
            }
        }
    }
}
