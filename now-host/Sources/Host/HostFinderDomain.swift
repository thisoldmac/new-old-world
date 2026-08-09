import Foundation
import MirrorKit

/// Pure host-side Finder state. Nothing here asks the guest Finder how it
/// arranged a window; that is the ownership boundary this mode exists to
/// prove before guest-following state is joined back in.
enum HostFinderDomain {
    static let windowPrefix = FinderItems.hostWindowPrefix
    static let controlPrefix = "host-finder-control:"

    enum Sort: String, CaseIterable, Identifiable, Sendable {
        case name, modified, size, kind
        var id: String { rawValue }

        var label: String {
            switch self {
            case .name: return "Name"
            case .modified: return "Date Modified"
            case .size: return "Size"
            case .kind: return "Kind"
            }
        }
    }

    struct Window: Identifiable, Equatable, Sendable {
        var id: String
        var path: String
        var rootLabel: String?
        var frame: Rect
        var view: Scene.FinderPresentation.View = .icon
        var sort: Sort = .name
        var ascending = true
        var entries: [FileEntry] = []
        var selectedNames: Set<String> = []
        /// Manual icon positions are a host-Finder concern. They are ignored
        /// by ordered list views and retained when switching back to icons.
        var iconPositions: [String: Point] = [:]
        var verticalScroll = 0
        var pages = 0
        var complete = false
        var loading = false
        var error: String?

        var title: String {
            if path.isEmpty {
                let root = rootLabel?.trimmingCharacters(in:
                    CharacterSet(charactersIn: ":"))
                return root?.isEmpty == false ? root! : "Guest Disk"
            }
            return path.components(separatedBy: ":").last ?? path
        }

        func entry(named name: String) -> FileEntry? {
            entries.first { $0.name == name }
        }
    }

    static func sortedEntries(of window: Window) -> [FileEntry] {
        let ascending = window.entries.sorted { a, b in
            switch window.sort {
            case .name:
                return compare(a.name, b.name)
            case .modified:
                return (a.modified ?? 0) == (b.modified ?? 0)
                    ? compare(a.name, b.name)
                    : (a.modified ?? 0) < (b.modified ?? 0)
            case .size:
                let asz = (a.dataBytes ?? 0) + (a.rsrcBytes ?? 0)
                let bsz = (b.dataBytes ?? 0) + (b.rsrcBytes ?? 0)
                return asz == bsz ? compare(a.name, b.name) : asz < bsz
            case .kind:
                let ak = kindLabel(a), bk = kindLabel(b)
                return ak == bk ? compare(a.name, b.name) : compare(ak, bk)
            }
        }
        return window.ascending ? ascending : Array(ascending.reversed())
    }

    static func projectedWindow(_ window: Window, z: Int) -> Scene.Window {
        let width = max(180, window.frame.r - window.frame.l)
        let contentHeight = max(100, window.frame.b - window.frame.t
                                - SceneBuilder.titleBarHeight)
        let infoTop = 20
        let headerHeight = window.view == .name ? 20 : 0
        let fieldTop = infoTop + headerHeight
        let fieldBottom = max(fieldTop + 1, contentHeight - 16)
        let fieldRight = max(1, width - 16)
        let visibleHeight = max(1, fieldBottom - fieldTop)
        let entries = sortedEntries(of: window)
        let contentHeightNeeded = layoutHeight(entries.count, view: window.view,
                                               width: fieldRight,
                                               fieldTop: fieldTop)
        let maxScroll = max(0, contentHeightNeeded - visibleHeight)
        let scroll = min(max(0, window.verticalScroll), maxScroll)

        var controls = [Scene.Control(
            ref: controlPrefix + window.id + ":vscroll",
            role: maxScroll > 0 ? "scrollbar" : "control", title: "",
            rect: Rect(l: fieldRight, t: infoTop, r: width,
                       b: fieldBottom),
            enabled: maxScroll > 0, visible: true, value: scroll,
            min: 0, max: maxScroll)]
        controls.append(Scene.Control(
            ref: controlPrefix + window.id + ":hscroll",
            role: "control", title: "",
            rect: Rect(l: 0, t: fieldBottom, r: fieldRight,
                       b: contentHeight), enabled: false, visible: true,
            value: 0, min: 0, max: 0))
        if window.view == .name {
            controls.append(contentsOf: columnControls(window, width: fieldRight,
                                                       top: infoTop))
        }

        return Scene.Window(
            id: window.id, app: "Finder", psn: "host.finder",
            title: window.title, kind: 20, rect: window.frame,
            front: z == 0, z: z, visible: true, controls: controls,
            controlsState: "complete", ref: window.id,
            closeBox: true, zoomBox: true,
            items: layout(entries, window: window, width: fieldRight,
                          top: fieldTop, scroll: scroll),
            finder: .init(path: window.path, view: window.view,
                          selectedNames: window.selectedNames,
                          pages: max(1, window.pages),
                          complete: window.complete),
            display: nil)
    }

