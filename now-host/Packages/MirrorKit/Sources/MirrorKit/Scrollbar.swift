import Foundation

/// Classic scrollbar anatomy, derived from what the wire already tells us: the
/// control's rect plus `value`/`min`/`max`. Pure geometry — no wire, no guest.
///
/// A scrollbar is five hit regions, and which one you press decides what the
/// guest does. The Control Manager's own `TrackControl` does the scrolling; our
/// job is only to press the right spot, so the arithmetic here IS the feature.
///
/// The wire reports a live range only when there is something to scroll: a
/// window whose content fits reports `value/min/max = 0/0/0` and degrades to
/// `role:"control"`. That is honest, not a gap — `isLive` is the test.
public enum Scrollbar {
    /// Classic arrow box at each end of the bar.
    public static let arrow = 16
    /// Classic thumb (OS 8/9 draws a proportional indicator, but the Control
    /// Manager still tracks a fixed-size thumb region).
    public static let thumbSize = 16

    /// Ranged, enabled, and actually scrollable. A window whose content fits
    /// has min == max and nothing to do.
    public static func isLive(_ c: Scene.Control) -> Bool {
        guard c.role == "scrollbar", c.enabled, c.visible,
              let mn = c.min, let mx = c.max, mx > mn, c.rect != nil
        else { return false }
        return true
    }

    /// Long axis. Ties go to vertical (the common case).
    public static func isVertical(_ c: Scene.Control) -> Bool {
        guard let r = c.rect else { return true }
        return (r.b - r.t) >= (r.r - r.l)
    }

    /// Track between the two arrow boxes, in the control's own space.
    public static func track(_ c: Scene.Control) -> Rect? {
        guard let r = c.rect else { return nil }
        if isVertical(c) {
            guard (r.b - r.t) > arrow * 2 else { return nil }
            return Rect(l: r.l, t: r.t + arrow, r: r.r, b: r.b - arrow)
        }
        guard (r.r - r.l) > arrow * 2 else { return nil }
        return Rect(l: r.l + arrow, t: r.t, r: r.r - arrow, b: r.b)
    }

    /// Where the thumb sits for the current value, in the control's own space.
    public static func thumbRect(_ c: Scene.Control) -> Rect? {
        guard isLive(c), let track = track(c),
              let v = c.value, let mn = c.min, let mx = c.max, mx > mn
        else { return nil }
        let frac = Double(min(max(v, mn), mx) - mn) / Double(mx - mn)
        if isVertical(c) {
            let span = max(0, (track.b - track.t) - thumbSize)
            let top = track.t + Int((Double(span) * frac).rounded())
            return Rect(l: track.l, t: top, r: track.r, b: top + thumbSize)
        }
        let span = max(0, (track.r - track.l) - thumbSize)
        let left = track.l + Int((Double(span) * frac).rounded())
        return Rect(l: left, t: track.t, r: left + thumbSize, b: track.b)
    }

    /// The five regions of a scrollbar. `lineUp`/`lineDown` are the arrows
    /// (one line, auto-repeating while held); `pageUp`/`pageDown` are the
    /// track either side of the thumb; `thumb` is dragged.
    public enum Part: String, Equatable, Sendable {
        case lineUp, lineDown, pageUp, pageDown, thumb
    }

    /// Which region is under a point (control-space coords)? nil when the bar
    /// isn't live or the point is outside it.
    public static func part(_ c: Scene.Control, atX x: Int, y: Int) -> Part? {
        guard isLive(c), let r = c.rect,
              x >= r.l, x < r.r, y >= r.t, y < r.b else { return nil }
        let vertical = isVertical(c)
        // Arrow boxes first — they bound the track.
        if vertical {
            if y < r.t + arrow { return .lineUp }
            if y >= r.b - arrow { return .lineDown }
        } else {
            if x < r.l + arrow { return .lineUp }
            if x >= r.r - arrow { return .lineDown }
        }
        guard let thumb = thumbRect(c) else { return nil }
        if vertical {
            if y < thumb.t { return .pageUp }
            if y >= thumb.b { return .pageDown }
        } else {
            if x < thumb.l { return .pageUp }
            if x >= thumb.r { return .pageDown }
        }
        return .thumb
    }

    /// Center of a region, in control space — the point to press.
    public static func center(_ c: Scene.Control, _ part: Part) -> (x: Int, y: Int)? {
        guard let r = c.rect else { return nil }
        let vertical = isVertical(c)
        switch part {
        case .lineUp:
            return vertical ? ((r.l + r.r) / 2, r.t + arrow / 2)
                            : (r.l + arrow / 2, (r.t + r.b) / 2)
        case .lineDown:
            return vertical ? ((r.l + r.r) / 2, r.b - arrow / 2)
                            : (r.r - arrow / 2, (r.t + r.b) / 2)
        case .thumb, .pageUp, .pageDown:
            guard let thumb = thumbRect(c), let track = track(c) else { return nil }
            if part == .thumb {
                return ((thumb.l + thumb.r) / 2, (thumb.t + thumb.b) / 2)
            }
            // Middle of the exposed track on the chosen side.
            // A gap thinner than this can't be pressed without the click
            // landing on the thumb (or past it, which pages the WRONG WAY).
            let minGap = 4
            if vertical {
                let t = part == .pageUp ? track.t : thumb.b
                let b = part == .pageUp ? thumb.t : track.b
                guard b - t >= minGap else { return nil }
                return ((r.l + r.r) / 2, (t + b) / 2)
            }
            let l = part == .pageUp ? track.l : thumb.r
            let rr = part == .pageUp ? thumb.l : track.r
            guard rr - l >= minGap else { return nil }
            return ((l + rr) / 2, (r.t + r.b) / 2)
        }
    }

    /// Where to drag the thumb to land on `value` — control space. The caller
    /// drags from the thumb's current center to this point; the guest's
    /// tracking loop does the scrolling.
    public static func thumbTarget(_ c: Scene.Control,
                                   value: Int) -> (x: Int, y: Int)? {
        guard isLive(c), let track = track(c), let r = c.rect,
              let mn = c.min, let mx = c.max, mx > mn else { return nil }
        let frac = Double(min(max(value, mn), mx) - mn) / Double(mx - mn)
        if isVertical(c) {
            let span = max(0, (track.b - track.t) - thumbSize)
            let top = track.t + Int((Double(span) * frac).rounded())
            return ((r.l + r.r) / 2, top + thumbSize / 2)
        }
        let span = max(0, (track.r - track.l) - thumbSize)
        let left = track.l + Int((Double(span) * frac).rounded())
        return (left + thumbSize / 2, (r.t + r.b) / 2)
    }
}
