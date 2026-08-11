import Foundation
import NOWAgentIntegration

/// The NOW-owned command seam for root-scoped guest file observation.
///
/// This layer knows nothing about MCP framing. It validates and rebases paths,
/// owns receipts/audit events, and asks the existing host-owned listener to
/// perform the current wire exchange. An MCP projection can only narrow these
/// commands later.
@MainActor
final class GuestFilesCommandService {
    typealias Audit = (HostLog.LogLevel, String) -> Void

    private let listener: GuestListener
    private let policy: GuestFileAccessPolicy
    private let currentSessionID: () -> UUID?
    private let audit: Audit
    private let maximumStatPages: Int
    private let clock: @Sendable () -> Date
    private let uploadCommands: GuestFileUploadCommands
    private let mutationCommands: GuestFileMutationCommands
    /// Where a pull may land. Nil when private storage could not be created,
    /// which switches `download` off host-side rather than letting a
    /// transfer start with nowhere to put it.
    private let downloads: AgentDownloadStore?
    private var observations: [String: Observation] = [:]

    static let observationLifetime: TimeInterval = 60
    private static let maximumObservations = 256

    init(
        listener: GuestListener,
        policy: GuestFileAccessPolicy,
        currentSessionID: @escaping () -> UUID?,
        audit: Audit? = nil,
        maximumStatPages: Int = 8,
        clock: @escaping @Sendable () -> Date = Date.init,
        uploadStaging: GuestUploadStagingStore? = nil,
        /* Doubly optional so that "use the real per-launch store" and "there
           is no store" are different arguments rather than one nil meaning
           both. Omitted creates it; `.some(nil)` is a host that could not,
           which is the state the capability report has to be able to
           describe and a test has to be able to produce. */
        downloadStore: AgentDownloadStore?? = nil
    ) {
        let auditSink = audit ?? {
            HostLog.shared.write($0, "files", $1)
        }
        let staging = uploadStaging ?? (try? GuestUploadStagingStore(
            clock: clock))
        downloads = downloadStore ?? (try? AgentDownloadStore())
        self.listener = listener
        self.policy = policy
        self.currentSessionID = currentSessionID
        self.audit = auditSink
        self.maximumStatPages = max(1, maximumStatPages)
        self.clock = clock
        if let staging, staging.recoveredOrphanCount > 0 {
            auditSink(
                .warn,
                "guestFiles.put recovered "
                    + "\(staging.recoveredOrphanCount) private orphan "
                    + "staging director"
                    + (staging.recoveredOrphanCount == 1 ? "y" : "ies"))
        }
        uploadCommands = GuestFileUploadCommands(
            listener: listener,
            policy: policy,
            currentSessionID: currentSessionID,
            audit: auditSink,
            staging: staging,
            clock: clock)
        mutationCommands = GuestFileMutationCommands(
            listener: listener,
            policy: policy,
            currentSessionID: currentSessionID,
            audit: auditSink,
            clock: clock)
    }

    func capabilities() async -> GuestFileCommandResponse<
        GuestFileCapabilities
    > {
        let context = begin(.capabilities, path: "")
        guard let sessionID = context.sessionID else {
            return finishUnavailable(context)
        }
        let root = policy.snapshot.guestRoot
        let result = await listOnce(path: root.wireValue, cursor: nil)
        guard currentSessionID() == sessionID else {
            return finishStale(context, wireRequests: 1)
        }
        switch result {
        case .success(let listing):
            guard let validated = validateListing(
                listing, expectedPath: root.wireValue)
            else {
                return finishInvalidListing(
                    context, wireRequests: 1)
            }
            return finish(
                context, outcome: .success, wireRequests: 1,
                value: makeCapabilities(
                    root: root.wireValue,
                    rootLabel: validated.rootLabel,
                    listServed: true))
        case .failure(let failure):
            // A guest that REFUSES the root listing has answered the
            // question this command was asked. It is not a failed
            // capability report; it is a capability report saying list
            // and stat are not available here, which is exactly the
            // shape a caller needs against a guest implementing part of
            // the contract. Anything else — a timeout, a Toolbox error —
            // still fails, because it says nothing about what the guest
            // implements and reporting it as "deferred" would turn one
            // wedged MacTCP stack into a missing feature.
            guard AgentIntegrationCapabilityNames.isRefusal(failure.code)
            else {
                return finish(context, failure: failure, wireRequests: 1)
            }
            return finish(
                context, outcome: .success, wireRequests: 1,
                value: makeCapabilities(
                    root: root.wireValue,
                    rootLabel: nil,
                    listServed: false))
        }
    }

