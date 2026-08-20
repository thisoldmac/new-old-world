import Foundation
import MirrorKit
import NOWAgentIntegration

/// **The mutation half of "two clients, one state engine".**
///
/// A call names an object the snapshot already published, this turns it
/// into the same `Interaction` a gesture produces, and hands it to
/// `NOWMirrorSource.perform` — the identical entry point the Mirror
/// window's click path uses. Everything downstream is therefore shared:
/// `MirrorActionExecutor` decides the plan, the broker serialises it, the
/// typed postcondition settles it from a later observation, and the act
/// clocks measure it.
///
/// It resolves against the CURRENT scene rather than trusting the caller's
/// description of one. An agent may name a window that has since closed;
/// that is a refusal with a reason, not a positional guess.
@MainActor
struct MirrorDriveService {
    let scene: () -> MirrorKit.Scene?
    /// Says which of its four endings the act reached. This used to answer
    /// `String?` and everything but a refusal came back `nil`, so the two
    /// endings a headless caller most needs to tell apart — *brokered,
    /// later observation is coming* and *direct, only dispatch settles* — were
    /// the same value here.
    let perform: (Interaction) -> MirrorPerformDisposition
    /// The journal the broker writes into, so the reply can carry the same
    /// record the Mirror page shows rather than a second account of it.
    let journal: () -> MirrorOperationJournal?
    /// Abandon the lane, answering how many acts it ended. The same call
    /// the Mirror window's cancel button makes.
    let cancel: () -> Int

    func drive(_ request: AgentIntegrationMirrorDriveRequest)
        -> AgentIntegrationMirrorDriveResult {
        guard request.isWellFormed else {
            return .init(unavailable: .init(
                code: "now-mirror-drive-invalid",
                message: "The Mirror drive request is not well formed"))
        }
        /* BEFORE the scene guard, deliberately: a cancel acts on the
           host's own lane, and the wedged guest it exists for is exactly
           the one publishing no scene. Gating it on a snapshot would make
           the escape hatch unreachable from the situation it escapes. */
        if request.gesture == .cancel {
            let ended = cancel()
            return .init(operation: .init(
                id: "cancel", outcome: "cancelled",
                reason: ended == 0
                    ? "nothing was waiting"
                    : "cancelled \(ended) act" + (ended == 1 ? "" : "s")
                        + "; each journal record says whether anything "
                        + "was sent",
                settled: true, awaitsObservation: false))
        }
        guard let scene = scene() else {
            return .init(unavailable: .init(
                code: "now-mirror-snapshot-unavailable",
                message: "The Mirror has published no scene to act against"))
        }
        let interaction: Interaction
        switch resolve(request, in: scene) {
        case .resolved(let value): interaction = value
        case .refused(let refusal): return .init(unavailable: refusal)
        }
        /* **Every one of these used to be inferred, and two of the
           inferences were wrong.** The old code asked `perform` for a
           refusal sentence, then diffed the journal, and read "no new
           record" as "took the direct path". That signal is produced by
           three different endings:

           - a refusal — measured live 2026-08-05 against a guest whose
             interaction plane had never armed: the host logged `NOT
             DISPATCHED: Interaction policy is off` and told MCP the act
             `dispatched`;
           - a formerly HELD act, waiting for the observation in flight —
             measured the same day: a `finderOpen` was answered `id:
             "direct"`, which says *nothing will ever settle this*, and it
             settled `confirmed` from observation a few seconds later;
           - and the direct path itself, the only one the reading was
             ever true of.

           `perform` knows which. Ask it. */
        switch perform(interaction) {
        case .refused(let refusal):
            return .init(operation: .init(
                id: "not-dispatched", outcome: "refused", reason: refusal,
                settled: true, awaitsObservation: false))

        case .direct(let id):
            guard let record = journal()?.operation(id: id) else {
                return .init(operation: .init(
                    id: id, outcome: "queued", reason: nil,
                    settled: false, awaitsObservation: false))
            }
            return .init(operation: Self.projected(record))

        case .brokered(let id):
            /* By id, not by diffing the journal for something that looks
               like what we asked for. The broker appended synchronously
               inside `perform`, so it is there. */
            guard let record = (journal()?.records ?? []).first(where: {
                $0.id == id
            }) else {
                return .init(operation: .init(
                    id: id, outcome: "queued", reason: nil,
                    settled: false, awaitsObservation: true))
            }
            return .init(operation: Self.projected(record))
        }
    }

    static func projected(_ record: MirrorOperation)
        -> AgentIntegrationMirrorDriveOperation {
        .init(id: record.id, outcome: record.outcome.rawValue,
              reason: record.reason,
              settled: record.outcome.isTerminal,
              awaitsObservation: record.postcondition != nil)
    }

    /// Swift's `Result` needs its failure to be an `Error`, and this
    /// refusal is a value the caller renders rather than something thrown.
    enum Resolution {
        case resolved(Interaction)
        case refused(AgentIntegrationUnavailable)
    }

