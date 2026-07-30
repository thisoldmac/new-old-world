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
        /* Beside capture on purpose: the two costly MEASUREMENTS of the
           machine sit together, before the actions. */
        CatalogSearchProjection.self,
        LaunchSoftwareProjection.self,
        BringToFrontProjection.self,
        RequestQuitProjection.self,
        TransferApprovedArtifactProjection.self,
        GuestFilesCapabilitiesProjection.self,
        GuestFilesListProjection.self,
        GuestFilesStatProjection.self,
        GuestFilesUploadBeginProjection.self,
        GuestFilesUploadAppendProjection.self,
        GuestFilesUploadCommitProjection.self,
    ]
}
