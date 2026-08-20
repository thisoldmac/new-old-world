import Foundation

/// Which side of the MCP page's split a card sits on.
enum MCPCardColumn: String, Codable, Sendable {
    case left
    case right
}

/// The MCP page's cards, by stable identity. The raw values are the
/// persistence contract; renaming one orphans every saved layout that
/// mentions it.
enum MCPCardID: String, Codable, CaseIterable, Sendable {
    case transportHTTP = "transport.http"
    case presence
    case heldLane = "held-lane"
    case consent
    case activity

    /// Where a card the saved layout has never seen belongs. History reads
    /// on the right; everything a person operates sits on the left.
    var defaultColumn: MCPCardColumn {
        self == .activity ? .right : .left
    }

    /// Only transport cards carry a session log tail.
    var hasLogTail: Bool {
        self == .transportHTTP
    }
}

/// The persisted arrangement of the MCP page: column membership and order,
/// which cards are collapsed, and which transport log tails are open.
///
/// Columns hold raw strings rather than `MCPCardID` so a layout written by a
/// newer build with a card this one has never heard of still decodes; the
/// unknown id is dropped by `sanitised` instead of failing the whole blob.
struct MCPCardLayout: Codable, Equatable {
    static let currentVersion = 3

    var version: Int
    var left: [String]
    var right: [String]
    var collapsed: [String]
    var openLogTails: [String]

    /// Every card open, tails shut, activity alone on the right.
    static var standard: MCPCardLayout {
        MCPCardLayout(
            version: currentVersion,
            left: MCPCardID.allCases
                .filter { $0.defaultColumn == .left }
                .map(\.rawValue),
            right: MCPCardID.allCases
                .filter { $0.defaultColumn == .right }
                .map(\.rawValue),
            collapsed: [],
            openLogTails: [])
    }

    /// The version advances when a card leaves the product. `sanitised`
    /// removes that retired raw id while preserving every surviving card's
    /// relative order and state.
    func migratedToCurrent() -> MCPCardLayout {
        var migrated = self
        migrated.version = Self.currentVersion
        return migrated
    }

    /// A layout every card of this build appears in exactly once, with
    /// nothing this build does not know. First occurrence wins on
    /// duplicates, left scanned before right; a known card the blob never
    /// mentioned joins the end of its default column.
    func sanitised(known: [MCPCardID] = MCPCardID.allCases) -> MCPCardLayout {
        let knownRaw = Set(known.map(\.rawValue))
        var seen = Set<String>()
        var left = self.left.filter {
            knownRaw.contains($0) && seen.insert($0).inserted
        }
        var right = self.right.filter {
            knownRaw.contains($0) && seen.insert($0).inserted
        }
        for id in known where !seen.contains(id.rawValue) {
            switch id.defaultColumn {
            case .left: left.append(id.rawValue)
            case .right: right.append(id.rawValue)
            }
        }
        let tailRaw = Set(known.filter(\.hasLogTail).map(\.rawValue))
        return MCPCardLayout(
            version: Self.currentVersion,
            left: left,
            right: right,
            collapsed: collapsed.filter(knownRaw.contains).sorted(),
            openLogTails: openLogTails.filter(tailRaw.contains).sorted())
    }

    func cards(in column: MCPCardColumn) -> [MCPCardID] {
        (column == .left ? left : right).compactMap(MCPCardID.init(rawValue:))
    }

    func isCollapsed(_ id: MCPCardID) -> Bool {
        collapsed.contains(id.rawValue)
    }

    func isLogTailOpen(_ id: MCPCardID) -> Bool {
        openLogTails.contains(id.rawValue)
    }
}