    /// One place decides which Files commands this guest offers, so the
    /// served and refused cases cannot drift into two different lists.
    private func makeCapabilities(root: String,
                                  rootLabel: String?,
                                  listServed: Bool) -> GuestFileCapabilities {
        var available: [GuestFileCommandKind] = [.capabilities]
        var deferred: [GuestFileCommandKind] = [
            .readText, .tailText, .delete, .deployTree, .prune,
        ]
        if listServed {
            available.append(contentsOf: [.list, .stat])
        } else {
            deferred.append(contentsOf: [.list, .stat])
        }
        /* The download lane is a host-side condition AND a guest one, the
           same split `put` describes below: private storage can exist while
           the guest serves no `file.get`. Only a real call finds that out,
           so this stays the host's answer and the session capability report
           carries the guest's. It also needs the listing, because the size
           ceiling is applied to what the listing observed. */
        if downloads != nil && listServed {
            available.append(.download)
        } else {
            deferred.append(.download)
        }
        // The put lane is a host-side condition AND a guest one: staging
        // can be ready while the guest cannot receive. Only the commit
        // finds that out, so this stays the host's answer and the session
        // report carries the guest's.
        if uploadCommands.isAvailable {
            available.append(.put)
        } else {
            deferred.append(.put)
        }
        /* The four mutations are wired on THIS side, which is all this
           report can honestly speak for — the same split the put lane above
           states. Whether the connected guest serves `file.move` and its
           three siblings is a question about the guest, and the session
           capability report is where it is asked and answered: against a
           guest that refuses all four, `now_guest_files_mutate` reads
           unavailable while this list still says the commands exist here. */
        available.append(contentsOf: [.mkdir, .move, .trash, .restore])
        return GuestFileCapabilities(
            guestRoot: root,
            rootLabel: rootLabel,
            availableCommands: available,
            deferredCommands: deferred,
            maximumPageEntries: 16,
            maximumStatPages: maximumStatPages,
            maximumPathBytes: GuestFilePath.maximumWireBytes,
            maximumSegmentBytes: GuestFilePath.maximumSegmentBytes,
            transferLaneState: transferLaneState,
            observedAt: Date())
    }

    func list(path: String, cursor: Int? = nil) async
        -> GuestFileCommandResponse<GuestFileListingSnapshot> {
        let context = begin(.list, path: path)
        guard let sessionID = context.sessionID else {
            return finishUnavailable(context)
        }
        let scoped: GuestFilePath
        do {
            scoped = try GuestFilePath(path)
        } catch {
            return finishInvalidPath(context)
        }
        guard cursor == nil || cursor! >= 1 else {
            return finishRefused(
                context, code: "now-files-cursor-invalid",
                message: "Listing cursor must be at least 1")
        }
        let wirePath: GuestFilePath
        do {
            wirePath = try scoped.appending(to: policy.snapshot.guestRoot)
        } catch {
            return finishInvalidPath(context)
        }
        let result = await listOnce(
            path: wirePath.wireValue, cursor: cursor)
        guard currentSessionID() == sessionID else {
            return finishStale(context, wireRequests: 1)
        }
        switch result {
        case .success(let listing):
            guard let validated = validateListing(
                listing, expectedPath: wirePath.wireValue)
            else {
                return finishInvalidListing(
                    context, wireRequests: 1)
            }
            let observedAt = clock()
            let entries = validated.entries.map {
                observedEntry(
                    $0, parent: scoped, sessionID: sessionID,
                    observedAt: observedAt)
            }
            let snapshot = GuestFileListingSnapshot(
                path: scoped.wireValue,
                entries: entries,
                hasMore: validated.nextCursor != nil,
                nextCursor: validated.nextCursor,
                rootLabel: validated.rootLabel,
                observedAt: observedAt)
            return finish(
                context, outcome: .success, wireRequests: 1,
                value: snapshot)
        case .failure(let failure):
            return finish(context, failure: failure, wireRequests: 1)
        }
    }

