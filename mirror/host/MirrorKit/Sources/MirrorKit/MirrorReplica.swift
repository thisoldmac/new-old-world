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
    /// The Finder's desktop roster, retained across structural scenes.
    ///
    /// It needs a home of its own because it is the one plane NO producer
    /// reports: the guests' walks read the Toolbox, and a desktop icon is
    /// not a window, a control or a menu — it is a file the Finder draws.
    /// So it arrives only as an enrichment, and every structural scene
    /// omits the key honestly. Without this the projection was rebuilt
    /// from that scene each poll and the roster lived about a second;
    /// `desktopItems` read nil on every drive for a week while folder
    /// windows, retained per window record, kept their items.
    ///
    /// Nil means nobody has read it. An empty array is a claim that the
    /// desktop is empty, and it is kept as one.
    public var desktopItems: [Scene.DesktopItem]?
    public var tombstones: [MirrorTombstone]
    public var snapshot: MirrorProjection

    init(session: MirrorGuestSession, lastSequence: Int,
         applications: [MirrorProcessIdentity: MirrorApplicationRecord],
         windows: [MirrorWindowIdentity: MirrorWindowRecord],
         menubar: MirrorMenubarRecord?,
         desktopItems: [Scene.DesktopItem]? = nil,
         tombstones: [MirrorTombstone],
         snapshot: MirrorProjection) {
        self.session = session
        self.lastSequence = lastSequence
        self.applications = applications
        self.windows = windows
        self.menubar = menubar
        self.desktopItems = desktopItems
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
