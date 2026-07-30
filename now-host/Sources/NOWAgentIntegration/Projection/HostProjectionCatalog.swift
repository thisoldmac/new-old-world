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
        ListProcessesProjection.self,
        CaptureScreenProjection.self,
        LaunchSoftwareProjection.self,
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
        GuestFilesUploadBeginProjection.self,
        GuestFilesUploadAppendProjection.self,
        GuestFilesUploadCommitProjection.self,
    ]
}
