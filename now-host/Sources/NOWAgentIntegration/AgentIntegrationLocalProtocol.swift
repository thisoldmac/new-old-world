import Foundation

public enum AgentIntegrationLocalProtocol {
    /// Version 12 adds a typed settlement read by semantic operation ID and
    /// makes a version mismatch observable as compatibility, not malformed
    /// data. A v12 companion can therefore name an older host once, before a
    /// caller retries a mutation against an unknowable transport outcome.
    /// Version 11 separates the host-owned machine title from the name the
    /// guest reported at hello. `AgentIntegrationGuestReference.name` now
    /// carries the title shown in NOW and `reportedName` carries the guest's
    /// own value. A v10 companion must fail closed instead of silently
    /// interpreting the edited host title as guest identity.
    ///
    /// Version 10 adds the guest-provided menubar and rows to the Mirror
    /// snapshot DTO. The same bounded scene can carry 96 menu items, so the
    /// local envelope grows to the MCP face's existing 64 KiB ceiling rather
    /// than truncating the state engine's authoritative projection.
    ///
    /// Version 9 adds one read-only lane over the native Mirror's immutable
    /// state engine. Status, snapshot, find and wait are intentions on that
    /// lane rather than four transports, and none of them polls the guest.
    /// A v8 host refuses the new shape instead of letting a companion mistake
    /// an independently-observed process list for the Mirror's own state.
    ///
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
    public static let version = 12
    public static let maximumMessageBytes = 64 * 1024
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
           here. Every current case is wired; `notImplemented` remains in the
           response vocabulary so a newer client gets an honest typed answer
           from an older host instead of treating version skew as corruption.

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
        /// The PPC guest's qualified, path-free development registration.
        case developmentEnvironment = "development_environment"
        /// Time a whole-volume catalog search for applications.
        case catalogSearch = "catalog_search"
        /// Show an item in the machine's own Finder. Opens nothing.
        case revealItem = "reveal_item"
        /// One of the three diagnostics, named. One operation because none
        /// of them takes an argument, all three answer rows, and they have
        /// a single home.
        case diagnostics = "diagnostics"
        /// Read the native Mirror's already-published immutable state. Four
        /// intentions share one operation because they are renderings of one
        /// engine lane, not four observers.
        case mirrorRead = "mirror_read"
        /// Drive the native Mirror through the SAME executor a gesture
        /// uses. Not a sibling of the act lane's five: those address an
        /// observation-minted element and settle for nothing, and this
        /// addresses a published scene entity and settles the way a click
        /// does. Two mutation paths would be two products.
        case mirrorDrive = "mirror_drive"
        /// Open the native Mirror window on an ALREADY-RUNNING host, and
        /// raise it if it is already open.
        ///
        /// The only operation on this surface whose whole effect is on
        /// the modern machine — `reveal_item` is the closest relative and
        /// still crosses the wire. It takes no arguments for the same
        /// reason the diagnostics do not: there is exactly one Mirror,
        /// and which Mac it shows is the one this host is driving.
        ///
        /// Not folded into `mirror_read` or `mirror_drive`. Those two
        /// address a published scene and are meaningless before a window
        /// exists; this one is what makes a window exist, and a caller
        /// that had to ask for a reading to get one would be opening a
        /// window as a side effect of observing.
        case mirrorOpen = "mirror_open"
        /// Open the live-stream bracket, read a frame off it, or close it.
        ///
        /// One operation for the same reason `capture` folded take, page and
        /// abandon into one, and one more that is this operation's own: a
        /// bracket is a lane rather than a family, and the two intentions
        /// that are not `start` are meaningless except against the `start`
        /// that opened it. Three operations would let a caller ask for a
        /// frame of a stream nothing opened.
        case stream = "stream"

