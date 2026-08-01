import Foundation

/// Where you are on the other machine, decomposed.
///
/// A file browser that shows only the current folder and a way out tells
/// you how to leave and not where you stand. That matters more here than
/// in a Finder window: these are folders on someone else's classic Mac,
/// and the person navigating them may never have seen the volume's shape.
/// So the bar names the whole path — disk first — and every place it
/// names that we are allowed to enter is a place one click reaches.
///
/// It is computed as data, away from any view, so the shape of a path can
/// be asserted without a screenshot.
///
/// **The root is a volume, not a slash.** An HFS path begins with the
/// name of the disk (`Macintosh HD:System Folder:Extensions`), and the
/// guest tells us the whole absolute path of what it publishes. The
/// components ABOVE the published folder are real places on that machine
/// but the share boundary (`contract/share_path.h`) will not let us list
/// them, so they are shown and not offered: context, not navigation.
/// Rendering a `/` there, or the word "Share", would answer neither
/// question.
enum FilePathBar {

    /// One element of the path, and whether it is somewhere we may go.
    struct Crumb: Identifiable, Equatable {
        enum Role: Equatable {
            /// Between the disk and the published folder: real, named,
            /// and outside what we are allowed to browse.
            case aboveShare
            /// The folder the other machine publishes. Browsing starts
            /// here, and this is as far up as anyone gets.
            case shareRoot
            /// Somewhere inside it.
            case folder
        }

        var name: String
        var role: Role
        /// True for the first component of the absolute path — the disk
        /// itself, which may also be the published folder when a whole
        /// volume is shared.
        var isVolume = false
        /// A stand-in shown before the guest has told us what it shares.
        /// Absence is a fact to render, so it gets a crumb of its own
        /// rather than an empty bar.
        var isPlaceholder = false
        /// Argument for `FilesModuleModel.jump(toDepth:)`: -1 is the
        /// share root, 0 the first folder inside it. `nil` means the
        /// crumb names a place the share boundary will not open.
        var depth: Int?
        /// Position in the whole path, so identity survives two sibling
        /// folders with the same name at different depths.
        var index: Int

        var id: String { "\(index)-\(name)" }
        var isNavigable: Bool { depth != nil }
    }

    /// What the bar draws: crumbs, and the gaps where crumbs were folded
    /// away. An elision keeps everything it hides — the bar shows fewer
    /// crumbs, it never forgets any.
    enum Item: Identifiable, Equatable {
        case crumb(Crumb)
        case elision([Crumb])

        var id: String {
            switch self {
            case .crumb(let crumb): return crumb.id
            case .elision(let hidden):
                return "elide-" + (hidden.first.map(\.id) ?? "empty")
            }
        }
    }

    /// What the bar says when it is not simply showing a loaded folder.
    /// Every one of these is a sentence rather than a blank bar.
    enum Status: Equatable {
        /// A folder is on screen and it is the one that was asked for.
        case ready
        /// No machine on the other end, so there is no path to be at.
        case noGuest
        /// Connected, first listing in flight.
        case loading
        /// Connected, nothing listed yet and nothing in flight.
        case unlisted
        /// The listing failed. The crumbs stay: they are where we tried
        /// to be, which is the thing you need in order to go elsewhere.
        case failed(String)
    }

    /// Above this many folder crumbs the middle of the path folds away.
    /// Three is what fits without argument and is deep enough that most
    /// real paths never elide at all.
    static let foldersShownInFull = 3
    /// How many of the deepest folders always stay visible: the one you
    /// are in, and the one that contains it.
    static let trailingFoldersKept = 2

    /// The whole path in the guest's own spelling — for a tooltip, or to
    /// hand to a person who wants to type it on that machine.
    static func fullPath(shareRoot: String?, breadcrumb: [String]) -> String {
        let root = (shareRoot ?? "").trimmingTrailingSeparator()
        let inside = breadcrumb.joined(separator: ":")
        if root.isEmpty { return inside }
        return inside.isEmpty ? root : root + ":" + inside
    }

    /// Every component of the path, deepest last, before any folding.
    static func crumbs(shareRoot: String?,
                       breadcrumb: [String]) -> [Crumb] {
        var out: [Crumb] = []
        let rootParts = FileChangeNames.components(shareRoot ?? "")

        if rootParts.isEmpty {
            /* The guest has not said what it shares. The bar still needs
               a root to hang the rest off, and it must not claim a name
               it was not given. */
            out.append(Crumb(name: "Shared Folder", role: .shareRoot,
                             isPlaceholder: true, depth: -1, index: 0))
        } else {
            for (i, part) in rootParts.enumerated() {
                let isRoot = i == rootParts.count - 1
                out.append(Crumb(name: part,
                                 role: isRoot ? .shareRoot : .aboveShare,
                                 // A single component means the whole
                                 // volume is the published folder, so
                                 // this crumb is both.
                                 isVolume: i == 0,
                                 depth: isRoot ? -1 : nil,
                                 index: i))
            }
        }
        for (i, name) in breadcrumb.enumerated() {
            out.append(Crumb(name: name, role: .folder, depth: i,
                             index: out.count))
        }
        return out
    }

    /// The crumbs, with the middle folded away when the path is deeper
    /// than the bar should grow.
    ///
    /// **Why fold by depth and never truncate a name.** HFS caps a name
    /// at 31 characters, so the width of one crumb is already bounded and
    /// small; depth is the only axis with no ceiling. Cutting a name
    /// short trades a bounded problem for an ambiguous one — "System
    /// Folder Extension…" and "System Folder Extensions (Disabled)" are
    /// different folders that differ late — while dropping a middle
    /// component costs nothing you cannot get back, because the fold is a
    /// menu that still lists and still jumps. What survives a fold is
    /// chosen for the two questions actually being asked: the disk and
    /// the published folder answer "whose machine, which share", the last
    /// two folders answer "where exactly". Everything between them is the
    /// part you scroll past in a Finder title bar anyway.
    ///
    /// The result is a bar with a hard maximum of six elements, each at
    /// most 31 characters — a width that fits, computed rather than hoped
    /// for.
    static func items(shareRoot: String?,
                      breadcrumb: [String]) -> [Item] {
        let all = crumbs(shareRoot: shareRoot, breadcrumb: breadcrumb)
        let above = all.filter { $0.role != .folder }
        let folders = all.filter { $0.role == .folder }
        var items: [Item] = []

        /* The disk and the published folder are the anchors; anything
           between them is unenterable context and folds first. */
        if above.count <= 2 {
            items += above.map(Item.crumb)
        } else {
            items.append(.crumb(above[0]))
            items.append(.elision(Array(above[1..<(above.count - 1)])))
            items.append(.crumb(above[above.count - 1]))
        }

        if folders.count <= foldersShownInFull {
            items += folders.map(Item.crumb)
        } else {
            let keep = folders.suffix(trailingFoldersKept)
            items.append(.elision(Array(folders.dropLast(
                trailingFoldersKept))))
            items += keep.map(Item.crumb)
        }
        return items
    }
}

private extension String {
    /// `"Macintosh HD:"` and `"Macintosh HD"` name the same place; only
    /// one of them reads well with something joined onto it.
    func trimmingTrailingSeparator() -> String {
        hasSuffix(":") ? String(dropLast()) : self
    }
}