    func stat(path: String) async
        -> GuestFileCommandResponse<GuestFileObservedEntry> {
        let context = begin(.stat, path: path)
        guard let sessionID = context.sessionID else {
            return finishUnavailable(context)
        }
        let scoped: GuestFilePath
        do {
            scoped = try GuestFilePath(path)
        } catch {
            return finishInvalidPath(context)
        }
        guard let leaf = scoped.leaf else {
            return finishRefused(
                context, code: "now-files-path-invalid",
                message: "Stat requires one item below guestRoot")
        }
        let wireParent: GuestFilePath
        do {
            wireParent = try scoped.parent.appending(
                to: policy.snapshot.guestRoot)
        } catch {
            return finishInvalidPath(context)
        }

        switch await scanParent(
            for: leaf, wireParent: wireParent, sessionID: sessionID) {
        case .found(let match, let pages):
            return finish(
                context, outcome: .success, wireRequests: pages,
                value: observedEntry(
                    match, parent: scoped.parent,
                    sessionID: sessionID, observedAt: clock()))
        case .notFound(let pages):
            return finish(
                context, outcome: .notFound, wireRequests: pages,
                failure: .init(
                    code: "now-files-not-found",
                    message: "No exact item was observed at that path"))
        case .scanLimit(let pages):
            return finish(
                context, outcome: .scanLimit, wireRequests: pages,
                failure: .init(
                    code: "now-files-scan-limit",
                    message:
                        "The bounded parent scan ended before that item was observed"))
        case .stale(let pages):
            return finishStale(context, wireRequests: pages)
        case .invalidListing(let pages):
            return finishInvalidListing(context, wireRequests: pages)
        case .failure(let failure, let pages):
            return finish(context, failure: failure, wireRequests: pages)
        }
    }

    /// One bounded parent scan, and what it reached.
    ///
    /// Extracted from `stat` when the download lane needed the same scan for
    /// a different receipt: an agent download refuses on the size the
    /// guest's own listing reports, so it has to observe the item before it
    /// asks for the bytes. Two copies of a bounded scan would be two places
    /// for the bound to drift, and the page count is part of every receipt
    /// this file writes.
    private enum ParentScan {
        case found(FileEntry, pages: Int)
        case notFound(pages: Int)
        case scanLimit(pages: Int)
        case stale(pages: Int)
        case invalidListing(pages: Int)
        case failure(GuestListener.FileFailure, pages: Int)
    }

    private func scanParent(
        for leaf: String,
        wireParent: GuestFilePath,
        sessionID: UUID
    ) async -> ParentScan {
        var cursor: Int?
        for page in 1...maximumStatPages {
            let result = await listOnce(
                path: wireParent.wireValue, cursor: cursor)
            guard currentSessionID() == sessionID else {
                return .stale(pages: page)
            }
            switch result {
            case .failure(let failure):
                return .failure(failure, pages: page)
            case .success(let listing):
                guard let validated = validateListing(
                    listing, expectedPath: wireParent.wireValue)
                else {
                    return .invalidListing(pages: page)
                }
                if let match = validated.entries.first(where: {
                    $0.name == leaf
                }) {
                    return .found(match, pages: page)
                }
                guard let next = validated.nextCursor else {
                    return .notFound(pages: page)
                }
                cursor = next
            }
        }
        return .scanLimit(pages: maximumStatPages)
    }

    // MARK: - Download (W1 #4, the pull direction)

