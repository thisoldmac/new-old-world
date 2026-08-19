import Foundation
import os

/// The one modern-host directory a projection may read bytes out of, pinned
/// by whoever started this process — never discovered from the environment.
///
/// It exists for the chat workspace lane: the host spawns its own executable
/// as an MCP companion (`--mcp-stdio`) and, when the lane has a granted
/// folder, names it with `--workspace-root`. That argument is the person's
/// Settings choice travelling one hop, so the authority is the host's, not
/// this process's to widen. A companion launched any other way has no root,
/// and `now_guest_files_upload_file` refuses rather than guessing one —
/// an ambient default (cwd, $HOME, an env var) is exactly the stale-address
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
