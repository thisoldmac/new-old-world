import Foundation

/// NOW-owned staged upload command family.
///
/// Staging accepts bytes, never a modern-host path. The final command enters
/// the existing one-at-a-time `file.offer` lane with overwrite disabled.
@MainActor
final class GuestFileUploadCommands {
    typealias Audit = (HostLog.LogLevel, String) -> Void

    private struct Authority {
        let sessionID: UUID
        let policyVersion: Int
        let destination: GuestFilePath
        let wireParent: GuestFilePath
        let name: String
        let container: String
        let fileType: String?
        let creator: String?
        let modified: Int?
        let sha256: String
    }

    private struct Context {
        let commandID: UUID
        let sessionID: UUID?
        let policyVersion: Int
        let startedAt: Date
        let path: String
    }

    private let listener: GuestListener
    private let policy: GuestFileAccessPolicy
    private let currentSessionID: () -> UUID?
    private let audit: Audit
    private let staging: GuestUploadStagingStore?
    private let clock: @Sendable () -> Date
    private var authorities: [UUID: Authority] = [:]
    private var committing: Set<UUID> = []
    private var consumed: [UUID] = []
    private var expirationTasks: [UUID: Task<Void, Never>] = [:]

    init(
        listener: GuestListener,
        policy: GuestFileAccessPolicy,
        currentSessionID: @escaping () -> UUID?,
        audit: @escaping Audit,
        staging: GuestUploadStagingStore?,
        clock: @escaping @Sendable () -> Date
    ) {
        self.listener = listener
        self.policy = policy
        self.currentSessionID = currentSessionID
        self.audit = audit
        self.staging = staging
        self.clock = clock
    }

    var isAvailable: Bool { staging != nil }

    func begin(_ request: GuestFileUploadBeginRequest) async
        -> GuestFileCommandResponse<GuestFileUploadStageStatus> {
        let context = start(path: request.destinationPath)
        guard let sessionID = context.sessionID else {
            return unavailable(context)
        }
        guard let staging else {
            return refused(
                context,
                code: "now-files-staging-unavailable",
                message: "Private upload staging is unavailable")
        }

        let destination: GuestFilePath
        let wireDestination: GuestFilePath
        do {
            destination = try GuestFilePath(request.destinationPath)
            guard destination.leaf != nil else {
                return refused(
                    context,
                    code: "now-files-path-invalid",
                    message: "Upload requires one file below guestRoot")
            }
            wireDestination = try destination.appending(
                to: policy.snapshot.guestRoot)
        } catch {
            return refused(
                context,
                code: "now-files-path-invalid",
                message:
                    "Path must be canonical, root-relative, and HFS-representable")
        }
        guard request.container == "data"
                || request.container == "macbinary" else {
            return refused(
                context,
                code: "now-files-container-invalid",
                message: "Upload container must be data or macbinary")
        }
        guard validOSType(request.fileType),
              validOSType(request.creator) else {
            return refused(
                context,
                code: "now-files-metadata-invalid",
                message:
                    "Classic file type and creator must be four MacRoman characters")
        }
        if request.container == "macbinary",
           request.fileType != nil || request.creator != nil {
            return refused(
                context,
                code: "now-files-metadata-invalid",
                message:
                    "MacBinary carries its own classic type and creator metadata")
        }

        switch await staging.begin(
            expectedBytes: request.bytes,
            expectedSHA256: request.sha256) {
        case .failure(let failure):
            return refused(
                context, code: failure.code, message: failure.message)
        case .success(let status):
            let authority = Authority(
                sessionID: sessionID,
                policyVersion: policy.snapshot.version,
                destination: destination,
                wireParent: wireDestination.parent,
                name: wireDestination.leaf!,
                container: request.container,
                fileType: request.fileType,
                creator: request.creator,
                // A classic file date is unsigned seconds since 1904
                // (good to ~2040); the guest now parses it unsigned
                // (now_json_find_u32, now-guest-ppc/src/core/json.c).
                // This used to clamp at Int32.max instead (~Jan 1972,
                // the deployed guest's OLD signed strtol ceiling) and
                // silently dropped every modern date - the same
                // regression ClassicDate.guestWireSeconds carried and
                // is fixed there; this is an independent duplicate of
                // that clamp for the agent-upload path, not something
                // ClassicDate's fix reaches on its own. Omission stays
                // the canonical safe behavior for a genuinely
                // unrepresentable (pre-1904 or post-2040) date.
                modified: request.modified.flatMap {
                    $0 >= 0 && $0 <= Int(UInt32.max) ? $0 : nil
                },
                sha256: request.sha256)
            authorities[status.uploadID] = authority
            scheduleExpiry(status)
            return finish(
                context, outcome: .success, wireRequests: 0,
                value: stageValue(status, authority: authority))
        }
    }

