import Foundation

/// The registry rows. One line per capability, and the only file a new
/// capability edits besides its own.
///
/// Order is what every face presents, so keep it deliberate: read-only
/// session facts, then observation, then the actions, then the guest Files
/// family. It is not alphabetical and should not become so.
public enum HostProjectionCatalog {
    public static let projections: [any HostProjection.Type] = [
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
        /* With the observations rather than beside the Files family: it
           reads what the guest wrote about itself, changes nothing, and
           names no file — the nearest neighbour of a process listing, not
           of a directory one. */
        GuestLogTailProjection.self,
        CaptureScreenProjection.self,
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
        LaunchSoftwareProjection.self,
        /* Beside launch rather than at the tail: they are the same guest
           verb pair over the same target grammar, and reveal is the one
           that opens nothing. */
        RevealItemProjection.self,
        BringToFrontProjection.self,
        RequestQuitProjection.self,
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
    ]
}
