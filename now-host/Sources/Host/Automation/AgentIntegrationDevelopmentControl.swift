import Foundation
import NOWAgentIntegration

/// Drives only the guest's closed Development commands. Project and product
/// references cross; HFS paths and rendered MPW scripts do not.
@MainActor
final class AgentIntegrationDevelopmentControl {
    private let listener: GuestListener
    private let currentSessionID: @MainActor () -> UUID?
    private let projectStore: ProjectStore?

    init(listener: GuestListener,
         currentSessionID: @escaping @MainActor () -> UUID?,
         projectStore: ProjectStore?) {
        self.listener = listener
        self.currentSessionID = currentSessionID
        self.projectStore = projectStore
    }

    func perform(_ request: AgentIntegrationDevelopmentRequest) async
        -> AgentIntegrationGuestRowReportResult {
        guard request.isWellFormed else {
            return .refused(.init(code: "now-development-invalid-request",
                                  message: "The Development operation has invalid opaque references."))
        }
        guard let sessionID = currentSessionID() else {
            return .unavailable(.guest)
        }
        switch request.operation {
        case .importGuest:
            return await importGuest(request, sessionID: sessionID)
        case .stage:
            return await stage(request, sessionID: sessionID)
        case .stageStatus, .stageDiscard:
            return await candidateCommand(request, sessionID: sessionID)
        case .promote:
            return await promote(request, sessionID: sessionID)
        default:
            break
        }
        let route: (verb: String, group: String, args: [String: String])
        switch request.operation {
        case .importGuest, .stage, .stageStatus, .stageDiscard, .promote:
            preconditionFailure("Candidate operations settle above")
        case .buildStart:
            var args = ["action": "start"]
            if let projectID = request.projectID { args["projectID"] = projectID }
            if let candidateID = request.candidateID {
                args["candidateID"] = candidateID
            }
            route = ("development-build", "development-build", args)
        case .buildStatus:
            route = ("development-build", "development-build",
                     ["action": "status"])
        case .buildCancel:
            route = ("development-build", "development-build",
                     ["action": "cancel"])
        case .run:
            route = ("development-run", "development-run",
                     ["productRef": request.productRef!])
        case .openInCodeKitten:
            route = ("development-open", "development-open",
                     ["projectID": request.projectID!])
        }
        var result: CommandResult = await withCheckedContinuation { continuation in
            listener.runCommand(route.verb, args: route.args) {
                continuation.resume(returning: $0)
            }
        }
        if request.operation == .openInCodeKitten {
            var attempts = 0
            while result.ok,
                  result.output?[route.group]?.contains(
                    where: { $0.first == "State" && $0.last == "launching" }) == true {
                attempts += 1
                guard attempts < 40 else {
                    return .refused(.init(
                        code: "codekitten-launch-timeout",
                        message: "CodeKitten was launched but did not become ready for the project handoff."))
                }
                guard currentSessionID() == sessionID else {
                    return .refused(.init(
                        code: "now-development-outcome-unknown",
                        message: "The paired guest changed while CodeKitten was launching."))
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
                result = await withCheckedContinuation { continuation in
                    listener.runCommand(route.verb, args: route.args) {
                        continuation.resume(returning: $0)
                    }
                }
            }
        }
        guard currentSessionID() == sessionID else {
            return .refused(.init(
                code: "now-development-outcome-unknown",
                message: "The paired guest changed while the Development operation was settling."))
        }
        guard result.ok else {
            return .refused(.init(
                code: AgentIntegrationBoundedText.prefix(
                    result.error?.code ?? "development-failed", scalars: 64),
                message: AgentIntegrationBoundedText.prefix(
                    result.error?.message ?? "The paired guest refused Development.",
                    scalars: 256)))
        }
        guard let cells = result.output?[route.group] else {
            return .refused(.init(code: "now-development-invalid",
                                  message: "The paired guest returned no Development rows."))
        }
        if let projectStore {
            let values = Dictionary(uniqueKeysWithValues: cells.compactMap {
                row -> (String, String)? in
                guard row.count >= 2 else { return nil }
                return (row[0], row[row.count - 1])
            })
            if request.operation == .buildStart,
               let rawCandidate = request.candidateID,
               let candidateID = ProjectCandidateID(rawValue: rawCandidate),
               let buildID = values["Job"] {
                do {
                    _ = try projectStore.recordBuildStarted(
                        candidateID: candidateID, buildID: buildID)
                } catch {
                    return .refused(.init(code: "now-development-build-unsettled",
                                          message: error.localizedDescription))
                }
            } else if request.operation == .buildStatus,
                      let rawCandidate = values["Candidate"],
                      let candidateID = ProjectCandidateID(rawValue: rawCandidate),
                      let buildID = values["Job"],
                      let state = values["State"],
                      ["succeeded", "failed", "cancelled"].contains(state) {
                do {
                    _ = try projectStore.recordBuild(
                        candidateID: candidateID, buildID: buildID,
                        succeeded: state == "succeeded")
                } catch {
                    return .refused(.init(code: "now-development-build-unsettled",
                                          message: error.localizedDescription))
                }
            }
        }
        let rows = cells.prefix(16).map {
            AgentIntegrationGuestRow(
                label: AgentIntegrationBoundedText.prefix($0.first ?? "", scalars: 64),
                value: AgentIntegrationBoundedText.prefix(
                    $0.count > 1 ? $0.last ?? "" : "", scalars: 2_048))
        }
        return .completed(.init(
            verb: route.verb,
            groups: [.init(name: route.group, rows: rows)],
            note: cells.count > 16 ? "The host bounded the Development receipt." : nil,
            observedAt: Date()))
    }

    private func stage(
        _ request: AgentIntegrationDevelopmentRequest, sessionID: UUID
    ) async -> AgentIntegrationGuestRowReportResult {
        guard let projectStore,
              let rawProject = request.projectID,
              let projectID = ProjectID(rawValue: rawProject) else {
            return .refused(.init(
                code: "now-development-project-unavailable",
                message: "The bounded host Projects store is unavailable."))
        }
        let workspaceID: ProjectWorkspaceID?
        if let raw = request.workspaceID {
            workspaceID = ProjectWorkspaceID(rawValue: raw)
            guard workspaceID != nil else {
                return .refused(.init(code: "now-development-invalid-request",
                                      message: "The workspace identity is malformed."))
            }
        } else {
            workspaceID = nil
        }
        let candidate: ProjectCandidate
        do {
            candidate = try projectStore.stageCandidate(
                projectID: projectID, workspaceID: workspaceID)
        } catch {
            return .refused(.init(code: "now-development-stage-refused",
                                  message: error.localizedDescription))
        }
        let candidateID = candidate.receipt.candidateID.rawValue
        let prepared = await command(
            "development-stage",
            args: ["action": "prepare", "candidateID": candidateID,
                   "projectID": rawProject])
        guard currentSessionID() == sessionID else {
            return .refused(.init(
                code: "now-development-outcome-unknown",
                message: "The paired guest changed while the candidate was being prepared."))
        }
        guard prepared.ok else {
            try? projectStore.discardCandidate(
                candidateID: candidate.receipt.candidateID)
            return refusal(prepared, fallback: "The guest refused the candidate.")
        }

        for entry in candidate.receipt.manifest {
            guard let destination = hfsDestination(entry.path) else {
                await discardGuestCandidate(candidateID)
                try? projectStore.discardCandidate(
                    candidateID: candidate.receipt.candidateID)
                return .refused(.init(
                    code: "now-development-path-unrepresentable",
                    message: "A project-relative path is not representable as bounded HFS components."))
            }
            do {
                let bytes = try projectStore.candidateFile(
                    candidateID: candidate.receipt.candidateID,
                    path: entry.path)
                let transfer = await put(candidateID: candidateID,
                                         name: destination.name,
                                         path: destination.parent,
                                         bytes: bytes)
                guard case .success = transfer else {
                    let reason: String
                    if case .failure(let failure) = transfer {
                        reason = failure.message
                    } else { reason = "The candidate transfer failed." }
                    await discardGuestCandidate(candidateID)
                    try? projectStore.discardCandidate(
                        candidateID: candidate.receipt.candidateID)
                    return .refused(.init(code: "now-development-transfer-failed",
                                          message: reason))
                }
            } catch {
                await discardGuestCandidate(candidateID)
                try? projectStore.discardCandidate(
                    candidateID: candidate.receipt.candidateID)
                return .refused(.init(code: "now-development-transfer-failed",
                                      message: error.localizedDescription))
            }
        }
        guard currentSessionID() == sessionID else {
            return .refused(.init(
                code: "now-development-outcome-unknown",
                message: "The paired guest changed while the candidate was transferring."))
        }
        do {
            _ = try projectStore.recordGuestTransfer(
                candidateID: candidate.receipt.candidateID)
        } catch {
            return .refused(.init(code: "now-development-stage-unsettled",
                                  message: error.localizedDescription))
        }
        let finalized = await command(
            "development-stage",
            args: ["action": "finalize", "candidateID": candidateID,
                   "expectedDigest": candidate.receipt.contentDigest,
                   "expectedFiles": String(candidate.receipt.manifest.count)])
        guard currentSessionID() == sessionID else {
            return .refused(.init(
                code: "now-development-outcome-unknown",
                message: "The paired guest changed while candidate verification was settling."))
        }
        guard finalized.ok else {
            return refusal(finalized,
                           fallback: "The inactive candidate did not verify on the guest.")
        }
        guard let digest = value("Digest", in: finalized,
                                 group: "development-stage"),
              digest == candidate.receipt.contentDigest else {
            return .refused(.init(
                code: "now-development-candidate-mismatch",
                message: "The guest did not return the exact staged source digest."))
        }
        do {
            _ = try projectStore.recordGuestVerification(
                candidateID: candidate.receipt.candidateID, digest: digest)
        } catch {
            return .refused(.init(code: "now-development-stage-unsettled",
                                  message: error.localizedDescription))
        }
        let rows = [
            AgentIntegrationGuestRow(label: "Candidate", value: candidateID),
            .init(label: "State", value: "verified and inactive"),
            .init(label: "Files", value: String(candidate.receipt.manifest.count)),
            .init(label: "Digest", value: digest),
        ]
        return .completed(.init(
            verb: "development-stage",
            groups: [.init(name: "development-stage", rows: rows)],
            note: "The sealed guest candidate matches the host staging receipt and remains inactive.",
            observedAt: Date()))
    }

    private struct GuestSnapshotFile {
        let path: String
        let digest: String
    }

    private func importGuest(
        _ request: AgentIntegrationDevelopmentRequest, sessionID: UUID
    ) async -> AgentIntegrationGuestRowReportResult {
        guard let projectStore, let projectID = request.projectID else {
            return .refused(.init(code: "now-development-project-unavailable",
                                  message: "The bounded host Projects store is unavailable."))
        }
        var cursor = 0
        var expectedDigest: String?
        var expectedCount: Int?
        var files: [GuestSnapshotFile] = []
        repeat {
            let page = await command(
                "development-project",
                args: ["projectID": projectID, "cursor": String(cursor)])
            guard currentSessionID() == sessionID else {
                return .refused(.init(code: "now-development-outcome-unknown",
                                      message: "The paired guest changed during project import."))
            }
            guard page.ok, let rows = page.output?["development-project"],
                  let digest = rows.first(where: { $0.first == "Digest" })?.last,
                  let countText = rows.first(where: { $0.first == "Files" })?.last,
                  let count = Int(countText), count >= 1, count <= 128,
                  digest.count == 64 else {
                return refusal(page, fallback: "The guest project snapshot is invalid.")
            }
            guard expectedDigest == nil || expectedDigest == digest,
                  expectedCount == nil || expectedCount == count else {
                return .refused(.init(code: "now-development-project-changed",
                                      message: "The guest project changed between manifest pages."))
            }
            expectedDigest = digest
            expectedCount = count
            for row in rows where row.first == "File" {
                guard let record = row.last,
                      let split = record.lastIndex(of: "|") else {
                    return .refused(.init(code: "now-development-project-invalid",
                                          message: "A guest manifest entry is malformed."))
                }
                let path = String(record[..<split])
                let fileDigest = String(record[record.index(after: split)...])
                guard !files.contains(where: { $0.path == path }),
                      fileDigest.count == 64 else {
                    return .refused(.init(code: "now-development-project-invalid",
                                          message: "The guest manifest repeats or malforms a file."))
                }
                files.append(.init(path: path, digest: fileDigest))
            }
            guard let nextText = rows.first(where: { $0.first == "Next" })?.last,
                  let next = Int(nextText), next == -1 || next > cursor else {
                return .refused(.init(code: "now-development-project-invalid",
                                      message: "The guest manifest cursor did not advance."))
            }
            cursor = next
        } while cursor >= 0
        guard files.count == expectedCount else {
            return .refused(.init(code: "now-development-project-invalid",
                                  message: "The guest manifest file count is inconsistent."))
        }
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-project-import-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: staging,
                                                    withIntermediateDirectories: true)
        } catch {
            return .refused(.init(code: "now-development-import-failed",
                                  message: "NOW could not create private import staging."))
        }
        defer { try? FileManager.default.removeItem(at: staging) }
        var projectDocument: Data?
        var changes: [ProjectFileChange] = []
        for file in files {
            let delivery = await getProjectFile(projectID: projectID,
                                                path: file.path,
                                                staging: staging)
            guard currentSessionID() == sessionID else {
                return .refused(.init(code: "now-development-outcome-unknown",
                                      message: "The paired guest changed during project import."))
            }
            switch delivery {
            case .failure(let failure):
                return .refused(.init(code: "now-development-import-failed",
                                      message: failure.message))
            case .success(let value):
                do {
                    let data = try Data(contentsOf: value.staged.url)
                    guard ProjectDigest.sha256(data) == file.digest else {
                        return .refused(.init(code: "now-development-project-changed",
                                              message: "A guest source file changed during import."))
                    }
                    if file.path == "Project.ckp" { projectDocument = data }
                    else { changes.append(.init(path: file.path, contents: data)) }
                    value.staged.discard()
                } catch {
                    return .refused(.init(code: "now-development-import-failed",
                                          message: error.localizedDescription))
                }
            }
        }
        guard let projectDocument, let digest = expectedDigest else {
            return .refused(.init(code: "now-development-project-invalid",
                                  message: "The guest snapshot has no Project.ckp."))
        }
        do {
            let receipt = try projectStore.importGuestSnapshot(
                projectDocument: projectDocument, files: changes,
                guestDigest: digest)
            return .completed(.init(
                verb: "development-project",
                groups: [.init(name: "development-project", rows: [
                    .init(label: "Project", value: receipt.projectID.rawValue),
                    .init(label: "State", value: "verified guest snapshot"),
                    .init(label: "Revision", value: String(receipt.revision)),
                    .init(label: "Digest", value: receipt.contentDigest),
                ])], observedAt: Date()))
        } catch {
            return .refused(.init(code: "now-development-import-failed",
                                  message: error.localizedDescription))
        }
    }

    private func getProjectFile(projectID: String, path: String, staging: URL)
        async -> Result<GuestListener.FileDelivery, GuestListener.FileFailure> {
        await withCheckedContinuation { continuation in
            listener.getDevelopmentProjectFile(
                projectID: projectID, path: path,
                stagingDirectory: staging) {
                    continuation.resume(returning: $0)
                }
        }
    }

    private func candidateCommand(
        _ request: AgentIntegrationDevelopmentRequest, sessionID: UUID
    ) async -> AgentIntegrationGuestRowReportResult {
        let action = request.operation == .stageDiscard ? "discard" : "status"
        let result = await command(
            "development-stage",
            args: ["action": action, "candidateID": request.candidateID!])
        guard currentSessionID() == sessionID else {
            return .refused(.init(code: "now-development-outcome-unknown",
                                  message: "The paired guest changed while the candidate operation settled."))
        }
        guard result.ok else { return refusal(result, fallback: "Candidate unavailable.") }
        if request.operation == .stageDiscard,
           let projectStore,
           let id = ProjectCandidateID(rawValue: request.candidateID!) {
            try? projectStore.discardCandidate(candidateID: id)
        }
        return report(result, verb: "development-stage",
                      group: "development-stage")
    }

    private func promote(
        _ request: AgentIntegrationDevelopmentRequest, sessionID: UUID
    ) async -> AgentIntegrationGuestRowReportResult {
        guard let projectStore,
              let id = ProjectCandidateID(rawValue: request.candidateID!) else {
            return .refused(.init(code: "now-development-candidate-unavailable",
                                  message: "The host candidate receipt is unavailable."))
        }
        let candidate: ProjectCandidate
        do {
            candidate = try projectStore.candidate(candidateID: id)
        } catch {
            return .refused(.init(code: "now-development-candidate-unavailable",
                                  message: error.localizedDescription))
        }
        guard candidate.lifecycle == .buildSucceeded,
              let base = candidate.receipt.baseGuestDigest else {
            return .refused(.init(
                code: "now-development-promotion-refused",
                message: "Promotion requires a successful guest-home candidate build with a verified base."))
        }
        let result = await command(
            "development-stage",
            args: ["action": "promote", "candidateID": id.rawValue,
                   "baseGuestDigest": base])
        guard currentSessionID() == sessionID else {
            return .refused(.init(code: "now-development-outcome-unknown",
                                  message: "The paired guest changed while promotion was settling."))
        }
        guard result.ok else {
            if let current = value("Current digest", in: result,
                                   group: "development-stage") {
                _ = try? projectStore.observeGuest(
                    projectID: candidate.receipt.projectID, digest: current)
            }
            return refusal(result, fallback: "The guest refused promotion.")
        }
        guard let previous = value("Previous digest", in: result,
                                   group: "development-stage"),
              let promoted = value("Promoted digest", in: result,
                                   group: "development-stage"),
              promoted == candidate.receipt.contentDigest else {
            return .refused(.init(
                code: "now-development-promotion-unsettled",
                message: "The guest promoted a tree that does not match the staged receipt."))
        }
        do {
            _ = try projectStore.promoteCandidate(
                candidateID: id, currentGuestDigest: previous)
        } catch {
            return .refused(.init(code: "now-development-promotion-unsettled",
                                  message: error.localizedDescription))
        }
        return report(result, verb: "development-stage",
                      group: "development-stage")
    }

    private func command(_ verb: String, args: [String: String]) async
        -> CommandResult {
        await withCheckedContinuation { continuation in
            listener.runCommand(verb, args: args) {
                continuation.resume(returning: $0)
            }
        }
    }

    private func put(candidateID: String, name: String, path: String,
                     bytes: Data) async -> Result<GuestListener.PutReceipt,
                                                  GuestListener.FileFailure> {
        await withCheckedContinuation { continuation in
            listener.putDevelopmentCandidateFileWithReceipt(
                candidateID: candidateID, name: name, into: path,
                bytes: bytes) { continuation.resume(returning: $0) }
        }
    }

    private func discardGuestCandidate(_ candidateID: String) async {
        _ = await command("development-stage",
                          args: ["action": "discard",
                                 "candidateID": candidateID])
    }

    private func hfsDestination(_ path: String)
        -> (parent: String, name: String)? {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard let name = pieces.last, !name.isEmpty,
              pieces.allSatisfy({ part in
                  !part.isEmpty && part.utf8.count <= 31
                      && part.unicodeScalars.allSatisfy { $0.value < 128 }
                      && !part.contains(":")
              }) else { return nil }
        return (pieces.dropLast().joined(separator: ":"), name)
    }

    private func refusal(_ result: CommandResult, fallback: String)
        -> AgentIntegrationGuestRowReportResult {
        .refused(.init(
            code: AgentIntegrationBoundedText.prefix(
                result.error?.code ?? "development-failed", scalars: 64),
            message: AgentIntegrationBoundedText.prefix(
                result.error?.message ?? fallback, scalars: 256)))
    }

    private func report(_ result: CommandResult, verb: String, group: String)
        -> AgentIntegrationGuestRowReportResult {
        guard let cells = result.output?[group] else {
            return .refused(.init(code: "now-development-invalid",
                                  message: "The paired guest returned no Development rows."))
        }
        return .completed(.init(
            verb: verb,
            groups: [.init(name: group, rows: cells.prefix(16).map {
                .init(label: AgentIntegrationBoundedText.prefix(
                    $0.first ?? "", scalars: 64),
                      value: AgentIntegrationBoundedText.prefix(
                    $0.count > 1 ? $0.last ?? "" : "", scalars: 2_048))
            })],
            observedAt: Date()))
    }

    private func value(_ label: String, in result: CommandResult,
                       group: String) -> String? {
        result.output?[group]?.first(where: { $0.first == label })?.last
    }
}
