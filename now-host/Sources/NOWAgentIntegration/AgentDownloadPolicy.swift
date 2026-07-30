import Foundation

/// The agent download ceiling, stated once for the two places that need it.
///
/// The store in the app target enforces it; `GuestFilesDownloadProjection`
/// publishes it in a schema a caller reads. Those are different targets, so
/// the number lives here rather than being typed in both — the shape of drift
/// this repository has paid for before (a control-frame cap that existed as
/// prose, as a sender constant, and as a different number in the receiver's
/// buffer).
///
/// **4 MiB, and it is where the evidence ends rather than a round number.**
/// Two independent bounds already sit there: the artifact approval lane caps
/// a human-selected source at 4 MiB (docs/agent-integration.md), and the
/// reverse-streaming path's metal ladder on the PowerBook 1400c stopped at
/// 4 MiB — the largest verified pull, 11.70 s
/// (docs/reverse-file-streaming.md). Raising it is a metal question, not a
/// constant edit.
public enum AgentDownloadPolicy {
    public static let maximumBytes = 4 * 1024 * 1024
}
