import Foundation

public enum MirrorFreshness: String, Codable, Equatable, Sendable {
    case fresh
    case expectedStale
}

public enum MirrorPublicationReason: String, Codable, Equatable, Sendable {
    case structure
    case semantics
    case finder
    case visibility
    case content
    case policy
    case coverage
}

/// The exact reducer generations represented by one immutable projection.
/// A consumer can distinguish progressive enrichment from a new structural
/// world without inferring that relationship from publication order.
public struct MirrorGenerationSet: Codable, Equatable, Sendable {
    public var structure: Int
    public var semantics: Int
    public var finder: Int
    public var visibility: Int
    public var content: Int

    public init(structure: Int = 0, semantics: Int = 0, finder: Int = 0,
                visibility: Int = 0, content: Int = 0) {
        self.structure = structure
        self.semantics = semantics
        self.finder = finder
        self.visibility = visibility
        self.content = content
    }
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
    public var generations: MirrorGenerationSet
    public var publicationReason: MirrorPublicationReason
    public var scene: Scene

    public init(id: Int, session: MirrorGuestSession, sequence: Int,
                digest: String, baseComplete: Bool,
                sceneGeneration: Int = 1, contentGeneration: Int = 0,
                generations: MirrorGenerationSet? = nil,
                publicationReason: MirrorPublicationReason = .structure,
                scene: Scene) {
        self.id = id
        self.session = session
        self.sequence = sequence
        self.digest = digest
        self.baseComplete = baseComplete
        self.sceneGeneration = sceneGeneration
        self.contentGeneration = contentGeneration
        self.generations = generations ?? .init(
            structure: sceneGeneration, content: contentGeneration)
        self.publicationReason = publicationReason
        self.scene = scene
    }
}
