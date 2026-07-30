import Foundation

public enum AgentIntegrationLocalProtocol {
    /// Version 8 makes an agent call VISIBLE to the person at the machine.
    /// The shape changed because the surface gained an operation that asks
    /// the host for nothing: the companion reports what it was asked to do
    /// and what came of it, and the host writes that into its own log. A v7
    /// host answers `invalid-request` to it, which is the honest answer —
    /// that host has no audit line to write — and a v7 companion simply
    /// never sends one, which is what rule 3 of the parity slice exists to
    /// stop being acceptable.
    ///
    /// Version 7 made the surface guest-ADDRESSABLE. The version moves
    /// because the shape changed again: the host serves several machines
    /// at once, so a request may now say WHICH one it means and every
    /// guest-dependent answer names the machine it came from. A v6
    /// companion cannot say which machine it wants and would take
    /// whichever one happened to be active as the answer to a question it
    /// asked about another.
    ///
    /// Version 6 added the read-only session capability report.
    public static let version = 8
    public static let maximumMessageBytes = 16 * 1024
}

public struct AgentIntegrationLocalRequest: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case sessionHealth = "session_health"
        case sessionCapabilities = "session_capabilities"
        case listProcesses = "list_processes"
        case launchSoftware = "launch_software"
        case requestQuit = "request_quit"
        case transferApprovedArtifact = "transfer_approved_artifact"
        case guestFilesCapabilities = "guest_files_capabilities"
        case guestFilesList = "guest_files_list"
        case guestFilesStat = "guest_files_stat"
        case guestFilesUploadBegin = "guest_files_upload_begin"
        case guestFilesUploadAppend = "guest_files_upload_append"
        case guestFilesUploadCommit = "guest_files_upload_commit"
        /// Not a request for anything. The face reports one invocation it
        /// has already performed so the host can write it into the log the
        /// person at the machine reads.
        case audit = "audit"
        /// Take a capture, or fetch one page of the one just taken, or
        /// abandon the wait for one in flight. Three intentions on one
        /// operation because they are one lane: a page is only meaningful
        /// against the capture that produced it, and splitting them would
        /// let a caller fetch pages of a stage no operation created.
        case capture = "capture"

        /* The eleven verbs of P1a, added as ONE deliberate edit
           (docs/plans/2026-07-30-005). Every capability that needs a new
           client verb touches this enum, the result enum and the response's
           field list, and those three tails conflicted on every merge that
           reached them last slice — so the verbs land together, before the
           per-capability agents fan out, and none of them has to come back
           here. They are UNWIRED: the dispatch answers `notImplemented`
           until a capability's own projection row lands, and no face can
           send one until then.

           Eleven capabilities, eleven operations — but not one per guest
           MESSAGE. The file mutations are four messages on one lane and the
           diagnostics are three argument-less verbs with one home, and each
           of those is one operation here for the reason capture folded take,
           page and abandon into one: they are a lane, not a family. */

        /// One page of one hardware-census probe.
        case census = "census"
        /// One page of what is installed, by domain.
        case softwareInventory = "software_inventory"
        /// Pull a file off the machine. `file.get` on PowerPC, the `put`
        /// verb on 68K — one operation, and the adapter picks.
        case guestFileDownload = "guest_file_download"
        /// Bring a running process forward.
        case bringToFront = "bring_to_front"
        /// Move, trash, restore or create — four intentions on one
        /// operation, because they are one lane and `restore` consumes
        /// what `trash` answered.
        case guestFileMutation = "guest_file_mutation"
        /// Stop the transfer in flight, in whichever direction it is going.
        /// Its own operation and not part of the download: the lane is one
        /// transfer wide across BOTH directions, so folding it into the
        /// download would leave an upload with nothing that can end it.
        case transferCancel = "transfer_cancel"
        /// The last lines of the guest's log for this launch.
        case guestLogTail = "guest_log_tail"
        /// The machine's own account of itself, via Gestalt.
        case machineFacts = "machine_facts"
        /// Time a whole-volume catalog search for applications.
        case catalogSearch = "catalog_search"
        /// Show an item in the machine's own Finder. Opens nothing.
        case revealItem = "reveal_item"
        /// One of the three diagnostics, named. One operation because none
        /// of them takes an argument, all three answer rows, and they have
        /// a single home.
        case diagnostics = "diagnostics"
    }

    public let version: Int
    public let requestID: UUID
    public let operation: Operation
    public let launchSelection: AgentIntegrationLaunchSelection?
    public let processReference: String?
    public let approvalReceipt: String?
    public let guestFilePath: String?
    public let guestFileCursor: Int?
    public let guestFileUpload: AgentIntegrationGuestFileUploadBegin?
    public let guestFileUploadID: UUID?
    public let guestFileUploadOffset: Int?
    public let guestFileUploadChunk: String?
    /// Opt in to the one read-only probe that costs the guest real work.
    public let probeCostly: Bool?
    /// One completed invocation, reported for the log. Present only on the
    /// `audit` operation, and never a request for anything.
    public var auditEvent: HostProjectionAuditEvent? = nil
    /// Bits per pixel to ask the guest's screen capture for. Present only
    /// when the `capture` operation is TAKING one.
    public var captureDepth: Int? = nil
    /// Which staged capture a continuation is reading, and from where.
    /// Present together, and only on a continuation.
    public var captureID: UUID? = nil
    public var captureOffset: Int? = nil
    /// Abandon the wait for a capture in flight instead of taking one.
    public var captureAbandon: Bool? = nil
    /// WHICH machine this request is about, if the caller cares.
    ///
    /// Accepts a machine id (`pb1400c` — "whatever is connected to that
    /// Mac now", which follows a reconnection) or a session id
    /// (`pb1400c-<uuid>` — precise, and fails once that connection ends
    /// rather than being retargeted at its successor). Nil means "the
    /// machine this host is driving", which is what every v6 caller
    /// meant and what a single-Mac desk still means.
    ///
    /// A `var` with a default rather than another parameter on eleven
    /// factory methods: it is orthogonal to every one of them.
    public var guestSelector: String?

    /* P1a's fields. Each is present on ONE operation (two, where a field
       already meant the right thing), and the per-operation key set below
       is what enforces that — a field carried by an operation with no use
       for it is refused, not ignored.

       Note what is NOT here: #4 and #7 address the guest with
       `guestFilePath`, and #5 with `processReference`. Reusing them is not
       a saving, it is the point — a path on that machine and a revalidated
       process reference are the same things they already were, and a second
       spelling of either would be two vocabularies for one idea. */

    /// Which census probe, and where in it. The probe is REQUIRED because
    /// `census.request` requires it; the cursor continues a paginated
    /// report and absent starts the probe over.
    public var censusProbe: String? = nil
    public var censusCursor: Int? = nil
    /// Which software domain, and where in it. Required for the same
    /// reason: `software.list` has no "all domains" form, and a host that
    /// invented one by asking five times and summing would be answering out
    /// of its own state.
    public var softwareDomain: AgentIntegrationSoftwareDomain? = nil
    public var softwareCursor: Int? = nil
    /// Which of the four catalog mutations. Present only on
    /// `guestFileMutation`, where `guestFilePath` names the item.
    public var guestFileMutation: AgentIntegrationGuestFileMutation? = nil
    /// Where a `move` is going, including the item's new name — so a
    /// rename and a move are one thing, as the contract has them.
    public var guestFileDestinationPath: String? = nil
    /// The name a `trash` reported, which is the only key a `restore`
    /// takes. `guestFilePath` carries where it is going back to.
    public var guestFileTrashName: String? = nil
    /// How many log lines, newest last.
    public var logLineCount: Int? = nil
    /// What to reveal: an item name, a full HFS path (the software
    /// listing's path doubles as the reveal key), or `#n` from the guest's
    /// stored match list. Not `guestFilePath`: this one is resolved by the
    /// guest's own launch grammar rather than being a path in the share,
    /// and the two must not be confused into one field that is bounded by
    /// the wrong rule.
    public var revealTarget: String? = nil
    /// Which diagnostic.
    public var diagnosticProbe: AgentIntegrationDiagnosticProbe? = nil

    private init(requestID: UUID,
                 operation: Operation,
                 launchSelection: AgentIntegrationLaunchSelection?,
                 processReference: String?,
                 approvalReceipt: String?,
                 guestFilePath: String?,
                 guestFileCursor: Int?,
                 guestFileUpload:
                    AgentIntegrationGuestFileUploadBegin? = nil,
                 guestFileUploadID: UUID? = nil,
                 guestFileUploadOffset: Int? = nil,
                 guestFileUploadChunk: String? = nil,
                 probeCostly: Bool? = nil) {
        version = AgentIntegrationLocalProtocol.version
        self.probeCostly = probeCostly
        self.requestID = requestID
        self.operation = operation
        self.launchSelection = launchSelection
        self.processReference = processReference
        self.approvalReceipt = approvalReceipt
        self.guestFilePath = guestFilePath
        self.guestFileCursor = guestFileCursor
        self.guestFileUpload = guestFileUpload
        self.guestFileUploadID = guestFileUploadID
        self.guestFileUploadOffset = guestFileUploadOffset
        self.guestFileUploadChunk = guestFileUploadChunk
    }

    public static func sessionHealth(requestID: UUID = UUID()) -> Self {
        .init(requestID: requestID, operation: .sessionHealth,
              launchSelection: nil, processReference: nil,
              approvalReceipt: nil, guestFilePath: nil,
              guestFileCursor: nil)
    }

    public static func sessionCapabilities(
        probeCostly: Bool,
        requestID: UUID = UUID()
    ) -> Self {
        .init(requestID: requestID, operation: .sessionCapabilities,
              launchSelection: nil, processReference: nil,
              approvalReceipt: nil, guestFilePath: nil,
              guestFileCursor: nil, probeCostly: probeCostly)
    }

    public static func processList(requestID: UUID = UUID()) -> Self {
        .init(requestID: requestID, operation: .listProcesses,
              launchSelection: nil, processReference: nil,
              approvalReceipt: nil, guestFilePath: nil,
              guestFileCursor: nil)
    }

    public static func launchSoftware(
        _ selection: AgentIntegrationLaunchSelection,
        requestID: UUID = UUID()
    ) -> Self {
        .init(requestID: requestID, operation: .launchSoftware,
              launchSelection: selection, processReference: nil,
              approvalReceipt: nil, guestFilePath: nil,
              guestFileCursor: nil)
    }

    public static func requestQuit(
        reference: String,
        requestID: UUID = UUID()
    ) -> Self {
        .init(requestID: requestID, operation: .requestQuit,
              launchSelection: nil, processReference: reference,
              approvalReceipt: nil, guestFilePath: nil,
              guestFileCursor: nil)
    }

    public static func transferApprovedArtifact(
        receipt: String,
        requestID: UUID = UUID()
    ) -> Self {
        .init(
            requestID: requestID,
            operation: .transferApprovedArtifact,
            launchSelection: nil,
            processReference: nil,
            approvalReceipt: receipt,
            guestFilePath: nil,
            guestFileCursor: nil)
    }

    public static func guestFilesCapabilities(
        requestID: UUID = UUID()
    ) -> Self {
        .init(
            requestID: requestID,
            operation: .guestFilesCapabilities,
            launchSelection: nil,
            processReference: nil,
            approvalReceipt: nil,
            guestFilePath: nil,
            guestFileCursor: nil)
    }

    public static func guestFilesList(
        path: String,
        cursor: Int?,
        requestID: UUID = UUID()
    ) -> Self {
        .init(
            requestID: requestID,
            operation: .guestFilesList,
            launchSelection: nil,
            processReference: nil,
            approvalReceipt: nil,
            guestFilePath: path,
            guestFileCursor: cursor)
    }

    public static func guestFilesStat(
        path: String,
        requestID: UUID = UUID()
    ) -> Self {
        .init(
            requestID: requestID,
            operation: .guestFilesStat,
            launchSelection: nil,
            processReference: nil,
            approvalReceipt: nil,
            guestFilePath: path,
            guestFileCursor: nil)
    }

    public static func guestFilesUploadBegin(
        _ upload: AgentIntegrationGuestFileUploadBegin,
        requestID: UUID = UUID()
    ) -> Self {
        .init(
            requestID: requestID,
            operation: .guestFilesUploadBegin,
            launchSelection: nil,
            processReference: nil,
            approvalReceipt: nil,
            guestFilePath: nil,
            guestFileCursor: nil,
            guestFileUpload: upload)
    }

    public static func guestFilesUploadAppend(
        uploadID: UUID,
        offset: Int,
        base64: String,
        requestID: UUID = UUID()
    ) -> Self {
        .init(
            requestID: requestID,
            operation: .guestFilesUploadAppend,
            launchSelection: nil,
            processReference: nil,
            approvalReceipt: nil,
            guestFilePath: nil,
            guestFileCursor: nil,
            guestFileUploadID: uploadID,
            guestFileUploadOffset: offset,
            guestFileUploadChunk: base64)
    }

    public static func guestFilesUploadCommit(
        uploadID: UUID,
        requestID: UUID = UUID()
    ) -> Self {
        .init(
            requestID: requestID,
            operation: .guestFilesUploadCommit,
            launchSelection: nil,
            processReference: nil,
            approvalReceipt: nil,
            guestFilePath: nil,
            guestFileCursor: nil,
            guestFileUploadID: uploadID)
    }

    /// One completed invocation, on its way to the host's log.
    ///
    /// It carries no selection of any kind: the event names a capability the
    /// host validates against its own registry, a face from a closed set,
    /// one outcome word and a bounded refusal sentence. That bound is what
    /// keeps this from being a way to write arbitrary text into the person's
    /// log — a same-uid process can already cause real agent lines by
    /// making real calls, and this operation must not let it invent lines
    /// about capabilities that do not exist.
    public static func audit(_ event: HostProjectionAuditEvent,
                             requestID: UUID = UUID()) -> Self {
        var request = Self(
            requestID: requestID,
            operation: .audit,
            launchSelection: nil,
            processReference: nil,
            approvalReceipt: nil,
            guestFilePath: nil,
            guestFileCursor: nil)
        request.auditEvent = event
        return request
    }

    /// Take a capture of the addressed machine's screen.
    public static func capture(depth: Int,
                               requestID: UUID = UUID()) -> Self {
        var request = Self(
            requestID: requestID,
            operation: .capture,
            launchSelection: nil,
            processReference: nil,
            approvalReceipt: nil,
            guestFilePath: nil,
            guestFileCursor: nil)
        request.captureDepth = depth
        return request
    }

    /// Read one page of a capture already staged by this host.
    public static func capturePage(captureID: UUID,
                                   offset: Int,
                                   requestID: UUID = UUID()) -> Self {
        var request = Self(
            requestID: requestID,
            operation: .capture,
            launchSelection: nil,
            processReference: nil,
            approvalReceipt: nil,
            guestFilePath: nil,
            guestFileCursor: nil)
        request.captureID = captureID
        request.captureOffset = offset
        return request
    }

    /// Abandon the host's wait for a capture in flight.
    public static func captureAbandon(requestID: UUID = UUID()) -> Self {
        var request = Self(
            requestID: requestID,
            operation: .capture,
            launchSelection: nil,
            processReference: nil,
            approvalReceipt: nil,
            guestFilePath: nil,
            guestFileCursor: nil)
        request.captureAbandon = true
        return request
    }

    // MARK: - P1a: the eleven verbs, unwired

    /// The shell every P1a factory fills in. Private, and it exists so that
    /// eleven factories are eleven lines of intent rather than eleven copies
    /// of the same nine nils.
    private static func projected(
        _ operation: Operation,
        requestID: UUID
    ) -> Self {
        .init(requestID: requestID,
              operation: operation,
              launchSelection: nil,
              processReference: nil,
              approvalReceipt: nil,
              guestFilePath: nil,
              guestFileCursor: nil)
    }

    /// #2 — one page of one census probe.
    public static func census(
        probe: String = AgentIntegrationCensusPolicy.defaultProbe,
        cursor: Int? = nil,
        requestID: UUID = UUID()
    ) -> Self {
        var request = projected(.census, requestID: requestID)
        request.censusProbe = probe
        request.censusCursor = cursor
        return request
    }

    /// #3 — one page of one software domain.
    public static func softwareInventory(
        domain: AgentIntegrationSoftwareDomain,
        cursor: Int? = nil,
        requestID: UUID = UUID()
    ) -> Self {
        var request = projected(.softwareInventory, requestID: requestID)
        request.softwareDomain = domain
        request.softwareCursor = cursor
        return request
    }

    /// #4 — pull one file off the machine.
    public static func guestFileDownload(
        path: String,
        requestID: UUID = UUID()
    ) -> Self {
        .init(requestID: requestID,
              operation: .guestFileDownload,
              launchSelection: nil,
              processReference: nil,
              approvalReceipt: nil,
              guestFilePath: path,
              guestFileCursor: nil)
    }

    /// #5 — bring one running process forward.
    ///
    /// The same reference vocabulary `requestQuit` takes, and for the same
    /// reason: a PSN outlives nothing, so the host hands out a reference it
    /// can revalidate rather than letting a caller name a process by a
    /// string a person typed.
    public static func bringToFront(
        reference: String,
        requestID: UUID = UUID()
    ) -> Self {
        .init(requestID: requestID,
              operation: .bringToFront,
              launchSelection: nil,
              processReference: reference,
              approvalReceipt: nil,
              guestFilePath: nil,
              guestFileCursor: nil)
    }

    /// #7 — move or rename. The destination includes the new name.
    public static func guestFileMove(
        path: String,
        toPath: String,
        requestID: UUID = UUID()
    ) -> Self {
        var request = mutation(.move, path: path, requestID: requestID)
        request.guestFileDestinationPath = toPath
        return request
    }

    /// #7 — to the Trash, reversibly.
    public static func guestFileTrash(
        path: String,
        requestID: UUID = UUID()
    ) -> Self {
        mutation(.trash, path: path, requestID: requestID)
    }

    /// #7 — back out of the Trash, by the name the trashing reported.
    public static func guestFileRestore(
        trashedAs: String,
        toPath: String,
        requestID: UUID = UUID()
    ) -> Self {
        var request = mutation(
            .restore, path: toPath, requestID: requestID)
        request.guestFileTrashName = trashedAs
        return request
    }

    /// #7 — create a folder. Missing parents are not created.
    public static func guestFileMakeDirectory(
        path: String,
        requestID: UUID = UUID()
    ) -> Self {
        mutation(.mkdir, path: path, requestID: requestID)
    }

    private static func mutation(
        _ mutation: AgentIntegrationGuestFileMutation,
        path: String,
        requestID: UUID
    ) -> Self {
        var request = Self(
            requestID: requestID,
            operation: .guestFileMutation,
            launchSelection: nil,
            processReference: nil,
            approvalReceipt: nil,
            guestFilePath: path,
            guestFileCursor: nil)
        request.guestFileMutation = mutation
        return request
    }

    /// #8 — stop the transfer in flight, whichever way it is going.
    public static func transferCancel(requestID: UUID = UUID()) -> Self {
        projected(.transferCancel, requestID: requestID)
    }

    /// #9 — the last lines of the guest's log for this launch.
    public static func guestLogTail(
        lines: Int? = nil,
        requestID: UUID = UUID()
    ) -> Self {
        var request = projected(.guestLogTail, requestID: requestID)
        request.logLineCount = lines
        return request
    }

    /// #10 — the machine's own account of itself.
    ///
    /// No arguments: a typed call to `gestalt` returns every group, and the
    /// slicing a console line does is the guest's business — the host
    /// cannot slice what it does not understand.
    public static func machineFacts(requestID: UUID = UUID()) -> Self {
        projected(.machineFacts, requestID: requestID)
    }

    /// #11 — time a whole-volume catalog search for applications.
    public static func catalogSearch(requestID: UUID = UUID()) -> Self {
        projected(.catalogSearch, requestID: requestID)
    }

    /// #12 — show an item in the machine's own Finder.
    public static func revealItem(
        target: String,
        requestID: UUID = UUID()
    ) -> Self {
        var request = projected(.revealItem, requestID: requestID)
        request.revealTarget = target
        return request
    }

    /// #13 — run one of the three diagnostics.
    public static func diagnostics(
        probe: AgentIntegrationDiagnosticProbe,
        requestID: UUID = UUID()
    ) -> Self {
        var request = projected(.diagnostics, requestID: requestID)
        request.diagnosticProbe = probe
        return request
    }
}

