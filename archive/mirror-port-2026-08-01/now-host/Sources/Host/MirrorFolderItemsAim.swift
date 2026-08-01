import Foundation
import MirrorKit

/// **The aim half of the folder-window model: opening one named item.**
///
/// `MirrorFolderItemsJoin` draws from a cache on purpose — a scene is worth
/// showing even a moment stale. An ACT is not: a position old enough to draw
/// from is not old enough to click from, because the Finder lays icons out
/// live and a scrolled window moves every one of them. So nothing here reads
/// `Scene.Window.items`, ever — every position this type acts on came from a
/// `script` call THIS function made, immediately before deciding anything.
/// That is the one discipline this file exists to keep, and
/// `MirrorFolderItemsAimTests` proves it by giving the cache and the fresh
/// walk different answers and asserting the fresh one wins.
///
/// ## The route, and why it is not `script`
///
/// `docs/input-plane-decisions.md` §2 ruled that SELECTING a Finder item
/// goes through the Finder's own `select item "X" of window "Y"` — and this
/// host still has no lane for `script` as an ACT (`MirrorActionDriver`
/// refuses `.finderSelect` by name, for that reason, unchanged by this
/// file). OPENING one is a different question with a shorter answer: an
/// `odoc` Apple Event addressed at the Finder's own process, carrying the
/// item's full HFS path, is exactly what a double-click already asks the
/// Finder to do to itself — no script, no OSA component, and `aesend` is
/// already the four-event lane declared for it
/// (`contract/asyncapi.yaml` `aesend`). This is that route, and only for
/// `open`; a name this cannot resolve is refused, never approximated by a
/// nearby verb.
///
/// ## What "out of view" means here
///
/// The click-point discipline is `FinderItems.clickPoint`'s own — an icon
/// scrolled out from under the window's visible field has no point to press,
/// and inventing one is how a click lands on the wrong file. The window's
/// CHROME (its rect and its scrollbars) still comes from the scene that was
/// last drawn — a resize between draw and this act is a real gap, and it is
/// the same gap `MirrorWindowResolver` already lives with for a window op.
/// What must never come from that scene is the ITEM'S position, and it
/// doesn't.
@MainActor
struct MirrorFolderItemsAim {
    /// One command, asked of the connected machine. Injected so a test can
    /// answer it without a socket — the same seam `MirrorWindowResolver`
    /// uses, for the same reason.
    typealias Ask = @MainActor (_ name: String,
                                _ args: [String: String]) async -> CommandResult

    let ask: Ask

    init(ask: @escaping Ask) {
        self.ask = ask
    }

    init(listener: GuestListener) {
        self.init { name, args in
            await withCheckedContinuation { continuation in
                listener.runCommand(name, args: args) {
                    continuation.resume(returning: $0)
                }
            }
        }
    }

    /// What became of one open.
    enum Outcome: Equatable {
        case dispatched(String)
        case refused(String)
        case unavailable(String)
    }

    /// Open one named item in one named Finder window.
    ///
    /// - Parameters:
    ///   - item: the item's name, as the Finder itself reports it.
    ///   - windowTitle: the folder window's title — a Finder folder window's
    ///     title IS its folder's name, which is what `window "Y"` matches.
    ///   - finderPSN: the scene's OWN "hi.lo" string for the Finder process
    ///     (`Scene.ProcessRef.psn`) — the address `aesend` sends to.
    ///   - chrome: the window's rect and controls, for the visibility check
    ///     ONLY. Its `items` are never read (see the header).
    func open(item: String, windowTitle: String, finderPSN: String,
             chrome: MirrorKit.Scene.Window) async -> Outcome {
        guard let serial = MirrorWindowResolver.serial(finderPSN) else {
            return .unavailable(
                "The scene reports the Finder's process as "
                    + "\"\(finderPSN)\", which is not a process serial this "
                    + "side can address. Nothing was asked of the Mac.")
        }

        /* The one re-fetch this whole file exists to force. Whatever
           `MirrorFolderItemsJoin` cached is not consulted here at all. */
        let walk = await ask("script",
                             ["source": FinderItems.windowsScript()])
        guard walk.ok else {
            let said = walk.error.map { "\($0.message) [\($0.code)]" }
                ?? "it refused without saying why"
            return .refused(
                "Opening \"\(item)\" needed a fresh position first, and the "
                    + "Mac would not answer: \(said)")
        }
        guard let output = MirrorFolderItemsJoin.scriptOutput(walk) else {
            return .unavailable(
                "The Mac's window walk carried no readable \"output\" row, "
                    + "so there is no fresh position to open \"\(item)\" "
                    + "from.")
        }
        let reports = FinderItems.parse(output)
        let named = reports.filter { $0.title == windowTitle }
        guard named.count == 1, let report = named.first else {
            return .unavailable(named.isEmpty
                ? "No Finder window titled \"\(windowTitle)\" answered the "
                    + "fresh walk — it may have closed since this was drawn. "
                    + "Nothing was opened."
                : "\(named.count) Finder windows are titled "
                    + "\"\(windowTitle)\" on the fresh walk, and this host "
                    + "cannot tell them apart by title alone — the same "
                    + "limit the Finder's own scripting terminology has. "
                    + "Nothing was opened.")
        }
        guard let placed = report.items.first(where: { $0.name == item })
        else {
            return .unavailable(
                "\"\(item)\" is not among \(windowTitle)'s items on the "
                    + "fresh walk — it may have moved, been renamed, or been "
                    + "removed since this was drawn. Nothing was opened.")
        }
        let fresh = MirrorKit.Scene.DesktopItem.make(
            name: placed.name, kind: "file", x: placed.x, y: placed.y,
            placed: true, alias: false, invisible: false)
        guard FinderItems.clickPoint(fresh, in: chrome) != nil else {
            return .refused(
                "\"\(item)\" is scrolled out of \(windowTitle)'s visible "
                    + "icon field on the fresh walk, so there is no point to "
                    + "open it from. Nothing was sent.")
        }
        guard !report.path.isEmpty else {
            return .unavailable(
                "The Finder did not report a folder path for "
                    + "\"\(windowTitle)\" on the fresh walk, so there is no "
                    + "HFS path to open \"\(item)\" at. Nothing was sent.")
        }
        /* The Finder's own `(item of window i) as text` already ends in a
           colon (`FinderItems`'s header measured it: "Macintosh HD:…:"), so
           this only adds one when a future reply ever omits it. */
        let path = report.path.hasSuffix(":")
            ? report.path + item : report.path + ":" + item

        let sent = await ask("aesend", [
            "event": "odoc",
            "serialHi": String(serial.hi),
            "serialLo": String(serial.lo),
            "path": path,
        ])
        guard sent.ok else {
            let said = sent.error.map { "\($0.message) [\($0.code)]" }
                ?? "it refused without saying why"
            return .refused("Opening \"\(item)\": \(said)")
        }
        return .dispatched(
            "\"\(item)\": an odoc event naming \(path) was sent to the "
                + "Finder. Whether it opened is a question for the next "
                + "scene.")
    }
}