    /// Pulls one bounded file off the machine into host-owned private
    /// storage, and reports where it landed.
    ///
    /// The policy this implements, stated once here because it is the answer
    /// docs/agent-integration.md deferred ("arbitrary download remains
    /// absent until a typed NOW command, root/size policy, receipts, audit,
    /// and explicit tool projection"):
    ///
    /// 1. **The source is bounded by the host's `guestRoot` policy**, the
    ///    same canonical root-relative path `list` and `stat` accept. No
    ///    absolute guest path, no traversal, one item — a folder is refused
    ///    rather than walked.
    /// 2. **The size is refused before any byte moves**, from the fork sizes
    ///    the guest's own listing reports, against
    ///    `AgentDownloadStore.maximumBytes`. Checked again after arrival,
    ///    because a source can grow between the two and MacBinary adds bytes
    ///    the forks do not include; an over-ceiling arrival is discarded and
    ///    lands nothing, which costs the wire time and is the honest price
    ///    of not putting an agent's ceiling into the human's own download
    ///    lane.
    /// 3. **The destination is not the caller's to name** — see
    ///    `AgentDownloadStore`.
    /// 4. **One attempt.** No resume: the deployed sequence has no
    ///    guest-issued source identity before the host asks for an offset
    ///    (docs/reverse-file-streaming.md), so a retained partial could
    ///    stitch two different sources. A `resumeToken` is reported when the
    ///    guest offers one and is never used.
    /// 5. **The container is the guest's answer, not the caller's choice.**
    ///    Whether a classic file is data or MacBinary is a fact about its
    ///    forks; the receipt says which arrived.
    ///
    /// The bytes themselves go through the existing reverse-streaming path
    /// unchanged — bounded fork reads, a private disk sink, progress, CRC,
    /// interruption cleanup, atomic finalization — staged directly into the
    /// store's root. Nothing here is a second transfer path.
    func download(path: String) async
        -> GuestFileCommandResponse<GuestFileDownloadLanding> {
        let context = begin(.download, path: path)
        guard let sessionID = context.sessionID else {
            return finishUnavailable(context)
        }
        guard let downloads else {
            return finishRefused(
                context, code: "now-download-staging-unavailable",
                message: "Private download storage is unavailable")
        }
        let scoped: GuestFilePath
        do {
            scoped = try GuestFilePath(path)
        } catch {
            return finishInvalidPath(context)
        }
        guard let leaf = scoped.leaf else {
            return finishRefused(
                context, code: "now-files-path-invalid",
                message: "Download requires one file below guestRoot")
        }
        let wireParent: GuestFilePath
        let wirePath: GuestFilePath
        do {
            wireParent = try scoped.parent.appending(
                to: policy.snapshot.guestRoot)
            wirePath = try scoped.appending(to: policy.snapshot.guestRoot)
        } catch {
            return finishInvalidPath(context)
        }

        let observed: FileEntry
        var wireRequests: Int
        switch await scanParent(
            for: leaf, wireParent: wireParent, sessionID: sessionID) {
        case .found(let match, let pages):
            observed = match
            wireRequests = pages
        case .notFound(let pages):
            return finish(
                context, outcome: .notFound, wireRequests: pages,
                failure: .init(
                    code: "now-files-not-found",
                    message: "No exact item was observed at that path"))
        case .scanLimit(let pages):
            return finish(
                context, outcome: .scanLimit, wireRequests: pages,
                failure: .init(
                    code: "now-files-scan-limit",
                    message:
                        "The bounded parent scan ended before that item was observed"))
        case .stale(let pages):
            return finishStale(context, wireRequests: pages)
        case .invalidListing(let pages):
            return finishInvalidListing(context, wireRequests: pages)
        case .failure(let failure, let pages):
            return finish(context, failure: failure, wireRequests: pages)
        }

        guard !observed.isFolder else {
            return finishRefused(
                context, code: "now-download-not-a-file",
                message: "That item is a folder; a download takes one file",
                wireRequests: wireRequests)
        }
        /* Both forks, because a MacBinary answer carries both and the
           ceiling is about what crosses the wire. An absent fork size is
           NOT read as zero — the guest declining to say how big something
           is leaves the ceiling unenforceable before the fact, which is a
           refusal rather than a reason to try. */
        guard let dataBytes = observed.dataBytes,
              let resourceBytes = observed.rsrcBytes else {
            return finishRefused(
                context, code: "now-download-size-unknown",
                message:
                    "The guest's listing did not report that item's size, "
                    + "so the download ceiling cannot be applied first",
                wireRequests: wireRequests)
        }
        do {
            try downloads.reserve(bytes: dataBytes + resourceBytes)
        } catch let failure as AgentDownloadStore.Failure {
            return finishRefused(
                context, code: failure.code, message: failure.message,
                wireRequests: wireRequests)
        } catch {
            return finishRefused(
                context, code: "now-download-staging-unavailable",
                message: "Private download storage is unavailable",
                wireRequests: wireRequests)
        }

        wireRequests += 1
        let pull = await pullOnce(
            path: wirePath.wireValue, into: downloads.rootURL)
        guard currentSessionID() == sessionID else {
            return finishStale(context, wireRequests: wireRequests)
        }
        switch pull {
        case .failure(let failure):
            return finish(
                context, failure: failure, wireRequests: wireRequests)
        case .success(let delivery):
            let landing: AgentDownloadStore.Landing
            do {
                landing = try downloads.land(
                    delivery.staged, named: delivery.name)
            } catch let failure as AgentDownloadStore.Failure {
                return finishRefused(
                    context, code: failure.code, message: failure.message,
                    wireRequests: wireRequests)
            } catch {
                return finishRefused(
                    context, code: "now-download-landing-failed",
                    message: "NOW could not place the downloaded file",
                    wireRequests: wireRequests)
            }
            return finish(
                context, outcome: .success, wireRequests: wireRequests,
                value: GuestFileDownloadLanding(
                    guestPath: scoped.wireValue,
                    hostPath: landing.url.path,
                    bytes: landing.bytes,
                    container: delivery.container,
                    crc32: delivery.crc32.map { Int($0) },
                    resumeToken: delivery.resumeToken,
                    elapsedMs: delivery.transferMs))
        }
    }

