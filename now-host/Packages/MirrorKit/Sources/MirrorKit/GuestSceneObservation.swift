import Foundation

/// One decoded scene with the transport identity needed to order and isolate
/// it. Guest wall-clock time remains presentation evidence; `scene.seq` is the
/// ordering authority within this session.
public struct GuestSceneObservation: Equatable, Sendable {
    public var session: MirrorGuestSession
    public var scene: Scene
    public var receivedAt: Date

    public init(session: MirrorGuestSession, scene: Scene, receivedAt: Date) {
        self.session = session
        self.scene = scene
        self.receivedAt = receivedAt
    }

    public func coverage(scope: String, owner: String? = nil)
        -> Scene.CoverageClaim? {
        scene.meta.coverage?.first {
            $0.scope == scope && $0.owner == owner
        }
    }
}
