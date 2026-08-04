import Foundation

public enum MirrorFreshness: String, Codable, Equatable, Sendable {
    case fresh
    case expectedStale
}

public struct MirrorProjection: Equatable, Sendable {
    public var id: Int
    public var session: MirrorGuestSession
    public var sequence: Int
    public var digest: String
    public var baseComplete: Bool
    public var scene: Scene

    public init(id: Int, session: MirrorGuestSession, sequence: Int,
                digest: String, baseComplete: Bool, scene: Scene) {
        self.id = id
        self.session = session
        self.sequence = sequence
        self.digest = digest
        self.baseComplete = baseComplete
        self.scene = scene
    }
}
