import Foundation

/// The bounded, privacy-preserving facts from one successful MCP initialize.
/// Transport is supplied by the sink that owns the route; request payloads,
/// authorization headers, workspace grants, and tool arguments never enter
/// this value.
public struct MCPClientInitialization: Equatable, Sendable {
    public static let maximumIdentityScalars = 200

    public let clientName: String
    public let clientVersion: String
    public let sessionKey: String

    public init(clientName: String?, clientVersion: String?,
                sessionKey: String?) {
        self.clientName = Self.bounded(clientName)
        self.clientVersion = Self.bounded(clientVersion)
        self.sessionKey = Self.bounded(sessionKey)
    }

    private static func bounded(_ raw: String?) -> String {
        guard let raw else { return "" }
        let scalars = raw.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }
        return String(String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(maximumIdentityScalars))
    }
}

public protocol MCPClientLifecycleSink: Sendable {
    func recordInitialization(_ initialization: MCPClientInitialization)
        async
}
