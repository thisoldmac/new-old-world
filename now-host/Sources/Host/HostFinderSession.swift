import Foundation
import MirrorKit

/// A host Finder presentation over the guest file contract.
///
/// Interiors always settle locally. Optional development couplings mirror
/// folder-window lifecycle and geometry to the guest, then reconcile from a
/// later scene without putting guest latency back in the interaction path.
@MainActor
final class HostFinderSession {
    static let preferenceKey = "mirror.emulateFinderWindows"
    static let desktopPreferenceKey = "mirror.emulateDesktop"
    static let lifecycleSyncPreferenceKey = "mirror.emulatedFinder.syncLifecycle"
    static let geometrySyncPreferenceKey = "mirror.emulatedFinder.syncGeometry"

    private let listener: GuestListener
    private let defaults: UserDefaults
    private(set) var windows: [HostFinderDomain.Window] = []
    private(set) var status = "Host Finder is off"
    var onChange: () -> Void = {}

    private var serial = 0
    private var screen: Scene.ScreenSize?
    private var lastGuestWindows: [Scene.Window] = []
    private var generation = 0
    private var dragSubject: DragTargeting.Subject?
    private(set) var active = true
    private var fileWatch: HostEventSubscription?
    private var desktopEntries: [FileEntry] = []
    private var desktopRootLabel: String?
    private var desktopLoading = false
    private var desktopLoaded = false
    private var guestCatalogs: [String: [FileEntry]] = [:]
    private var loadingGuestCatalogs = Set<String>()
    private var guestIdentityByWindowID: [String: String] = [:]
    private var guestRefByWindowID: [String: String] = [:]
    private var suppressedGuestIdentities: [String: Date] = [:]
    private var pendingGeometry: [String: (Rect, Date)] = [:]
    private var pendingGeometryActions: [String: Set<String>] = [:]
    private var dispatchedGeometry: [String: Rect] = [:]
    private var guestOpenRequested = Set<String>()