    private func pullOnce(path: String, into directory: URL) async
        -> Result<GuestListener.FileDelivery, GuestListener.FileFailure> {
        await withCheckedContinuation { continuation in
            /* `container` stays nil: the guest's own fork rule decides
               whether this is a stream of data bytes or a MacBinary, which
               is a fact about the file rather than a caller's preference. */
            listener.getFile(
                path: path, container: nil, stagingDirectory: directory
            ) {
                continuation.resume(returning: $0)
            }
        }
    }

    func beginUpload(_ request: GuestFileUploadBeginRequest) async
        -> GuestFileCommandResponse<GuestFileUploadStageStatus> {
        await uploadCommands.begin(request)
    }

    func appendUpload(uploadID: UUID, offset: Int, bytes: Data) async
        -> GuestFileCommandResponse<GuestFileUploadStageStatus> {
        await uploadCommands.append(
            uploadID: uploadID, offset: offset, bytes: bytes)
    }

    func commitUpload(uploadID: UUID) async
        -> GuestFileCommandResponse<GuestFileUploadTransferReceipt> {
        await uploadCommands.commit(uploadID: uploadID)
    }

    /// Move, trash, restore or create one item. The authority, the bounds
    /// and the one-request rule live in `GuestFileMutationCommands`.
    func mutate(_ request: AgentIntegrationGuestFileMutationRequest) async
        -> GuestFileCommandResponse<GuestFileMutationReport> {
        await mutationCommands.mutate(request)
    }

    private var transferLaneState: String {
        listener.captureProgress != nil || listener.activeStreamId != nil
            ? "busy" : "unknown"
    }

    private struct ValidatedListing {
        let entries: [FileEntry]
        let nextCursor: Int?
        let rootLabel: String?
    }

