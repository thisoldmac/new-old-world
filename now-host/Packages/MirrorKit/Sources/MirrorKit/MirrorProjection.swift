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
    /// Semantic structural generation. A later transport sequence carrying
    /// the same reduced state does not advance it.
    public var sceneGeneration: Int
    /// Render-bearing enrichment generation. Content and Finder contributions
    /// advance independently from the structural observation cadence.
    public var contentGeneration: Int
    public var scene: Scene

    public init(id: Int, session: MirrorGuestSession, sequence: Int,
                digest: String, baseComplete: Bool,
                sceneGeneration: Int = 1, contentGeneration: Int = 0,
                scene: Scene) {
        self.id = id
        self.session = session
        self.sequence = sequence
        self.digest = digest
        self.baseComplete = baseComplete
        self.sceneGeneration = sceneGeneration
        self.contentGeneration = contentGeneration
        self.scene = scene
    }
}