public enum AgentIntegrationLocalResult: Equatable, Sendable {
    case sessionHealth(AgentIntegrationSessionHealthResult)
    case sessionCapabilities(AgentIntegrationSessionCapabilitiesResult)
    case processList(AgentIntegrationProcessListResult)
    case launchSoftware(AgentIntegrationLaunchSoftwareResult)
    case requestQuit(AgentIntegrationQuitResult)
    case transferApprovedArtifact(AgentIntegrationArtifactTransferResult)
    case guestFilesCapabilities(
        AgentIntegrationGuestFileCapabilitiesResult)
    case guestFilesList(AgentIntegrationGuestFileListResult)
    case guestFilesStat(AgentIntegrationGuestFileStatResult)
    case guestFilesUploadStage(
        AgentIntegrationGuestFileUploadStageResult)
    case guestFilesUploadCommit(
        AgentIntegrationGuestFileUploadCommitResult)
    /// The request named a machine, and this host cannot answer for it.
    ///
    /// One case rather than a variant of each of the eleven results,
    /// because the reason is the same for all of them and belongs to the
    /// ADDRESSING, not to the operation: nothing about the guest was
    /// asked, so no operation-shaped answer would be honest.
    case notAddressed(AgentIntegrationUnavailable)
    case capture(AgentIntegrationCaptureResult)
    /// The reported invocation reached the host's log. It says only that,
    /// because that is all the caller can be told: the line is written where
    /// the person reads it, not returned to whoever reported it.
    case recorded