    private func validateListing(
        _ listing: FileListing,
        expectedPath: String
    ) -> ValidatedListing? {
        guard listing.path == expectedPath,
              listing.entries.count <= 16,
              !listing.more || (listing.cursor ?? 0) >= 1
        else { return nil }

        let validEntries = listing.entries.allSatisfy { entry in
            guard (entry.kind == "file" || entry.kind == "folder"),
                  let name = try? GuestFilePath(entry.name),
                  name.components.count == 1,
                  entry.fileType.map({
                      $0.unicodeScalars.count <= 4
                  }) ?? true,
                  entry.creator.map({
                      $0.unicodeScalars.count <= 4
                  }) ?? true,
                  entry.dataBytes.map({ $0 >= 0 }) ?? true,
                  entry.rsrcBytes.map({ $0 >= 0 }) ?? true
            else { return false }
            if let identity = entry.identity,
               !Self.isValidGuestIdentity(identity) {
                return false
            }
            guard let modified = entry.modified else { return true }
            return modified >= 0 && UInt64(modified) <= UInt64(UInt32.max)
        }
        guard validEntries else { return nil }

        return ValidatedListing(
            entries: listing.entries,
            nextCursor: listing.more ? listing.cursor : nil,
            rootLabel: listing.root.map {
                String($0.unicodeScalars.prefix(128))
            })
    }

    private func observedEntry(
        _ entry: FileEntry,
        parent: GuestFilePath,
        sessionID: UUID,
        observedAt: Date
    )
        -> GuestFileObservedEntry {
        let path = parent.wireValue.isEmpty
            ? entry.name : parent.wireValue + ":" + entry.name
        let reference = entry.identity.map {
            rememberObservation(
                identity: $0, path: path, sessionID: sessionID,
                observedAt: observedAt)
        }
        return GuestFileObservedEntry(
            path: path,
            name: entry.name,
            isFolder: entry.isFolder,
            fileType: entry.fileType,
            creator: entry.creator,
            dataBytes: entry.dataBytes,
            resourceBytes: entry.rsrcBytes,
            modified: entry.modified,
            observationReference: reference)
    }

    /// Resolves no authority on its own. Future mutations must also carry the
    /// returned guest token over the wire and have the guest recompute it
    /// immediately before acting.
    func resolveObservation(reference: String, path: String)
        -> GuestFileMutationPrecondition? {
        pruneObservations()
        guard let observation = observations[reference],
              observation.expiresAt >= clock(),
              observation.sessionID == currentSessionID(),
              observation.policyVersion == policy.snapshot.version,
              observation.path == path
        else { return nil }
        return .init(
            sessionID: observation.sessionID,
            policyVersion: observation.policyVersion,
            path: observation.path,
            guestIdentity: observation.guestIdentity)
    }

    private struct Observation {
        let sessionID: UUID
        let policyVersion: Int
        let path: String
        let guestIdentity: String
        let expiresAt: Date
    }

    private func rememberObservation(
        identity: String,
        path: String,
        sessionID: UUID,
        observedAt: Date
    ) -> String {
        pruneObservations()
        if observations.count >= Self.maximumObservations,
           let first = observations.keys.sorted().first {
            observations.removeValue(forKey: first)
        }
        let reference =
            "now-file-\(UUID().uuidString.lowercased())"
        observations[reference] = Observation(
            sessionID: sessionID,
            policyVersion: policy.snapshot.version,
            path: path,
            guestIdentity: identity,
            expiresAt: observedAt.addingTimeInterval(
                Self.observationLifetime))
        return reference
    }

    private func pruneObservations() {
        let now = clock()
        let sessionID = currentSessionID()
        observations = observations.filter {
            $0.value.expiresAt >= now
                && $0.value.sessionID == sessionID
                && $0.value.policyVersion == policy.snapshot.version
        }
    }

    private static func isValidGuestIdentity(_ value: String) -> Bool {
        value.count == 16 && value.allSatisfy {
            $0.isNumber || ("a"..."f").contains($0)
        }
    }

    private func listOnce(path: String, cursor: Int?) async
        -> Result<FileListing, GuestListener.FileFailure> {
        await withCheckedContinuation { continuation in
            listener.listFiles(path: path, cursor: cursor) {
                continuation.resume(returning: $0)
            }
        }
    }

    private struct Context {
        let commandID: UUID
        let sessionID: UUID?
        let policyVersion: Int
        let operation: GuestFileCommandKind
        let startedAt: Date
        let path: String
    }

