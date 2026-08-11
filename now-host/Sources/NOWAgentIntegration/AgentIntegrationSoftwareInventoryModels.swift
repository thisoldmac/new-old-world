import Foundation

/// #3 — what is installed on the machine, projected from `software.list` /
/// `software.listing`.
///
/// The sharpest gap in the inventory and the one the plan says to wire
/// first: an agent can launch an application it can already name and cannot
/// ask what is there. `launchSoftware` does not answer it — that operation
/// returns a launch RESULT, and the listing it composes over is consumed
/// internally and thrown away.

/// The listing's five domains, closed by the contract's own enum.
///
/// Enumerated here — unlike the census probe registry — because this one
/// really is closed in the message schema: a `software.list` naming
/// something else is a malformed request, not a probe an older peer has
/// not heard of.
public enum AgentIntegrationSoftwareDomain:
    String, Codable, Equatable, Sendable, CaseIterable {
    /// The startup volume's catalog swept for type `APPL` — the
    /// `catsearch`-measured sweep, stopped at one page.
    case apps
    case extensions
    case cdevs
    case startup
    case apple
}

/// One installed item.
public struct AgentIntegrationSoftwareItem:
    Codable, Equatable, Sendable {
    public let name: String
    /// Full HFS path — the launch key, and `reveal`'s target too. **Empty
    /// is a real answer**: the parent chain could not be named honestly, so
    /// the item is listed and is not launchable from here. An empty path is
    /// not a missing field to be filled in with a guess.
    public let path: String
    public let fileType: String?
    public let creator: String?
    /// Data + resource forks. `-1` when unreadable, as the guest reports
    /// it — kept rather than mapped to nil, because "we looked and could
    /// not read it" is not the same as "we did not look".
    public let sizeK: Int?
    /// In an Extensions Manager disabled folder. The guest calls this
    /// `off`; spelled out here because a boolean named `off` reads
    /// backwards at every use site.
    public let disabled: Bool?
    /// Joined against the guest's own process list.
    public let running: Bool?
    /// The `vers` short version string, when the guest read one. Absent
    /// means the file has no readable `vers` — a fork open per served
    /// entry is an explicitly bounded cost and never an inventory walk.
    public let version: String?

    public init(name: String,
                path: String,
                fileType: String? = nil,
                creator: String? = nil,
                sizeK: Int? = nil,
                disabled: Bool? = nil,
                running: Bool? = nil,
                version: String? = nil) {
        self.name = name
        self.path = path
        self.fileType = fileType
        self.creator = creator
        self.sizeK = sizeK
        self.disabled = disabled
        self.running = running
        self.version = version
    }
}

public struct AgentIntegrationSoftwareInventoryPage:
    Codable, Equatable, Sendable {
    public let domain: AgentIntegrationSoftwareDomain
    public let entries: [AgentIntegrationSoftwareItem]
    public let hasMore: Bool
    public let nextCursor: Int?
    /// The honest edges — the inventory truncated at the guest's cache, or
    /// a domain that is not served on this ISA. Rule 4: on 68K the ANSWER
    /// degrades and says so here; the message does not change.
    public let note: String?
    public let observedAt: Date

    public init(domain: AgentIntegrationSoftwareDomain,
                entries: [AgentIntegrationSoftwareItem],
                hasMore: Bool,
                nextCursor: Int?,
                note: String? = nil,
                observedAt: Date) {
        self.domain = domain
        self.entries = entries
        self.hasMore = hasMore
        self.nextCursor = nextCursor
        self.note = note
        self.observedAt = observedAt
    }
}

public typealias AgentIntegrationSoftwareInventoryResult =
    AgentIntegrationProjectedResult<AgentIntegrationSoftwareInventoryPage>
