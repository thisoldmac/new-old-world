import Foundation

/// The single host-owned authority boundary for projects and agent workspaces.
/// Callers hold opaque IDs; URLs never cross this API.
final class ProjectStore {
    private struct CatalogRecord: Codable {
        var projectID: ProjectID
        var name: String
        var home: ProjectHome
        var formatVersion: Int
        var revision: Int
        var currentCommit: String
        var contentDigest: String
        var verifiedGuestDigest: String?
        var guestState: GuestProjectSyncState
        var history: [ProjectHistoryEntry]
        var activeWorkspaceID: ProjectWorkspaceID?
    }

    let root: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    static func applicationSupportRoot(fileManager: FileManager = .default) throws -> URL {
        guard let support = fileManager.urls(for: .applicationSupportDirectory,
                                             in: .userDomainMask).first else {
            throw ProjectStoreError.unavailable("Application Support is unavailable.")
        }
        return support.appendingPathComponent("New Old World/Projects", isDirectory: true)
    }

    convenience init() throws {
        try self.init(root: Self.applicationSupportRoot())
    }

    init(root: URL, fileManager: FileManager = .default) throws {
        self.root = root
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try fileManager.createDirectory(at: projectsURL,
                                        withIntermediateDirectories: true)
        try fileManager.createDirectory(at: repositoriesURL,
                                        withIntermediateDirectories: true)
        try fileManager.createDirectory(at: catalogURL,
                                        withIntermediateDirectories: true)
        try fileManager.createDirectory(at: workspacesURL,
                                        withIntermediateDirectories: true)
        try fileManager.createDirectory(at: candidatesURL,
                                        withIntermediateDirectories: true)
    }

