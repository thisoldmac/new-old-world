import Foundation

/// The registry rows. One line per capability, and the only file a new
/// capability edits besides its own.
///
/// Order is what every face presents, so keep it deliberate: read-only
/// session facts, then observation, then the actions, then the guest Files
/// family. It is not alphabetical and should not become so.
public enum HostProjectionCatalog {
    // Swift 6.1 accepts the immutable erased-metatype array as Sendable and
    // warns on the escape hatch; Swift 6.2+ requires that hatch again. The
    // rows stay in one factory so the compiler fence cannot fork the catalog.
#if compiler(>=6.2)
    public nonisolated(unsafe) static let projections = makeProjections()
#else
    public static let projections = makeProjections()
#endif

    private static func makeProjections() -> [any HostProjection.Type] { [
        ProjectsProjection.self,
        DevelopmentEnvironmentProjection.self,
        DevelopmentProjection.self,
        SessionHealthProjection.self,
        SessionCapabilitiesProjection.self,
        /* First of the observations, because it is the machine's standing
           facts: what the hardware IS changes on a timescale of screwdrivers,
           where the process table and the screen change while you read them.
           A person opening the app meets the Census page in the same
           position. */
        HardwareCensusProjection.self,
        /* Immediately after the census, because it answers the same class of
           question — what the machine IS — by the other route, and the two
           are meant to be read together. Adjacent and not merged: the
           difference in plane, shape and meaning of absence is argued in
           both rows and in docs/mcp-coverage.md. */
        MachineFactsProjection.self,
        ListProcessesProjection.self,
        /* Immediately after the process listing, because it is the next
           question a caller asks with the answer in hand: what is INSIDE
           one of those processes. It is an observation and belongs here
           rather than with the act rows below — it changes nothing, it sits
           a consent tier below every act, and it is the only thing in the
           product that mints the references those acts require. Read in
           order, the observations go from the machine, to its processes, to
           the elements of one of them. */
        ObserveElementsProjection.self,
        /* Four views of the SAME immutable lane the native Mirror renders.
           Kept together immediately after the legacy element walk so the
           distinction is visible: these rows do not ask the guest again,
           mint a second cache, or substitute for the direct-input/pixel
           gate. Status is the cheap identity, snapshot the full projection,
           find a bounded local query, and wait the next published snapshot. */
        /* First of the family, because it is the row that makes the
           others answer anything: they read a state engine that only runs
           while the window is open, and nothing else here can open it. */
        MirrorOpenProjection.self,
        MirrorStatusProjection.self,
        MirrorSnapshotProjection.self,
        MirrorFindProjection.self,
        MirrorWaitProjection.self,
        /* And metrics, because the Mirror page shows them and a headless
           client that cannot see them has to guess at the difference
           between a slow machine and a queued act. */
        MirrorMetricsProjection.self,
        /* Beside the metrics, because a measurement without its premise is
           a confident, meaningless number: this row is the premise. */
        MirrorLifecycleProjection.self,
        MirrorJournalProjection.self,
        MirrorSettlementProjection.self,
        /* And the one mutation row that shares the window's executor. It
           sits with the reads rather than with the act lane's five because
           it is the same engine seen the other way round, and because a
           reader who found it beside them would reasonably assume it took
           their addressing. */
        MirrorDriveProjection.self,
        /* With the observations rather than beside the Files family: it
           reads what the guest wrote about itself, changes nothing, and
           names no file — the nearest neighbour of a process listing, not
           of a directory one. */
        GuestLogTailProjection.self,
        CaptureScreenProjection.self,
        /* Immediately after capture, because it is the same observation
           held open: one picture now, or the bracket that produces them
           until somebody stops it. Adjacent and not merged — a capture is a
           bounded call and a stream is a lane an agent takes, and the two
           are mutually exclusive on the wire, which is the first thing a
           reader of either row needs to meet in the other. */
        StreamScreenProjection.self,
        /* Beside capture on purpose: the two costly MEASUREMENTS of the
           machine sit together, before the actions. */
        CatalogSearchProjection.self,
        /* The three diagnostics, with the costly measurements and before the
           actions, because that is what they are: measurements of the
           machine that change nothing on it. They are three rows rather
           than one because availability is per row and these three do not
           co-occur on any guest — the argument is at the top of
           GuestDiagnosticsProjection.swift. Kept adjacent and in the order
           the module draws them, so a person reading either list meets them
           the same way. */
        FramebufferProbeProjection.self,
        CaptureDiagnosticsProjection.self,
        TransferDiagnosticsProjection.self,
        /* Between the measurement of the sweep and the verb that acts on
           what the sweep found, which is the order a caller uses them in:
           what does this inventory cost, what is in it, open one of them.
           It is the last of the observations for that reason — the next row
           is the first that changes the machine. */
        SoftwareInventoryProjection.self,
        LaunchSoftwareProjection.self,
        /* Beside launch rather than at the tail: they are the same guest
           verb pair over the same target grammar, and reveal is the one
           that opens nothing. */
        RevealItemProjection.self,
        BringToFrontProjection.self,
        RequestQuitProjection.self,
        /* The act plane, with the process drive verbs and after them: the
           same class of thing — a row that changes the machine rather than
           reads it — one reach further in. The drive verbs above address a
           PROCESS and can say only which application is in front; these five
           address a piece of an application's own interface, and every one
           of them takes a reference `now_observe_elements` minted.

           Ordered by what they reach: the window, then the control inside
           it, then the menu bar above it, then the text. The read sits
           between the write and its neighbours rather than with the
           observations, and that is deliberate: it is an act-plane row that
           happens to change nothing, sharing the identity grammar, the
           reference vocabulary and the availability of the rows around it.
           Its readOnlyHint puts it a consent tier below them, which is the
           thing that split makes expressible. */
        WindowActProjection.self,
        ControlActProjection.self,
        MenuActProjection.self,
        TextGetProjection.self,
        TextSetProjection.self,
        TransferApprovedArtifactProjection.self,
        /* Beside the transfer it can end, and before the Files family:
           it ends a transfer in EITHER direction, so it belongs to
           neither half of the lane. */
        TransferCancelProjection.self,
        GuestFilesCapabilitiesProjection.self,
        GuestFilesListProjection.self,
        GuestFilesStatProjection.self,
        /* Last of the read side: it returns one file rather than a
           listing, and changes nothing on the machine. */
        GuestFilesDownloadProjection.self,
        GuestFilesMutateProjection.self,
        GuestFilesUploadBeginProjection.self,
        GuestFilesUploadAppendProjection.self,
        GuestFilesUploadCommitProjection.self,
    ] }
}
