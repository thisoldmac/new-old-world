import Foundation
import MirrorKit

/// An independent Finder presentation over the guest file contract.
///
/// Folder-window lifecycle, geometry, ordering, selection and scrolling all
/// stop at this object. The guest Finder is never asked to open or select a
/// folder while this mode is enabled; only actual file operations cross the
/// wire.
@MainActor
final class HostFinderSession {
    static let preferenceKey = "mirror.emulateFinderWindows"

    private let listener: GuestListener
    private let defaults: UserDefaults
    private(set) var windows: [HostFinderDomain.Window] = []
    private(set) var status = "Host Finder is off"
    var onChange: () -> Void = {}

    private var serial = 0
    private var seeded = false
    private var screen: Scene.ScreenSize?
    private var generation = 0
    private var dragSubject: DragTargeting.Subject?
    private(set) var active = true
    private var fileWatch: HostEventSubscription?

    var currentDragContainer: DragTargeting.Container? {
        dragSubject?.container
    }

    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: Self.preferenceKey)
            generation &+= 1
            windows.removeAll()
            seeded = false
            active = enabled
            status = enabled ? "Opening the guest disk…" : "Host Finder is off"
            if enabled { seedIfNeeded() }
            onChange()
        }
    }

    init(listener: GuestListener, defaults: UserDefaults = UserDefaults(
        suiteName: ProductIdentity.preferencesSuite) ?? .standard) {
        self.listener = listener
        self.defaults = defaults
        enabled = defaults.bool(forKey: Self.preferenceKey)
        fileWatch = listener.events.subscribe { [weak self] event in
            guard let self, self.enabled else { return }
            if case .fileTreeChanged(_, let side, _) = event, side == .guest {
                self.refresh()
            }
        }
    }

    func observe(screen: Scene.ScreenSize) {
        self.screen = screen
        seedIfNeeded()
    }

    func resetForGuestChange() {
        generation &+= 1
        windows.removeAll()
        seeded = false
        status = enabled ? "Opening the guest disk…" : "Host Finder is off"
        seedIfNeeded()
        onChange()
    }

    func refresh() {
        guard enabled else { return }
        generation &+= 1
        let ids = windows.map(\.id)
        for id in ids { load(windowID: id, replacing: true) }
        if ids.isEmpty {
            seeded = false
            seedIfNeeded()
        }
    }

    func project(_ base: Scene) -> Scene {
        guard enabled else { return base }
        var result = base
        result.windows.removeAll {
            FinderItems.isFolderWindow($0)
                && !FinderItems.isHostOwnedWindow($0)
        }
        if !windows.isEmpty, active {
            for index in result.windows.indices { result.windows[index].front = false }
            let projected = windows.enumerated().map {
                HostFinderDomain.projectedWindow($0.element, z: $0.offset)
            }
            result.windows = projected + result.windows.enumerated().map {
                var window = $0.element
                window.z = windows.count + $0.offset
                return window
            }
            for index in result.apps.indices {
                result.apps[index].front = result.apps[index].name == "Finder"
            }
            if var processes = result.processes {
                for index in processes.indices {
                    processes[index].front = processes[index].name == "Finder"
                }
                result.processes = processes
            }
            result.menubar = HostFinderDomain.finderMenubar(
                from: base.menubar, window: windows.first)
        } else if !windows.isEmpty {
            let offset = result.windows.count
            let projected = windows.enumerated().map { pair -> Scene.Window in
                var window = HostFinderDomain.projectedWindow(
                    pair.element, z: offset + pair.offset)
                window.front = false
                return window
            }
            result.windows.append(contentsOf: projected)
        }
        return result
    }

    func select(_ names: [String], in id: String) {
        mutate(id) { window in
            let available = Set(window.entries.map(\.name))
            window.selectedNames = Set(names).intersection(available)
        }
        status = names.isEmpty ? "Selection cleared" : "Selected \(names.count) item(s)"
    }

    func setView(_ view: Scene.FinderPresentation.View, in id: String) {
        mutate(id) { window in
            window.view = view
            window.verticalScroll = 0
        }
        status = "Changed Finder view"
    }

    func sort(_ sort: HostFinderDomain.Sort, in id: String) {
        mutate(id) { window in
            if window.sort == sort { window.ascending.toggle() }
            else { window.sort = sort; window.ascending = true }
            window.verticalScroll = 0
        }
        status = "Sorted by \(sort.label)"
    }

    func scroll(windowID: String, part: Scrollbar.Part) {
        mutate(windowID) { window in
            let step: Int
            switch part {
            case .lineUp: step = -19
            case .lineDown: step = 19
            case .pageUp: step = -180
            case .pageDown: step = 180
            default: return
            }
            window.verticalScroll = max(0, window.verticalScroll + step)
        }
    }

    func setScroll(windowID: String, value: Int) {
        mutate(windowID) { $0.verticalScroll = max(0, value) }
    }

    func windowAct(id: String, act: MirrorAction.WindowAct) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        switch act {
        case .select:
            active = true
            bringFront(index)
        case .close:
            windows.remove(at: index)
            status = "Closed Finder window"
            onChange()
        case .zoom:
            guard let screen else { return }
            windows[index].frame = defaultFrame(in: screen, offset: 0,
                                                expanded: true)
            onChange()
        case .move(let left, let top):
            active = true
            let width = windows[index].frame.r - windows[index].frame.l
            let height = windows[index].frame.b - windows[index].frame.t
            windows[index].frame = Rect(l: left, t: top - SceneBuilder.titleBarHeight,
                                        r: left + width,
                                        b: top - SceneBuilder.titleBarHeight + height)
            bringFront(index)
        case .resize(let width, let height):
            active = true
            windows[index].frame.r = windows[index].frame.l + max(180, width)
            windows[index].frame.b = windows[index].frame.t
                + SceneBuilder.titleBarHeight + max(100, height)
            bringFront(index)
        }
    }

    func open(_ names: [String], in id: String) {
        active = true
        guard let window = windows.first(where: { $0.id == id }) else { return }
        for name in names {
            guard let entry = window.entry(named: name) else { continue }
            let path = HostFinderDomain.joined(window.path, name)
            if entry.isFolder {
                openFolder(path)
            } else if entry.fileType == "APPL" || entry.fileType == "appe"
                        || entry.fileType == "cdev" {
                launch(path: path, root: window.rootLabel)
            } else {
                openDocument(path: path, root: window.rootLabel)
            }
        }
    }

    func rename(_ name: String, to newName: String, in id: String) {
        guard let window = windows.first(where: { $0.id == id }),
              !newName.isEmpty, newName != name else { return }
        let oldPath = HostFinderDomain.joined(window.path, name)
        let newPath = HostFinderDomain.joined(window.path, newName)
        listener.moveFile(from: oldPath, to: newPath) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.status = "Renamed \(name) to \(newName)"
                self.load(windowID: id, replacing: true)
            case .failure(let failure):
                self.status = "Rename failed: \(failure.message)"
                self.onChange()
            }
        }
    }

    func beginDrag(_ subject: DragTargeting.Subject) -> Bool {
        guard case .window(let id) = subject.container,
              HostFinderDomain.isWindowID(id),
              windows.contains(where: { $0.id == id }) else { return false }
        dragSubject = subject
        active = true
        return true
    }

    func activate() {
        guard enabled else { return }
        active = true
        onChange()
    }

    func deactivate() {
        guard enabled, active else { return }
        active = false
        onChange()
    }

    func finishDrag(_ plan: DragTargeting.Plan?) {
        defer { dragSubject = nil }
        guard let plan, dragSubject == plan.subject else { return }
        guard case .window(let sourceID) = plan.subject.container,
              let source = windows.first(where: { $0.id == sourceID }) else { return }
        switch (plan.intent, plan.destination) {
        case (.rearrange, _):
            let originX = source.frame.l
            let originY = source.frame.t + SceneBuilder.titleBarHeight
            mutate(sourceID) {
                $0.iconPositions[plan.subject.name] = Point(
                    x: max(0, plan.dropFrame.l - originX),
                    y: max(20, plan.dropFrame.t - originY))
            }
            status = "Rearranged \(plan.subject.name)"
        case (_, .finderWindow(let destinationID, _, _, _)):
            move(plan.subject.name, from: sourceID, to: destinationID)
        case (_, .container(let folder, let kind, _, _)) where kind == "folder"
                || kind == "disk":
            guard let destination = source.entry(named: folder), destination.isFolder
            else { status = "\(folder) is not a folder"; onChange(); return }
            movePath(HostFinderDomain.joined(source.path, plan.subject.name),
                     to: HostFinderDomain.joined(
                        HostFinderDomain.joined(source.path, folder),
                        plan.subject.name), refreshing: [sourceID])
        default:
            status = "That host-owned Finder drop is not supported yet"
            onChange()
        }
    }

    private func seedIfNeeded() {
        guard enabled, !seeded, let screen else { return }
        seeded = true
        serial &+= 1
        windows = [.init(id: HostFinderDomain.windowID(serial), path: "",
                         frame: defaultFrame(in: screen, offset: 0))]
        load(windowID: windows[0].id, replacing: true)
        onChange()
    }

    private func openFolder(_ path: String) {
        if let index = windows.firstIndex(where: { $0.path == path }) {
            bringFront(index)
            return
        }
        guard let screen else { return }
        serial &+= 1
        let id = HostFinderDomain.windowID(serial)
        windows.insert(.init(id: id, path: path,
                             frame: defaultFrame(in: screen,
                                                 offset: windows.count)), at: 0)
        active = true
        status = "Opening \(path.components(separatedBy: ":").last ?? path)…"
        load(windowID: id, replacing: true)
        onChange()
    }

    private func load(windowID: String, replacing: Bool) {
        guard let index = windows.firstIndex(where: { $0.id == windowID }) else { return }
        let path = windows[index].path
        let requestGeneration = generation
        windows[index].loading = true
        windows[index].error = nil
        if replacing {
            windows[index].entries = []
            windows[index].pages = 0
            windows[index].complete = false
        }
        onChange()
        loadPage(windowID: windowID, path: path, cursor: nil,
                 generation: requestGeneration)
    }

    private func loadPage(windowID: String, path: String, cursor: Int?,
                          generation requestGeneration: Int) {
        listener.listFiles(path: path, cursor: cursor) { [weak self] result in
            guard let self, requestGeneration == self.generation,
                  let index = self.windows.firstIndex(where: { $0.id == windowID })
            else { return }
            switch result {
            case .failure(let failure):
                self.windows[index].loading = false
                self.windows[index].error = failure.message
                self.status = "Finder could not read \(self.windows[index].title): \(failure.message)"
                self.onChange()
            case .success(let listing):
                self.windows[index].rootLabel = listing.root
                self.windows[index].entries.append(contentsOf: listing.entries)
                self.windows[index].pages += 1
                let next = listing.cursor
                if listing.more, let next,
                   next != cursor, self.windows[index].pages < 256 {
                    self.onChange()
                    self.loadPage(windowID: windowID, path: path, cursor: next,
                                  generation: requestGeneration)
                } else {
                    self.windows[index].loading = false
                    self.windows[index].complete = !listing.more
                    self.status = "\(self.windows[index].entries.count) item(s) in \(self.windows[index].title)"
                    self.onChange()
                }
            }
        }
    }

    private func launch(path: String, root: String?) {
        guard let full = HostFinderDomain.fullPath(root: root, relative: path)
        else { status = "The guest did not name the shared volume"; onChange(); return }
        listener.runCommand("launch", args: ["path": full]) { [weak self] result in
            guard let self else { return }
            self.status = result.ok ? "Opened \(path)" : "Open failed: \(result.error?.message ?? "unknown error")"
            self.onChange()
        }
    }

    private func openDocument(path: String, root: String?) {
        guard let full = HostFinderDomain.fullPath(root: root, relative: path)
        else { status = "The guest did not name the shared volume"; onChange(); return }
        let escaped = full.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        listener.runCommand("script", args: [
            "source": "tell application \"Finder\" to open item \"\(escaped)\""
        ]) { [weak self] result in
            guard let self else { return }
            self.status = result.ok ? "Opened \(path)" : "Open failed: \(result.error?.message ?? "unknown error")"
            self.onChange()
        }
    }

    private func move(_ name: String, from sourceID: String, to destinationID: String) {
        guard let source = windows.first(where: { $0.id == sourceID }),
              let destination = windows.first(where: { $0.id == destinationID }) else { return }
        movePath(HostFinderDomain.joined(source.path, name),
                 to: HostFinderDomain.joined(destination.path, name),
                 refreshing: [sourceID, destinationID])
    }

    private func movePath(_ source: String, to destination: String,
                          refreshing ids: [String]) {
        listener.moveFile(from: source, to: destination) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.status = "Moved \(source.components(separatedBy: ":").last ?? source)"
                for id in Set(ids) { self.load(windowID: id, replacing: true) }
            case .failure(let failure):
                self.status = "Move failed: \(failure.message)"
                self.onChange()
            }
        }
    }

    private func mutate(_ id: String,
                        _ body: (inout HostFinderDomain.Window) -> Void) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        body(&windows[index])
        onChange()
    }

    private func bringFront(_ index: Int) {
        guard windows.indices.contains(index) else { return }
        let window = windows.remove(at: index)
        windows.insert(window, at: 0)
        onChange()
    }

    private func defaultFrame(in screen: Scene.ScreenSize, offset: Int,
                              expanded: Bool = false) -> Rect {
        if expanded {
            return Rect(l: 8, t: 28, r: max(220, screen.w - 8),
                        b: max(160, screen.h - 8))
        }
        let n = offset % 7
        let left = min(max(12, screen.w / 9 + n * 18), max(12, screen.w - 260))
        let top = min(38 + n * 18, max(28, screen.h - 190))
        return Rect(l: left, t: top,
                    r: min(screen.w - 12, left + max(300, screen.w * 2 / 3)),
                    b: min(screen.h - 12, top + max(220, screen.h * 2 / 3)))
    }
}