    func list() throws -> [ProjectStatus] {
        try fileManager.contentsOfDirectory(at: catalogURL,
                                            includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try decoder.decode(CatalogRecord.self,
                                      from: Data(contentsOf: $0)) }
            .map(status)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    func create(name: String, home: ProjectHome, guestDigest: String? = nil,
                projectDocument: Data,
                files: [ProjectFileChange]) throws -> ProjectRevisionReceipt {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.unicodeScalars.count <= 64 else {
            throw ProjectStoreError.invalidProject("The display name must be 1-64 characters.")
        }
        if home == .guest {
            guard let guestDigest, isSHA256(guestDigest) else {
                throw ProjectStoreError.invalidProject(
                    "A guest-home project requires a verified guest digest.")
            }
        }
        let parsed = try CKProjectDocument.parse(projectDocument)
        let projectID = ProjectID.mint()
        let projectContainer = projectsURL.appendingPathComponent(projectID.rawValue)
        let staging = projectsURL.appendingPathComponent(".staging-\(UUID().uuidString)")
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        var committed = false
        defer { if !committed { try? fileManager.removeItem(at: staging) } }
        try parsed.replacingID(projectID).write(
            to: staging.appendingPathComponent("Project.ckp"), options: .atomic)
        try preflight(files, under: staging, allowMissingExpected: true)
        try apply(files, to: staging)
        _ = try CKProjectDocument.parse(Data(contentsOf:
            staging.appendingPathComponent("Project.ckp")))
        let digest = try ProjectDigest.tree(at: staging, fileManager: fileManager)
        let repository = try repository(for: projectID)
        let date = Date()
        let commit = try repository.commit(tree: staging, parent: nil,
                                           message: "Create project", date: date)
        try fileManager.createDirectory(at: projectContainer,
                                        withIntermediateDirectories: true)
        let working = projectContainer.appendingPathComponent("Working")
        try fileManager.moveItem(at: staging, to: working)
        try repository.update(branch: "main", to: commit)
        let entry = ProjectHistoryEntry(revision: 1, commit: commit, parent: nil,
                                        contentDigest: digest,
                                        message: "Create project", committedAt: date)
        let record = CatalogRecord(
            projectID: projectID, name: name, home: home, formatVersion: 1,
            revision: 1, currentCommit: commit, contentDigest: digest,
            verifiedGuestDigest: guestDigest,
            guestState: home == .guest ? .verified : .notApplicable,
            history: [entry], activeWorkspaceID: nil)
        try save(record)
        committed = true
        return ProjectRevisionReceipt(projectID: projectID, home: home,
                                      revision: 1, commit: commit,
                                      contentDigest: digest,
                                      changedPaths: (["Project.ckp"] + files.map(\.path)).sorted(),
                                      committedAt: date)
    }

    func status(projectID: ProjectID) throws -> ProjectStatus {
        status(try load(projectID))
    }

    func history(projectID: ProjectID) throws -> [ProjectHistoryEntry] {
        try load(projectID).history
    }

    @discardableResult
    func importGuestSnapshot(projectDocument: Data,
                             files: [ProjectFileChange],
                             guestDigest: String) throws
        -> ProjectRevisionReceipt {
        guard isSHA256(guestDigest) else {
            throw ProjectStoreError.invalidProject(
                "The measured guest digest is malformed.")
        }
        let parsed = try CKProjectDocument.parse(projectDocument)
        let projectID = parsed.id
        let staging = projectsURL.appendingPathComponent(
            ".import-\(UUID().uuidString)")
        try fileManager.createDirectory(at: staging,
                                        withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }
        try projectDocument.write(to: staging.appendingPathComponent("Project.ckp"),
                                  options: .atomic)
        try preflight(files, under: staging, allowMissingExpected: true)
        try apply(files, to: staging)
        let measured = try ProjectDigest.tree(at: staging, fileManager: fileManager)
        guard measured == guestDigest else {
            throw ProjectStoreError.unavailable(
                "The imported bytes do not match the coherent guest snapshot.")
        }
        let existing = try? load(projectID)
        guard existing?.home != .host else {
            throw ProjectStoreError.unavailable(
                "A host-home project already owns that identity.")
        }
        if let existing, existing.verifiedGuestDigest == guestDigest {
            return ProjectRevisionReceipt(
                projectID: projectID, home: .guest,
                revision: existing.revision, commit: existing.currentCommit,
                contentDigest: existing.contentDigest, changedPaths: [],
                committedAt: existing.history.last?.committedAt ?? Date())
        }
        let repository = try repository(for: projectID)
        let date = Date()
        let parent = existing?.currentCommit
        let commit = try repository.commit(
            tree: staging, parent: parent,
            message: existing == nil ? "Import guest project" : "Refresh guest snapshot",
            date: date)
        let revision = (existing?.revision ?? 0) + 1
        let working = workingURL(projectID)
        if existing == nil {
            try fileManager.createDirectory(
                at: working.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try fileManager.copyItem(at: staging, to: working)
        } else {
            let replacement = working.deletingLastPathComponent()
                .appendingPathComponent(".import-working-\(UUID().uuidString)")
            let backup = working.deletingLastPathComponent()
                .appendingPathComponent(".import-backup-\(UUID().uuidString)")
            try fileManager.copyItem(at: staging, to: replacement)
            try fileManager.moveItem(at: working, to: backup)
            do {
                try fileManager.moveItem(at: replacement, to: working)
                try fileManager.removeItem(at: backup)
            } catch {
                try? fileManager.removeItem(at: working)
                try? fileManager.moveItem(at: backup, to: working)
                try? fileManager.removeItem(at: replacement)
                throw error
            }
        }
        try repository.update(branch: "main", to: commit)
        let entry = ProjectHistoryEntry(
            revision: revision, commit: commit, parent: parent,
            contentDigest: measured,
            message: existing == nil ? "Import guest project" : "Refresh guest snapshot",
            committedAt: date)
        let record = CatalogRecord(
            projectID: projectID, name: parsed.name, home: .guest,
            formatVersion: 1, revision: revision, currentCommit: commit,
            contentDigest: measured, verifiedGuestDigest: guestDigest,
            guestState: existing?.activeWorkspaceID == nil ? .verified : .divergent,
            history: (existing?.history ?? []) + [entry],
            activeWorkspaceID: existing?.activeWorkspaceID)
        try save(record)
        return ProjectRevisionReceipt(
            projectID: projectID, home: .guest, revision: revision,
            commit: commit, contentDigest: measured,
            changedPaths: (["Project.ckp"] + files.map(\.path)).sorted(),
            committedAt: date)
    }

    func read(projectID: ProjectID, path: String, maximumBytes: Int = 262_144) throws -> Data {
        let record = try load(projectID)
        let url = try ProjectPath.checkedURL(path, under: workingURL(record.projectID),
                                             fileManager: fileManager)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber,
              size.intValue <= maximumBytes else {
            throw ProjectStoreError.unavailable("The bounded read exceeds \(maximumBytes) bytes.")
        }
        return try Data(contentsOf: url)
    }

    @discardableResult
    func apply(projectID: ProjectID, expectedRevision: Int,
               changes: [ProjectFileChange], message: String) throws -> ProjectRevisionReceipt {
        var record = try load(projectID)
        guard record.revision == expectedRevision else {
            throw ProjectStoreError.revisionConflict(expected: expectedRevision,
                                                     current: record.revision)
        }
        let result = try commitBatch(
            source: workingURL(projectID), changes: changes,
            repository: repository(for: projectID), parent: record.currentCommit,
            branch: "main", message: message)
        let date = result.date
        record.revision += 1
        record.currentCommit = result.commit
        record.contentDigest = result.digest
        record.history.append(ProjectHistoryEntry(
            revision: record.revision, commit: result.commit,
            parent: result.parent, contentDigest: result.digest,
            message: result.message, committedAt: date))
        try save(record)
        return ProjectRevisionReceipt(
            projectID: projectID, home: record.home, revision: record.revision,
            commit: result.commit, contentDigest: result.digest,
            changedPaths: changes.map(\.path).sorted(), committedAt: date)
    }

    func openWorkspace(projectID: ProjectID) throws -> ProjectWorkspace {
        var project = try load(projectID)
        if let current = project.activeWorkspaceID,
           let workspace = try? loadWorkspace(current), workspace.lifecycle == .active {
            return workspace
        }
        let workspaceID = ProjectWorkspaceID.mint()
        let container = workspaceContainer(workspaceID)
        try fileManager.createDirectory(at: container, withIntermediateDirectories: true)
        try fileManager.copyItem(at: workingURL(projectID),
                                 to: container.appendingPathComponent("Working"))
        let now = Date()
        let workspace = ProjectWorkspace(
            workspaceID: workspaceID, projectID: projectID,
            baseRevision: project.revision, baseProjectCommit: project.currentCommit,
            baseGuestDigest: project.verifiedGuestDigest,
            currentCommit: project.currentCommit, contentDigest: project.contentDigest,
            lifecycle: .active, promotedCommit: nil,
            createdAt: now, updatedAt: now)
        try saveWorkspace(workspace)
        project.activeWorkspaceID = workspaceID
        try save(project)
        return workspace
    }

    func resumeWorkspace(workspaceID: ProjectWorkspaceID) throws -> ProjectWorkspace {
        try loadWorkspace(workspaceID)
    }

    @discardableResult
    func apply(workspaceID: ProjectWorkspaceID, expectedCommit: String,
               changes: [ProjectFileChange], message: String) throws -> ProjectWorkspace {
        var workspace = try loadWorkspace(workspaceID)
        guard workspace.lifecycle == .active else {
            throw ProjectStoreError.unavailable("The workspace is not active.")
        }
        guard workspace.currentCommit == expectedCommit else {
            throw ProjectStoreError.commitConflict(expected: expectedCommit,
                                                   current: workspace.currentCommit)
        }
        let result = try commitBatch(
            source: workspaceContainer(workspaceID).appendingPathComponent("Working"),
            changes: changes, repository: repository(for: workspace.projectID),
            parent: workspace.currentCommit,
            branch: "workspaces/\(workspaceID.rawValue)", message: message)
        workspace.currentCommit = result.commit
        workspace.contentDigest = result.digest
        workspace.updatedAt = result.date
        try saveWorkspace(workspace)
        return workspace
    }

    func discardWorkspace(workspaceID: ProjectWorkspaceID) throws {
        var workspace = try loadWorkspace(workspaceID)
        guard workspace.currentCommit == workspace.baseProjectCommit
                || workspace.promotedCommit == workspace.currentCommit else {
            throw ProjectStoreError.unpromotedWorkspace
        }
        workspace.lifecycle = .discarded
        workspace.updatedAt = Date()
        try saveWorkspace(workspace)
        try? fileManager.removeItem(at: workspaceContainer(workspaceID)
            .appendingPathComponent("Working"))
        var project = try load(workspace.projectID)
        if project.activeWorkspaceID == workspaceID {
            project.activeWorkspaceID = nil
            try save(project)
        }
    }

    /// Materializes the exact host-side tree that will be published. The
    /// returned receipt contains no host path; the coordinator alone can ask
    /// for the candidate's files when it drives the private transfer lane.
    func stageCandidate(projectID: ProjectID,
                        workspaceID: ProjectWorkspaceID? = nil) throws
        -> ProjectCandidate {
        let project = try load(projectID)
        let source: URL
        let sourceCommit: String
        let workspace: ProjectWorkspace?
        if let workspaceID {
            let loaded = try loadWorkspace(workspaceID)
            guard loaded.projectID == projectID, loaded.lifecycle == .active else {
                throw ProjectStoreError.unavailable(
                    "The workspace is not an active workspace for this project.")
            }
            source = workspaceContainer(workspaceID).appendingPathComponent("Working")
            sourceCommit = loaded.currentCommit
            workspace = loaded
        } else {
            guard project.home == .host else {
                throw ProjectStoreError.unavailable(
                    "A guest-home candidate must come from a recoverable workspace.")
            }
            source = workingURL(projectID)
            sourceCommit = project.currentCommit
            workspace = nil
        }
        let candidateID = ProjectCandidateID.mint()
        let container = candidateContainer(candidateID)
        try fileManager.createDirectory(at: container, withIntermediateDirectories: true)
        do {
            let before = try ProjectDigest.tree(at: source, fileManager: fileManager)
            try fileManager.copyItem(at: source,
                                     to: container.appendingPathComponent("Working"))
            let after = try ProjectDigest.tree(at: source, fileManager: fileManager)
            let copied = try ProjectDigest.tree(
                at: container.appendingPathComponent("Working"),
                fileManager: fileManager)
            guard before == after, after == copied else {
                throw ProjectStoreError.unavailable(
                    "The source changed while the candidate was being staged.")
            }
            let receipt = ProjectCandidateReceipt(
                candidateID: candidateID, projectID: projectID, home: project.home,
                sourceRevision: workspace?.baseRevision ?? project.revision,
                sourceCommit: sourceCommit, workspaceID: workspaceID,
                baseGuestDigest: workspace?.baseGuestDigest
                    ?? project.verifiedGuestDigest,
                contentDigest: copied, manifest: try manifest(at: source),
                stagedAt: Date())
            let candidate = ProjectCandidate(receipt: receipt, lifecycle: .hostStaged,
                                             buildID: nil, guestDigest: nil,
                                             updatedAt: Date())
            try saveCandidate(candidate)
            return candidate
        } catch {
            try? fileManager.removeItem(at: container)
            throw error
        }
    }

    func candidate(candidateID: ProjectCandidateID) throws -> ProjectCandidate {
        try loadCandidate(candidateID)
    }

    func candidateFile(candidateID: ProjectCandidateID, path: String) throws -> Data {
        _ = try loadCandidate(candidateID)
        let url = try ProjectPath.checkedURL(
            path, under: candidateContainer(candidateID).appendingPathComponent("Working"),
            fileManager: fileManager)
        return try Data(contentsOf: url)
    }

    func recordBuild(candidateID: ProjectCandidateID, buildID: String,
                     succeeded: Bool) throws -> ProjectCandidate {
        var candidate = try loadCandidate(candidateID)
        let terminal: ProjectCandidateLifecycle = succeeded
            ? .buildSucceeded : .buildFailed
        if candidate.lifecycle == terminal, candidate.buildID == buildID {
            return candidate
        }
        guard candidate.lifecycle == .guestVerified else {
            throw ProjectStoreError.unavailable("The candidate is not awaiting a build.")
        }
        guard candidate.buildID == nil || candidate.buildID == buildID else {
            throw ProjectStoreError.unavailable(
                "The build receipt does not match the candidate's active job.")
        }
        candidate.lifecycle = terminal
        candidate.buildID = buildID
        candidate.updatedAt = Date()
        try saveCandidate(candidate)
        return candidate
    }

    func recordBuildStarted(candidateID: ProjectCandidateID,
                            buildID: String) throws -> ProjectCandidate {
        var candidate = try loadCandidate(candidateID)
        guard candidate.lifecycle == .guestVerified else {
            throw ProjectStoreError.unavailable(
                "The candidate is not verified for a build.")
        }
        guard buildID.hasPrefix("build-"), buildID.count <= 40 else {
            throw ProjectStoreError.unavailable("The build identity is malformed.")
        }
        candidate.buildID = buildID
        candidate.updatedAt = Date()
        try saveCandidate(candidate)
        return candidate
    }

    func recordGuestTransfer(candidateID: ProjectCandidateID) throws
        -> ProjectCandidate {
        var candidate = try loadCandidate(candidateID)
        guard candidate.lifecycle == .hostStaged else {
            throw ProjectStoreError.unavailable(
                "The candidate is not awaiting guest transfer.")
        }
        candidate.lifecycle = .guestTransferred
        candidate.updatedAt = Date()
        try saveCandidate(candidate)
        return candidate
    }

    func recordGuestVerification(candidateID: ProjectCandidateID,
                                 digest: String) throws -> ProjectCandidate {
        var candidate = try loadCandidate(candidateID)
        guard candidate.lifecycle == .guestTransferred else {
            throw ProjectStoreError.unavailable(
                "The candidate is not awaiting guest verification.")
        }
        guard isSHA256(digest), digest == candidate.receipt.contentDigest else {
            throw ProjectStoreError.unavailable(
                "The guest candidate digest does not match the staged source.")
        }
        candidate.lifecycle = .guestVerified
        candidate.guestDigest = digest
        candidate.updatedAt = Date()
        try saveCandidate(candidate)
        return candidate
    }

    /// Records activation only after the guest coordinator has measured the
    /// active tree. A guest-home promotion advances the verified mirror to the
    /// workspace commit; a host-home promotion leaves host source authority
    /// untouched and only settles the candidate lifecycle.
    func promoteCandidate(candidateID: ProjectCandidateID,
                          currentGuestDigest: String?) throws
        -> ProjectPromotionReceipt {
        var candidate = try loadCandidate(candidateID)
        guard candidate.lifecycle == .buildSucceeded else {
            throw ProjectStoreError.candidateNotBuilt
        }
        var project = try load(candidate.receipt.projectID)
        if project.home == .guest {
            guard let base = candidate.receipt.baseGuestDigest,
                  let current = currentGuestDigest else {
                throw ProjectStoreError.unavailable(
                    "Promotion requires both base and current guest digests.")
            }
            guard base == current else {
                project.guestState = .divergent
                try save(project)
                throw ProjectStoreError.guestDiverged(base: base, current: current)
            }
            guard let workspaceID = candidate.receipt.workspaceID else {
                throw ProjectStoreError.unavailable(
                    "A guest-home candidate has no workspace provenance.")
            }
            var workspace = try loadWorkspace(workspaceID)
            try replaceWorkingTree(projectID: project.projectID,
                                   withCandidate: candidateID)
            let date = Date()
            project.revision += 1
            project.currentCommit = workspace.currentCommit
            project.contentDigest = workspace.contentDigest
            project.verifiedGuestDigest = candidate.receipt.contentDigest
            project.guestState = .verified
            project.history.append(ProjectHistoryEntry(
                revision: project.revision, commit: workspace.currentCommit,
                parent: workspace.baseProjectCommit,
                contentDigest: workspace.contentDigest,
                message: "Promote verified guest candidate", committedAt: date))
            try repository(for: project.projectID).update(
                branch: "main", to: workspace.currentCommit)
            workspace.lifecycle = .promoted
            workspace.promotedCommit = workspace.currentCommit
            workspace.updatedAt = date
            try saveWorkspace(workspace)
            try save(project)
        }
        candidate.lifecycle = .promoted
        candidate.updatedAt = Date()
        try saveCandidate(candidate)
        return ProjectPromotionReceipt(
            candidateID: candidateID, projectID: project.projectID,
            home: project.home, baseGuestDigest: candidate.receipt.baseGuestDigest,
            currentGuestDigest: currentGuestDigest,
            promotedRevision: project.revision,
            promotedCommit: project.currentCommit,
            contentDigest: candidate.receipt.contentDigest,
            promotedAt: candidate.updatedAt)
    }

    func discardCandidate(candidateID: ProjectCandidateID) throws {
        var candidate = try loadCandidate(candidateID)
        guard candidate.lifecycle != .promoted else {
            throw ProjectStoreError.unavailable("A promoted candidate is retained as evidence.")
        }
        candidate.lifecycle = .discarded
        candidate.updatedAt = Date()
        try saveCandidate(candidate)
        try? fileManager.removeItem(at: candidateContainer(candidateID)
            .appendingPathComponent("Working"))
    }

    func observeGuest(projectID: ProjectID, digest: String) throws -> ProjectStatus {
        guard isSHA256(digest) else {
            throw ProjectStoreError.invalidProject("The guest digest is malformed.")
        }
        var project = try load(projectID)
        guard project.home == .guest else {
            throw ProjectStoreError.unavailable("The project is not guest-home.")
        }
        project.guestState = digest == project.verifiedGuestDigest
            ? .verified : (project.activeWorkspaceID == nil ? .dirtyOnGuest : .divergent)
        try save(project)
        return status(project)
    }

    func testingWorkingURL(projectID: ProjectID) -> URL {
        workingURL(projectID)
    }

    private struct BatchResult {
        let commit: String
        let parent: String
        let digest: String
        let message: String
        let date: Date
    }

    private func commitBatch(source: URL, changes: [ProjectFileChange],
                             repository: LooseGitRepository, parent: String,
                             branch: String, message: String) throws -> BatchResult {
        guard !changes.isEmpty, changes.count <= 128 else {
            throw ProjectStoreError.invalidProject("A batch must contain 1-128 changes.")
        }
        try preflight(changes, under: source, allowMissingExpected: false)
        let container = source.deletingLastPathComponent()
        let staging = container.appendingPathComponent(".staging-\(UUID().uuidString)")
        let backup = container.appendingPathComponent(".backup-\(UUID().uuidString)")
        try fileManager.copyItem(at: source, to: staging)
        var installed = false
        defer {
            try? fileManager.removeItem(at: staging)
            if !installed { try? fileManager.removeItem(at: backup) }
        }
        try apply(changes, to: staging)
        _ = try CKProjectDocument.parse(Data(contentsOf:
            staging.appendingPathComponent("Project.ckp")))
        let digest = try ProjectDigest.tree(at: staging, fileManager: fileManager)
        let date = Date()
        let cleanMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanMessage.isEmpty, cleanMessage.count <= 256 else {
            throw ProjectStoreError.invalidProject("A commit message must be 1-256 characters.")
        }
        let commit = try repository.commit(tree: staging, parent: parent,
                                           message: cleanMessage, date: date)
        try fileManager.moveItem(at: source, to: backup)
        do {
            try fileManager.moveItem(at: staging, to: source)
            try repository.update(branch: branch, to: commit)
            try fileManager.removeItem(at: backup)
            installed = true
        } catch {
            try? fileManager.removeItem(at: source)
            try? fileManager.moveItem(at: backup, to: source)
            throw error
        }
        return BatchResult(commit: commit, parent: parent, digest: digest,
                           message: cleanMessage, date: date)
    }

    private func preflight(_ changes: [ProjectFileChange], under root: URL,
                           allowMissingExpected: Bool) throws {
        var seen = Set<String>()
        for change in changes {
            try ProjectPath.validate(change.path)
            guard seen.insert(change.path).inserted else {
                throw ProjectStoreError.duplicatePath(change.path)
            }
            let url = try ProjectPath.checkedURL(change.path, under: root,
                                                 fileManager: fileManager)
            if let expected = change.expectedDigest {
                guard isSHA256(expected) else {
                    throw ProjectStoreError.invalidProject("An expected digest is malformed.")
                }
                let current = fileManager.fileExists(atPath: url.path)
                    ? ProjectDigest.sha256(try Data(contentsOf: url)) : nil
                guard current == expected else {
                    throw ProjectStoreError.digestConflict(path: change.path,
                                                           expected: expected,
                                                           current: current)
                }
            } else if !allowMissingExpected && change.contents == nil
                        && !fileManager.fileExists(atPath: url.path) {
                throw ProjectStoreError.invalidProject("Cannot delete a missing file.")
            }
        }
    }

    private func apply(_ changes: [ProjectFileChange], to root: URL) throws {
        for change in changes {
            let url = try ProjectPath.checkedURL(change.path, under: root,
                                                 fileManager: fileManager)
            if let contents = change.contents {
                try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                try contents.write(to: url, options: .atomic)
            } else {
                try fileManager.removeItem(at: url)
            }
        }
    }

    private func status(_ record: CatalogRecord) -> ProjectStatus {
        ProjectStatus(projectID: record.projectID, name: record.name,
                      home: record.home, formatVersion: record.formatVersion,
                      revision: record.revision,
                      currentCommit: record.currentCommit,
                      contentDigest: record.contentDigest,
                      verifiedGuestDigest: record.verifiedGuestDigest,
                      guestState: record.guestState,
                      activeWorkspaceID: record.activeWorkspaceID)
    }

    private func repository(for projectID: ProjectID) throws -> LooseGitRepository {
        try LooseGitRepository(url: repositoriesURL
            .appendingPathComponent(projectID.rawValue + ".git"),
            fileManager: fileManager)
    }

    private func load(_ id: ProjectID) throws -> CatalogRecord {
        let url = catalogURL.appendingPathComponent(id.rawValue + ".json")
        guard fileManager.fileExists(atPath: url.path) else {
            throw ProjectStoreError.projectNotFound
        }
        return try decoder.decode(CatalogRecord.self, from: Data(contentsOf: url))
    }

    private func save(_ record: CatalogRecord) throws {
        try encoder.encode(record).write(
            to: catalogURL.appendingPathComponent(record.projectID.rawValue + ".json"),
            options: .atomic)
    }

    private func loadWorkspace(_ id: ProjectWorkspaceID) throws -> ProjectWorkspace {
        let url = workspaceContainer(id).appendingPathComponent("Workspace.json")
        guard fileManager.fileExists(atPath: url.path) else {
            throw ProjectStoreError.workspaceNotFound
        }
        return try decoder.decode(ProjectWorkspace.self, from: Data(contentsOf: url))
    }

    private func saveWorkspace(_ workspace: ProjectWorkspace) throws {
        let url = workspaceContainer(workspace.workspaceID)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try encoder.encode(workspace).write(to: url.appendingPathComponent("Workspace.json"),
                                            options: .atomic)
    }

    private func manifest(at root: URL) throws -> [ProjectManifestEntry] {
        guard let walk = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]) else {
            throw ProjectStoreError.unavailable("The candidate tree cannot be read.")
        }
        var result: [ProjectManifestEntry] = []
        for case let url as URL in walk {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey,
                                                           .isSymbolicLinkKey])
            let path = url.pathComponents.suffix(walk.level)
                .joined(separator: "/")
            if path == "Build" || path.hasPrefix("Build/") {
                if values.isRegularFile != true { walk.skipDescendants() }
                continue
            }
            if values.isSymbolicLink == true { throw ProjectStoreError.linkEscape(path) }
            guard values.isRegularFile == true else { continue }
            let resourceFork = URL(fileURLWithPath:
                url.path + "/..namedfork/rsrc")
            if let resourceData = try? Data(contentsOf: resourceFork),
               !resourceData.isEmpty {
                throw ProjectStoreError.unavailable(
                    "The source file \(path) has a resource fork; candidates cannot preserve it yet.")
            }
            let data = try Data(contentsOf: url)
            result.append(.init(path: path, dataBytes: data.count,
                                resourceBytes: 0, type: nil, creator: nil,
                                digest: ProjectDigest.sha256(data)))
        }
        return result.sorted { $0.path < $1.path }
    }

    private func replaceWorkingTree(projectID: ProjectID,
                                    withCandidate candidateID: ProjectCandidateID) throws {
        let working = workingURL(projectID)
        let source = candidateContainer(candidateID).appendingPathComponent("Working")
        let parent = working.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".promote-\(UUID().uuidString)")
        let backup = parent.appendingPathComponent(".backup-\(UUID().uuidString)")
        try fileManager.copyItem(at: source, to: staging)
        try fileManager.moveItem(at: working, to: backup)
        do {
            try fileManager.moveItem(at: staging, to: working)
            try fileManager.removeItem(at: backup)
        } catch {
            try? fileManager.removeItem(at: working)
            try? fileManager.moveItem(at: backup, to: working)
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    private func loadCandidate(_ id: ProjectCandidateID) throws -> ProjectCandidate {
        let url = candidateContainer(id).appendingPathComponent("Candidate.json")
        guard fileManager.fileExists(atPath: url.path) else {
            throw ProjectStoreError.candidateNotFound
        }
        return try decoder.decode(ProjectCandidate.self, from: Data(contentsOf: url))
    }

    private func saveCandidate(_ candidate: ProjectCandidate) throws {
        let url = candidateContainer(candidate.receipt.candidateID)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try encoder.encode(candidate).write(to: url.appendingPathComponent("Candidate.json"),
                                            options: .atomic)
    }

    private func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private var projectsURL: URL { root.appendingPathComponent("WorkingTrees") }
    private var repositoriesURL: URL { root.appendingPathComponent("Repositories") }
    private var catalogURL: URL { root.appendingPathComponent("Catalog") }
    private var workspacesURL: URL { root.appendingPathComponent("Workspaces") }
    private var candidatesURL: URL { root.appendingPathComponent("Candidates") }
    private func workingURL(_ id: ProjectID) -> URL {
        projectsURL.appendingPathComponent(id.rawValue).appendingPathComponent("Working")
    }
    private func workspaceContainer(_ id: ProjectWorkspaceID) -> URL {
        workspacesURL.appendingPathComponent(id.rawValue)
    }
    private func candidateContainer(_ id: ProjectCandidateID) -> URL {
        candidatesURL.appendingPathComponent(id.rawValue)
    }
}