    func append(uploadID: UUID, offset: Int, bytes: Data) async
        -> GuestFileCommandResponse<GuestFileUploadStageStatus> {
        let authority = authorities[uploadID]
        let context = context(path: authority?.destination.wireValue ?? "")
        guard let authority else {
            return refused(
                context,
                code: missingCode(uploadID),
                message: missingMessage(uploadID),
                auditOutcome: true)
        }
        guard !committing.contains(uploadID) else {
            return refused(
                context,
                code: "now-files-upload-conflict",
                message: "The staged upload is being committed",
                auditOutcome: true)
        }
        guard stillCurrent(authority) else {
            await discard(uploadID)
            return stale(context)
        }
        guard let staging else {
            return refused(
                context,
                code: "now-files-staging-unavailable",
                message: "Private upload staging is unavailable",
                auditOutcome: true)
        }
        switch await staging.append(
            uploadID: uploadID, offset: offset, bytes: bytes) {
        case .success(let status):
            // Receipts provide per-call accountability; successful chunks do
            // not spam the human log.
            return finish(
                context, outcome: .success, wireRequests: 0,
                value: stageValue(status, authority: authority),
                auditOutcome: false)
        case .failure(let failure):
            return refused(
                context, code: failure.code, message: failure.message,
                auditOutcome: true)
        }
    }