    var currentDragContainer: DragTargeting.Container? {
        dragSubject?.container
    }

    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: Self.preferenceKey)
            generation &+= 1
            windows.removeAll()
            guestCatalogs.removeAll()
            loadingGuestCatalogs.removeAll()
            guestIdentityByWindowID.removeAll()
            guestRefByWindowID.removeAll()
            pendingGeometry.removeAll()
            pendingGeometryActions.removeAll()
            dispatchedGeometry.removeAll()
            guestOpenRequested.removeAll()
            active = enabled
            status = enabled ? "Reading open Finder windows…"
                : "Reading guest Finder state…"
            if enabled { reconcileGuestWindows(lastGuestWindows) }
            else { observeGuestCatalogs(lastGuestWindows) }
            onChange()
        }
    }

    var emulateDesktop: Bool {
        didSet {
            guard emulateDesktop != oldValue else { return }
            defaults.set(emulateDesktop, forKey: Self.desktopPreferenceKey)
            generation &+= 1
            desktopEntries.removeAll()
            desktopRootLabel = nil
            desktopLoading = false
            desktopLoaded = false
            status = emulateDesktop ? "Reading the guest Desktop Folder…"
                : enabled ? "Emulating Finder window interiors"
                : "Reading guest Finder state…"
            seedDesktopIfNeeded()
            onChange()
        }
    }

    var syncLifecycle: Bool {
        didSet {
            guard syncLifecycle != oldValue else { return }
            defaults.set(syncLifecycle, forKey: Self.lifecycleSyncPreferenceKey)
            if enabled { reconcileGuestWindows(lastGuestWindows) }
            onChange()
        }
    }

    var syncGeometry: Bool {
        didSet {
            guard syncGeometry != oldValue else { return }
            defaults.set(syncGeometry, forKey: Self.geometrySyncPreferenceKey)
            pendingGeometry.removeAll()
            pendingGeometryActions.removeAll()
            dispatchedGeometry.removeAll()
            if enabled { reconcileGuestWindows(lastGuestWindows) }
            onChange()
        }
    }

    init(listener: GuestListener, defaults: UserDefaults = UserDefaults(
        suiteName: ProductIdentity.preferencesSuite) ?? .standard) {
        self.listener = listener
        self.defaults = defaults
        enabled = defaults.bool(forKey: Self.preferenceKey)
        emulateDesktop = defaults.bool(forKey: Self.desktopPreferenceKey)
        syncLifecycle = defaults.object(forKey: Self.lifecycleSyncPreferenceKey)
            as? Bool ?? true
        syncGeometry = defaults.object(forKey: Self.geometrySyncPreferenceKey)
            as? Bool ?? true
        fileWatch = listener.events.subscribe { [weak self] event in
            guard let self else { return }
            if case .fileTreeChanged(_, let side, _) = event, side == .guest {
                self.refresh()
            }
        }
    }

    func observe(screen: Scene.ScreenSize) {
        self.screen = screen
        seedDesktopIfNeeded()
    }

    func observe(scene: Scene) {
        screen = scene.screen
        lastGuestWindows = scene.windows
        seedDesktopIfNeeded()
        if enabled {
            reconcileGuestWindows(scene.windows)
        } else {
            observeGuestCatalogs(scene.windows)
        }
    }

    func resetForGuestChange() {
        generation &+= 1
        windows.removeAll()
        lastGuestWindows.removeAll()
        desktopEntries.removeAll()
        desktopRootLabel = nil
        desktopLoading = false
        desktopLoaded = false
        guestCatalogs.removeAll()
        loadingGuestCatalogs.removeAll()
        guestIdentityByWindowID.removeAll()
        guestRefByWindowID.removeAll()
        suppressedGuestIdentities.removeAll()
        pendingGeometry.removeAll()
        pendingGeometryActions.removeAll()
        dispatchedGeometry.removeAll()
        guestOpenRequested.removeAll()
        /* Screen geometry belongs to the session that reported it. Keeping
           the old screen here would immediately seed a new host Finder and
           let it repaint over a replacement connection before that Mac had
           published even one frame. */
        screen = nil
        status = enabled ? "Opening the guest disk…" : "Host Finder is off"
        onChange()
    }

    func refresh() {
        generation &+= 1
        desktopEntries.removeAll()
        desktopRootLabel = nil
        desktopLoaded = false
        desktopLoading = false
        guestCatalogs.removeAll()
        loadingGuestCatalogs.removeAll()
        status = "Refreshing semantic Finder catalogs…"
        seedDesktopIfNeeded()
        if enabled {
            for id in windows.map(\.id) { load(windowID: id, replacing: true) }
        } else {
            observeGuestCatalogs(lastGuestWindows)
        }
        onChange()
    }

    func rebuild() {
        generation &+= 1
        windows.removeAll()
        lastGuestWindows.removeAll()
        desktopEntries.removeAll()
        desktopRootLabel = nil
        desktopLoaded = false
        desktopLoading = false
        guestCatalogs.removeAll()
        loadingGuestCatalogs.removeAll()
        guestIdentityByWindowID.removeAll()
        guestRefByWindowID.removeAll()
        suppressedGuestIdentities.removeAll()
        pendingGeometry.removeAll()
        pendingGeometryActions.removeAll()
        dispatchedGeometry.removeAll()
        guestOpenRequested.removeAll()
        status = "Cleared semantic Finder state; rebuilding…"
        seedDesktopIfNeeded()
        onChange()
    }

    func project(_ base: Scene) -> Scene {
        var result = base
        if emulateDesktop, desktopLoaded, let screen {
            let guestSystemItems = (base.desktopItems ?? []).filter {
                $0.kind == "disk" || $0.kind == "trash"
            }
            var local = HostFinderDomain.projectedDesktop(
                desktopEntries, rootLabel: desktopRootLabel, screen: screen)
            let localNames = Set(local.map(\.name))
            let extras = guestSystemItems.filter {
                !localNames.contains($0.name)
            }.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name)
                    == .orderedAscending
            }
            let right = max(8, screen.w - 58)
            for (index, var item) in extras.enumerated() {
                /* Desktop emulation owns placement too. Keeping Finder's
                   measured disk coordinates here made this toggle appear to
                   do nothing and left the desktop with two geometry owners. */
                item.x = max(8, right - (index + 1) * 84)
                item.y = item.kind == "trash" ? max(82, screen.h - 64) : 14
                local.append(item)
            }
            result.desktopItems = local
        }
        guard enabled else {
            result.windows = result.windows.map(projectGuestFinderFallback)
            return result
        }
        var localByGuestIdentity: [String: HostFinderDomain.Window] = [:]
        for local in windows {
            if let identity = guestIdentityByWindowID[local.id] {
                localByGuestIdentity[identity] = local
            }
        }
        result.windows = result.windows.map { guest in
            guard FinderItems.isFolderWindow(guest),
                  !FinderItems.isHostOwnedWindow(guest),
                  let local = localByGuestIdentity[Self.guestIdentity(guest)]
            else { return guest }
            return project(local, z: guest.z, guest: guest)
        }
        let independent = windows.filter { guestIdentityByWindowID[$0.id] == nil }
        if !independent.isEmpty, active {
            for index in result.windows.indices {
                result.windows[index].front = false
                result.windows[index].z += independent.count
            }
            let projected = independent.enumerated().map {
                HostFinderDomain.projectedWindow($0.element, z: $0.offset)
            }
            result.windows = projected + result.windows
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
                from: base.menubar, window: independent.first)
        } else if !independent.isEmpty {
            let offset = result.windows.count
            let projected = independent.enumerated().map { pair -> Scene.Window in
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
            if syncLifecycle || syncGeometry {
                closeGuestWindow(for: windows[index])
                if let identity = guestIdentityByWindowID[id] {
                    suppressedGuestIdentities[identity] = Date()
                        .addingTimeInterval(8)
                }
            }
            windows.remove(at: index)
            guestIdentityByWindowID[id] = nil
            guestRefByWindowID[id] = nil
            pendingGeometry[id] = nil
            pendingGeometryActions[id] = nil
            dispatchedGeometry[id] = nil
            guestOpenRequested.remove(id)
            status = "Closed Finder window"
            onChange()
        case .zoom:
            guard let screen else { return }
            windows[index].frame = defaultFrame(in: screen, offset: 0,
                                                expanded: true)
            notePendingGeometry(id, action: "move")
            notePendingGeometry(id, action: "resize")
            sendGuestWindowAct(id: id, action: "zoom")
            onChange()
        case .move(let left, let top):
            active = true
            let width = windows[index].frame.r - windows[index].frame.l
            let height = windows[index].frame.b - windows[index].frame.t
            windows[index].frame = Rect(l: left, t: top - SceneBuilder.titleBarHeight,
                                        r: left + width,
                                        b: top - SceneBuilder.titleBarHeight + height)
            notePendingGeometry(id, action: "move")
            sendPendingGuestGeometry(id: id)
            bringFront(index)
        case .resize(let width, let height):
            active = true
            windows[index].frame.r = windows[index].frame.l + max(180, width)
            windows[index].frame.b = windows[index].frame.t
                + SceneBuilder.titleBarHeight + max(100, height)
            notePendingGeometry(id, action: "resize")
            sendPendingGuestGeometry(id: id)
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

    func openDesktop(_ names: [String]) -> Bool {
        /* An emulated desktop can feed a guest-owned Finder window. Only
           consume the open locally when interior emulation can present the
           resulting window; otherwise the source must fall through to the
           ordinary guest Finder act. */
        guard enabled else { return false }
        active = true
        var handled = false
        let rootName = desktopRootLabel?.trimmingCharacters(
            in: CharacterSet(charactersIn: ":"))
        for name in names {
            if name == rootName {
                openFolder("")
                handled = true
                continue
            }
            guard let entry = desktopEntries.first(where: { $0.name == name })
            else { continue }
            let path = HostFinderDomain.joined("Desktop Folder", name)
            if entry.isFolder {
                openFolder(path)
            } else if entry.fileType == "APPL" || entry.fileType == "appe"
                        || entry.fileType == "cdev" {
                launch(path: path, root: desktopRootLabel)
            } else {
                openDocument(path: path, root: desktopRootLabel)
            }
            handled = true
        }
        return handled
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

    // MARK: - Guest reconciliation and semantic catalogs

    private func seedDesktopIfNeeded() {
        guard emulateDesktop, !desktopLoaded, !desktopLoading,
              screen != nil else { return }
        loadDesktop()
    }

    private func loadDesktop() {
        guard !desktopLoading else { return }
        desktopLoading = true
        let requestGeneration = generation
        loadDesktopPage(path: "Desktop Folder", cursor: nil, entries: [],
                        generation: requestGeneration)
    }

    private func loadDesktopPage(path: String, cursor: Int?,
                                 entries: [FileEntry],
                                 generation requestGeneration: Int) {
        listener.listFiles(path: path, cursor: cursor) { [weak self] result in
            guard let self, requestGeneration == self.generation else { return }
            switch result {
            case .failure(let failure):
                self.desktopLoading = false
                self.status = "Desktop Folder could not be read: \(failure.message)"
                self.onChange()
            case .success(let listing):
                let all = entries + listing.entries
                if listing.more, let next = listing.cursor, next != cursor {
                    self.loadDesktopPage(path: path, cursor: next, entries: all,
                                         generation: requestGeneration)
                    return
                }
                self.desktopEntries = all
                self.desktopRootLabel = Self.volumeRoot(of: listing.root)
                self.desktopLoading = false
                self.desktopLoaded = true
                self.onChange()
            }
        }
    }

    private func observeGuestCatalogs(_ guestWindows: [Scene.Window]) {
        for window in guestWindows where FinderItems.isFolderWindow(window) {
            guard let absolute = window.finder?.path, !absolute.isEmpty else {
                continue
            }
            let path = HostFinderDomain.relativePath(
                absolute, root: desktopRootLabel ?? Self.volumeRoot(of: absolute))
            loadGuestCatalogIfNeeded(path)
        }
    }

    private func loadGuestCatalogIfNeeded(_ path: String) {
        guard guestCatalogs[path] == nil,
              !loadingGuestCatalogs.contains(path) else { return }
        loadingGuestCatalogs.insert(path)
        loadGuestCatalogPage(path: path, cursor: nil, entries: [],
                             generation: generation)
    }

    private func loadGuestCatalogPage(path: String, cursor: Int?,
                                      entries: [FileEntry],
                                      generation requestGeneration: Int) {
        listener.listFiles(path: path, cursor: cursor) { [weak self] result in
            guard let self, requestGeneration == self.generation else { return }
            switch result {
            case .failure:
                self.loadingGuestCatalogs.remove(path)
            case .success(let listing):
                let all = entries + listing.entries
                if listing.more, let next = listing.cursor, next != cursor {
                    self.loadGuestCatalogPage(path: path, cursor: next,
                                              entries: all,
                                              generation: requestGeneration)
                } else {
                    self.loadingGuestCatalogs.remove(path)
                    self.guestCatalogs[path] = all
                    self.onChange()
                }
            }
        }
    }

    private func projectGuestFinderFallback(_ guest: Scene.Window)
        -> Scene.Window {
        guard FinderItems.isFolderWindow(guest),
              guest.items?.isEmpty != false,
              let presentation = guest.finder,
              !presentation.path.isEmpty else { return guest }
        let path = HostFinderDomain.relativePath(
            presentation.path,
            root: desktopRootLabel ?? Self.volumeRoot(of: presentation.path))
        guard let entries = guestCatalogs[path] else { return guest }
        var local = HostFinderDomain.Window(
            id: guest.id, path: path, rootLabel: desktopRootLabel,
            frame: guest.rect, view: presentation.view,
            entries: entries, selectedNames: presentation.selectedNames,
            pages: 1, complete: true)
        local.verticalScroll = max(0, FinderItems.scrollPosition(guest).y)
        var projected = guest
        projected.items = HostFinderDomain.projectedWindow(local, z: guest.z).items
        projected.display = nil
        projected.displayEpoch = nil
        return projected
    }

    private func reconcileGuestWindows(_ guestWindows: [Scene.Window]) {
        let now = Date()
        suppressedGuestIdentities = suppressedGuestIdentities.filter {
            $0.value > now
        }
        let guests = guestWindows.filter {
            FinderItems.isFolderWindow($0)
                && !FinderItems.isHostOwnedWindow($0)
        }
        let identities = Set(guests.map(Self.guestIdentity))

        for guest in guests {
            let identity = Self.guestIdentity(guest)
            if suppressedGuestIdentities[identity] != nil { continue }
            guard let absolute = guest.finder?.path, !absolute.isEmpty else {
                continue
            }
            let path = HostFinderDomain.relativePath(
                absolute, root: desktopRootLabel ?? Self.volumeRoot(of: absolute))
            var index = windows.firstIndex {
                guestIdentityByWindowID[$0.id] == identity
            }
            if index == nil { index = windows.firstIndex { $0.path == path } }
            if index == nil, let screen {
                serial &+= 1
                windows.insert(.init(
                    id: HostFinderDomain.windowID(serial), path: path,
                    rootLabel: desktopRootLabel,
                    frame: syncGeometry ? guest.rect
                        : defaultFrame(in: screen, offset: windows.count),
                    view: guest.finder?.view ?? .icon), at: 0)
                index = 0
                load(windowID: windows[0].id, replacing: true)
            }
            guard let index else { continue }
            let id = windows[index].id
            guestIdentityByWindowID[id] = identity
            if let ref = guest.ref { guestRefByWindowID[id] = ref }
            guestOpenRequested.insert(id)
            if let view = guest.finder?.view, view != .unknown {
                windows[index].view = view
            }
            if syncGeometry {
                if let pending = pendingGeometry[id], pending.1 > now,
                   pending.0 != guest.rect {
                    sendPendingGuestGeometry(id: id)
                    continue
                }
                pendingGeometry[id] = nil
                pendingGeometryActions[id] = nil
                dispatchedGeometry[id] = nil
                windows[index].frame = guest.rect
            }
        }

        guard syncLifecycle || syncGeometry else { return }
        let vanished = guestIdentityByWindowID.filter {
            !identities.contains($0.value)
        }.map(\.key)
        if !vanished.isEmpty {
            windows.removeAll { vanished.contains($0.id) }
            for id in vanished {
                guestIdentityByWindowID[id] = nil
                guestRefByWindowID[id] = nil
                pendingGeometry[id] = nil
                pendingGeometryActions[id] = nil
                dispatchedGeometry[id] = nil
                guestOpenRequested.remove(id)
            }
            onChange()
        }
    }

    private func notePendingGeometry(_ id: String, action: String) {
        guard syncGeometry,
              let frame = windows.first(where: { $0.id == id })?.frame else {
            return
        }
        pendingGeometry[id] = (frame, Date().addingTimeInterval(8))
        pendingGeometryActions[id, default: []].insert(action)
    }

    private func sendPendingGuestGeometry(id: String) {
        guard syncGeometry, let ref = guestRefByWindowID[id],
              let pending = pendingGeometry[id],
              dispatchedGeometry[id] != pending.0 else { return }
        let actions = pendingGeometryActions[id] ?? []
        let frame = pending.0
        var requests: [[String: CommandArg]] = []
        if actions.contains("move") {
            requests.append([
                "window": .text(ref), "action": .text("move"),
                "left": .number(frame.l),
                "top": .number(frame.t + SceneBuilder.titleBarHeight),
            ])
        }
        if actions.contains("resize") {
            requests.append([
                "window": .text(ref), "action": .text("resize"),
                "width": .number(max(1, frame.r - frame.l)),
                "height": .number(max(1, frame.b - frame.t
                    - SceneBuilder.titleBarHeight)),
            ])
        }
        guard !requests.isEmpty else { return }
        dispatchedGeometry[id] = frame
        sendGuestGeometryRequests(requests, id: id)
    }

    private func sendGuestGeometryRequests(_ requests: [[String: CommandArg]],
                                           id: String) {
        guard let request = requests.first else { return }
        listener.runCommand("winact", typed: request) { [weak self] result in
            guard let self else { return }
            guard result.ok else {
                self.status = "Guest window geometry refused: "
                    + (result.error?.message ?? "unknown error")
                self.dispatchedGeometry[id] = nil
                self.onChange()
                return
            }
            self.sendGuestGeometryRequests(Array(requests.dropFirst()), id: id)
        }
    }

    private func sendGuestWindowAct(id: String, action: String) {
        guard syncGeometry, let ref = guestRefByWindowID[id] else { return }
        let args: [String: CommandArg] = [
            "window": .text(ref), "action": .text(action),
        ]
        listener.runCommand("winact", typed: args) { [weak self] result in
            guard !result.ok else { return }
            self?.status = "Guest window \(action) refused: "
                + (result.error?.message ?? "unknown error")
            self?.onChange()
        }
    }

    private func openGuestWindowIfNeeded(id: String) {
        guard enabled, (syncLifecycle || syncGeometry),
              !guestOpenRequested.contains(id),
              let window = windows.first(where: { $0.id == id }),
              let full = HostFinderDomain.fullPath(
                root: window.rootLabel ?? desktopRootLabel,
                relative: window.path) else { return }
        guestOpenRequested.insert(id)
        runFinderScript("tell application \"Finder\" to open item \""
                        + Self.escape(full) + "\"")
    }

    private func closeGuestWindow(for window: HostFinderDomain.Window) {
        if let ref = guestRefByWindowID[window.id] {
            listener.runCommand("winact", typed: [
                "window": .text(ref), "action": .text("close"),
            ]) { _ in }
            return
        }
        guard let full = HostFinderDomain.fullPath(
            root: window.rootLabel ?? desktopRootLabel,
            relative: window.path) else { return }
        let escaped = Self.escape(full)
        runFinderScript("tell application \"Finder\"\nrepeat with w in "
                        + "every window\ntry\nif (item of w as text) is \""
                        + escaped + "\" then close w\nend try\nend repeat\nend tell")
    }

    private func runFinderScript(_ source: String) {
        listener.runCommand("script", args: ["source": source]) {
            [weak self] result in
            guard !result.ok else { return }
            self?.status = "Finder coupling refused: "
                + (result.error?.message ?? "unknown error")
            self?.onChange()
        }
    }

    private static func guestIdentity(_ window: Scene.Window) -> String {
        if let ref = window.ref { return ref }
        if let address = window.addr {
            return "\(window.incarnation ?? window.psn):\(address)"
        }
        return window.id
    }

    /// Replace only the Finder interior. The guest window remains the shell
    /// authority: title, rectangle, stacking, visibility and window chrome
    /// all come from the observed window while the host supplies semantic
    /// items, selection and scroll controls under a host-routable identity.
    private func project(_ local: HostFinderDomain.Window, z: Int,
                         guest: Scene.Window?) -> Scene.Window {
        var projected = HostFinderDomain.projectedWindow(local, z: z)
        guard let guest else { return projected }
        projected.app = guest.app
        projected.psn = guest.psn
        projected.title = guest.title
        projected.kind = guest.kind
        let pendingLocalGeometry = pendingGeometry[local.id]?.1 ?? .distantPast
        projected.rect = syncGeometry && pendingLocalGeometry <= Date()
            ? guest.rect : local.frame
        projected.front = guest.front
        projected.z = guest.z
        projected.visible = guest.visible
        projected.addr = guest.addr
        projected.incarnation = guest.incarnation
        projected.closeBox = guest.closeBox
        projected.zoomBox = guest.zoomBox
        return projected
    }

    private static func volumeRoot(of listingRoot: String?) -> String? {
        guard let first = listingRoot?.split(separator: ":").first,
              !first.isEmpty else { return nil }
        return String(first) + ":"
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
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
        openGuestWindowIfNeeded(id: id)
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
                    self.openGuestWindowIfNeeded(id: windowID)
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