    // MARK: - resolution

    private func resolve(_ request: AgentIntegrationMirrorDriveRequest,
                         in scene: MirrorKit.Scene)
        -> Resolution {
        switch request.gesture {
        case .select, .close, .zoom:
            guard let window = window(request.entityID, in: scene) else {
                return .refused(missing("window", request.entityID))
            }
            let part: MirrorObject.WindowPart
            switch request.gesture {
            case .close: part = .closeBox
            case .zoom: part = .zoomBox
            default: part = .titleBar
            }
            return .resolved(.init(
                object: .window(object(window, part: part)),
                gesture: .click(count: 1, mods: request.modifiers ?? 0,
                                at: .init(x: window.rect.l,
                                          y: window.rect.t))))

        case .activate:
            guard let app = app(request.entityID, in: scene) else {
                return .refused(missing("process", request.entityID))
            }
            return .resolved(.init(
                object: .app(app),
                gesture: .click(count: 1, mods: 0, at: .init(x: 0, y: 0))))

        case .menuItem:
            guard let menu = scene.menubar?.menus.first(where: {
                $0.id == request.menuID
            }), let item = menu.items.first(where: {
                $0.index == request.itemIndex
            }) else {
                return .refused(.init(
                    code: "now-mirror-drive-no-such-menu-item",
                    message: "The published menu bar has no menu "
                        + "\(request.menuID ?? 0) item "
                        + "\(request.itemIndex ?? 0)"))
            }
            /* WHERE THE TITLE SITS, OR NO ACT. This number is the
               identity check a menu press is guarded by: the resident
               answers a MenuSelect at that point and no other, so a
               substituted one does not miss - it answers somebody
               else's press. The scene builder used to substitute 0 here,
               which arms four pixels in, on the Apple menu. */
            guard let left = menu.left else {
                return .refused(.init(
                    code: "now-mirror-drive-menu-unplaced",
                    message: "The published menu bar does not say where "
                        + "menu \(request.menuID ?? 0)'s title is, and "
                        + "that position is what tells this act's press "
                        + "from the person's at the machine. Read "
                        + "now_semantic_ui_snapshot again: a menu bar that "
                        + "places its menus can be pressed."))
            }
            let shape = MirrorObject.Menu(
                id: menu.id, title: menu.title, left: left,
                isApple: menu.apple)
            return .resolved(.init(
                object: .menuItem(.init(
                    menu: shape, index: item.index, title: item.title,
                    cmd: item.cmd, isEnabled: item.enabled,
                    isSeparator: item.separator,
                    isAppleMenuItemsEntry:
                        ObjectResolver.isAppleMenuItemsEntry(item,
                                                             in: menu))),
                gesture: .click(count: 1, mods: 0,
                                at: .init(x: left, y: 0))))

        case .hide, .hideOthers, .showAll:
            guard let front = scene.processes?.first(where: \.front) else {
                return .refused(.init(
                    code: "now-mirror-drive-no-front-process",
                    message: "No process is front in the published scene"))
            }
            let frontApp = MirrorObject.App(
                psn: front.psn, name: front.name, isFront: true,
                incarnation: front.incarnation)
            let kind: MirrorObject.ApplicationMenuAction.Kind
            let title: String
            switch request.gesture {
            case .hide:
                kind = .hide(frontApp); title = "Hide \(front.name)"
            case .hideOthers:
                kind = .hideOthers(except: frontApp); title = "Hide Others"
            default:
                kind = .showAll; title = "Show All"
            }
            return .resolved(.init(
                object: .applicationMenuAction(.init(
                    title: title, isEnabled: true, kind: kind,
                    menu: .init(id: -16489, title: "", left: 0,
                                isApple: false),
                    index: 1)),
                gesture: .click(count: 1, mods: 0, at: .init(x: 0, y: 0))))

        case .key:
            return .resolved(.init(
                object: .desktop(nil),
                gesture: .key(code: request.keyCode ?? 0,
                              char: request.keyChar ?? 0,
                              mods: request.modifiers ?? 0)))

        case .type:
            return .resolved(.init(
                object: .desktop(nil),
                gesture: .type(request.text ?? "")))

        case .finderDeselect:
            return .resolved(.init(
                object: .desktop(nil),
                gesture: .click(count: 1, mods: 0, at: .init(x: 0, y: 0))))

        case .dialogItem:
            guard let window = window(request.entityID, in: scene) else {
                return .refused(missing("window", request.entityID))
            }
            let number = request.itemIndex ?? 0
            guard let item = (window.dialogItems ?? []).first(where: {
                $0.number == number
            }) else {
                return .refused(.init(
                    code: "now-mirror-drive-no-such-dialog-item",
                    message: "That window publishes no dialog item "
                        + "\(number). Read now_semantic_ui_snapshot: its "
                        + "surfaces list every item this window carries."))
            }
            return .resolved(.init(
                object: .dialogItem(.init(
                    number: item.number, ref: item.ref, title: item.title,
                    rect: item.rect, isEnabled: item.enabled,
                    window: object(window, part: .content),
                    semanticKind: item.semantic.kind,
                    semanticAction: item.semantic.action,
                    isSemanticallyActionable: item.enabled)),
                gesture: .click(count: 1, mods: 0,
                                at: .init(x: item.rect.l, y: item.rect.t))))

        case .appleMenuItem:
            /* An Apple Menu Items entry is not a separate object: it is a
               row of the Apple menu, and the interaction policy is what
               routes it to the guest Finder rather than to MenuSelect. So
               resolve it out of the PUBLISHED menu instead of fabricating
               one — a name that is not on the machine's Apple menu should
               refuse here rather than reach the guest as a script naming
               something that does not exist. */
            guard let apple = scene.menubar?.menus.first(where: \.apple)
            else {
                return .refused(.init(
                    code: "now-mirror-drive-no-apple-menu",
                    message: "The published menu bar carries no Apple menu"))
            }
            guard let row = apple.items.first(where: {
                $0.title == request.itemName
            }) else {
                return .refused(.init(
                    code: "now-mirror-drive-no-such-apple-item",
                    message: "The Apple menu has no row named "
                        + "\(request.itemName ?? "(unnamed)")"))
            }
            /* The Apple menu is the one this substitution aimed AT - an
               absent left resolved to 0, four pixels off its own title -
               so it is the last row that should be allowed to run on a
               guess. Most of its entries route to the Finder rather than
               to MenuSelect, and those would not care; the ones that
               remain are menu presses like any other. */
            guard let appleLeft = apple.left else {
                return .refused(.init(
                    code: "now-mirror-drive-menu-unplaced",
                    message: "The published menu bar does not say where "
                        + "the Apple menu's title is, and that position "
                        + "is what tells this act's press from the "
                        + "person's at the machine."))
            }
            return .resolved(.init(
                object: .menuItem(.init(
                    menu: .init(id: apple.id, title: apple.title,
                                left: appleLeft, isApple: true),
                    index: row.index, title: row.title, cmd: row.cmd,
                    isEnabled: row.enabled, isSeparator: row.separator,
                    isAppleMenuItemsEntry:
                        ObjectResolver.isAppleMenuItemsEntry(row,
                                                             in: apple))),
                gesture: .click(count: 1, mods: 0,
                                at: .init(x: appleLeft, y: 0))))

        case .finderOpen, .finderSelect:
            let container = request.container.flatMap {
                $0 == "desktop" ? nil : window($0, in: scene)
            }
            if let named = request.container, named != "desktop",
               container == nil {
                return .refused(missing("window", named))
            }
            let count = request.gesture == .finderOpen ? 2 : 1
            return .resolved(.init(
                object: .finderItem(.init(
                    name: request.itemName ?? "",
                    container: container.map { object($0, part: .content) },
                    point: .init(x: 0, y: 0))),
                gesture: .click(count: count, mods: 0,
                                at: .init(x: 0, y: 0))))

        case .cancel:
            /* Served before resolution ever runs — `drive` short-circuits
               it ahead of the scene guard. Stated rather than defaulted so
               a reordering that made a cancel reach here is a named
               refusal, not a positional guess. */
            return .refused(.init(
                code: "now-mirror-drive-cancel-misrouted",
                message: "A cancel acts on the host's lane and is served "
                    + "before resolution; it cannot name an entity"))
        }
    }

