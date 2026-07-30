import Foundation

/// #4, #7 and #8 — the guest-files verbs the local surface does not have
/// yet: pull a file OFF the machine, mutate the catalog, and stop a
/// transfer.
///
/// They reuse the existing `AgentIntegrationGuestFileResult` receipt
/// envelope rather than the lighter `AgentIntegrationProjectedResult`,
/// because they are the same family as the upload lane and inherit its
/// discipline: a policy version, a wire request count, and the affected
/// paths, written into a receipt whether the operation worked or not. The
/// upload half already answers that way, and a download that reported less
/// than the upload beside it would be the asymmetry the contract's
/// symmetry rule exists to catch.

/// #4 — what landed on the host.
///
/// **One host operation, two guest mechanisms.** The PowerPC guest serves
/// `file.get`; NOW-68K serves the `put` verb, which is a WAY IN to the same
/// `file.offer` → `file.accept` → bulk → `file.end` sequence rather than a
/// second one. Rule 2 puts that choice in the adapter: the verb here does
/// not fork by ISA, and a caller does not name a mechanism. The 68K route
/// takes a LEAF NAME inside the share and the PowerPC route takes a path,
/// which is a bound the adapter reports — not a second operation.
public struct AgentIntegrationGuestFileDownload:
    Codable, Equatable, Sendable {
    /// The item on the guest, as the caller named it.
    public let guestPath: String
    /// Where it landed on this Mac. Absent when the transfer did not
    /// complete — there is no path to name, and naming one anyway is how a
    /// caller ends up opening a partial file.
    public let hostPath: String?
    public let bytes: Int
    /// `data` or `macbinary`, as the container rule resolved it. A
    /// resource-forked classic file is not a stream of data bytes, and
    /// which of the two arrived decides what the receiver may do with it.
    public let container: String
    /// CRC-32 (IEEE) of the WHOLE file as the guest computed it. Absent
    /// means the guest did not compute one, which a receiver must treat as
    /// UNCHECKED — never as correct.
    public let crc32: Int?
    /// The token to resume with, when the guest offered one.
    public let resumeToken: String?
    public let elapsedMs: Int

    public init(guestPath: String,
                hostPath: String?,
                bytes: Int,
                container: String,
                crc32: Int? = nil,
                resumeToken: String? = nil,
                elapsedMs: Int) {
        self.guestPath = guestPath
        self.hostPath = hostPath
        self.bytes = bytes
        self.container = container
        self.crc32 = crc32
        self.resumeToken = resumeToken
        self.elapsedMs = elapsedMs
    }
}

public typealias AgentIntegrationGuestFileDownloadResult =
    AgentIntegrationGuestFileResult<AgentIntegrationGuestFileDownload>

/// #7 — which catalog mutation, out of the four the guest serves.
///
/// One operation with four intentions, not four operations, and the reason
/// is the one capture used for its three: they are one lane. They share the
/// share-relative path space, the same `file.result` reply with its one
/// `code` vocabulary, and the same authorization — and `restore` is not
/// merely adjacent to `trash`, it CONSUMES `trash`'s answer. Splitting them
/// would let a caller reach a restore for a trashing no operation performed.
public enum AgentIntegrationGuestFileMutation:
    String, Codable, Equatable, Sendable, CaseIterable {
    /// Move or rename — the same operation, since the destination includes
    /// the name. Missing parent folders are NOT created: moving into a
    /// folder that is not there is a mistake, not an instruction.
    case move
    /// To the Trash, reversibly. The reply names where it landed.
    case trash
    /// Back out of the Trash, by the name `trash` reported. The enclosing
    /// folder must still exist.
    case restore
    /// Create a folder.
    case mkdir
}

/// What the mutation did.
public struct AgentIntegrationGuestFileMutationOutcome:
    Codable, Equatable, Sendable {
    public let mutation: AgentIntegrationGuestFileMutation
    /// Where the item ended up, when that is expressible.
    public let path: String?
    /// Answering a `trash`: the name the item landed under inside the
    /// Trash. **The caller must keep it** — it is the only key `restore`
    /// takes, and the guest does not remember it for anyone.
    public let trashedAs: String?
    public let observedAt: Date

    public init(mutation: AgentIntegrationGuestFileMutation,
                path: String?,
                trashedAs: String? = nil,
                observedAt: Date) {
        self.mutation = mutation
        self.path = path
        self.trashedAs = trashedAs
        self.observedAt = observedAt
    }
}

public typealias AgentIntegrationGuestFileMutationResult =
    AgentIntegrationGuestFileResult<
        AgentIntegrationGuestFileMutationOutcome>

/// #8 — what came of asking the transfer to stop.
public enum AgentIntegrationTransferCancelOutcome:
    String, Codable, Equatable, Sendable, CaseIterable {
    case cancelled
    /// No transfer was in flight. **A refusal, not an error**: asking a
    /// quiet machine to stop is a reasonable thing to have done, and the
    /// honest answer is that there was nothing to stop.
    case nothingToCancel = "nothing-to-cancel"
}

public struct AgentIntegrationTransferCancelReport:
    Codable, Equatable, Sendable {
    public let outcome: AgentIntegrationTransferCancelOutcome
    /// Which direction it was going, when there was one. The lane is ONE
    /// transfer wide across both directions — which is why this operation
    /// is not folded into the download that shares its name: cancelling
    /// also ends an upload the download lane knows nothing about.
    public let direction: String?
    public let note: String?
    public let observedAt: Date

    public init(outcome: AgentIntegrationTransferCancelOutcome,
                direction: String? = nil,
                note: String? = nil,
                observedAt: Date) {
        self.outcome = outcome
        self.direction = direction
        self.note = note
        self.observedAt = observedAt
    }
}

public typealias AgentIntegrationTransferCancelResult =
    AgentIntegrationProjectedResult<AgentIntegrationTransferCancelReport>