    /* P1a's eleven answers. */
    case census(AgentIntegrationCensusResult)
    case softwareInventory(AgentIntegrationSoftwareInventoryResult)
    case guestFileDownload(AgentIntegrationGuestFileDownloadResult)
    case bringToFront(AgentIntegrationFrontResult)
    case guestFileMutation(AgentIntegrationGuestFileMutationResult)
    case transferCancel(AgentIntegrationTransferCancelResult)
    /* Four capabilities, one payload type: their verbs' declared output is
       the same `x-rowArray` shape, so this side does not invent four. The
       CASES stay distinct — a caller must be able to tell a log tail from a
       Gestalt read, and the response's exactly-one-of guard counts them
       separately. */
    case guestLogTail(AgentIntegrationGuestRowReportResult)
    case machineFacts(AgentIntegrationGuestRowReportResult)
    case catalogSearch(AgentIntegrationGuestRowReportResult)
    case revealItem(AgentIntegrationGuestRowReportResult)
    case diagnostics(AgentIntegrationGuestRowReportResult)

    /// The operation is carried by this protocol and NOTHING SERVES IT YET.
    ///
    /// One case for all eleven, because the fact is about the host's wiring
    /// rather than about any operation — the same argument that gives
    /// `notAddressed` one case instead of a variant per result.
    ///
    /// It is a case and not an empty success on purpose. An empty
    /// `softwareInventory` reads as "nothing is installed on that Mac";
    /// this reads as what is true, and the agent who inherits the verb
    /// finds a failing call rather than a plausible wrong answer.
    case notImplemented(AgentIntegrationUnavailable)
}