    private func begin(_ operation: GuestFileCommandKind, path: String)
        -> Context {
        let context = Context(
            commandID: UUID(),
            sessionID: currentSessionID(),
            policyVersion: policy.snapshot.version,
            operation: operation,
            startedAt: clock(),
            path: path)
        audit(.info, "\(tag(context)) started path=\(quoted(path)) "
              + "policy=\(context.policyVersion)")
        return context
    }

    private func finish<Value: Sendable>(
        _ context: Context,
        outcome: GuestFileCommandOutcome,
        wireRequests: Int,
        value: Value? = nil,
        failure: GuestFileCommandFailure? = nil
    ) -> GuestFileCommandResponse<Value> {
        let completedAt = clock()
        let receipt = GuestFileCommandReceipt(
            commandID: context.commandID,
            sessionID: context.sessionID,
            policyVersion: context.policyVersion,
            operation: context.operation,
            startedAt: context.startedAt,
            completedAt: completedAt,
            outcome: outcome,
            wireRequestCount: wireRequests,
            affectedPaths: context.path.isEmpty ? [] : [context.path])
        let level: HostLog.LogLevel =
            outcome == .success ? .info : .warn
        audit(level, "\(tag(context)) \(outcome.rawValue) "
              + "wireRequests=\(wireRequests)"
              + (failure.map { " code=\($0.code)" } ?? ""))
        return GuestFileCommandResponse(
            receipt: receipt, value: value, failure: failure)
    }

    private func finish<Value: Sendable>(
        _ context: Context,
        failure: GuestListener.FileFailure,
        wireRequests: Int
    ) -> GuestFileCommandResponse<Value> {
        let outcome: GuestFileCommandOutcome
        let code: String
        switch failure.code {
        case "disconnected":
            outcome = .unavailable
            code = "now-guest-unavailable"
        case "not-found":
            outcome = .notFound
            code = "now-files-not-found"
        default:
            outcome = .refused
            let suffix = bounded(failure.code, scalars: 48)
            code = "now-files-\(suffix)"
        }
        return finish(
            context, outcome: outcome, wireRequests: wireRequests,
            failure: .init(
                code: bounded(code, scalars: 64),
                message: bounded(failure.message, scalars: 256)))
    }

    private func finishUnavailable<Value: Sendable>(_ context: Context)
        -> GuestFileCommandResponse<Value> {
        finish(
            context, outcome: .unavailable, wireRequests: 0,
            failure: .init(
                code: "now-guest-unavailable",
                message: "No paired New Old World guest is available"))
    }

    private func finishInvalidPath<Value: Sendable>(_ context: Context)
        -> GuestFileCommandResponse<Value> {
        finishRefused(
            context, code: "now-files-path-invalid",
            message:
                "Path must be canonical, root-relative, and HFS-representable")
    }

    private func finishRefused<Value: Sendable>(
        _ context: Context,
        code: String,
        message: String,
        wireRequests: Int = 0
    ) -> GuestFileCommandResponse<Value> {
        finish(
            context, outcome: .refused, wireRequests: wireRequests,
            failure: .init(code: code, message: message))
    }

    private func finishInvalidListing<Value: Sendable>(
        _ context: Context,
        wireRequests: Int
    ) -> GuestFileCommandResponse<Value> {
        finishRefused(
            context, code: "now-files-listing-invalid",
            message: "The guest returned an invalid or unbounded listing",
            wireRequests: wireRequests)
    }

    private func finishStale<Value: Sendable>(
        _ context: Context,
        wireRequests: Int
    ) -> GuestFileCommandResponse<Value> {
        finish(
            context, outcome: .staleSession, wireRequests: wireRequests,
            failure: .init(
                code: "now-session-stale",
                message:
                    "The paired guest session changed during the command"))
    }

    private func tag(_ context: Context) -> String {
        "@\(context.commandID.uuidString.prefix(8)) "
            + "guestFiles.\(context.operation.rawValue)"
    }

    private func quoted(_ value: String) -> String {
        value.debugDescription
    }

    private func bounded(_ value: String, scalars: Int) -> String {
        String(value.unicodeScalars.prefix(scalars))
    }
}