    func commit(uploadID: UUID) async
        -> GuestFileCommandResponse<GuestFileUploadTransferReceipt> {
        let authority = authorities[uploadID]
        let context = start(path: authority?.destination.wireValue ?? "")
        guard let authority else {
            return refused(
                context,
                code: missingCode(uploadID),
                message: missingMessage(uploadID))
        }
        guard !committing.contains(uploadID) else {
            return refused(
                context,
                code: "now-files-upload-conflict",
                message: "The staged upload is already being committed")
        }
        guard stillCurrent(authority) else {
            await discard(uploadID)
            return stale(context)
        }
        guard let staging else {
            return refused(
                context,
                code: "now-files-staging-unavailable",
                message: "Private upload staging is unavailable")
        }
        let sealed: GuestUploadStagingStore.SealedUpload
        switch await staging.seal(uploadID: uploadID) {
        case .success(let value):
            sealed = value
        case .failure(let failure):
            if failure.code == "now-files-integrity-failed" {
                authorities.removeValue(forKey: uploadID)
            }
            return refused(
                context, code: failure.code, message: failure.message)
        }
        if authority.container == "macbinary" {
            do {
                let reader = try sealed.source.openReader()
                let header = try await reader.readAsync(
                    offset: 0, count: min(128, sealed.status.expectedBytes))
                guard OutboundFile.validMacBinaryHeader(
                    header, totalBytes: sealed.status.expectedBytes) else {
                    await discard(uploadID)
                    return refused(
                        context,
                        code: "now-files-container-invalid",
                        message:
                            "The staged bytes are not a complete MacBinary artifact")
                }
            } catch {
                await discard(uploadID)
                return refused(
                    context,
                    code: "now-files-staging-changed",
                    message: "The sealed upload could not be revalidated")
            }
        }
        guard stillCurrent(authority) else {
            await discard(uploadID)
            return stale(context)
        }

        committing.insert(uploadID)
        expirationTasks.removeValue(forKey: uploadID)?.cancel()
        let result = await put(
            authority: authority, source: sealed.source)
        committing.remove(uploadID)
        let cleanup = await staging.finish(uploadID: uploadID)
        if cleanup == .cleanupNeeded {
            audit(
                .warn,
                "\(tag(context)) cleanup-needed for private staging")
        }
        authorities.removeValue(forKey: uploadID)
        consumed.append(uploadID)
        if consumed.count > 64 {
            consumed.removeFirst(consumed.count - 64)
        }
        guard stillCurrent(authority) else {
            let evidence: GuestFileTransferFailureEvidence?
            switch result {
            case .success(let receipt):
                evidence = failureEvidence(
                    receipt, hostCleanup: cleanup.rawValue)
            case .failure(let failure):
                evidence = failure.putEvidence.map {
                    failureEvidence($0, hostCleanup: cleanup.rawValue)
                }
            }
            return finish(
                context, outcome: .failed, wireRequests: 1,
                failure: .init(
                    code: "now-files-outcome-unknown",
                    message:
                        "The guest session changed while upload was in flight",
                    transferEvidence: evidence))
        }
        switch result {
        case .success(let wire):
            guard wire.totalBytes == sealed.status.expectedBytes,
                  wire.receiverConfirmedBytes == wire.totalBytes else {
                return finish(
                    context, outcome: .failed, wireRequests: 1,
                    failure: .init(
                        code: "now-files-receipt-invalid",
                        message:
                            "The guest completion did not confirm all declared bytes"))
            }
            let stalled: String
            if let gap = wire.maximumProgressGapMs {
                stalled = gap >= 15_000 ? "observed" : "not-observed"
            } else {
                stalled = "unknown"
            }
            let receipt = GuestFileUploadTransferReceipt(
                uploadID: uploadID,
                destinationPath: authority.destination.wireValue,
                container: authority.container,
                sha256: authority.sha256,
                totalBytes: wire.totalBytes,
                acceptedOffset: wire.acceptedOffset,
                receiverConfirmedBytes: wire.receiverConfirmedBytes,
                elapsedMs: wire.elapsedMs,
                averageBytesPerSecond: wire.averageBytesPerSecond,
                stalledState: stalled,
                maximumProgressGapMs: wire.maximumProgressGapMs,
                progressEvidence: wire.progressEvidence,
                guestFreeBytesBefore: wire.guestFreeBytesBefore,
                guestReservedBytes: wire.guestReservedBytes,
                guestStaging: wire.guestStaging,
                finalization: wire.finalization,
                destinationAcknowledged: true,
                integrity: wire.integrity,
                hostStagingCleanup: cleanup.rawValue,
                guestCleanup: wire.cleanup)
            return finish(
                context, outcome: .success, wireRequests: 1,
                value: receipt)
        case .failure(let failure):
            let outcome: GuestFileCommandOutcome
            switch failure.code {
            case "disconnected":
                outcome = .unavailable
            case "exists":
                outcome = .conflict
            case "timeout", "io-error":
                outcome = .failed
            default:
                outcome = .refused
            }
            return finish(
                context, outcome: outcome, wireRequests: 1,
                failure: .init(
                    code: wireFailureCode(failure.code),
                    message: bounded(failure.message, scalars: 256),
                    transferEvidence:
                        failure.putEvidence.map {
                            failureEvidence(
                                $0, hostCleanup: cleanup.rawValue)
                        }))
        }
    }

    private func put(
        authority: Authority,
        source: OutboundFileSource
    ) async -> Result<GuestListener.PutReceipt, GuestListener.FileFailure> {
        await withCheckedContinuation { continuation in
            listener.putStagedFileWithReceipt(
                name: authority.name,
                into: authority.wireParent.wireValue,
                container: authority.container,
                source: source,
                fileType: authority.fileType,
                creator: authority.creator,
                modified: authority.modified,
                overwrite: false
            ) {
                continuation.resume(returning: $0)
            }
        }
    }