    private func window(_ id: String?, in scene: MirrorKit.Scene)
        -> MirrorKit.Scene.Window? {
        guard let id else { return nil }
        return scene.windows.first {
            MirrorEntityID.window($0, in: scene) == id || $0.id == id
        }
    }

    private func app(_ id: String?, in scene: MirrorKit.Scene)
        -> MirrorObject.App? {
        guard let id else { return nil }
        let wanted = id.hasPrefix("process:")
            ? String(id.dropFirst("process:".count)) : id
        guard let process = (scene.processes ?? []).first(where: {
            $0.incarnation == wanted || $0.psn == wanted
        }) else { return nil }
        return .init(psn: process.psn, name: process.name,
                     isFront: process.front,
                     incarnation: process.incarnation)
    }

    private func object(_ window: MirrorKit.Scene.Window,
                        part: MirrorObject.WindowPart)
        -> MirrorObject.Window {
        .init(id: window.id, ref: window.ref, psn: window.psn,
              title: window.title, rect: window.rect, kind: window.kind,
              isFront: window.front, part: part)
    }

    private func missing(_ kind: String, _ id: String?)
        -> AgentIntegrationUnavailable {
        .init(code: "now-mirror-drive-no-such-\(kind)",
              message: "The published Mirror snapshot has no \(kind) "
                  + "\(id ?? "(unnamed)"). Read now_semantic_ui_snapshot again; "
                  + "the machine may have moved on.")
    }
}