        /* THE ACT LANE, five operations, added as one edit for the reason
           P1a's eleven were: every one of them touches this enum, the
           result enum and the response's field list, and five separate
           edits to the same three tails is five merge conflicts.

           FIVE AND NOT ONE, which is the opposite of the choice `capture`,
           `stream` and `guestFileMutation` each made — so the difference is
           worth stating. Those three folded because their intentions are a
           LANE: a capture page is meaningless except against the capture
           that produced it, and `restore` consumes what `trash` answered.
           These five share no state at all. Each is one command.request
           with its own arguments, its own guest verb, and its own
           capability that a machine may serve while refusing the others —
           `textget` is explicitly the one a guest can answer while
           declining the two that drive it. Folding them would produce one
           operation with five argument shapes and one availability, which
           is exactly what the row-level design refused. */

        /// Move, resize, zoom or close one addressed window.
        case windowAct = "window_act"
        /// Answer one addressed control's own TrackControl with a part code.
        case controlAct = "control_act"
        /// Answer one application's own MenuSelect with a menu item.
        case menuAct = "menu_act"
        /// Read one addressed text element. The only one of the five that
        /// changes nothing.
        case textGet = "text_get"
        /// Replace one addressed text element's whole contents.
        case textSet = "text_set"

        /* THE WALK THAT MINTS WHAT THE FIVE ABOVE TAKE, added 2026-08-07
           and six days late.

           Every one of the five acts addresses a `now-element-…` or
           `now-window-…` reference, and `elements` is the only thing that
           produces one. The five landed here without it, so this surface
           spent six days serving five operations no caller could compose a
           legal argument for — a lane whose door was on the other side of
           the wall. `ObserveElementsProjection` was registered the same
           week and answered a protocol default, which is how it stayed
           unnoticed: the MCP row existed, listed, described, and refused.

           NO VERSION BUMP, and that is a decision rather than an oversight.
           The version moves when the SHAPE changes in a way that would let
           an older peer misread an answer — v10 grew the snapshot DTO, v7
           made every reply name its machine. A new operation is additive:
           an older host fails the strict decode of an operation string it
           has never heard of and answers `invalid-request`, which is the
           honest sentence, and a bump would instead refuse every existing
           companion for a lane it never asks about. */

        /// Walk one process's on-screen elements and mint a reference for
        /// each. An observation and not an act: it changes nothing, and the
        /// `serialHi`/`serialLo` pair aims the WALK — there is no spelling
        /// anywhere downstream for "whatever is frontmost".
        case observeElements = "observe_elements"
        case projects = "projects"
        // Names the guest's build/toolchain operation, not this file's
        // unrelated `.projects` case above (the app-owned project catalog).
        // The host module this operation drives is titled "Projects" in
        // the UI now (034 G-2); this wire operation string stays
        // "development" on purpose — MCP tool names are a separate rename.
        case development = "development"
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
    /// Which rendering of the native Mirror state engine to read. Present
    /// only on `mirror_read`; its own grammar pins each intention's fields.
    public var mirrorReadRequest: AgentIntegrationMirrorReadRequest? = nil
    /// Which gesture to run against the published Mirror snapshot.
    public var mirrorDriveRequest: AgentIntegrationMirrorDriveRequest? = nil

    /* The bracket's fields. Which of the three intentions is always
       explicit, unlike `capture`'s three shapes — a bracket's intentions
       are not told apart by which optional arrived, because `frame` with no
       id and `stop` would then be the same request with nothing in it. */

    /// Open, read, or close. Required on the `stream` operation and refused
    /// anywhere else.
    public var streamIntention: AgentIntegrationStreamIntention? = nil
    /// Bits per pixel and the frame-rate ceiling to open with. Present
    /// together and only on `start`; the projection fills the pace in when
    /// the caller names none, so this is never absent on the wire.
    public var streamDepth: Int? = nil
    public var streamMinIntervalMs: Int? = nil
    /// Which staged frame a continuation is reading, and from where. Present
    /// together, and only on a `frame` continuation — a `frame` carrying
    /// neither is the request for the NEXT one.
    public var streamFrameID: UUID? = nil
    public var streamFrameOffset: Int? = nil

