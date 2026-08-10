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
        type=APPL
        creator=MMTR
        file=Sources/Main.c
        file-info=TEXT|MPS |0000|Sources/Main.c
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
        XCTAssertThrowsError(try CKProjectDocument.parse(Data("""
            CKPROJECT 1
            id=0123456789abcdef0123456789abcdef
            name=Bad Source
            target=application
            configuration=debug
            toolchain=mpw@3.6
            product=Build/Product
            type=APPL
            creator=TEST
            file=Build/Generated.c
            """.utf8)))
    }

    func testProjectFileIdentityIsExplicitAndPathMayContainPipe() throws {
        let parsed = try CKProjectDocument.parse(Data("""
            CKPROJECT 1
            id=0123456789abcdef0123456789abcdef
            name=Classic Files
            target=application
            configuration=debug
            toolchain=mpw@3.6
            product=Build/Product
            type=APPL
            creator=TEST
            file=Sources/Main|Debug.c
            file-info=TEXT|MPS |4000|Sources/Main|Debug.c
            """.utf8))
        XCTAssertEqual(parsed.fileIdentities["Sources/Main|Debug.c"],
                       .init(path: "Sources/Main|Debug.c", type: "TEXT",
                             creator: "MPS ", finderFlags: 0x4000))
    }

    func testProjectFileIdentityRefusesUnknownDuplicateAndMalformedRows() throws {
        func document(_ rows: String) -> Data {
            Data("""
                CKPROJECT 1
                id=0123456789abcdef0123456789abcdef
                name=Classic Files
                target=application
                configuration=debug
                toolchain=mpw@3.6
                product=Build/Product
                type=APPL
                creator=TEST
                file=Sources/Main.c
                \(rows)
                """.utf8)
        }
        XCTAssertThrowsError(try CKProjectDocument.parse(document(
            "file-info=TEXT|MPS |0000|Sources/Other.c")))
        XCTAssertThrowsError(try CKProjectDocument.parse(document("""
            file-info=TEXT|MPS |0000|Sources/Main.c
            file-info=TEXT|MPS |0000|Sources/Main.c
            """)))
        XCTAssertThrowsError(try CKProjectDocument.parse(document(
            "file-info=TEXT|MPS |ZZZZ|Sources/Main.c")))
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

    func testSystemGitAcceptsTheEmbeddedHistoryAsAStandardRepository() throws {
        let root = try root()
        let store = try ProjectStore(root: root)
        let created = try store.create(
            name: "Git Oracle", home: .host, projectDocument: document,
            files: [ProjectFileChange(path: "Sources/Main.c",
                                      contents: Data("int x;".utf8))])
        _ = try store.apply(
            projectID: created.projectID, expectedRevision: 1,
            changes: [ProjectFileChange(path: "Sources/Main.c",
                                        contents: Data("int y;".utf8))],
            message: "Second revision")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "--git-dir", root.appendingPathComponent("Repositories")
                .appendingPathComponent(created.projectID.rawValue + ".git").path,
            "fsck", "--strict",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(),
                          as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, text)
    }

    func testGitCommitCarriesRecoverableClassicFileArchive() throws {
        let root = try root()
        let store = try ProjectStore(root: root)
        let dataFork = Data("source".utf8)
        let resourceFork = Data("resource".utf8)
        let created = try store.create(
            name: "Archived Forks", home: .host, projectDocument: document,
            files: [
                .init(path: "Sources/Main.c", type: "TEXT", creator: "MPS ",
                      finderFlags: 0x4000, contents: dataFork),
                .init(path: "Sources/Main.c", fork: .resource,
                      contents: resourceFork),
            ])
        let repository = root.appendingPathComponent("Repositories")
            .appendingPathComponent(created.projectID.rawValue + ".git")
        let index = try gitObject(
            gitDirectory: repository,
            specification: "\(created.commit):.now-classic/index.json")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: index) as? [String: Any])
        let files = try XCTUnwrap(object["files"] as? [[String: Any]])
        let archived = try XCTUnwrap(files.first {
            $0["path"] as? String == "Sources/Main.c"
        })
        XCTAssertEqual(archived["creator"] as? String, "MPS ")
        XCTAssertEqual(archived["finderFlags"] as? Int, 16384)

        let packageName = ProjectDigest.sha256(Data("Sources/Main.c".utf8)) + ".bin"
        let package = try gitObject(
            gitDirectory: repository,
            specification: "\(created.commit):.now-classic/files/\(packageName)")
        let decoded = try MacBinaryFile.decode(package)
        XCTAssertEqual(decoded.dataFork, dataFork)
        XCTAssertEqual(decoded.resourceFork, resourceFork)
        XCTAssertEqual(decoded.type, "TEXT")
        XCTAssertEqual(decoded.creator, "MPS ")
        XCTAssertEqual(decoded.finderFlags, 0x4000)
    }

    private func gitObject(gitDirectory: URL, specification: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--git-dir", gitDirectory.path, "show", specification]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0,
                       String(decoding: errorData, as: UTF8.self))
        return data
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

    func testCandidateBindsExactManifestAndRequiresSuccessfulBuild() throws {
        let store = try ProjectStore(root: try root())
        let created = try store.create(
            name: "Candidate", home: .host, projectDocument: document,
            files: [ProjectFileChange(path: "Sources/Main.c",
                                      contents: Data("source".utf8))])
        let candidate = try store.stageCandidate(projectID: created.projectID)

        XCTAssertEqual(candidate.lifecycle, .hostStaged)
        XCTAssertEqual(candidate.receipt.manifest.map(\.path),
                       ["Project.ckp", "Sources/Main.c"])
        let encoded = try store.candidateFile(
            candidateID: candidate.receipt.candidateID,
            path: "Sources/Main.c")
        XCTAssertEqual(try MacBinaryFile.decode(encoded).dataFork,
                       Data("source".utf8))
        XCTAssertThrowsError(try store.promoteCandidate(
            candidateID: candidate.receipt.candidateID,
            currentGuestDigest: nil)) { error in
                XCTAssertEqual(error as? ProjectStoreError, .candidateNotBuilt)
            }

        XCTAssertEqual(try store.recordGuestTransfer(
            candidateID: candidate.receipt.candidateID).lifecycle,
                       .guestTransferred)
        XCTAssertEqual(try store.recordGuestVerification(
            candidateID: candidate.receipt.candidateID,
            digest: candidate.receipt.contentDigest).lifecycle,
                       .guestVerified)
        let built = try store.recordBuild(
            candidateID: candidate.receipt.candidateID,
            buildID: "build-0123456789abcdef", succeeded: true)
        XCTAssertEqual(built.lifecycle, .buildSucceeded)
        let promoted = try store.promoteCandidate(
            candidateID: candidate.receipt.candidateID,
            currentGuestDigest: nil)
        XCTAssertEqual(promoted.home, .host)
        XCTAssertEqual(try store.candidate(
            candidateID: candidate.receipt.candidateID).lifecycle, .promoted)
    }

    func testBuildArtifactsDoNotChangeSourceDigestOrCandidateManifest() throws {
        let store = try ProjectStore(root: try root())
        let created = try store.create(
            name: "Artifacts", home: .host, projectDocument: document,
            files: [ProjectFileChange(path: "Sources/Main.c",
                                      contents: Data("source".utf8))])
        let working = store.testingWorkingURL(projectID: created.projectID)
        let before = try ProjectDigest.tree(at: working)
        let build = working.appendingPathComponent("Build")
        try FileManager.default.createDirectory(at: build,
                                                withIntermediateDirectories: true)
        try Data("generated".utf8).write(to: build.appendingPathComponent("Product"))
        XCTAssertEqual(try ProjectDigest.tree(at: working), before)
        XCTAssertEqual(try store.stageCandidate(projectID: created.projectID)
            .receipt.manifest.map(\.path), ["Project.ckp", "Sources/Main.c"])
    }

    func testCandidatePreservesBothForksAndFinderIdentity() throws {
        let store = try ProjectStore(root: try root())
        let created = try store.create(
            name: "Forked Source", home: .host, projectDocument: document,
            files: [ProjectFileChange(path: "Sources/Main.c",
                                      contents: Data("source".utf8))])
        let source = store.testingWorkingURL(projectID: created.projectID)
            .appendingPathComponent("Sources/Main.c")
        let resourceFork = URL(fileURLWithPath: source.path + "/..namedfork/rsrc")
        try Data("resource".utf8).write(to: resourceFork)

        let candidate = try store.stageCandidate(projectID: created.projectID)
        let entry = try XCTUnwrap(candidate.receipt.manifest.first {
            $0.path == "Sources/Main.c"
        })
        XCTAssertEqual(entry.resourceBytes, 8)
        XCTAssertEqual(entry.type, "TEXT")
        XCTAssertEqual(entry.creator, "MPS ")
        XCTAssertEqual(entry.finderFlags, 0)
        let encoded = try store.candidateFile(
            candidateID: candidate.receipt.candidateID,
            path: "Sources/Main.c")
        let decoded = try MacBinaryFile.decode(encoded)
        XCTAssertEqual(decoded.dataFork, Data("source".utf8))
        XCTAssertEqual(decoded.resourceFork, Data("resource".utf8))
        XCTAssertEqual(decoded.type, "TEXT")
        XCTAssertEqual(decoded.creator, "MPS ")
        XCTAssertEqual(decoded.finderFlags, 0)
    }

    func testGuestImportCreatesVerifiedMirrorAndPreservesWorkspaceOnRefresh() throws {
        let store = try ProjectStore(root: try root())
        let first = Data("guest one".utf8)
        let firstDigest = try snapshotDigest(document: document,
                                             path: "Sources/Main.c", data: first)
        let imported = try store.importGuestSnapshot(
            projectDocument: document,
            files: [.init(path: "Sources/Main.c", contents: first)],
            guestDigest: firstDigest)
        XCTAssertEqual(imported.home, .guest)
        XCTAssertEqual(try store.status(projectID: imported.projectID).guestState,
                       .verified)
        let unchanged = try store.importGuestSnapshot(
            projectDocument: document,
            files: [.init(path: "Sources/Main.c", contents: first)],
            guestDigest: firstDigest)
        XCTAssertEqual(unchanged.revision, imported.revision)

        let workspace = try store.openWorkspace(projectID: imported.projectID)
        let second = Data("human edit".utf8)
        let secondDigest = try snapshotDigest(document: document,
                                              path: "Sources/Main.c", data: second)
        let refreshed = try store.importGuestSnapshot(
            projectDocument: document,
            files: [.init(path: "Sources/Main.c", contents: second)],
            guestDigest: secondDigest)
        XCTAssertEqual(refreshed.revision, imported.revision + 1)
        XCTAssertEqual(try store.status(projectID: imported.projectID).guestState,
                       .divergent)
        XCTAssertEqual(try store.resumeWorkspace(
            workspaceID: workspace.workspaceID).baseGuestDigest, firstDigest)
        XCTAssertEqual(try store.read(projectID: imported.projectID,
                                      path: "Sources/Main.c"), second)
    }

    private func snapshotDigest(document: Data, path: String, data: Data) throws
        -> String {
        let snapshot = try root()
        try document.write(to: snapshot.appendingPathComponent("Project.ckp"))
        let destination = snapshot.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try data.write(to: destination)
        return try ProjectDigest.tree(at: snapshot)
    }

    func testGuestPromotionRefusesDivergenceAndPreservesWorkspace() throws {
        let store = try ProjectStore(root: try root())
        let baseDigest = String(repeating: "a", count: 64)
        let created = try store.create(
            name: "Guest Candidate", home: .guest, guestDigest: baseDigest,
            projectDocument: document,
            files: [ProjectFileChange(path: "Sources/Main.c",
                                      contents: Data("guest".utf8))])
        let workspace = try store.openWorkspace(projectID: created.projectID)
        let edited = try store.apply(
            workspaceID: workspace.workspaceID,
            expectedCommit: workspace.currentCommit,
            changes: [ProjectFileChange(path: "Sources/Main.c",
                                        contents: Data("agent".utf8))],
            message: "Agent edit")
        let candidate = try store.stageCandidate(
            projectID: created.projectID, workspaceID: workspace.workspaceID)
        _ = try store.recordGuestTransfer(
            candidateID: candidate.receipt.candidateID)
        _ = try store.recordGuestVerification(
            candidateID: candidate.receipt.candidateID,
            digest: candidate.receipt.contentDigest)
        _ = try store.recordBuild(candidateID: candidate.receipt.candidateID,
                                  buildID: "build-0123456789abcdef",
                                  succeeded: true)
        let changedDigest = String(repeating: "b", count: 64)

        XCTAssertThrowsError(try store.promoteCandidate(
            candidateID: candidate.receipt.candidateID,
            currentGuestDigest: changedDigest)) { error in
                XCTAssertEqual(error as? ProjectStoreError,
                               .guestDiverged(base: baseDigest,
                                              current: changedDigest))
            }
        XCTAssertEqual(try store.status(projectID: created.projectID).guestState,
                       .divergent)
        XCTAssertEqual(try store.resumeWorkspace(
            workspaceID: workspace.workspaceID).currentCommit,
                       edited.currentCommit)
        XCTAssertEqual(try store.read(projectID: created.projectID,
                                      path: "Sources/Main.c"),
                       Data("guest".utf8))
    }

    func testVerifiedGuestPromotionAdvancesMirrorAndWorkspaceLifecycle() throws {
        let store = try ProjectStore(root: try root())
        let baseDigest = String(repeating: "c", count: 64)
        let created = try store.create(
            name: "Guest Candidate", home: .guest, guestDigest: baseDigest,
            projectDocument: document,
            files: [ProjectFileChange(path: "Sources/Main.c",
                                      contents: Data("guest".utf8))])
        let workspace = try store.openWorkspace(projectID: created.projectID)
        let edited = try store.apply(
            workspaceID: workspace.workspaceID,
            expectedCommit: workspace.currentCommit,
            changes: [ProjectFileChange(path: "Sources/Main.c",
                                        contents: Data("accepted".utf8))],
            message: "Accepted agent edit")
        let candidate = try store.stageCandidate(
            projectID: created.projectID, workspaceID: workspace.workspaceID)
        _ = try store.recordGuestTransfer(
            candidateID: candidate.receipt.candidateID)
        _ = try store.recordGuestVerification(
            candidateID: candidate.receipt.candidateID,
            digest: candidate.receipt.contentDigest)
        _ = try store.recordBuild(candidateID: candidate.receipt.candidateID,
                                  buildID: "build-fedcba9876543210",
                                  succeeded: true)
        let receipt = try store.promoteCandidate(
            candidateID: candidate.receipt.candidateID,
            currentGuestDigest: baseDigest)

        XCTAssertEqual(receipt.promotedCommit, edited.currentCommit)
        XCTAssertEqual(try store.read(projectID: created.projectID,
                                      path: "Sources/Main.c"),
                       Data("accepted".utf8))
        XCTAssertEqual(try store.resumeWorkspace(
            workspaceID: workspace.workspaceID).lifecycle, .promoted)
        XCTAssertEqual(try store.status(projectID: created.projectID).guestState,
                       .verified)
    }
}
