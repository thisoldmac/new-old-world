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
        ListProcessesProjection.self,
        CaptureScreenProjection.self,
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