    /* The act lane's arguments, carried as the TYPED requests rather than
       as thirteen loose scalars.

       The alternative was a field per argument — `actWindow`, `actAction`,
       `actLeft`, `actTop`, `actWidth`, `actHeight`, `actElement`, `actPart`,
       `actMenu`, `actItem`, `actTitleLeft`, `actSerialHi`, `actSerialLo` —
       and this file already shows what that costs: the per-operation key
       sets below would have to re-derive, in a switch, the per-action
       geometry rule that `AgentIntegrationWindowActRequest` already states
       once. A second spelling of a grammar is a second thing to get wrong,
       and the one that drifts is always the copy.

       It follows `launchSelection`, `guestFileUpload` and
       `guestFileMutation`, which are typed for the same reason. And it does
       NOT make the codec's job smaller: a synthesised decode admits a
       `close` carrying a width, so each of these is re-checked against its
       own `isWellFormed` on arrival. The strict key list guards the
       envelope; the grammar guards the value. */

    /// The window act's target, action and geometry. Present only on
    /// `window_act`.
    public var windowActRequest: AgentIntegrationWindowActRequest? = nil
    /// The control act's element and part code. Present only on
    /// `control_act`.
    public var controlActRequest: AgentIntegrationControlActRequest? = nil
    /// The menu act's item and its identity check. Present only on
    /// `menu_act`.
    public var menuActRequest: AgentIntegrationMenuActRequest? = nil
    /// The addressed text element, on `text_get` and on `text_set`. One
    /// field for both because it is one reference vocabulary: a caller that
    /// can read an element can name it to write it, and two fields would
    /// let a request address one element and write another.
    public var actElement: String? = nil
    /// The replacement contents. Present only on `text_set`, and required
    /// there — an absent text is not an empty one. Emptying a field is a
    /// legal act and is spelled with an empty string.
    public var actText: String? = nil
    /// Which process the walk aims at, on `observe_elements`. **Absent is a
    /// COMPLETE request** and means the frontmost application — the
    /// contract's own default for `elements`. The pair rule (both halves or
    /// neither) is enforced where a caller's keys are first read, in
    /// `AgentIntegrationProcessSerial.decode`; by the time a value reaches
    /// this field it is a whole serial number or nothing.
    public var observeProcess: AgentIntegrationProcessSerial? = nil
    public var projectRequest: AgentIntegrationProjectRequest? = nil
    public var developmentRequest: AgentIntegrationDevelopmentRequest? = nil

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

