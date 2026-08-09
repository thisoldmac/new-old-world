import Foundation

/// Host-only edit presentation. It deliberately does not enter `Scene`: the
/// guest reported an item named `original`, while the text field is an
/// interaction the person is still composing on this host.
public struct FinderRenamePresentation: Equatable, Sendable {
    public var windowID: String
    public var original: String
    public var text: String

    public init(windowID: String, original: String, text: String) {
        self.windowID = windowID
        self.original = original
        self.text = text
    }
}

/// Immediate host-side interaction state for semantic Finder interiors.
///
/// The guest remains authoritative for which windows exist, their geometry,
/// view, and eventual scrollbar values. A click does not need to wait for the
/// next guest scene to look selected or scrolled, though: this projection
/// applies the interaction locally, then retires a scroll preview as soon as
/// the guest reports that the corresponding control value moved.
public struct FinderInteriorState: Equatable, Sendable {
    public enum SelectionMode: Equatable, Sendable {
        case replace
        case toggle
        case range
    }

    private struct ScrollPreview: Equatable, Sendable {
        var controlRef: String
        var baseline: Int
        var delta: Int
        var vertical: Bool
    }

    private var selections: [String: Set<String>] = [:]
    private var selectionAnchors: [String: String] = [:]
    private var scrolls: [String: ScrollPreview] = [:]
    private var marqueeBases: [String: Set<String>] = [:]
    public private(set) var rename: FinderRenamePresentation?
    private var renameSelectsAll = false

    public init() {}

    public mutating func select(_ name: String, in windowID: String) {
        selections[windowID] = [name]
        selectionAnchors[windowID] = name
        rename = nil
    }

    /// Apply Macintosh selection semantics and answer the exact host-owned
    /// set that should be sent to Finder.
    @discardableResult
    public mutating func select(_ name: String, in window: Scene.Window,
                                mode: SelectionMode) -> Set<String> {
        let id = window.id
        var selected = selections[id] ?? window.finder?.selectedNames ?? []
        switch mode {
        case .replace:
            selected = [name]
            selectionAnchors[id] = name
        case .toggle:
            if selected.contains(name) { selected.remove(name) }
            else { selected.insert(name) }
            selectionAnchors[id] = name
        case .range:
            let ordered = FinderItems.itemTargetRects(window).map(\.item.name)
            let anchor = selectionAnchors[id] ?? name
            if let a = ordered.firstIndex(of: anchor),
               let b = ordered.firstIndex(of: name) {
                selected = Set(ordered[min(a, b)...max(a, b)])
            } else {
                selected = [name]
            }
        }
        selections[id] = selected
        rename = nil
        return selected
    }

    public mutating func clearSelection(in windowID: String) {
        selections[windowID] = []
        selectionAnchors[windowID] = nil
        rename = nil
    }

    public mutating func setSelection(_ names: Set<String>,
                                      in windowID: String) {
        selections[windowID] = names
        selectionAnchors[windowID] = names.count == 1 ? names.first : nil
        rename = nil
    }

    public func selectedNames(in windowID: String) -> Set<String> {
        selections[windowID] ?? []
    }

    public func selectedNames(in window: Scene.Window) -> Set<String> {
        selections[window.id] ?? window.finder?.selectedNames ?? []
    }

    public func isSelected(_ name: String, in windowID: String) -> Bool {
        selectedNames(in: windowID).contains(name)
    }

    public func isSelected(_ name: String, in window: Scene.Window) -> Bool {
        selectedNames(in: window).contains(name)
    }

    /// Begin and update a rubber-band selection. `rect` is global guest
    /// geometry, while Finder item targets are content-local.
    public mutating func beginMarquee(in window: Scene.Window,
                                     extending: Bool) {
        marqueeBases[window.id] = extending
            ? (selections[window.id] ?? window.finder?.selectedNames ?? []) : []
        if !extending { selections[window.id] = [] }
        rename = nil
    }

    @discardableResult
    public mutating func updateMarquee(in window: Scene.Window, rect: Rect)
        -> Set<String> {
        let origin = FinderItems.contentOrigin(window)
        let local = Rect(l: rect.l - origin.x, t: rect.t - origin.y,
                         r: rect.r - origin.x, b: rect.b - origin.y)
        let hits = Set(FinderItems.itemTargetRects(window).compactMap {
            Self.intersects(local, $0.rect) ? $0.item.name : nil
        })
        let selected = (marqueeBases[window.id] ?? []).union(hits)
        selections[window.id] = selected
        return selected
    }

    public mutating func endMarquee(in windowID: String) {
        marqueeBases[windowID] = nil
    }

    @discardableResult
    public mutating func beginRename(in windowID: String) -> Bool {
        guard let name = selections[windowID], name.count == 1,
              let only = name.first else { return false }
        rename = .init(windowID: windowID, original: only, text: only)
        renameSelectsAll = true
        return true
    }

    public mutating func appendRenameText(_ text: String) {
        guard rename != nil else { return }
        let safe = text.filter { $0 != ":" }
        if renameSelectsAll {
            rename?.text = safe
            renameSelectsAll = false
        } else {
            rename?.text.append(contentsOf: safe)
        }
    }

    public mutating func deleteRenameCharacter() {
        guard rename != nil else { return }
        if renameSelectsAll {
            rename?.text = ""
            renameSelectsAll = false
        } else if rename?.text.isEmpty == false {
            rename?.text.removeLast()
        }
    }