    private func stillCurrent(_ authority: Authority) -> Bool {
        currentSessionID() == authority.sessionID
            && policy.snapshot.version == authority.policyVersion
    }

    private func discard(_ uploadID: UUID) async {
        expirationTasks.removeValue(forKey: uploadID)?.cancel()
        committing.remove(uploadID)
        authorities.removeValue(forKey: uploadID)
        if let staging {
            let cleanup = await staging.discard(uploadID)
            if cleanup == .cleanupNeeded {
                audit(
                    .warn,
                    "@\(uploadID.uuidString.prefix(8)) guestFiles.put "
                        + "cleanup-needed for private staging")
            }
        }
    }

    private func scheduleExpiry(_ status: GuestUploadStagingStore.Status) {
        expirationTasks.removeValue(forKey: status.uploadID)?.cancel()
        let delay = max(0, status.expiresAt.timeIntervalSince(clock()))
        expirationTasks[status.uploadID] = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self,
                  !self.committing.contains(status.uploadID) else {
                return
            }
            await self.discard(status.uploadID)
            self.audit(
                .info,
                "@\(status.uploadID.uuidString.prefix(8)) guestFiles.put "
                    + "expired private staging")
        }
    }

    private func missingCode(_ uploadID: UUID) -> String {
        consumed.contains(uploadID)
            ? "now-files-upload-replayed"
            : "now-files-upload-expired"
    }

    private func missingMessage(_ uploadID: UUID) -> String {
        consumed.contains(uploadID)
            ? "The staged upload was already committed"
            : "The staged upload is missing or expired"
    }

    private func stageValue(
        _ status: GuestUploadStagingStore.Status,
        authority: Authority
    ) -> GuestFileUploadStageStatus {
        .init(
            uploadID: status.uploadID,
            destinationPath: authority.destination.wireValue,
            expectedBytes: status.expectedBytes,
            receivedBytes: status.receivedBytes,
            maximumChunkBytes: status.maximumChunkBytes,
            expiresAt: status.expiresAt,
            hostAvailableBytesAtStart:
                status.hostAvailableBytesAtStart,
            hostReservedBytes: status.hostReservedBytes,
            sealed: status.sealed)
    }

    private func validOSType(_ value: String?) -> Bool {
        guard let value else { return true }
        guard value.unicodeScalars.count == 4 else { return false }
        return value.data(
            using: .macOSRoman, allowLossyConversion: false) != nil
    }

    private func start(path: String) -> Context {
        let context = self.context(path: path)
        audit(
            .info,
            "\(tag(context)) started path=\(path.debugDescription) "
                + "policy=\(context.policyVersion)")
        return context
    }

    private func context(path: String) -> Context {
        .init(
            commandID: UUID(),
            sessionID: currentSessionID(),
            policyVersion: policy.snapshot.version,
            startedAt: clock(),
            path: path)
    }

    private func finish<Value: Sendable>(
        _ context: Context,
        outcome: GuestFileCommandOutcome,
        wireRequests: Int,
        value: Value? = nil,
        failure: GuestFileCommandFailure? = nil,
        auditOutcome: Bool = true
    ) -> GuestFileCommandResponse<Value> {
        let completedAt = clock()
        let receipt = GuestFileCommandReceipt(
            commandID: context.commandID,
            sessionID: context.sessionID,
            policyVersion: context.policyVersion,
            operation: .put,
            startedAt: context.startedAt,
            completedAt: completedAt,
            outcome: outcome,
            wireRequestCount: wireRequests,
            affectedPaths: context.path.isEmpty ? [] : [context.path])
        if auditOutcome {
            let level: HostLog.LogLevel =
                outcome == .success ? .info : .warn
            audit(
                level,
                "\(tag(context)) \(outcome.rawValue) "
                    + "wireRequests=\(wireRequests)"
                    + (failure.map { " code=\($0.code)" } ?? ""))
        }
        return .init(receipt: receipt, value: value, failure: failure)
    }

    private func unavailable<Value: Sendable>(_ context: Context)
        -> GuestFileCommandResponse<Value> {
        finish(
            context, outcome: .unavailable, wireRequests: 0,
            failure: .init(
                code: "now-guest-unavailable",
                message: "No paired New Old World guest is available"))
    }

    private func stale<Value: Sendable>(_ context: Context)
        -> GuestFileCommandResponse<Value> {
        finish(
            context, outcome: .staleSession, wireRequests: 0,
            failure: .init(
                code: "now-session-stale",
                message:
                    "The paired guest session or guestRoot policy changed"))
    }

    private func refused<Value: Sendable>(
        _ context: Context,
        code: String,
        message: String,
        auditOutcome: Bool = true
    ) -> GuestFileCommandResponse<Value> {
        let outcome: GuestFileCommandOutcome
        if code.contains("expired") {
            outcome = .expired
        } else if code.contains("conflict")
                    || code.contains("replayed") {
            outcome = .conflict
        } else {
            outcome = .refused
        }
        return finish(
            context, outcome: outcome, wireRequests: 0,
            failure: .init(
                code: bounded(code, scalars: 64),
                message: bounded(message, scalars: 256)),
            auditOutcome: auditOutcome)
    }

    private func wireFailureCode(_ code: String) -> String {
        switch code {
        case "disconnected": "now-guest-unavailable"
        case "exists": "now-files-destination-exists"
        case "too-big": "now-files-insufficient-guest-space"
        case "timeout": "now-files-outcome-unknown"
        default: "now-files-\(bounded(code, scalars: 48))"
        }
    }

    private func failureEvidence(
        _ wire: GuestListener.PutFailureEvidence,
        hostCleanup: String
    ) -> GuestFileTransferFailureEvidence {
        let stalled: String
        if let gap = wire.maximumProgressGapMs {
            stalled = gap >= 15_000 ? "observed" : "not-observed"
        } else {
            stalled = "unknown"
        }
        return .init(
            totalBytes: wire.totalBytes,
            acceptedOffset: wire.acceptedOffset,
            receiverConfirmedBytes: wire.receiverConfirmedBytes,
            elapsedMs: wire.elapsedMs,
            stalledState: stalled,
            maximumProgressGapMs: wire.maximumProgressGapMs,
            progressEvidence: wire.progressEvidence,
            guestFreeBytesBefore: wire.guestFreeBytesBefore,
            guestReservedBytes: wire.guestReservedBytes,
            guestStaging: wire.guestStaging,
            hostStagingCleanup: hostCleanup,
            guestCleanup: wire.guestCleanup)
    }

    private func failureEvidence(
        _ wire: GuestListener.PutReceipt,
        hostCleanup: String
    ) -> GuestFileTransferFailureEvidence {
        let stalled: String
        if let gap = wire.maximumProgressGapMs {
            stalled = gap >= 15_000 ? "observed" : "not-observed"
        } else {
            stalled = "unknown"
        }
        return .init(
            totalBytes: wire.totalBytes,
            acceptedOffset: wire.acceptedOffset,
            receiverConfirmedBytes: wire.receiverConfirmedBytes,
            elapsedMs: wire.elapsedMs,
            stalledState: stalled,
            maximumProgressGapMs: wire.maximumProgressGapMs,
            progressEvidence: wire.progressEvidence,
            guestFreeBytesBefore: wire.guestFreeBytesBefore,
            guestReservedBytes: wire.guestReservedBytes,
            guestStaging: wire.guestStaging,
            hostStagingCleanup: hostCleanup,
            guestCleanup: wire.cleanup)
    }

    private func tag(_ context: Context) -> String {
        "@\(context.commandID.uuidString.prefix(8)) guestFiles.put"
    }

    private func bounded(_ value: String, scalars: Int) -> String {
        String(value.unicodeScalars.prefix(scalars))
    }
}
