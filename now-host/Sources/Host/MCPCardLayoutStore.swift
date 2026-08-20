import Combine
import Foundation

/// Persistence for the MCP page's card arrangement — a structural copy of
/// `NavigationLayoutStore`, which learned the rules: never overwrite a blob
/// a newer build wrote, sanitise on every read and write, and write only
/// when the bytes changed.
@MainActor
struct MCPCardLayoutStore {
    static let layoutKey = "mcpCardLayout"

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = ProductIdentity.defaults) {
        self.defaults = defaults
        encoder.outputFormatting = [.sortedKeys]
    }

    func load() -> MCPCardLayout {
        if let data = defaults.data(forKey: Self.layoutKey),
           let stored = try? decoder.decode(MCPCardLayout.self, from: data) {
            guard stored.version <= MCPCardLayout.currentVersion else {
                /* A newer app owns this payload. Use a safe layout without
                   destroying state this build does not understand. */
                return .standard
            }
            let loaded = stored.migratedToCurrent().sanitised()
            persist(loaded, replacing: data)
            return loaded
        }
        let loaded = MCPCardLayout.standard
        persist(loaded)
        return loaded
    }

    @discardableResult
    func save(_ layout: MCPCardLayout) -> MCPCardLayout {
        let repaired = layout.sanitised()
        if let data = defaults.data(forKey: Self.layoutKey),
           let stored = try? decoder.decode(MCPCardLayout.self, from: data),
           stored.version > MCPCardLayout.currentVersion {
            return repaired
        }
        persist(repaired)
        return repaired
    }

    private func persist(_ canonical: MCPCardLayout,
                         replacing existing: Data? = nil) {
        guard let data = try? encoder.encode(canonical),
              data != (existing ?? defaults.data(forKey: Self.layoutKey))
        else { return }
        defaults.set(data, forKey: Self.layoutKey)
    }
}

/// The MCP page's live arrangement: every mutation is an intent that also
/// persists, so the view has no second copy of the truth to drift from.
@MainActor
final class MCPCardLayoutModel: ObservableObject {
    @Published private(set) var layout: MCPCardLayout

    private let store: MCPCardLayoutStore

    init(defaults: UserDefaults = ProductIdentity.defaults) {
        let store = MCPCardLayoutStore(defaults: defaults)
        self.store = store
        layout = store.load()
    }

    func toggleCollapsed(_ id: MCPCardID) {
        var next = layout
        if let index = next.collapsed.firstIndex(of: id.rawValue) {
            next.collapsed.remove(at: index)
        } else {
            next.collapsed.append(id.rawValue)
        }
        apply(next)
    }

    func toggleLogTail(_ id: MCPCardID) {
        guard id.hasLogTail else { return }
        var next = layout
        if let index = next.openLogTails.firstIndex(of: id.rawValue) {
            next.openLogTails.remove(at: index)
        } else {
            next.openLogTails.append(id.rawValue)
        }
        apply(next)
    }

    /// Place `id` in `column` immediately before `target`; with no target it
    /// joins the end of that column. Moving a card before itself is a no-op.
    func move(_ id: MCPCardID, to column: MCPCardColumn,
              before target: MCPCardID? = nil) {
        guard id != target else { return }
        var next = layout
        next.left.removeAll { $0 == id.rawValue }
        next.right.removeAll { $0 == id.rawValue }
        var destination = column == .left ? next.left : next.right
        if let target,
           let index = destination.firstIndex(of: target.rawValue) {
            destination.insert(id.rawValue, at: index)
        } else {
            destination.append(id.rawValue)
        }
        if column == .left {
            next.left = destination
        } else {
            next.right = destination
        }
        apply(next)
    }

    /// Keyboard/VoiceOver reordering: one step within the card's column.
    func nudge(_ id: MCPCardID, forward: Bool) {
        let column: MCPCardColumn =
            layout.left.contains(id.rawValue) ? .left : .right
        let cards = layout.cards(in: column)
        guard let index = cards.firstIndex(of: id) else { return }
        let destination = forward ? index + 1 : index - 1
        guard cards.indices.contains(destination) else { return }
        move(id, to: column,
             before: forward
                ? (cards.indices.contains(destination + 1)
                    ? cards[destination + 1] : nil)
                : cards[destination])
    }

    func column(of id: MCPCardID) -> MCPCardColumn {
        layout.left.contains(id.rawValue) ? .left : .right
    }

    private func apply(_ next: MCPCardLayout) {
        let saved = store.save(next)
        guard saved != layout else { return }
        layout = saved
    }
}
