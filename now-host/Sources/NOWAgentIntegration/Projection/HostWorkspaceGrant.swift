import Foundation

/// One server session's immutable permission to read from an exact modern-host
/// directory. Transport credentials never imply this value.
public struct HostWorkspaceGrant: Sendable {
    public let canonicalRoot: URL

    public init(workspaceRoot: URL) {
        canonicalRoot = workspaceRoot.standardizedFileURL
            .resolvingSymlinksInPath()
    }
}
