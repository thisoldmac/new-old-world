import Foundation

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

    init(
        listener: GuestListener,
        policy: GuestFileAccessPolicy,
        currentSessionID: @escaping () -> UUID?,
        audit: Audit? = nil,
        maximumStatPages: Int = 8
    ) {
        self.listener = listener
        self.policy = policy
        self.currentSessionID = currentSessionID
        self.audit = audit ?? {
            HostLog.shared.write($0, "files", $1)
        }
        self.maximumStatPages = max(1, maximumStatPages)
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
            let capabilities = GuestFileCapabilities(
                guestRoot: root.wireValue,
                rootLabel: validated.rootLabel,
                availableCommands: [.capabilities, .list, .stat],
                deferredCommands: [
                    .download, .readText, .tailText, .put, .mkdir,
                    .move, .delete, .deployTree, .prune,
                ],
                maximumPageEntries: 16,
                maximumStatPages: maximumStatPages,
                maximumPathBytes: GuestFilePath.maximumWireBytes,
                maximumSegmentBytes: GuestFilePath.maximumSegmentBytes,
                transferLaneState: transferLaneState,
                observedAt: Date())
            return finish(
                context, outcome: .success, wireRequests: 1,
                value: capabilities)
        case .failure(let failure):
            return finish(context, failure: failure, wireRequests: 1)
        }
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
            let observedAt = Date()
            let entries = validated.entries.map {
                observedEntry($0, parent: scoped)
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

        var cursor: Int?
        for page in 1...maximumStatPages {
            let result = await listOnce(
                path: wireParent.wireValue, cursor: cursor)
            guard currentSessionID() == sessionID else {
                return finishStale(context, wireRequests: page)
            }
            switch result {
            case .failure(let failure):
                return finish(
                    context, failure: failure, wireRequests: page)
            case .success(let listing):
                guard let validated = validateListing(
                    listing, expectedPath: wireParent.wireValue)
                else {
                    return finishInvalidListing(
                        context, wireRequests: page)
                }
                if let match = validated.entries.first(where: {
                    $0.name == leaf
                }) {
                    return finish(
                        context, outcome: .success, wireRequests: page,
                        value: observedEntry(match, parent: scoped.parent))
                }
                guard let next = validated.nextCursor else {
                    return finish(
                        context, outcome: .notFound, wireRequests: page,
                        failure: .init(
                            code: "now-files-not-found",
                            message:
                                "No exact item was observed at that path"))
                }
                cursor = next
            }
        }
        return finish(
            context, outcome: .scanLimit,
            wireRequests: maximumStatPages,
            failure: .init(
                code: "now-files-scan-limit",
                message:
                    "The bounded parent scan ended before that item was observed"))
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

    private func observedEntry(_ entry: FileEntry, parent: GuestFilePath)
        -> GuestFileObservedEntry {
        let path = parent.wireValue.isEmpty
            ? entry.name : parent.wireValue + ":" + entry.name
        return GuestFileObservedEntry(
            path: path,
            name: entry.name,
            isFolder: entry.isFolder,
            fileType: entry.fileType,
            creator: entry.creator,
            dataBytes: entry.dataBytes,
            resourceBytes: entry.rsrcBytes,
            modified: entry.modified)
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
    }

    private func begin(_ operation: GuestFileCommandKind, path: String)
        -> Context {
        let context = Context(
            commandID: UUID(),
            sessionID: currentSessionID(),
            policyVersion: policy.snapshot.version,
            operation: operation,
            startedAt: Date())
        audit(.info, "\(tag(context)) started path=\(quoted(path)) "
              + "policy=\(context.policyVersion)")
        return context
    }

    private func finish<Value>(
        _ context: Context,
        outcome: GuestFileCommandOutcome,
        wireRequests: Int,
        value: Value? = nil,
        failure: GuestFileCommandFailure? = nil
    ) -> GuestFileCommandResponse<Value> {
        let completedAt = Date()
        let receipt = GuestFileCommandReceipt(
            commandID: context.commandID,
            sessionID: context.sessionID,
            policyVersion: context.policyVersion,
            operation: context.operation,
            startedAt: context.startedAt,
            completedAt: completedAt,
            outcome: outcome,
            wireRequestCount: wireRequests)
        let level: HostLog.LogLevel =
            outcome == .success ? .info : .warn
        audit(level, "\(tag(context)) \(outcome.rawValue) "
              + "wireRequests=\(wireRequests)"
              + (failure.map { " code=\($0.code)" } ?? ""))
        return GuestFileCommandResponse(
            receipt: receipt, value: value, failure: failure)
    }

    private func finish<Value>(
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

    private func finishUnavailable<Value>(_ context: Context)
        -> GuestFileCommandResponse<Value> {
        finish(
            context, outcome: .unavailable, wireRequests: 0,
            failure: .init(
                code: "now-guest-unavailable",
                message: "No paired New Old World guest is available"))
    }

    private func finishInvalidPath<Value>(_ context: Context)
        -> GuestFileCommandResponse<Value> {
        finishRefused(
            context, code: "now-files-path-invalid",
            message:
                "Path must be canonical, root-relative, and HFS-representable")
    }

    private func finishRefused<Value>(
        _ context: Context,
        code: String,
        message: String,
        wireRequests: Int = 0
    ) -> GuestFileCommandResponse<Value> {
        finish(
            context, outcome: .refused, wireRequests: wireRequests,
            failure: .init(code: code, message: message))
    }

    private func finishInvalidListing<Value>(
        _ context: Context,
        wireRequests: Int
    ) -> GuestFileCommandResponse<Value> {
        finishRefused(
            context, code: "now-files-listing-invalid",
            message: "The guest returned an invalid or unbounded listing",
            wireRequests: wireRequests)
    }

    private func finishStale<Value>(
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
