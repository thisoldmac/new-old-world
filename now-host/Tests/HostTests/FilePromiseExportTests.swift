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
        XCTAssertEqual(GuestFilePromiseDescriptor.describe(
            row("Project", folder: true)),
            GuestFilePromiseDescriptor(type: .folder,
                                       requiresMacBinary: false))
    }

    func testExtensionlessApplicationsPromiseTheirRealTypeAndForks() {
        let application = FileRow(entry: FileEntry(
            name: "New Old World", kind: "file", fileType: "APPL",
            creator: "NOWo", dataBytes: 4096, rsrcBytes: 2048,
            modified: nil, identity: "app"), path: "New Old World")

        let promise = GuestFilePromiseDescriptor.describe(application)

        XCTAssertEqual(promise.type, .application)
        XCTAssertTrue(promise.requiresMacBinary,
                      "the lazy fetch must preserve Finder metadata and forks")
    }

    func testExtensionStillWinsWhenItIdentifiesAModernDocument() {
        let promise = GuestFilePromiseDescriptor.describe(row("Notes.txt"))
        XCTAssertEqual(promise.type, .plainText)
        XCTAssertTrue(promise.requiresMacBinary,
                      "type and creator metadata still need MacBinary")
    }

    func testMultiplePromisesUseTheSingleTransferLaneInOrder() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var started: [String] = []
        var pending: [(URL, (Result<Void, Error>) -> Void)] = []
        let exporter = GuestFilePromiseExporter(
            listPage: { _, _, done in
                done(.failure(TestFailure.unexpectedList))
            },
            fetchFile: { row, url, done in
                started.append(row.name)
                pending.append((url, done))
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
        var next = pending.removeFirst()
        try Data("One".utf8).write(to: next.0)
        next.1(.success(()))
        XCTAssertEqual(started, ["One", "Two"])
        XCTAssertEqual(completed, ["One"])
        next = pending.removeFirst()
        try Data("Two".utf8).write(to: next.0)
        next.1(.success(()))
        XCTAssertEqual(completed, ["One", "Two"])
    }

    func testAFolderPromiseBuildsTheWholeRecursiveTree() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Project")
        let listings: [String: [FileEntry]] = [
            "Project:Source": [entry("main.c"),
                               entry("Empty", folder: true)],
            "Project:Source:Empty": [],
        ]
        var projectPages = 0
        let exporter = GuestFilePromiseExporter(
            listPage: { path, cursor, done in
                if path == "Project" {
                    projectPages += 1
                    if cursor == nil {
                        done(.success(FileListing(
                            id: 1, path: path, entries: [self.entry("Read Me")],
                            more: true, cursor: 2)))
                    } else {
                        XCTAssertEqual(cursor, 2)
                        done(.success(FileListing(
                            id: 2, path: path,
                            entries: [self.entry("Source", folder: true)],
                            more: false, cursor: nil)))
                    }
                    return
                }
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
        XCTAssertEqual(projectPages, 2, "all listing pages must be followed")
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

    func testAnOversizedFolderIsRefusedBeforeAnyChildTransfer() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Project")
        let entries = (0...GuestFilePromiseExporter.itemLimit).map {
            entry("Item \($0)")
        }
        var fetched = 0
        let exporter = GuestFilePromiseExporter(
            listPage: { path, _, done in
                done(.success(FileListing(
                    id: 1, path: path, entries: entries,
                    more: false, cursor: nil)))
            },
            fetchFile: { _, _, done in
                fetched += 1
                done(.success(()))
            })
        var result: Result<Void, Error>?

        exporter.enqueue(row("Project", folder: true), to: destination) {
            result = $0
        }

        guard case .failure = try XCTUnwrap(result) else {
            return XCTFail("an oversized folder promise reported success")
        }
        XCTAssertEqual(fetched, 0,
                       "the bound must apply before child transfers begin")
    }

    func testMaterializationFailureIsReportedOutsideAppKitCompletion() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Native App")
        var visibleError: String?
        var completionError: Error?
        let exporter = GuestFilePromiseExporter(
            listPage: { _, _, done in
                done(.failure(TestFailure.unexpectedList))
            },
            fetchFile: { _, url, done in
                try? Data("MacBinary envelope".utf8).write(to: url)
                done(.failure(TestFailure.materializationFailed))
            },
            onFailure: { visibleError = $0.localizedDescription })

        exporter.enqueue(row("Native App"), to: destination) { result in
            if case .failure(let error) = result { completionError = error }
        }

        XCTAssertEqual(completionError?.localizedDescription,
                       "could not reconstruct the promised file")
        XCTAssertEqual(visibleError,
                       "Could not export Native App: "
                        + "could not reconstruct the promised file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path),
                       "a MacBinary envelope must never survive as the promise")
    }

    func testFilePromiseNeverOverwritesOrDeletesALateDestination() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Document")
        var staged: URL?
        var finishFetch: ((Result<Void, Error>) -> Void)?
        let exporter = GuestFilePromiseExporter(
            listPage: { _, _, done in
                done(.failure(TestFailure.unexpectedList))
            },
            fetchFile: { _, url, done in
                staged = url
                finishFetch = done
            })
        var result: Result<Void, Error>?

        exporter.enqueue(row("Document"), to: destination) { result = $0 }
        try Data("guest".utf8).write(to: try XCTUnwrap(staged))
        try Data("mine".utf8).write(to: destination)
        try XCTUnwrap(finishFetch)(.success(()))

        guard case .failure = try XCTUnwrap(result) else {
            return XCTFail("a late destination was overwritten")
        }
        XCTAssertEqual(try Data(contentsOf: destination), Data("mine".utf8))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: try XCTUnwrap(staged).path),
            "only the exporter-owned staging file should be cleaned up")
    }

    func testCancelledPromiseCleansLateStagingWithoutPublishing() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Document")
        var staged: URL?
        var finishFetch: ((Result<Void, Error>) -> Void)?
        var completions = 0
        var result: Result<Void, Error>?
        let exporter = GuestFilePromiseExporter(
            listPage: { _, _, done in
                done(.failure(TestFailure.unexpectedList))
            },
            fetchFile: { _, url, done in
                staged = url
                finishFetch = done
            })

        exporter.enqueue(row("Document"), to: destination) {
            completions += 1
            result = $0
        }
        exporter.cancelAll(reason: "The guest changed.")
        try Data("late".utf8).write(to: try XCTUnwrap(staged))
        try XCTUnwrap(finishFetch)(.success(()))

        guard case .failure = try XCTUnwrap(result) else {
            return XCTFail("cancellation reported success")
        }
        XCTAssertEqual(completions, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: try XCTUnwrap(staged).path))
    }

    private enum TestFailure: LocalizedError {
        case unexpectedList
        case unknownPath(String)
        case transferFailed
        case materializationFailed

        var errorDescription: String? {
            switch self {
            case .unexpectedList: return "unexpected listing"
            case .unknownPath(let path): return "unknown path \(path)"
            case .transferFailed: return "transfer failed"
            case .materializationFailed:
                return "could not reconstruct the promised file"
            }
        }
    }
}
