import Foundation

/// The pixel islands the poller holds between polls, plus the two rules that
/// make holding them safe: how a window is *keyed*, and when its pixels are
/// dropped. Pure state — no wire — so both rules are testable without a guest.
///
/// Why it exists: only the FRONT window is ever re-captured (a full-window
/// capture is ~1 s), so every other window's interior is whatever we last saw.
/// That is the product requirement — an app's interior updates when it launches,
/// when it is raised, and while it is focused, and otherwise shows its last
/// known state instead of going blank.
struct IslandStore {
    /// The held pixels, by cache key.
    var pixels: [String: PixelIsland] = [:]
    /// The content-rect + blit-tick signature the pixels were captured at;
    /// an unchanged signature is what lets the front window skip a capture.
    var contentKey: [String: String] = [:]
    /// Newest draw tick already accounted for (the MoveBits fast-path's cursor).
    var tick: [String: Int] = [:]
    /// Poll seq at which each key was last present in a scene — the eviction
    /// clock.
    var seen: [String: Int] = [:]

    /// Polls a window may be absent before its pixels are dropped.
    var gracePolls = 60

    /// The cache key for each window, in `windows` order.
    ///
    /// Deliberately **not** `Scene.Window.id`: that is
    /// `psn/title#<index into the app's window list>`, and the index is
    /// z-order — it changes the instant focus moves between two windows of the
    /// same app, so a `win.id`-keyed cache would miss exactly when it matters
    /// and leak an entry per raise. (`Serve.resolveWindow` already treats the
    /// `#` suffix as volatile and prefix-matches without it.)
    ///
    /// `psn/title` is stable across raises *and* moves. Two windows with the
    /// same title in one app (two `untitled` SimpleText docs) are disambiguated
    /// by top-left corner — still stable across a raise, and a duplicate that
    /// moves while unfocused simply re-captures the next time it is focused.
    static func keys(for windows: [Scene.Window]) -> [String] {
        var occurrences: [String: Int] = [:]
        for win in windows {
            occurrences["\(win.psn)/\(win.title)", default: 0] += 1
        }
        return windows.map { win in
            let base = "\(win.psn)/\(win.title)"
            guard occurrences[base, default: 0] > 1 else { return base }
            return "\(base)@\(win.rect.l),\(win.rect.t)"
        }
    }

    /// Mark these keys as present in the current poll.
    mutating func touch(_ keys: [String], seq: Int) {
        for key in keys { seen[key] = seq }
    }

    /// Drop everything for windows that have been gone for `gracePolls` polls,
    /// so a long session's dictionaries stay bounded rather than accumulating
    /// one island per window ever opened.
    mutating func evict(living: Set<String>, seq: Int) {
        for (key, lastSeen) in seen where !living.contains(key) {
            guard seq - lastSeen >= gracePolls else { continue }
            seen[key] = nil
            pixels[key] = nil
            contentKey[key] = nil
            tick[key] = nil
        }
    }

    /// Keys we currently hold pixels for (the meter tests read this).
    var heldKeys: Set<String> { Set(pixels.keys) }
}
