import Foundation

/// The one typed descriptor every launch surface constructs (MIRRORKIT-PLAN
/// decision 1). The mirror is a consumer, not a deployer: it assumes AXPeek +
/// a toolkit worker are already live at `host:port`.
public struct MirrorTarget: Codable, Equatable, Sendable {
    /// Wire host (the worker's forwarded port lives here).
    public var host: String
    /// Worker wire port.
    public var port: Int
    /// axtree scope to poll ("all" or "front").
    public var scope: String
    /// Machine id, for window titling and capability lookup (e.g. "mac99").
    public var machine: String
    /// QMP unix-socket path for the emu drag plane. nil on metal — every
    /// action that needs it is typed emu-only and degrades honestly
    /// (MIRRORKIT-PLAN decision 6).
    public var qmp: String?

    public init(host: String, port: Int, scope: String = "all",
                machine: String, qmp: String? = nil) {
        self.host = host
        self.port = port
        self.scope = scope
        self.machine = machine
        self.qmp = qmp
    }
}