    public mutating func cancelRename() {
        rename = nil
        renameSelectsAll = false
    }

    /// End editing and return a real rename only when the text changed and is
    /// nonempty. Finder remains authoritative if it refuses that name.
    public mutating func commitRename() -> FinderRenamePresentation? {
        guard let edit = rename else { return nil }
        rename = nil
        renameSelectsAll = false
        guard !edit.text.isEmpty, edit.text != edit.original else { return nil }
        return edit
    }

    /// Preview one scrollbar part immediately. The value delta and item
    /// translation are the same fact in opposite directions.
    public mutating func previewScroll(in window: Scene.Window,
                                       control: Scene.Control,
                                       part: Scrollbar.Part) {
        guard FinderItems.isFolderWindow(window),
              Scrollbar.isLive(control),
              part != .thumb,
              let value = control.value,
              let minimum = control.min,
              let maximum = control.max else { return }
        let vertical = Scrollbar.isVertical(control)
        let field = FinderItems.iconArea(window)
        let line = window.finder?.view == .name ? 19 : 16
        let visible = vertical ? field.b - field.t : field.r - field.l
        let amount: Int
        switch part {
        case .lineUp, .lineDown:
            amount = line
        case .pageUp, .pageDown:
            amount = max(line, visible - line)
        case .thumb:
            return
        }
        let direction = (part == .lineDown || part == .pageDown) ? 1 : -1
        var preview = scrolls[window.id]
            ?? .init(controlRef: control.ref, baseline: value, delta: 0,
                     vertical: vertical)
        guard preview.controlRef == control.ref else { return }
        let desired = min(max(preview.baseline + preview.delta
                              + direction * amount, minimum), maximum)
        preview.delta = desired - preview.baseline
        scrolls[window.id] = preview
    }

    /// Preview a thumb drag from its original pointer delta. Repeated drag
    /// frames replace rather than accumulate the delta.
    public mutating func previewThumb(in window: Scene.Window,
                                      control: Scene.Control,
                                      pointerDelta: Int) {
        guard FinderItems.isFolderWindow(window),
              Scrollbar.isLive(control),
              let value = control.value,
              let minimum = control.min,
              let maximum = control.max,
              let track = Scrollbar.track(control) else { return }
        let vertical = Scrollbar.isVertical(control)
        let span = vertical ? track.b - track.t - Scrollbar.thumbSize
                            : track.r - track.l - Scrollbar.thumbSize
        guard span > 0 else { return }
        let existing = scrolls[window.id]
        let baseline = existing?.controlRef == control.ref
            ? existing!.baseline : value
        let valueDelta = Int((Double(pointerDelta)
            * Double(maximum - minimum) / Double(span)).rounded())
        let desired = min(max(baseline + valueDelta, minimum), maximum)
        scrolls[window.id] = .init(
            controlRef: control.ref, baseline: baseline,
            delta: desired - baseline, vertical: vertical)
    }

    /// Retire previews once the guest's own scrollbar value advances. Local
    /// selection remains until another host selection replaces it; Finder's
    /// global selection is not present in ordinary structural polls.
    public mutating func reconcile(with scene: Scene) {
        let liveIDs = Set(scene.windows.map(\.id))
        selections = selections.filter { liveIDs.contains($0.key) }
        for window in scene.windows {
            guard let items = window.items, selections[window.id] != nil else {
                continue
            }
            let liveNames = Set(items.map(\.name))
            selections[window.id]?.formIntersection(liveNames)
        }
        selectionAnchors = selectionAnchors.filter { liveIDs.contains($0.key) }
        marqueeBases = marqueeBases.filter { liveIDs.contains($0.key) }
        if let rename, !liveIDs.contains(rename.windowID) { self.rename = nil }
        scrolls = scrolls.filter { windowID, preview in
            guard let window = scene.windows.first(where: {
                      $0.id == windowID
                  }),
                  let control = window.controls.first(where: {
                      $0.ref == preview.controlRef
                  }), let value = control.value else { return false }
            return value == preview.baseline
        }
    }

    /// Apply local selection and scroll to a copy used for drawing, hit
    /// testing, and object resolution. No guest-authored scene is mutated.
    public func projecting(_ scene: Scene) -> Scene {
        var out = scene
        for index in out.windows.indices {
            let id = out.windows[index].id
            if let selected = selections[id], out.windows[index].finder != nil {
                out.windows[index].finder?.selectedNames = selected
            }
            guard let preview = scrolls[id], preview.delta != 0 else {
                continue
            }
            guard let controlIndex = out.windows[index].controls.firstIndex(
                    where: { $0.ref == preview.controlRef }),
                  out.windows[index].controls[controlIndex].value
                    == preview.baseline else { continue }
            out.windows[index].controls[controlIndex].value =
                preview.baseline + preview.delta
            out.windows[index].items = out.windows[index].items?.map { item in
                var shifted = item
                if preview.vertical { shifted.y -= preview.delta }
                else { shifted.x -= preview.delta }
                return shifted
            }
        }
        return out
    }

    private static func intersects(_ a: Rect, _ b: Rect) -> Bool {
        a.l < b.r && a.r > b.l && a.t < b.b && a.b > b.t
    }
}
