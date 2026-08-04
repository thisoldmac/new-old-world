import Foundation

/// One connected guest lifetime. The display name is not enough: reconnecting
/// the same machine creates a successor incarnation that must not inherit
/// capabilities, queued work, or deletion evidence.
public struct MirrorGuestSession: Codable, Equatable, Hashable, Sendable {
    public var guest: String
    public var incarnation: String

    public init(guest: String, incarnation: String) {
        self.guest = guest
        self.incarnation = incarnation
    }
}

public struct MirrorProcessIdentity: Codable, Equatable, Hashable, Sendable {
    public var session: MirrorGuestSession
    public var incarnation: String

    public init(session: MirrorGuestSession, incarnation: String) {
        self.session = session
        self.incarnation = incarnation
    }
}

public struct MirrorWindowIdentity: Codable, Equatable, Hashable, Sendable {
    public var process: MirrorProcessIdentity
    public var incarnation: String

    public init(process: MirrorProcessIdentity, incarnation: String) {
        self.process = process
        self.incarnation = incarnation
    }
}

public enum MirrorEntityIdentity: Codable, Equatable, Hashable, Sendable {
    case process(MirrorProcessIdentity)
    case window(MirrorWindowIdentity)
}
