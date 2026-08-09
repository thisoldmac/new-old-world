import Foundation

/// The production endpoint every Mirror client binds to. It names only the
/// guest wire and machine identity; development-oracle transports belong to
/// their adapter package and must not leak into this descriptor.
public struct MirrorTarget: Codable, Equatable, Sendable {
    /// Wire host (the worker's forwarded port lives here).
    public var host: String
    /// Worker wire port.
    public var port: Int
    /// axtree scope to poll ("all" or "front").
    public var scope: String
    /// Machine id, for window titling and capability lookup (e.g. "mac99").
    public var machine: String
    public init(host: String, port: Int, scope: String = "all",
                machine: String) {
        self.host = host
        self.port = port
        self.scope = scope
        self.machine = machine
    }
}
