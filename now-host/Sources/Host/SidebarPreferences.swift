import Foundation
import Combine

/// How the sidebar is arranged and how much of each row it shows.
///
/// The same three choices the guest's rail carries — order, density, and
/// whether it is folded down to icons — because the two halves are meant to
/// feel like the same product seen from either machine, and a person who
/// rearranges one and finds the other fixed has learned something untrue
/// about which is in charge.
///
/// The ordering rule below is the guest's `order_adopt` in Swift, and it is
/// deliberately the same rule: unknown ids are dropped, missing ones are
/// appended in registry order. That is what lets a module added LATER arrive
/// at the foot of an arrangement somebody already saved, instead of
/// invalidating it — and what makes a corrupt or truncated stored value cost
/// nothing.
@MainActor
final class SidebarPreferences: ObservableObject {
    /// One line per row instead of a title and a summary.
    @Published var compact: Bool {
        didSet { defaults.set(compact, forKey: Self.compactKey) }
    }

    /// Folded down to icons. Separate from `compact` rather than a third
    /// value of it, so unfolding gives back the density that was chosen.
    @Published var collapsed: Bool {
        didSet { defaults.set(collapsed, forKey: Self.collapsedKey) }
    }

    /// The person's arrangement of the LIST modules, by id. Footer modules
    /// are not in here: the foot of the sidebar is the state of this side,
    /// and it stays where it is put.
    @Published private(set) var order: [String] {
        didSet { defaults.set(order, forKey: Self.orderKey) }
    }

    private let defaults: UserDefaults
    private static let compactKey = "sidebarCompact"
    private static let collapsedKey = "sidebarCollapsed"
    private static let orderKey = "sidebarOrder"

    init(defaults: UserDefaults = ProductIdentity.defaults, registry: ModuleRegistry) {
        self.defaults = defaults
        compact = defaults.bool(forKey: Self.compactKey)
        collapsed = defaults.bool(forKey: Self.collapsedKey)
        order = Self.sanitised(defaults.stringArray(forKey: Self.orderKey) ?? [],
                               against: registry.listModules.map(\.id))
    }

    /// A stored order made whole against what exists today.
    ///
    /// Pure and static so it can be tested without a defaults suite — the
    /// part worth testing is this rule, not the plumbing around it.
    static func sanitised(_ stored: [String], against known: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        /* Through the rename table first, for the same reason the saved
           SELECTION goes through it: a renamed module is not a retired one,
           and dropping its old id here would silently move the page a person
           had dragged to the top down to the bottom of their sidebar. */
        for stored in stored {
            let id = known.contains(stored)
                ? stored
                : ModuleRegistry.renamedIDs[stored].flatMap {
                    known.contains($0) ? $0 : nil
                }
            guard let id, seen.insert(id).inserted else { continue }
            result.append(id)
        }
        // Anything the stored order has never heard of goes to the end, in
        // the registry's own order — a module added since it was saved.
        for id in known where !seen.contains(id) {
            result.append(id)
        }
        return result
    }

    /// The list modules in the person's order.
    ///
    /// Derived on read rather than stored as descriptors, so a registry
    /// change (a rename, a new module, a summary edit) reaches the sidebar
    /// without anything having to migrate the saved order.
    func ordered(_ modules: [ModuleDescriptor]) -> [ModuleDescriptor] {
        let byID = Dictionary(uniqueKeysWithValues: modules.map { ($0.id, $0) })
        let ids = Self.sanitised(order, against: modules.map(\.id))
        return ids.compactMap { byID[$0] }
    }

    /// Applies a drag. `IndexSet`/`toOffset` are the List's own vocabulary,
    /// so this takes them rather than making the view translate.
    func move(_ modules: [ModuleDescriptor], from source: IndexSet, to destination: Int) {
        var ids = ordered(modules).map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        order = ids
    }

    /// Back to the registry's own order — the escape hatch for a sidebar
    /// rearranged into confusion, and the only way back that does not
    /// require dragging every row.
    func resetOrder(_ modules: [ModuleDescriptor]) {
        order = modules.map(\.id)
    }
}