    static func finderMenubar(from base: Scene.Menubar?) -> Scene.Menubar {
        let apple = base?.menus.first(where: \.apple)
            ?? .init(title: "", apple: true, left: 0, id: 1, items: [])
        let viewItems = [
            Scene.MenuItem(title: "as Icons", index: 1),
            .init(title: "as Buttons", index: 2),
            .init(title: "as List", index: 3),
            .init(title: "", index: 4, separator: true, enabled: false),
            .init(title: "By Name", index: 5),
            .init(title: "By Date Modified", index: 6),
            .init(title: "By Size", index: 7),
            .init(title: "By Kind", index: 8),
        ]
        let app = base?.menus.first(where: { $0.id == -16489 })
            ?? .init(title: "", apple: false, left: 0, id: -16489, items: [])
        return .init(app: "Finder", menus: [
            apple,
            .init(title: "File", apple: false, left: 31, id: -30001,
                  items: [.init(title: "Close", index: 1, enabled: false,
                                cmd: "W")]),
            .init(title: "Edit", apple: false, left: 66, id: -30002,
                  items: []),
            .init(title: "View", apple: false, left: 101, id: -30003,
                  items: viewItems),
            .init(title: "Special", apple: false, left: 143, id: -30004,
                  items: []),
            app,
        ])
    }

    static func joined(_ base: String, _ leaf: String) -> String {
        base.isEmpty ? leaf : base + ":" + leaf
    }

    static func fullPath(root: String?, relative: String) -> String? {
        guard var root, !root.isEmpty else { return nil }
        if !root.hasSuffix(":") { root += ":" }
        return relative.isEmpty ? String(root.dropLast()) : root + relative
    }

    static func windowID(_ serial: Int) -> String {
        windowPrefix + String(serial)
    }

    static func isWindowID(_ id: String) -> Bool {
        id.hasPrefix(windowPrefix)
    }

    static func control(_ ref: String) -> (windowID: String, action: String)? {
        guard ref.hasPrefix(controlPrefix) else { return nil }
        let body = String(ref.dropFirst(controlPrefix.count))
        guard let split = body.lastIndex(of: ":") else { return nil }
        return (String(body[..<split]), String(body[body.index(after: split)...]))
    }

    private static func compare(_ a: String, _ b: String) -> Bool {
        a.localizedCaseInsensitiveCompare(b) == .orderedAscending
    }

    private static func kindLabel(_ entry: FileEntry) -> String {
        if entry.isFolder { return "Folder" }
        return entry.fileType ?? "Document"
    }

    private static func layoutHeight(_ count: Int,
                                     view: Scene.FinderPresentation.View,
                                     width: Int, fieldTop: Int) -> Int {
        switch view {
        case .name:
            return fieldTop + count * 19 + 4
        case .smallIcon:
            let columns = max(1, width / 170)
            return fieldTop + ((count + columns - 1) / columns) * 22 + 8
        case .icon, .unknown:
            let columns = max(1, width / 96)
            return fieldTop + ((count + columns - 1) / columns) * 72 + 10
        }
    }

    private static func layout(
        _ entries: [FileEntry], window: Window,
        width: Int, top: Int, scroll: Int
    ) -> [Scene.DesktopItem] {
        let view = window.view
        let columns: Int
        switch view {
        case .smallIcon: columns = max(1, width / 170)
        case .icon, .unknown: columns = max(1, width / 96)
        case .name: columns = 1
        }
        return entries.enumerated().map { index, entry in
            let x: Int, y: Int, side: Int
            switch view {
            case .name:
                x = 4; y = top + index * 19 - scroll; side = 16
            case .smallIcon:
                x = 6 + (index % columns) * 170
                y = top + 3 + (index / columns) * 22 - scroll
                side = 16
            case .icon, .unknown:
                let defaultPoint = Point(x: 28 + (index % columns) * 96,
                                         y: top + 10
                                            + (index / columns) * 72)
                let point = window.iconPositions[entry.name] ?? defaultPoint
                x = point.x
                y = point.y - scroll
                side = 32
            }
            return .init(name: entry.name,
                         kind: entry.isFolder ? "folder"
                             : entry.fileType == "APPL" ? "application"
                             : "file",
                         type: entry.fileType, creator: entry.creator,
                         x: x, y: y, placed: true, alias: false,
                         invisible: false, w: side, h: side,
                         origin: .drawn)
        }
    }

    private static func columnControls(_ window: Window, width: Int, top: Int)
        -> [Scene.Control] {
        let widths = [max(90, width * 45 / 100), max(72, width * 25 / 100),
                      max(48, width * 12 / 100)]
        let columns: [(Sort, Int)] = [(.name, widths[0]),
                                      (.modified, widths[1]),
                                      (.size, widths[2]),
                                      (.kind, max(48, width - widths.reduce(0,+)))]
        var left = 0
        return columns.map { sort, columnWidth in
            defer { left += columnWidth }
            return Scene.Control(
                ref: controlPrefix + window.id + ":sort-" + sort.rawValue,
                role: "control", title: sort.label,
                rect: Rect(l: left, t: top, r: min(width, left + columnWidth),
                           b: top + 20), enabled: true, visible: true,
                semantic: .init(knowledge: .known, kind: "pushButton",
                                action: "press", provenance: "host-finder",
                                completeness: .complete))
        }
    }
}
