import Foundation
import XCTest
@testable import Host

final class ProjectStoreTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-project-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private let document = Data("""
        CKPROJECT 1
        id=0123456789abcdef0123456789abcdef
        name=Memory Meter
        target=application
        configuration=debug
        toolchain=mpw@3.6
        product=Build/Memory Meter
        file=Sources/Main.c
        """.utf8)

    func testContractFixtureParsesAndTraversalFixtureIsRefused() throws {
        let base = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contract/project/fixtures")
        XCTAssertEqual(try CKProjectDocument.parse(
            Data(contentsOf: base.appendingPathComponent("minimal.ckp"))).name,
                       "Memory Meter")
        XCTAssertThrowsError(try CKProjectDocument.parse(
            Data(contentsOf: base.appendingPathComponent("invalid-traversal.ckp"))))
    }

    func testCreateAndApplyProduceRecoverableGitHistory() throws {
        let root = try root()
        let store = try ProjectStore(root: root)
        let created = try store.create(
            name: "Memory Meter", home: .host, projectDocument: document,
            files: [ProjectFileChange(path: "Sources/Main.c",
                                      contents: Data("int main(void) { return 0; }".utf8))])
        XCTAssertEqual(created.revision, 1)
        XCTAssertEqual(created.home, .host)
        XCTAssertEqual(try store.read(projectID: created.projectID,
                                      path: "Sources/Main.c"),
                       Data("int main(void) { return 0; }".utf8))

        let changed = try store.apply(
            projectID: created.projectID, expectedRevision: 1,
            changes: [ProjectFileChange(path: "Sources/Main.c",
                                        expectedDigest: ProjectDigest.sha256(
                                            Data("int main(void) { return 0; }".utf8)),
                                        contents: Data("int main(void) { return 1; }".utf8))],
            message: "Change return value")
        XCTAssertEqual(changed.revision, 2)
        XCTAssertEqual(try store.history(projectID: created.projectID).count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            root.appendingPathComponent("Repositories")
                .appendingPathComponent(created.projectID.rawValue + ".git")
                .appendingPathComponent("objects/\(changed.commit.prefix(2))/\(changed.commit.dropFirst(2))").path))

        let reopened = try ProjectStore(root: root)
        XCTAssertEqual(try reopened.status(projectID: created.projectID).revision, 2)
        XCTAssertEqual(try reopened.read(projectID: created.projectID,
                                         path: "Sources/Main.c"),
                       Data("int main(void) { return 1; }".utf8))
    }

    func testStaleRevisionAndPriorDigestLeaveWholeBatchUntouched() throws {
        let store = try ProjectStore(root: try root())
        let created = try store.create(
            name: "Atomic", home: .host, projectDocument: document,
            files: [ProjectFileChange(path: "A", contents: Data("old".utf8)),
                    ProjectFileChange(path: "B", contents: Data("old".utf8))])

        XCTAssertThrowsError(try store.apply(
            projectID: created.projectID, expectedRevision: 0,
            changes: [ProjectFileChange(path: "A", contents: Data("new".utf8))],
            message: "stale")) { error in
                XCTAssertEqual(error as? ProjectStoreError,
                               .revisionConflict(expected: 0, current: 1))
        }
        XCTAssertThrowsError(try store.apply(
            projectID: created.projectID, expectedRevision: 1,
            changes: [
                ProjectFileChange(path: "A", contents: Data("new".utf8)),
                ProjectFileChange(path: "B", expectedDigest: String(repeating: "0", count: 64),
                                  contents: Data("new".utf8)),
            ], message: "bad prior digest"))
        XCTAssertEqual(try store.read(projectID: created.projectID, path: "A"),
                       Data("old".utf8))
        XCTAssertEqual(try store.read(projectID: created.projectID, path: "B"),
                       Data("old".utf8))
        XCTAssertEqual(try store.status(projectID: created.projectID).revision, 1)
    }

    func testPathsAndSymlinkEscapesAreRefused() throws {
        let root = try root()
        let store = try ProjectStore(root: root)
        let created = try store.create(name: "Safe", home: .host,
                                       projectDocument: document, files: [])
        for path in ["/tmp/out", "../out", "a/../out", "a//b", "a\\b", "."] {
            XCTAssertThrowsError(try store.apply(
                projectID: created.projectID, expectedRevision: 1,
                changes: [ProjectFileChange(path: path, contents: Data())],
                message: "escape"), path)
        }

        let working = store.testingWorkingURL(projectID: created.projectID)
        try FileManager.default.createSymbolicLink(
            at: working.appendingPathComponent("link"),
            withDestinationURL: root.deletingLastPathComponent())
        XCTAssertThrowsError(try store.read(projectID: created.projectID,
                                            path: "link/anything"))
    }

    func testGuestWorkspaceResumesAndOnlyUnpromotedCopyCannotBeDiscarded() throws {
        let root = try root()
        let store = try ProjectStore(root: root)
        let created = try store.create(name: "Guest Source", home: .guest,
                                       guestDigest: String(repeating: "a", count: 64),
                                       projectDocument: document,
                                       files: [ProjectFileChange(path: "Sources/Main.c",
                                                                 contents: Data("old".utf8))])
        let workspace = try store.openWorkspace(projectID: created.projectID)
        let edited = try store.apply(
            workspaceID: workspace.workspaceID,
            expectedCommit: workspace.currentCommit,
            changes: [ProjectFileChange(path: "Sources/Main.c",
                                        contents: Data("agent".utf8))],
            message: "Agent edit")

        let reopened = try ProjectStore(root: root)
        XCTAssertEqual(try reopened.resumeWorkspace(
            workspaceID: workspace.workspaceID).currentCommit, edited.currentCommit)
        XCTAssertThrowsError(try reopened.discardWorkspace(
            workspaceID: workspace.workspaceID)) { error in
                XCTAssertEqual(error as? ProjectStoreError,
                               .unpromotedWorkspace)
        }
    }
}
