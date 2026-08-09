import Foundation

/// Immediate host-side interaction state for semantic Finder interiors.
///
/// The guest remains authoritative for which windows exist, their geometry,
/// view, and eventual scrollbar values. A click does not need to wait for the
/// next guest scene to look selected or scrolled, though: this projection
/// applies the interaction locally, then retires a scroll preview as soon as
/// the guest reports that the corresponding control value moved.
public struct FinderInteriorState: Equatable, Sendable {
    private struct ScrollPreview: Equatable, Sendable {
        var controlRef: String
        var baseline: Int
        var delta: Int
        var vertical: Bool
    }

    private var selections: [String: Set<String>] = [:]
    private var scrolls: [String: ScrollPreview] = [:]

    public init() {}

    public mutating func select(_ name: String, in windowID: String) {
        selections[windowID] = [name]
    }

    public mutating func clearSelection(in windowID: String) {
        selections[windowID] = []
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
}
