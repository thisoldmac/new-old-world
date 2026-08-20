import Foundation
import os

/// The one modern-host directory a projection may read bytes out of, pinned
/// by the host's own Settings answer — never discovered from the
/// environment.
///
/// It exists for the chat workspace lane. Two configurers, one authority:
/// the host pins it in-process before each lane spawn (the HTTP MCP runs
/// inside the host, the lane's mainline since stdio's sunset), and the
/// sunset `--mcp-stdio` companion still receives it as `--workspace-root`
/// on its command line. Either way the value is the person's Settings
/// choice travelling one hop. A process with no root pinned has none, and
/// `now_guest_files_upload_file` refuses rather than guessing one — an
/// ambient default (cwd, $HOME, an env var) is exactly the stale-address
/// class of failure the deploy scripts refuse to have.
public enum HostProjectionLocalRead {
    private static let state = OSAllocatedUnfairLock<URL?>(initialState: nil)

    /// Set once at companion start, before any request is served. Callable
    /// again only so tests can stage and clear it; product code has one
    /// call site, in the `--mcp-stdio` entry point.
    public static func configure(workspaceRoot: URL?) {
        state.withLock { $0 = workspaceRoot }
    }

    public static var workspaceRoot: URL? {
        state.withLock { $0 }
    }
}
