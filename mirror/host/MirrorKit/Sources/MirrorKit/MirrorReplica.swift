import Foundation

public struct MirrorApplicationRecord: Equatable, Sendable {
    public var identity: MirrorProcessIdentity
    public var app: Scene.AppRef
    public var process: Scene.ProcessRef?
    public var freshness: MirrorFreshness
    public var actionable: Bool
    public var lastAuthoritativeSequence: Int
    var ordinal: Int
}

public struct MirrorWindowRecord: Equatable, Sendable {
    public var identity: MirrorWindowIdentity
    public var window: Scene.Window
    public var freshness: MirrorFreshness
    public var actionable: Bool
    public var lastAuthoritativeSequence: Int
    var ordinal: Int
}

public struct MirrorMenubarRecord: Equatable, Sendable {
    public var menubar: Scene.Menubar
    public var owner: MirrorProcessIdentity?
    public var freshness: MirrorFreshness
    public var actionable: Bool
    public var lastAuthoritativeSequence: Int
}

public enum MirrorTombstoneIdentity: Equatable, Sendable {
    case process(MirrorProcessIdentity)
    case window(MirrorWindowIdentity)
}

public struct MirrorTombstone: Equatable, Sendable {
    public var identity: MirrorTombstoneIdentity
    public var sequence: Int
}

public struct MirrorReplica: Equatable, Sendable {
    public var session: MirrorGuestSession
    public var lastSequence: Int
    public var applications: [MirrorProcessIdentity: MirrorApplicationRecord]
    public var windows: [MirrorWindowIdentity: MirrorWindowRecord]
    public var menubar: MirrorMenubarRecord?
    public var tombstones: [MirrorTombstone]
    public var snapshot: MirrorProjection

    init(session: MirrorGuestSession, lastSequence: Int,
         applications: [MirrorProcessIdentity: MirrorApplicationRecord],
         windows: [MirrorWindowIdentity: MirrorWindowRecord],
         menubar: MirrorMenubarRecord?, tombstones: [MirrorTombstone],
         snapshot: MirrorProjection) {
        self.session = session
        self.lastSequence = lastSequence
        self.applications = applications
        self.windows = windows
        self.menubar = menubar
        self.tombstones = tombstones
        self.snapshot = snapshot
    }
}

public enum MirrorObservationRejection: Error, Equatable, Sendable {
    case sessionMismatch
    case outOfOrder(last: Int, received: Int)
}

public enum MirrorReductionResult: Equatable, Sendable {
    case accepted(MirrorReplica)
    case rejected(MirrorObservationRejection)
}