public struct AgentIntegrationLocalError: Codable, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct AgentIntegrationLocalResponse: Codable, Equatable, Sendable {
    public let version: Int
    public let requestID: UUID?
    public let result: AgentIntegrationSessionHealthResult?
    public var sessionCapabilitiesResult:
        AgentIntegrationSessionCapabilitiesResult? = nil
    public let processListResult: AgentIntegrationProcessListResult?
    public let launchResult: AgentIntegrationLaunchSoftwareResult?
    public let quitResult: AgentIntegrationQuitResult?
    public let artifactTransferResult: AgentIntegrationArtifactTransferResult?
    public let guestFilesCapabilitiesResult:
        AgentIntegrationGuestFileCapabilitiesResult?
    public let guestFilesListResult: AgentIntegrationGuestFileListResult?
    public let guestFilesStatResult: AgentIntegrationGuestFileStatResult?
    public var guestFilesUploadStageResult:
        AgentIntegrationGuestFileUploadStageResult? = nil
    public var guestFilesUploadCommitResult:
        AgentIntegrationGuestFileUploadCommitResult? = nil
    /// One capture, or one page of it. Sized so a full page still leaves the
    /// response inside the 16 KiB cap.
    public var captureResult: AgentIntegrationCaptureResult? = nil
    /// The request named a machine this host cannot answer for. Set
    /// INSTEAD of any operation result: nothing was asked of any guest.
    public var notAddressed: AgentIntegrationUnavailable? = nil
    /// The reported invocation was written to the host's log. Set INSTEAD of
    /// any operation result; nothing was asked of any guest.
    public var recorded: Bool? = nil

    /* P1a's eleven result fields, plus the answer they all give until each
       one is wired. `var … = nil` rather than `let`, which is what lets the
       twelve inits below be four lines each instead of restating every
       other field — and what keeps the fifteen existing inits untouched. */
    public var censusResult: AgentIntegrationCensusResult? = nil
    public var softwareInventoryResult:
        AgentIntegrationSoftwareInventoryResult? = nil
    public var guestFileDownloadResult:
        AgentIntegrationGuestFileDownloadResult? = nil
    public var bringToFrontResult: AgentIntegrationFrontResult? = nil
    public var guestFileMutationResult:
        AgentIntegrationGuestFileMutationResult? = nil
    public var transferCancelResult:
        AgentIntegrationTransferCancelResult? = nil
    public var guestLogTailResult:
        AgentIntegrationGuestRowReportResult? = nil
    public var machineFactsResult:
        AgentIntegrationGuestRowReportResult? = nil
    public var catalogSearchResult:
        AgentIntegrationGuestRowReportResult? = nil
    public var revealItemResult:
        AgentIntegrationGuestRowReportResult? = nil
    public var diagnosticsResult:
        AgentIntegrationGuestRowReportResult? = nil
    /// The operation exists here and no capability serves it yet. Set
    /// INSTEAD of any result, and counted with them: a response carrying
    /// both would be claiming to have answered a call it also says it
    /// cannot make.
    public var notImplemented: AgentIntegrationUnavailable? = nil

    public let error: AgentIntegrationLocalError?

    public init(requestID: UUID,
                notAddressed: AgentIntegrationUnavailable) {
        version = AgentIntegrationLocalProtocol.version
        self.requestID = requestID
        self.notAddressed = notAddressed
        result = nil
        processListResult = nil
        launchResult = nil
        quitResult = nil
        artifactTransferResult = nil
        guestFilesCapabilitiesResult = nil
        guestFilesListResult = nil
        guestFilesStatResult = nil
        error = nil
    }

    public init(requestID: UUID, recorded: Bool) {
        version = AgentIntegrationLocalProtocol.version
        self.requestID = requestID
        self.recorded = recorded
        result = nil
        processListResult = nil
        launchResult = nil
        quitResult = nil
        artifactTransferResult = nil
        guestFilesCapabilitiesResult = nil
        guestFilesListResult = nil
        guestFilesStatResult = nil
        error = nil
    }

    public init(requestID: UUID,
                result: AgentIntegrationSessionHealthResult) {
        version = AgentIntegrationLocalProtocol.version
        self.requestID = requestID
        self.result = result
        processListResult = nil
        launchResult = nil
        quitResult = nil
        artifactTransferResult = nil
        guestFilesCapabilitiesResult = nil
        guestFilesListResult = nil
        guestFilesStatResult = nil
        error = nil
    }

    public init(
        requestID: UUID,
        sessionCapabilitiesResult:
            AgentIntegrationSessionCapabilitiesResult
    ) {
        version = AgentIntegrationLocalProtocol.version
        self.requestID = requestID
        result = nil
        self.sessionCapabilitiesResult = sessionCapabilitiesResult
        processListResult = nil
        launchResult = nil
        quitResult = nil
        artifactTransferResult = nil
        guestFilesCapabilitiesResult = nil
        guestFilesListResult = nil
        guestFilesStatResult = nil
        error = nil
    }

    public init(requestID: UUID,
                processListResult: AgentIntegrationProcessListResult) {
        version = AgentIntegrationLocalProtocol.version
        self.requestID = requestID
        result = nil
        self.processListResult = processListResult
        launchResult = nil
        quitResult = nil
        artifactTransferResult = nil
        guestFilesCapabilitiesResult = nil
        guestFilesListResult = nil
        guestFilesStatResult = nil
        error = nil
    }

    public init(requestID: UUID,
                launchResult: AgentIntegrationLaunchSoftwareResult) {
        version = AgentIntegrationLocalProtocol.version
        self.requestID = requestID
        result = nil
        processListResult = nil
        self.launchResult = launchResult
        quitResult = nil
        artifactTransferResult = nil
        guestFilesCapabilitiesResult = nil
        guestFilesListResult = nil
        guestFilesStatResult = nil
        error = nil
    }

    public init(requestID: UUID,
                quitResult: AgentIntegrationQuitResult) {
        version = AgentIntegrationLocalProtocol.version
        self.requestID = requestID
        result = nil
        processListResult = nil
        launchResult = nil
        self.quitResult = quitResult
        artifactTransferResult = nil
        guestFilesCapabilitiesResult = nil
        guestFilesListResult = nil
        guestFilesStatResult = nil
        error = nil
    }