    public static func developmentEnvironment(
        requestID: UUID = UUID()
    ) -> Self {
        projected(.developmentEnvironment, requestID: requestID)
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

    public static func mirrorRead(
        _ read: AgentIntegrationMirrorReadRequest,
        requestID: UUID = UUID()
    ) -> Self {
        var request = projected(.mirrorRead, requestID: requestID)
        request.mirrorReadRequest = read
        return request
    }

    public static func mirrorDrive(
        _ drive: AgentIntegrationMirrorDriveRequest,
        requestID: UUID = UUID()
    ) -> Self {
        var request = projected(.mirrorDrive, requestID: requestID)
        request.mirrorDriveRequest = drive
        return request
    }

    /// Open the Mirror on this host. No arguments — there is one Mirror,
    /// and it shows the Mac this host is driving.
    public static func mirrorOpen(requestID: UUID = UUID()) -> Self {
        projected(.mirrorOpen, requestID: requestID)
    }

    // MARK: - The live-stream bracket

    /// Open the bracket. The pace is not optional here even though the
    /// contract lets it be: absent means the guest's own floor, and this
    /// surface has no unbounded setting to hand out.
    public static func streamStart(
        depth: Int,
        minIntervalMs: Int,
        requestID: UUID = UUID()
    ) -> Self {
        var request = projected(.stream, requestID: requestID)
        request.streamIntention = .start
        request.streamDepth = depth
        request.streamMinIntervalMs = minIntervalMs
        return request
    }

    /// Ask the open bracket for a whole frame, and read its first page.
    public static func streamFrame(requestID: UUID = UUID()) -> Self {
        var request = projected(.stream, requestID: requestID)
        request.streamIntention = .frame
        return request
    }

    /// Read one more page of the frame this host already staged.
    public static func streamFramePage(
        frameID: UUID,
        offset: Int,
        requestID: UUID = UUID()
    ) -> Self {
        var request = projected(.stream, requestID: requestID)
        request.streamIntention = .frame
        request.streamFrameID = frameID
        request.streamFrameOffset = offset
        return request
    }

    /// Close the bracket.
    public static func streamStop(requestID: UUID = UUID()) -> Self {
        var request = projected(.stream, requestID: requestID)
        request.streamIntention = .stop
        return request
    }

    // MARK: - The act lane

    /// Move, resize, zoom or close one addressed window.
    public static func windowAct(
        _ act: AgentIntegrationWindowActRequest,
        requestID: UUID = UUID()
    ) -> Self {
        var request = projected(.windowAct, requestID: requestID)
        request.windowActRequest = act
        return request
    }

    /// Answer one addressed control's own `TrackControl`.
    public static func controlAct(
        _ act: AgentIntegrationControlActRequest,
        requestID: UUID = UUID()
    ) -> Self {
        var request = projected(.controlAct, requestID: requestID)
        request.controlActRequest = act
        return request
    }

    /// Answer one application's own `MenuSelect`.
    public static func menuAct(
        _ act: AgentIntegrationMenuActRequest,
        requestID: UUID = UUID()
    ) -> Self {
        var request = projected(.menuAct, requestID: requestID)
        request.menuActRequest = act
        return request
    }

    /// Read one addressed text element.
    public static func textGet(
        element: String,
        requestID: UUID = UUID()
    ) -> Self {
        var request = projected(.textGet, requestID: requestID)
        request.actElement = element
        return request
    }

    /// Replace one addressed text element's whole contents.
    public static func textSet(
        element: String, text: String,
        requestID: UUID = UUID()
    ) -> Self {
        var request = projected(.textSet, requestID: requestID)
        request.actElement = element
        request.actText = text
        return request
    }

    /// Walk one process's elements, or the frontmost application's.
    ///
    /// The parameter has no default value on purpose, even though nil is
    /// legal: "observe the frontmost" is a choice a caller makes, and a
    /// defaulted argument would let a call that meant to name a process
    /// compile into one that asks about whichever application happens to be
    /// in front.
    public static func observeElements(
        process: AgentIntegrationProcessSerial?,
        requestID: UUID = UUID()
    ) -> Self {
        var request = projected(.observeElements, requestID: requestID)
        request.observeProcess = process
        return request
    }

    public static func projects(
        _ project: AgentIntegrationProjectRequest,
        requestID: UUID = UUID()
    ) -> Self {
        var request = projected(.projects, requestID: requestID)
        request.projectRequest = project
        return request
    }

    public static func development(
        _ development: AgentIntegrationDevelopmentRequest,
        requestID: UUID = UUID()
    ) -> Self {
        var request = projected(.development, requestID: requestID)
        request.developmentRequest = development
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
    case developmentEnvironment(AgentIntegrationGuestRowReportResult)
    case catalogSearch(AgentIntegrationGuestRowReportResult)
    case revealItem(AgentIntegrationGuestRowReportResult)
    case diagnostics(AgentIntegrationGuestRowReportResult)
    case mirrorRead(AgentIntegrationMirrorReadResult)
    case mirrorDrive(AgentIntegrationMirrorDriveResult)
    case mirrorOpen(AgentIntegrationMirrorOpenResult)
    /// The bracket's state, or one page of one frame off it.
    case stream(AgentIntegrationStreamResult)
    /* The act lane's five, one case each — for the reason the five
       operations are five: they share no state, and a caller reading a
       menu act's answer out of a case that could also hold a text reading
       would have to ask which it held. */
    case windowAct(AgentIntegrationWindowActResult)
    case controlAct(AgentIntegrationControlActResult)
    case menuAct(AgentIntegrationMenuActResult)
    case textGet(AgentIntegrationTextReadingResult)
    case textSet(AgentIntegrationTextSetResult)
    /// The walk's whole tree. Its own case rather than a row report: this
    /// answer is navigated and then addressed, and flattening it would
    /// destroy the containment that makes a reference mean anything.
    case observeElements(AgentIntegrationElementObservationResult)
    case projects(AgentIntegrationProjectResult)
    case development(AgentIntegrationGuestRowReportResult)

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
    public var developmentEnvironmentResult:
        AgentIntegrationGuestRowReportResult? = nil
    public var catalogSearchResult:
        AgentIntegrationGuestRowReportResult? = nil
    public var revealItemResult:
        AgentIntegrationGuestRowReportResult? = nil
    public var diagnosticsResult:
        AgentIntegrationGuestRowReportResult? = nil
    public var mirrorReadResult: AgentIntegrationMirrorReadResult? = nil
    public var mirrorDriveResult: AgentIntegrationMirrorDriveResult? = nil
    public var mirrorOpenResult: AgentIntegrationMirrorOpenResult? = nil
    /// The bracket, or one page of a frame off it. Sized like the capture
    /// field beside it, and for the same reason — a frame IS a capture, so
    /// a full page still leaves the response inside the 16 KiB cap.
    public var streamResult: AgentIntegrationStreamResult? = nil
    /* The act lane's five result fields. Named in `projectedResultKeys`
       below, which is what puts them through BOTH of `decodeResponse`'s
       gates — the allowlist and the exactly-one-of count — so a response
       carrying a window act AND a text reading is malformed rather than
       ambiguous. */
    public var windowActResult: AgentIntegrationWindowActResult? = nil
    public var controlActResult: AgentIntegrationControlActResult? = nil
    public var menuActResult: AgentIntegrationMenuActResult? = nil
    public var textGetResult: AgentIntegrationTextReadingResult? = nil
    public var textSetResult: AgentIntegrationTextSetResult? = nil
    /// The observation's tree. Named in `projectedResultKeys` with the
    /// rest, so a response carrying a walk AND an act is malformed rather
    /// than ambiguous.
    public var observeElementsResult:
        AgentIntegrationElementObservationResult? = nil
    public var projectResult: AgentIntegrationProjectResult? = nil
    public var developmentResult: AgentIntegrationGuestRowReportResult? = nil
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
        developmentEnvironmentResult: AgentIntegrationGuestRowReportResult
    ) {
        self.init(empty: requestID)
        self.developmentEnvironmentResult = developmentEnvironmentResult
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
                mirrorReadResult: AgentIntegrationMirrorReadResult) {
        self.init(empty: requestID)
        self.mirrorReadResult = mirrorReadResult
    }

    public init(requestID: UUID,
                mirrorDriveResult: AgentIntegrationMirrorDriveResult) {
        self.init(empty: requestID)
        self.mirrorDriveResult = mirrorDriveResult
    }

    public init(requestID: UUID,
                mirrorOpenResult: AgentIntegrationMirrorOpenResult) {
        self.init(empty: requestID)
        self.mirrorOpenResult = mirrorOpenResult
    }

    public init(requestID: UUID,
                streamResult: AgentIntegrationStreamResult) {
        self.init(empty: requestID)
        self.streamResult = streamResult
    }

    public init(requestID: UUID,
                windowActResult: AgentIntegrationWindowActResult) {
        self.init(empty: requestID)
        self.windowActResult = windowActResult
    }

    public init(requestID: UUID,
                controlActResult: AgentIntegrationControlActResult) {
        self.init(empty: requestID)
        self.controlActResult = controlActResult
    }

    public init(requestID: UUID,
                menuActResult: AgentIntegrationMenuActResult) {
        self.init(empty: requestID)
        self.menuActResult = menuActResult
    }

    public init(requestID: UUID,
                textGetResult: AgentIntegrationTextReadingResult) {
        self.init(empty: requestID)
        self.textGetResult = textGetResult
    }

    public init(requestID: UUID,
                textSetResult: AgentIntegrationTextSetResult) {
        self.init(empty: requestID)
        self.textSetResult = textSetResult
    }

    public init(
        requestID: UUID,
        observeElementsResult: AgentIntegrationElementObservationResult
    ) {
        self.init(empty: requestID)
        self.observeElementsResult = observeElementsResult
    }

    public init(requestID: UUID,
                notImplemented: AgentIntegrationUnavailable) {
        self.init(empty: requestID)
        self.notImplemented = notImplemented
    }

    public init(requestID: UUID,
                projectResult: AgentIntegrationProjectResult) {
        self.init(empty: requestID)
        self.projectResult = projectResult
    }

    public init(requestID: UUID,
                developmentResult: AgentIntegrationGuestRowReportResult) {
        self.init(empty: requestID)
        self.developmentResult = developmentResult
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
        "developmentEnvironmentResult",
        "catalogSearchResult", "revealItemResult",
        "diagnosticsResult", "mirrorReadResult", "mirrorDriveResult",
        "mirrorOpenResult",
        "streamResult",
        // The act lane's five, in both gates from the day they landed.
        "windowActResult", "controlActResult", "menuActResult",
        "textGetResult", "textSetResult",
        // The walk that mints what those five address.
        "observeElementsResult",
        "projectResult",
        "developmentResult",
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

    /// **A reply that will not fit is still a reply.**
    ///
    /// The server's one exit used to encode with `try?` and return on
    /// failure, and its `defer` closed the socket — so an answer past the
    /// ceiling reached the caller as a hang-up: no error frame, no code, no
    /// reason. On 2026-08-07 that was `mirror_read --intention snapshot`
    /// closing the connection 3/3 while `status`, `metrics` and `find`
    /// answered on the same path, which reads as a broken host rather than
    /// an oversized payload, and it silently disabled the only instrument
    /// that can measure live render flicker.
    ///
    /// Every refusal in this tree says what happened and why; a closed
    /// socket is the least informative answer there is. So the encode never
    /// fails silently: it returns either the response or a bounded refusal
    /// naming the operation, the size it reached and the ceiling it met.
    ///
    /// This is the TRANSPORT's guarantee, which is why it lives here rather
    /// than in the verb that was caught — the encode is the one exit every
    /// served operation leaves by.
    public static func encodeOrRefusal(
        _ response: AgentIntegrationLocalResponse,
        operation: String?) -> Data {
        let encoder = makeEncoder()
        let encoded = try? encoder.encode(response)
        if let encoded,
           encoded.count <= AgentIntegrationLocalProtocol.maximumMessageBytes {
            return encoded
        }
        let cap = AgentIntegrationLocalProtocol.maximumMessageBytes
        let named = operation ?? "this operation"
        let reached = encoded.map { "reached \($0.count) bytes" }
            /* Nil means the encoder itself refused the value, which is a
               different fault from an oversized one and must not be
               reported as a size. */
            ?? "could not be encoded at all"
        let refusal = AgentIntegrationLocalResponse(
            requestID: response.requestID,
            error: .init(
                code: "response-too-large",
                message: "The \(named) reply \(reached) and one agent "
                    + "protocol message carries at most \(cap) bytes. "
                    + "Nothing was sent and nothing was truncated; this "
                    + "refusal is here so the connection does not simply "
                    + "close. Ask for a narrower reading of \(named) — a "
                    + "metadata-only or filtered intention where it has "
                    + "one — or reduce what the host is being asked to "
                    + "carry in one answer."))
        if let data = try? encoder.encode(refusal), data.count <= cap {
            return data
        }
        /* The floor beneath the floor: hand-built so it cannot itself be
           the thing that fails to encode. A caller that reaches this still
           gets a well-formed response with a code it can switch on. */
        return Data("""
        {"version":\(AgentIntegrationLocalProtocol.version),\
        "error":{"code":"response-too-large",\
        "message":"The reply exceeded \(cap) bytes and could not be sent."}}
        """.utf8)
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
            "mirrorReadRequest",
            "mirrorDriveRequest",
            // The bracket's fields, clearing the same two gates.
            "streamIntention", "streamDepth", "streamMinIntervalMs",
            "streamFrameID", "streamFrameOffset",
            // The act lane's fields, clearing the same two gates.
            "windowActRequest", "controlActRequest", "menuActRequest",
            "actElement", "actText",
            // The observation's aim, clearing the same two gates.
            "observeProcess",
            "projectRequest",
            "developmentRequest",
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
        case .transferCancel, .machineFacts, .developmentEnvironment,
             .catalogSearch:
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
        case .mirrorDrive:
            expectedKeys = [
                "version", "requestID", "operation", "mirrorDriveRequest",
            ]
            guard let drive = request.mirrorDriveRequest,
                  drive.isWellFormed else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Mirror drive request does not match its gesture")
            }
        case .mirrorOpen:
            /* Says only its own name, like the three grouped above — but
               its own branch rather than joining them, because it is the
               one operation here that never reaches a guest and a reader
               scanning for "what does this send to the Mac" should not
               find it in a group whose other members do. */
            expectedKeys = ["version", "requestID", "operation"]
        case .mirrorRead:
            expectedKeys = [
                "version", "requestID", "operation", "mirrorReadRequest",
            ]
            guard let read = request.mirrorReadRequest,
                  read.isWellFormed else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Mirror read request does not match its intention")
            }
        case .stream:
            /* The intention is REQUIRED and carries the shape, unlike
               capture's three-way read of which optional arrived: `stop`
               and "the next frame" would otherwise be the same empty
               request. Each intention then admits exactly its own fields,
               and the key-set equality below refuses the rest — so a
               `stop` carrying a depth is refused rather than served with
               the depth ignored. */
            var streamKeys: Set<String> = [
                "version", "requestID", "operation", "streamIntention",
            ]
            guard let intention = request.streamIntention else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Stream request names no intention")
            }
            switch intention {
            case .start:
                guard let depth = request.streamDepth,
                      AgentIntegrationCapturePolicy.isValidDepth(depth),
                      let interval = request.streamMinIntervalMs,
                      AgentIntegrationStreamPolicy.isValidInterval(interval)
                else {
                    /* The pace is required here even though the contract
                       makes it optional on the wire, and this is the one
                       place that can hold the line: absent means the
                       guest's own ~15 fps floor, and a surface that let a
                       caller omit it would be handing out the unbounded
                       setting by accident rather than on purpose. */
                    throw AgentIntegrationLocalTransportError.invalidMessage(
                        "Stream start does not name a depth the guest "
                            + "implements and a pace this surface will ask "
                            + "for")
                }
                streamKeys.formUnion(["streamDepth", "streamMinIntervalMs"])
            case .frame:
                /* Neither field is the request for the NEXT frame; both
                   together continue the one already staged. Either alone
                   is a request nothing can serve — the same guard the
                   capture page fetch keeps. */
                let continues = request.streamFrameID != nil
                    || request.streamFrameOffset != nil
                if continues {
                    guard request.streamFrameID != nil,
                          let offset = request.streamFrameOffset,
                          offset >= 0,
                          offset <= AgentIntegrationCapturePolicy
                              .maximumBytes,
                          offset % AgentIntegrationCapturePolicy.pageBytes
                              == 0 else {
                        throw AgentIntegrationLocalTransportError
                            .invalidMessage(
                                "Stream frame page request does not match "
                                    + "the schema")
                    }
                    streamKeys.formUnion(
                        ["streamFrameID", "streamFrameOffset"])
                }
            case .stop:
                break
            }
            expectedKeys = streamKeys

