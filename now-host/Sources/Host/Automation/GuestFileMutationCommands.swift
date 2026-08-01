import Foundation
import NOWAgentIntegration

/// The NOW-owned command seam for the four catalog mutations.
///
/// It is the mutating sibling of `GuestFilesCommands`' observation half and
/// keeps that file's discipline exactly: validate and rebase the caller's
/// paths beneath the policy root, log the start with the path and the outcome
/// with its code, and answer with a receipt whether it worked or not.
///
/// **One wire request, and never two.** Every mutation here is exactly one
/// `file.move` / `file.trash` / `file.restore` / `file.mkdir` and the one
/// `file.result` that answers it. There is deliberately no preflight listing:
/// whether the item is there and whether the destination is free are the
/// guest's answers, given atomically at the moment it acts, and a host that
/// asked first would be replacing a live answer with a stale one — and would
/// spend two round trips of a 68030's time to do it. What this layer owns is
/// the authority (the root), the bound (one item, one attempt), and the
/// translation of the guest's own `file.result` code into a typed outcome.
///
/// **Overwrite is not a parameter.** `GuestListener.moveFile` takes one and
/// this layer never passes it, so the agent lane cannot replace anything: a
/// collision comes back as the guest's `exists`, rendered `conflict`. The
/// human Files lane does not pass it either — the difference is that here it
/// is not reachable at all.
@MainActor
final class GuestFileMutationCommands {
    typealias Audit = (HostLog.LogLevel, String) -> Void

    private let listener: GuestListener
    private let policy: GuestFileAccessPolicy
    private let currentSessionID: () -> UUID?
    private let audit: Audit
    private let clock: () -> Date

    init(
        listener: GuestListener,
        policy: GuestFileAccessPolicy,
        currentSessionID: @escaping () -> UUID?,
        audit: @escaping Audit,
        clock: @escaping () -> Date = Date.init
    ) {
        self.listener = listener
        self.policy = policy
        self.currentSessionID = currentSessionID
        self.audit = audit
        self.clock = clock
    }

    func mutate(_ request: AgentIntegrationGuestFileMutationRequest) async
        -> GuestFileCommandResponse<GuestFileMutationReport> {
        let kind = Self.kind(of: request.mutation)
        let context = begin(kind, path: request.path)
        guard let sessionID = context.sessionID else {
            return finishUnavailable(context)
        }

        let scoped: GuestFilePath
        let wirePath: GuestFilePath
        do {
            scoped = try GuestFilePath(request.path)
            guard !scoped.wireValue.isEmpty else {
                return finishRefused(
                    context, code: "now-files-path-invalid",
                    message:
                        "A mutation names one item below guestRoot, never the root itself")
            }
            wirePath = try scoped.appending(to: policy.snapshot.guestRoot)
        } catch {
            return finishInvalidPath(context)
        }

        /* The move's second path gets the same treatment as the first: the
           destination is composed beneath the same root, so a caller cannot
           move something out of the share by naming where it lands. */
        var wireDestination: GuestFilePath?
        if let destination = request.destinationPath {
            do {
                let scopedDestination = try GuestFilePath(destination)
                guard !scopedDestination.wireValue.isEmpty else {
                    return finishRefused(
                        context, code: "now-files-path-invalid",
                        message:
                            "A move names where it is going, below guestRoot")
                }
                wireDestination = try scopedDestination.appending(
                    to: policy.snapshot.guestRoot)
            } catch {
                return finishInvalidPath(context)
            }
        }

        let result = await perform(
            request, path: wirePath, destination: wireDestination)
        guard currentSessionID() == sessionID else {
            return finishStale(context, wireRequests: 1)
        }

        switch result {
        case .failure(let failure):
            return finish(context, failure: failure, wireRequests: 1)
        case .success(let answer):
            /* `.success` here means `file.result ok:true` and nothing else:
               `GuestListener.resolveChange` collapses an `ok:false` answer
               into a `.failure` carrying the guest's own `code`, so the
               contract's closed refusal vocabulary — `exists`, `not-found`,
               `bad-path`, `io-error`, `busy` — arrives on the branch above
               rather than here. Worth knowing before adding an `ok` check
               that could never fire.

               The guest's `path` is absolute on that volume and the caller's
               vocabulary is root-relative, so the answer is stated in the
               caller's terms: for everything but a move, the item is where
               the request said it would be. A `path` we cannot express
               root-relative is reported absent rather than leaked. */
            let landed: String? = {
                switch request.mutation {
                case .move: return request.destinationPath
                case .mkdir, .restore: return request.path
                case .trash: return nil
                }
            }()
            return finish(
                context, outcome: .success, wireRequests: 1,
                value: GuestFileMutationReport(
                    mutation: request.mutation,
                    path: landed,
                    trashedAs: request.mutation == .trash
                        ? answer.trashedAs.map(Self.boundedName) : nil,
                    observedAt: clock()))
        }
    }

    private func perform(
        _ request: AgentIntegrationGuestFileMutationRequest,
        path: GuestFilePath,
        destination: GuestFilePath?
    ) async -> Result<FileResult, GuestListener.FileFailure> {
        await withCheckedContinuation { continuation in
            let answer: (Result<FileResult, GuestListener.FileFailure>)
                -> Void = { continuation.resume(returning: $0) }
            switch request.mutation {
            case .move:
                guard let destination else {
                    /* Unreachable: only the failable initialisers can build
                       a move, and they require a destination. */
                    return answer(.failure(.init(
                        code: "bad-path",
                        message: "A move names where it is going")))
                }
                listener.moveFile(from: path.wireValue,
                                  to: destination.wireValue,
                                  completion: answer)
            case .trash:
                listener.trashFile(path: path.wireValue, completion: answer)
            case .restore:
                guard let trashedAs = request.trashedAs else {
                    return answer(.failure(.init(
                        code: "bad-path",
                        message:
                            "A restore names the item's name in the Trash")))
                }
                listener.restoreFile(trashedAs: trashedAs,
                                     to: path.wireValue,
                                     completion: answer)
            case .mkdir:
                listener.makeFolder(path: path.wireValue, completion: answer)
            }
        }
    }