    public init(
        requestID: UUID,
        artifactTransferResult: AgentIntegrationArtifactTransferResult
    ) {
        version = AgentIntegrationLocalProtocol.version
        self.requestID = requestID
        result = nil
        processListResult = nil
        launchResult = nil
        quitResult = nil
        self.artifactTransferResult = artifactTransferResult
        guestFilesCapabilitiesResult = nil
        guestFilesListResult = nil
        guestFilesStatResult = nil
        error = nil
    }

    public init(
        requestID: UUID,
        guestFilesCapabilitiesResult:
            AgentIntegrationGuestFileCapabilitiesResult
    ) {
        version = AgentIntegrationLocalProtocol.version
        self.requestID = requestID
        result = nil
        processListResult = nil
        launchResult = nil
        quitResult = nil
        artifactTransferResult = nil
        self.guestFilesCapabilitiesResult =
            guestFilesCapabilitiesResult
        guestFilesListResult = nil
        guestFilesStatResult = nil
        error = nil
    }

    public init(
        requestID: UUID,
        guestFilesListResult: AgentIntegrationGuestFileListResult
    ) {
        version = AgentIntegrationLocalProtocol.version
        self.requestID = requestID
        result = nil
        processListResult = nil
        launchResult = nil
        quitResult = nil
        artifactTransferResult = nil
        guestFilesCapabilitiesResult = nil
        self.guestFilesListResult = guestFilesListResult
        guestFilesStatResult = nil
        error = nil
    }

    public init(
        requestID: UUID,
        guestFilesStatResult: AgentIntegrationGuestFileStatResult
    ) {
        version = AgentIntegrationLocalProtocol.version
        self.requestID = requestID
        result = nil
        processListResult = nil
        launchResult = nil
        quitResult = nil
        artifactTransferResult = nil
        guestFilesCapabilitiesResult = nil
        guestFilesListResult = nil
        self.guestFilesStatResult = guestFilesStatResult
        error = nil
    }

    public init(
        requestID: UUID,
        guestFilesUploadStageResult:
            AgentIntegrationGuestFileUploadStageResult
    ) {
        version = AgentIntegrationLocalProtocol.version
        self.requestID = requestID
        result = nil
        processListResult = nil
        launchResult = nil
        quitResult = nil
        artifactTransferResult = nil
        guestFilesCapabilitiesResult = nil
        guestFilesListResult = nil
        guestFilesStatResult = nil
        self.guestFilesUploadStageResult =
            guestFilesUploadStageResult
        error = nil
    }

    public init(
        requestID: UUID,
        guestFilesUploadCommitResult:
            AgentIntegrationGuestFileUploadCommitResult
    ) {
        version = AgentIntegrationLocalProtocol.version
        self.requestID = requestID
        result = nil
        processListResult = nil
        launchResult = nil
        quitResult = nil
        artifactTransferResult = nil
        guestFilesCapabilitiesResult = nil
        guestFilesListResult = nil
        guestFilesStatResult = nil
        self.guestFilesUploadCommitResult =
            guestFilesUploadCommitResult
        error = nil
    }

    public init(
        requestID: UUID,
        captureResult: AgentIntegrationCaptureResult
    ) {
        version = AgentIntegrationLocalProtocol.version
        self.requestID = requestID
        result = nil
        processListResult = nil
        launchResult = nil
        quitResult = nil
        artifactTransferResult = nil
        guestFilesCapabilitiesResult = nil
        guestFilesListResult = nil
        guestFilesStatResult = nil
        self.captureResult = captureResult
        error = nil
    }

    // MARK: - P1a: twelve responses over one empty shell

    /// Every `let` field nil, and nothing else said.
    ///
    /// The fifteen inits above each restate eight nils, which is why adding
    /// a field to this type used to be an edit in fifteen places. It is not
    /// worth rewriting them for their own sake — but the twelve below are
    /// built on this instead, so a thirteenth costs four lines.
    private init(empty requestID: UUID) {
        version = AgentIntegrationLocalProtocol.version
        self.requestID = requestID
        result = nil
        processListResult = nil
        launchResult = nil
        quitResult = nil
        artifactTransferResult = nil
        guestFilesCapabilitiesResult = nil
        guestFilesListResult = nil
        guestFilesStatResult = nil
        error = nil
    }

    public init(requestID: UUID,
                censusResult: AgentIntegrationCensusResult) {
        self.init(empty: requestID)
        self.censusResult = censusResult
    }

    public init(
        requestID: UUID,
        softwareInventoryResult:
            AgentIntegrationSoftwareInventoryResult
    ) {
        self.init(empty: requestID)
        self.softwareInventoryResult = softwareInventoryResult
    }

    public init(
        requestID: UUID,
        guestFileDownloadResult:
            AgentIntegrationGuestFileDownloadResult
    ) {
        self.init(empty: requestID)
        self.guestFileDownloadResult = guestFileDownloadResult
    }

    public init(requestID: UUID,
                bringToFrontResult: AgentIntegrationFrontResult) {
        self.init(empty: requestID)
        self.bringToFrontResult = bringToFrontResult
    }

    public init(
        requestID: UUID,
        guestFileMutationResult:
            AgentIntegrationGuestFileMutationResult
    ) {
        self.init(empty: requestID)
        self.guestFileMutationResult = guestFileMutationResult
    }

    public init(
        requestID: UUID,
        transferCancelResult: AgentIntegrationTransferCancelResult
    ) {
        self.init(empty: requestID)
        self.transferCancelResult = transferCancelResult
    }

    public init(
        requestID: UUID,
        guestLogTailResult: AgentIntegrationGuestRowReportResult
    ) {
        self.init(empty: requestID)
        self.guestLogTailResult = guestLogTailResult
    }

    public init(
        requestID: UUID,
        machineFactsResult: AgentIntegrationGuestRowReportResult
    ) {
        self.init(empty: requestID)
        self.machineFactsResult = machineFactsResult
    }

    public init(
        requestID: UUID,
        catalogSearchResult: AgentIntegrationGuestRowReportResult
    ) {
        self.init(empty: requestID)
        self.catalogSearchResult = catalogSearchResult
    }

    public init(
        requestID: UUID,
        revealItemResult: AgentIntegrationGuestRowReportResult
    ) {
        self.init(empty: requestID)
        self.revealItemResult = revealItemResult
    }

    public init(
        requestID: UUID,
        diagnosticsResult: AgentIntegrationGuestRowReportResult
    ) {
        self.init(empty: requestID)
        self.diagnosticsResult = diagnosticsResult
    }

    public init(requestID: UUID,
                notImplemented: AgentIntegrationUnavailable) {
        self.init(empty: requestID)
        self.notImplemented = notImplemented
    }

    public init(requestID: UUID? = nil,
                error: AgentIntegrationLocalError) {
        version = AgentIntegrationLocalProtocol.version
        self.requestID = requestID
        result = nil
        processListResult = nil
        launchResult = nil
        quitResult = nil
        artifactTransferResult = nil
        guestFilesCapabilitiesResult = nil
        guestFilesListResult = nil
        guestFilesStatResult = nil
        self.error = error
    }
}