        /* THE ACT LANE. Each of the five admits exactly its own field and
           re-checks the VALUE against the same grammar its projection row
           uses, because the socket is the trust boundary: any process of
           this uid can write it, and a synthesised `Codable` decode is
           happy to produce a `close` carrying a width or a window
           reference that is a bare string. The strict key list guards the
           envelope; `isWellFormed` guards what is inside it.

           None of them is refused HERE for being unserved by the connected
           machine. That is a capability question, resolved off the guest's
           own `help` table further down, and a codec that pre-empted it
           would be this side deciding what a Macintosh can do. */
        case .windowAct:
            expectedKeys = [
                "version", "requestID", "operation", "windowActRequest",
            ]
            guard let act = request.windowActRequest, act.isWellFormed
            else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Window act does not name one window reference, one "
                        + "action and exactly that action's geometry")
            }
        case .controlAct:
            expectedKeys = [
                "version", "requestID", "operation", "controlActRequest",
            ]
            guard let act = request.controlActRequest, act.isWellFormed
            else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Control act does not name one element reference and "
                        + "one part code")
            }
        case .menuAct:
            expectedKeys = [
                "version", "requestID", "operation", "menuActRequest",
            ]
            guard let act = request.menuActRequest, act.isWellFormed else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Menu act does not name a menu item and the titleLeft "
                        + "that is its identity check")
            }
        case .textGet:
            expectedKeys = [
                "version", "requestID", "operation", "actElement",
            ]
            guard let element = request.actElement,
                  AgentIntegrationActPolicy
                      .isValidElementReference(element) else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Text read does not name one element reference")
            }
        case .textSet:
            expectedKeys = [
                "version", "requestID", "operation", "actElement",
                "actText",
            ]
            /* The text is REQUIRED and may be empty. Emptying a field is a
               real act, so an empty string is a legal request and an
               absent key is not the same thing — which is why this reads
               `!= nil` rather than checking for content. */
            guard let element = request.actElement,
                  AgentIntegrationActPolicy
                      .isValidElementReference(element),
                  let text = request.actText,
                  AgentIntegrationActPolicy.isBoundedText(text) else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Text write does not name one element reference and a "
                        + "bounded replacement")
            }
        case .observeElements:
            /* The ONE operation on this surface whose key set is
               conditional on an ABSENCE being legal, and the reason is the
               contract's: `elements` with no serial observes the frontmost
               application, which is a complete request rather than an
               under-specified one. So an absent aim admits no key, and a
               present one admits exactly `observeProcess` — a request
               carrying the key with a null in it is refused by the decoder
               above before reaching here.

               Nothing else to check. The pair rule that makes half a serial
               number unspellable was enforced where the caller's keys were
               first read; there is no shape left here that a Macintosh
               would have to refuse. */
            var observeKeys: Set<String> = [
                "version", "requestID", "operation",
            ]
            if request.observeProcess != nil {
                observeKeys.insert("observeProcess")
            }
            expectedKeys = observeKeys
        case .projects:
            expectedKeys = [
                "version", "requestID", "operation", "projectRequest",
            ]
            guard let project = request.projectRequest,
                  project.isWellFormed else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Projects request does not match the schema")
            }
        case .development:
            expectedKeys = [
                "version", "requestID", "operation", "developmentRequest",
            ]
            guard let development = request.developmentRequest,
                  development.isWellFormed else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Development request does not match the schema")
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
        guard let actual = object["version"] as? Int else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Local response has no protocol version")
        }
        guard actual == AgentIntegrationLocalProtocol.version else {
            throw AgentIntegrationLocalTransportError.incompatibleProtocol(
                expected: AgentIntegrationLocalProtocol.version,
                actual: actual)
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
    /// The socket answered, but the host and MCP adapter do not share the same
    /// local contract. This is not an invalid response and retrying a
    /// mutation cannot repair it.
    case incompatibleProtocol(expected: Int, actual: Int)
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
    /// The host understood the local request but rejected this mutation's
    /// idempotency identity. It is actionable retry state, not malformed
    /// transport, and keeps a collision distinct from an unknown outcome.
    case attemptRefused(code: String, message: String)
    case hostUnavailable
    case unsafeEndpoint(String)
    case invalidMessage(String)
    case messageTooLarge
    case io(String)
}