    private static func kind(
        of mutation: AgentIntegrationGuestFileMutation
    ) -> GuestFileCommandKind {
        switch mutation {
        case .move: return .move
        case .trash: return .trash
        case .restore: return .restore
        case .mkdir: return .mkdir
        }
    }

    /// A name that came off the wire, bounded before it is carried further.
    private static func boundedName(_ value: String) -> String {
        String(value.unicodeScalars.prefix(
            AgentIntegrationGuestFilePolicy.maximumSegmentScalars))
    }

    // MARK: - Receipts

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
        audit(.info, "\(tag(context)) started path=\(path.debugDescription) "
              + "policy=\(context.policyVersion)")
        return context
    }

    private func finish(
        _ context: Context,
        outcome: GuestFileCommandOutcome,
        wireRequests: Int,
        value: GuestFileMutationReport? = nil,
        failure: GuestFileCommandFailure? = nil
    ) -> GuestFileCommandResponse<GuestFileMutationReport> {
        let receipt = GuestFileCommandReceipt(
            commandID: context.commandID,
            sessionID: context.sessionID,
            policyVersion: context.policyVersion,
            operation: context.operation,
            startedAt: context.startedAt,
            completedAt: clock(),
            outcome: outcome,
            wireRequestCount: wireRequests,
            affectedPaths: context.path.isEmpty ? [] : [context.path])
        audit(outcome == .success ? .info : .warn,
              "\(tag(context)) \(outcome.rawValue) "
                  + "wireRequests=\(wireRequests)"
                  + (failure.map { " code=\($0.code)" } ?? ""))
        return GuestFileCommandResponse(
            receipt: receipt, value: value, failure: failure)
    }

    /// Everything that is not `ok:true`, mapped to a typed outcome.
    ///
    /// The guest's `file.result` code vocabulary is closed (`exists`,
    /// `bad-path`, `not-found`, `io-error`, `busy`) and arrives here because
    /// `GuestListener.resolveChange` renders an `ok:false` answer as a
    /// failure carrying that code; transport and family refusals — a
    /// disconnect, a watchdog, a `not-implemented` — arrive the same way.
    /// **`exists` becoming `conflict` is the one a caller reads when this
    /// lane declines to overwrite**, and it is why the mapping is stated
    /// rather than collapsed into one refusal.
    ///
    /// The message is the guest's own, bounded and not reworded: an
    /// `io-error` carries the File Manager's number (-48 for a duplicate
    /// name), and that number is the only thing that makes such a failure
    /// debuggable from this side of the wire (docs/files.md).
    private func finish(
        _ context: Context,
        failure: GuestListener.FileFailure,
        wireRequests: Int
    ) -> GuestFileCommandResponse<GuestFileMutationReport> {
        let outcome: GuestFileCommandOutcome
        let code: String
        switch failure.code {
        case "disconnected":
            outcome = .unavailable
            code = "now-guest-unavailable"
        case "not-found":
            outcome = .notFound
            code = "now-files-not-found"
        case "exists":
            outcome = .conflict
            code = "now-files-exists"
        case "io-error":
            /* It was attempted and the File Manager broke. Distinct from
               `refused`, which is a request the guest declined to try. */
            outcome = .failed
            code = "now-files-io-error"
        default:
            outcome = .refused
            code = "now-files-\(bounded(failure.code, scalars: 48))"
        }
        return finish(
            context, outcome: outcome, wireRequests: wireRequests,
            failure: .init(code: bounded(code, scalars: 64),
                           message: bounded(failure.message, scalars: 256)))
    }

    private func finishUnavailable(_ context: Context)
        -> GuestFileCommandResponse<GuestFileMutationReport> {
        finish(
            context, outcome: .unavailable, wireRequests: 0,
            failure: .init(
                code: "now-guest-unavailable",
                message: "No paired New Old World guest is available"))
    }

    private func finishInvalidPath(_ context: Context)
        -> GuestFileCommandResponse<GuestFileMutationReport> {
        finishRefused(
            context, code: "now-files-path-invalid",
            message:
                "Path must be canonical, root-relative, and HFS-representable")
    }

    private func finishRefused(
        _ context: Context,
        code: String,
        message: String
    ) -> GuestFileCommandResponse<GuestFileMutationReport> {
        finish(context, outcome: .refused, wireRequests: 0,
               failure: .init(code: code, message: message))
    }

    private func finishStale(_ context: Context, wireRequests: Int)
        -> GuestFileCommandResponse<GuestFileMutationReport> {
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

    private func bounded(_ value: String, scalars: Int) -> String {
        String(value.unicodeScalars.prefix(scalars))
    }
}

/// What one mutation did, in the caller's own root-relative vocabulary.
struct GuestFileMutationReport: Equatable, Sendable {
    let mutation: AgentIntegrationGuestFileMutation
    /// Where the item is now, when that is expressible. A trash has no
    /// answer here: the Trash is not below `guestRoot`, and naming a path
    /// inside it would invite a caller to treat it as one.
    let path: String?
    /// A trash's undo key, and the only one. The host does not keep a copy —
    /// the contract keeps this state on neither side, so an undo outlives a
    /// restart of either machine and belongs to whoever holds the name.
    let trashedAs: String?
    let observedAt: Date
}