public enum AgentIntegrationLocalCodec {
    /// P1a's response fields, named once.
    ///
    /// Read by BOTH gates in `decodeResponse` — the allowlist and the
    /// exactly-one-of count — because a field admitted by one and uncounted
    /// by the other is a response that can carry two answers. The older
    /// fields are still spelled out in both places; this list is what stops
    /// eleven more from being.
    static let projectedResultKeys: Set<String> = [
        "censusResult", "softwareInventoryResult",
        "guestFileDownloadResult", "bringToFrontResult",
        "guestFileMutationResult", "transferCancelResult",
        "guestLogTailResult", "machineFactsResult",
        "catalogSearchResult", "revealItemResult",
        "diagnosticsResult",
        // Set INSTEAD of any of them, so it is counted with them.
        "notImplemented",
    ]

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func encode(_ request: AgentIntegrationLocalRequest)
        throws -> Data {
        try bounded(makeEncoder().encode(request))
    }

    public static func encode(_ response: AgentIntegrationLocalResponse)
        throws -> Data {
        try bounded(makeEncoder().encode(response))
    }

    public static func decodeRequest(_ data: Data) throws
        -> AgentIntegrationLocalRequest {
        let object = try strictObject(data, allowedKeys: [
            "version", "requestID", "operation", "launchSelection",
            "processReference", "approvalReceipt", "guestFilePath",
            "guestFileCursor", "guestFileUpload", "guestFileUploadID",
            "guestFileUploadOffset", "guestFileUploadChunk", "probeCostly",
            "auditEvent", "captureDepth", "captureID", "captureOffset",
            "captureAbandon",
            // P1a's fields. This list is one of the two gates every field
            // has to clear, and a field declared here and forgotten there
            // is the exact defect `guestSelector` shipped with for a week.
            "censusProbe", "censusCursor", "softwareDomain",
            "softwareCursor", "guestFileMutation",
            "guestFileDestinationPath", "guestFileTrashName",
            "logLineCount", "revealTarget", "diagnosticProbe",
            // Orthogonal to every operation, so it clears BOTH gates:
            // this allowlist, and the per-operation key set below.
            "guestSelector",
        ])
        guard object["version"] as? Int ==
                AgentIntegrationLocalProtocol.version else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Unsupported local protocol version")
        }
        let request = try makeDecoder().decode(
            AgentIntegrationLocalRequest.self, from: bounded(data))
        let expectedKeys: Set<String>
        switch request.operation {
        case .sessionHealth, .listProcesses, .guestFilesCapabilities:
            expectedKeys = ["version", "requestID", "operation"]
            guard request.launchSelection == nil,
                  request.processReference == nil,
                  request.approvalReceipt == nil,
                  request.guestFilePath == nil,
                  request.probeCostly == nil,
                  request.guestFileCursor == nil else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Read-only request contains an action selection")
            }
        case .sessionCapabilities:
            // The one flag is REQUIRED rather than defaulted, because it
            // decides whether this call spends four seconds of a
            // PowerBook's volume sweep. A caller says so on purpose.
            expectedKeys = [
                "version", "requestID", "operation", "probeCostly",
            ]
            guard request.launchSelection == nil,
                  request.processReference == nil,
                  request.approvalReceipt == nil,
                  request.guestFilePath == nil,
                  request.guestFileCursor == nil,
                  request.probeCostly != nil else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Session capabilities request does not match the schema")
            }
        case .launchSoftware:
            expectedKeys = [
                "version", "requestID", "operation", "launchSelection",
            ]
            guard request.launchSelection != nil,
                  request.processReference == nil,
                  request.approvalReceipt == nil,
                  request.guestFilePath == nil,
                  request.guestFileCursor == nil,
                  let rawSelection =
                    object["launchSelection"] as? [String: Any],
                  Set(rawSelection.keys) == ["name"]
                    || Set(rawSelection.keys) == ["reference"] else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Launch request selection does not match the schema")
            }
        case .requestQuit:
            expectedKeys = [
                "version", "requestID", "operation", "processReference",
            ]
            guard request.launchSelection == nil,
                  let reference = request.processReference,
                  request.approvalReceipt == nil,
                  request.guestFilePath == nil,
                  request.guestFileCursor == nil,
                  AgentIntegrationQuitPolicy.isValidReference(reference)
            else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Quit request reference does not match the schema")
            }
        case .transferApprovedArtifact:
            expectedKeys = [
                "version", "requestID", "operation", "approvalReceipt",
            ]
            guard request.launchSelection == nil,
                  request.processReference == nil,
                  let receipt = request.approvalReceipt,
                  request.guestFilePath == nil,
                  request.guestFileCursor == nil,
                  AgentIntegrationArtifactPolicy.isValidReceipt(receipt)
            else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Artifact transfer receipt does not match the schema")
            }
        case .guestFilesList:
            var listKeys: Set<String> = [
                "version", "requestID", "operation", "guestFilePath",
            ]
            if request.guestFileCursor != nil {
                listKeys.insert("guestFileCursor")
            }
            expectedKeys = listKeys
            guard request.launchSelection == nil,
                  request.processReference == nil,
                  request.approvalReceipt == nil,
                  let path = request.guestFilePath,
                  AgentIntegrationGuestFilePolicy.isBoundedPath(path),
                  request.guestFileCursor.map({ $0 >= 1 }) ?? true
            else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Guest Files list request does not match the schema")
            }
        case .guestFilesStat:
            expectedKeys = [
                "version", "requestID", "operation", "guestFilePath",
            ]
            guard request.launchSelection == nil,
                  request.processReference == nil,
                  request.approvalReceipt == nil,
                  request.guestFileCursor == nil,
                  let path = request.guestFilePath,
                  !path.isEmpty,
                  AgentIntegrationGuestFilePolicy.isBoundedPath(path)
            else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Guest Files stat request does not match the schema")
            }
        case .guestFilesUploadBegin:
            expectedKeys = [
                "version", "requestID", "operation", "guestFileUpload",
            ]
            guard let upload = request.guestFileUpload,
                  request.guestFileUploadID == nil,
                  request.guestFileUploadOffset == nil,
                  request.guestFileUploadChunk == nil,
                  request.launchSelection == nil,
                  request.processReference == nil,
                  request.approvalReceipt == nil,
                  request.guestFilePath == nil,
                  request.guestFileCursor == nil,
                  AgentIntegrationGuestFilePolicy.isBoundedPath(
                    upload.destinationPath),
                  !upload.destinationPath.isEmpty,
                  upload.bytes >= 0,
                  upload.bytes <= Int(Int32.max),
                  AgentIntegrationGuestFilePolicy.isCanonicalSHA256(
                    upload.sha256),
                  AgentIntegrationGuestFilePolicy.isClassicOSType(
                    upload.fileType),
                  AgentIntegrationGuestFilePolicy.isClassicOSType(
                    upload.creator),
                  upload.modified.map({ $0 >= 0 }) ?? true,
                  upload.container == "data"
                    || upload.container == "macbinary",
                  let raw = object["guestFileUpload"] as? [String: Any],
                  Set(raw.keys).isSuperset(of: [
                    "destinationPath", "bytes", "sha256", "container",
                  ]),
                  Set(raw.keys).isSubset(of: [
                    "destinationPath", "bytes", "sha256", "container",
                    "fileType", "creator", "modified",
                  ]) else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Guest Files upload begin does not match the schema")
            }
        case .guestFilesUploadAppend:
            expectedKeys = [
                "version", "requestID", "operation", "guestFileUploadID",
                "guestFileUploadOffset", "guestFileUploadChunk",
            ]
            guard request.guestFileUpload == nil,
                  request.launchSelection == nil,
                  request.processReference == nil,
                  request.approvalReceipt == nil,
                  request.guestFilePath == nil,
                  request.guestFileCursor == nil,
                  request.guestFileUploadID != nil,
                  let offset = request.guestFileUploadOffset,
                  offset >= 0,
                  let chunk = request.guestFileUploadChunk,
                  chunk.count
                    <= AgentIntegrationGuestFilePolicy
                        .maximumUploadChunkBase64Scalars,
                  let bytes = Data(base64Encoded: chunk),
                  !bytes.isEmpty,
                  bytes.count
                    <= AgentIntegrationGuestFilePolicy
                        .maximumUploadChunkBytes else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Guest Files upload chunk does not match the schema")
            }
        case .guestFilesUploadCommit:
            expectedKeys = [
                "version", "requestID", "operation", "guestFileUploadID",
            ]
            guard request.guestFileUpload == nil,
                  request.launchSelection == nil,
                  request.processReference == nil,
                  request.approvalReceipt == nil,
                  request.guestFilePath == nil,
                  request.guestFileCursor == nil,
                  request.guestFileUploadID != nil,
                  request.guestFileUploadOffset == nil,
                  request.guestFileUploadChunk == nil else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Guest Files upload commit does not match the schema")
            }
        case .audit:
            /* An audit event names a capability, so the capability has to
               exist: the host writes this into the log a person reads, and
               a line about a tool no row claims would be a line about
               nothing. Everything else in the event is a closed enum or a
               bounded sentence, which together are the whole bound on what
               this operation can put in that file. Note there is no guest
               SELECTOR here — the machine the call concerned travels inside
               the event, because nothing is being asked of any guest. */
            expectedKeys = [
                "version", "requestID", "operation", "auditEvent",
            ]
            guard let event = request.auditEvent,
                  request.launchSelection == nil,
                  request.processReference == nil,
                  request.approvalReceipt == nil,
                  request.guestFilePath == nil,
                  request.guestFileCursor == nil,
                  request.probeCostly == nil,
                  HostProjectionRegistry.hostFaces.projection(
                      named: event.capability) != nil,
                  (event.reason?.unicodeScalars.count ?? 0)
                      <= HostProjectionAuditEvent.maximumReasonScalars else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Audit event does not match the schema")
            }
        case .capture:
            /* Three shapes on one operation, and exactly one of them per
               request. A page fetch names its stage AND its offset — either
               alone is a request nothing can serve — and none of the three
               carries any other selection, because a capture takes no path,
               receipt or reference of any kind. */
            var captureKeys: Set<String> = [
                "version", "requestID", "operation",
            ]
            let takes = request.captureDepth != nil
            let pages = request.captureID != nil
                || request.captureOffset != nil
            let abandons = request.captureAbandon != nil
            guard [takes, pages, abandons].filter({ $0 }).count == 1,
                  request.launchSelection == nil,
                  request.processReference == nil,
                  request.approvalReceipt == nil,
                  request.guestFilePath == nil,
                  request.guestFileCursor == nil,
                  request.guestFileUpload == nil,
                  request.guestFileUploadID == nil,
                  request.guestFileUploadOffset == nil,
                  request.guestFileUploadChunk == nil,
                  request.probeCostly == nil,
                  request.auditEvent == nil else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Capture request does not match the schema")
            }
            if takes {
                guard let depth = request.captureDepth,
                      AgentIntegrationCapturePolicy.isValidDepth(depth) else {
                    throw AgentIntegrationLocalTransportError.invalidMessage(
                        "Capture depth is not one the guest implements")
                }
                captureKeys.insert("captureDepth")
            }
            if pages {
                guard request.captureID != nil,
                      let offset = request.captureOffset,
                      offset >= 0,
                      offset <= AgentIntegrationCapturePolicy.maximumBytes,
                      offset % AgentIntegrationCapturePolicy.pageBytes == 0
                else {
                    throw AgentIntegrationLocalTransportError.invalidMessage(
                        "Capture page request does not match the schema")
                }
                captureKeys.formUnion(["captureID", "captureOffset"])
            }
            if abandons {
                guard request.captureAbandon == true else {
                    throw AgentIntegrationLocalTransportError.invalidMessage(
                        "Capture abandon is only meaningful as true")
                }
                captureKeys.insert("captureAbandon")
            }
            expectedKeys = captureKeys

        /* P1a's eleven branches.

           They guard what a value MEANS and leave "carries nothing else" to
           the key-set equality at the bottom of this function, which is
           exact: a key no branch named is refused whether or not a guard
           mentions it. The older branches list their nils as well, which is
           belt and braces rather than a second gate — writing eleven more
           copies of that list would add length and no refusals. */
        case .census:
            /* The probe is REQUIRED, because `census.request` requires it
               and there is no "every probe" form. A host that invented one
               by asking fourteen times and stitching the pages would be
               composing an answer nothing asked for; the caller names the
               probe, and an unknown name comes back `refused` with a note
               from the machine itself rather than being pre-judged here. */
            var censusKeys: Set<String> = [
                "version", "requestID", "operation", "censusProbe",
            ]
            guard let probe = request.censusProbe,
                  AgentIntegrationCensusPolicy.isValidProbe(probe) else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Census request does not name a bounded probe")
            }
            if let cursor = request.censusCursor {
                /* Zero is legal HERE and not on the software listing, and
                   the difference is the contract's: a census cursor of 0
                   means "start the probe over", which is a thing a caller
                   may honestly say. */
                guard cursor >= 0 else {
                    throw AgentIntegrationLocalTransportError.invalidMessage(
                        "Census cursor is negative")
                }
                censusKeys.insert("censusCursor")
            }
            expectedKeys = censusKeys
        case .softwareInventory:
            var softwareKeys: Set<String> = [
                "version", "requestID", "operation", "softwareDomain",
            ]
            guard request.softwareDomain != nil else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Software inventory request names no domain")
            }
            if let cursor = request.softwareCursor {
                /* 1-based over the guest's cached inventory, and 1 rebuilds
                   the cache. There is no page zero to ask for. */
                guard cursor >= 1 else {
                    throw AgentIntegrationLocalTransportError.invalidMessage(
                        "Software inventory cursor starts at 1")
                }
                softwareKeys.insert("softwareCursor")
            }
            expectedKeys = softwareKeys
        case .guestFileDownload:
            expectedKeys = [
                "version", "requestID", "operation", "guestFilePath",
            ]
            guard let path = request.guestFilePath,
                  !path.isEmpty,
                  AgentIntegrationGuestFilePolicy.isBoundedPath(path) else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Guest file download request does not match the schema")
            }
        case .bringToFront:
            expectedKeys = [
                "version", "requestID", "operation", "processReference",
            ]
            guard let reference = request.processReference,
                  AgentIntegrationQuitPolicy.isValidReference(reference)
            else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Bring-to-front reference does not match the schema")
            }
        case .guestFileMutation:
            /* Four intentions, and each one's key set is its own — the
               shape capture's branch established. A `move` without a
               destination and a `restore` without the name the trashing
               reported are both requests nothing can serve, so neither
               reaches an adapter to be discovered there. */
            var mutationKeys: Set<String> = [
                "version", "requestID", "operation", "guestFilePath",
                "guestFileMutation",
            ]
            guard let mutation = request.guestFileMutation,
                  let path = request.guestFilePath,
                  !path.isEmpty,
                  AgentIntegrationGuestFilePolicy.isBoundedPath(path) else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Guest file mutation does not name a bounded path")
            }
            switch mutation {
            case .move:
                guard let destination = request.guestFileDestinationPath,
                      !destination.isEmpty,
                      AgentIntegrationGuestFilePolicy.isBoundedPath(
                        destination),
                      request.guestFileTrashName == nil else {
                    throw AgentIntegrationLocalTransportError.invalidMessage(
                        "A move names where it is going, and nothing else")
                }
                mutationKeys.insert("guestFileDestinationPath")
            case .restore:
                guard let trashed = request.guestFileTrashName,
                      AgentIntegrationProjectionPolicy.isBoundedSelector(
                        trashed),
                      request.guestFileDestinationPath == nil else {
                    throw AgentIntegrationLocalTransportError.invalidMessage(
                        "A restore names the item's name in the Trash, and "
                            + "nothing else")
                }
                mutationKeys.insert("guestFileTrashName")
            case .trash, .mkdir:
                guard request.guestFileDestinationPath == nil,
                      request.guestFileTrashName == nil else {
                    throw AgentIntegrationLocalTransportError.invalidMessage(
                        "This mutation takes one path and no second one")
                }
            }
            expectedKeys = mutationKeys
        case .transferCancel, .machineFacts, .catalogSearch:
            /* Three operations that say only their own name. Grouped
               because they are the same request, not because they are the
               same kind of thing: a cancel MUTATES and the other two read,
               and the branch is about shape. */
            expectedKeys = ["version", "requestID", "operation"]
        case .guestLogTail:
            var tailKeys: Set<String> = [
                "version", "requestID", "operation",
            ]
            if let lines = request.logLineCount {
                /* The verb's own bound, refused here rather than a round
                   trip to a 68030 to be refused there. */
                guard AgentIntegrationGuestLogPolicy.isValidLineCount(lines)
                else {
                    throw AgentIntegrationLocalTransportError.invalidMessage(
                        "The guest serves at most "
                            + "\(AgentIntegrationGuestLogPolicy.maximumLineCount)"
                            + " log lines")
                }
                tailKeys.insert("logLineCount")
            }
            expectedKeys = tailKeys
        case .revealItem:
            expectedKeys = [
                "version", "requestID", "operation", "revealTarget",
            ]
            guard let target = request.revealTarget,
                  AgentIntegrationProjectionPolicy.isBoundedSelector(target)
            else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Reveal request does not name a bounded target")
            }
        case .diagnostics:
            expectedKeys = [
                "version", "requestID", "operation", "diagnosticProbe",
            ]
            guard request.diagnosticProbe != nil else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Diagnostics request names no probe")
            }
        }
        /* Addressing belongs to no operation, so it is admitted for all of
           them rather than repeated in twelve key sets — and only when the
           caller actually sent it, so an absent selector stays absent
           rather than becoming a required field. */
        var operationKeys = expectedKeys
        if let selector = request.guestSelector {
            /* Absent means "the machine this host is driving", which is a
               real answer. Empty means a caller addressed nothing while
               claiming to address something, and it must not reach the
               adapter as a third state neither nil nor an id.

               Validated HERE and not only in the companion, because the
               companion is not the trust boundary: any process of this uid
               can write this socket directly, and the codec is what every
               one of them goes through. */
            guard !selector.isEmpty else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Local request names an empty machine")
            }
            operationKeys.insert("guestSelector")
        }
        guard Set(object.keys) == operationKeys else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Local request fields do not match the operation schema")
        }
        return request
    }

    public static func decodeResponse(_ data: Data) throws
        -> AgentIntegrationLocalResponse {
        let object = try strictObject(
            data,
            allowedKeys: ([
                "version", "requestID", "result", "error",
                "sessionCapabilitiesResult",
                "processListResult", "launchResult", "quitResult",
                "artifactTransferResult",
                "guestFilesCapabilitiesResult", "guestFilesListResult",
                "guestFilesStatResult", "guestFilesUploadStageResult",
                "guestFilesUploadCommitResult", "captureResult", "recorded",
                // A refusal, not a protocol error: without this the
                // companion reads a real answer as a broken message.
                "notAddressed",
            ] as Set<String>).union(projectedResultKeys))
        guard object["version"] as? Int ==
                AgentIntegrationLocalProtocol.version else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Unsupported local protocol version")
        }
        let hasResult = object["result"] != nil
        let hasSessionCapabilities =
            object["sessionCapabilitiesResult"] != nil
        let hasProcessList = object["processListResult"] != nil
        let hasLaunch = object["launchResult"] != nil
        let hasQuit = object["quitResult"] != nil
        let hasArtifactTransfer = object["artifactTransferResult"] != nil
        let hasGuestFilesCapabilities =
            object["guestFilesCapabilitiesResult"] != nil
        let hasGuestFilesList = object["guestFilesListResult"] != nil
        let hasGuestFilesStat = object["guestFilesStatResult"] != nil
        let hasGuestFilesUploadStage =
            object["guestFilesUploadStageResult"] != nil
        let hasGuestFilesUploadCommit =
            object["guestFilesUploadCommitResult"] != nil
        let hasCapture = object["captureResult"] != nil
        let hasRecorded = object["recorded"] != nil
        let hasError = object["error"] != nil
        /* Counted with the results rather than beside them: the refusal is
           set INSTEAD of an operation answer, so a response carrying both
           is malformed for the same reason two results are. */
        let hasNotAddressed = object["notAddressed"] != nil
        /* Counted from the one list rather than as twelve more bindings
           nobody reads. `notImplemented` is in it for the same reason
           `notAddressed` is counted above: it is set instead of an answer,
           not beside one. */
        let projected = Self.projectedResultKeys
            .filter { object[$0] != nil }
            .count
        guard [
            hasResult, hasSessionCapabilities,
            hasProcessList, hasLaunch, hasQuit,
            hasArtifactTransfer, hasGuestFilesCapabilities,
            hasGuestFilesList, hasGuestFilesStat,
            hasGuestFilesUploadStage, hasGuestFilesUploadCommit,
            hasCapture, hasRecorded, hasNotAddressed, hasError,
        ]
                .filter({ $0 }).count + projected == 1 else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Response must contain exactly one result or error")
        }
        return try makeDecoder().decode(
            AgentIntegrationLocalResponse.self, from: bounded(data))
    }

    private static func strictObject(_ data: Data, keys: Set<String>)
        throws -> [String: Any] {
        let object = try strictObject(data, allowedKeys: keys)
        guard Set(object.keys) == keys else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Local request fields do not match the schema")
        }
        return object
    }

    private static func strictObject(_ data: Data,
                                     allowedKeys: Set<String>)
        throws -> [String: Any] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(
                with: bounded(data), options: [])
        } catch {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Local message is not valid JSON")
        }
        guard let dictionary = object as? [String: Any],
              Set(dictionary.keys).isSubset(of: allowedKeys) else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Local message does not match the schema")
        }
        return dictionary
    }

    private static func bounded(_ data: Data) throws -> Data {
        guard data.count <= AgentIntegrationLocalProtocol.maximumMessageBytes
        else {
            throw AgentIntegrationLocalTransportError.messageTooLarge
        }
        return data
    }
}

public enum AgentIntegrationLocalTransportError: Error, Equatable {
    /// The host would not answer for the machine this request named.
    /// Carried out of the transport as itself, so the caller can report
    /// which machine and which one is being driven rather than "invalid
    /// response".
    case notAddressed(AgentIntegrationUnavailable)
    /// The host carries the operation and nothing serves it yet. Carried
    /// out as itself, like `notAddressed`, so a caller that reaches an
    /// unwired verb is told that rather than "the response had no result" —
    /// which would send whoever wires it looking for a decoding bug.
    case notImplemented(AgentIntegrationUnavailable)
    case hostUnavailable
    case unsafeEndpoint(String)
    case invalidMessage(String)
    case messageTooLarge
    case io(String)
}
