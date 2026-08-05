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
    let perform: (Interaction) -> Void
    /// The journal the broker writes into, so the reply can carry the same
    /// record the Mirror page shows rather than a second account of it.
    let journal: () -> MirrorOperationJournal?

    func drive(_ request: AgentIntegrationMirrorDriveRequest)
        -> AgentIntegrationMirrorDriveResult {
        guard request.isWellFormed else {
            return .init(unavailable: .init(
                code: "now-mirror-drive-invalid",
                message: "The Mirror drive request is not well formed"))
        }
        guard let scene = scene() else {
            return .init(unavailable: .init(
                code: "now-mirror-snapshot-unavailable",
                message: "The Mirror has published no scene to act against"))
        }
        let before = Set((journal()?.records ?? []).map(\.id))
        let interaction: Interaction
        switch resolve(request, in: scene) {
        case .resolved(let value): interaction = value
        case .refused(let refusal): return .init(unavailable: refusal)
        }
        perform(interaction)

        /* The broker appends synchronously inside `perform`, so a record
           that is going to exist exists now. Its absence is meaningful:
           this gesture took the direct path, which carries no typed
           postcondition and can never be confirmed by observation. Saying
           so is the difference between a caller polling once and a caller
           waiting forever for a settlement that cannot come. */
        guard let record = (journal()?.records ?? []).last(where: {
            !before.contains($0.id)
        }) else {
            return .init(operation: .init(
                id: "direct", outcome: "dispatched", reason: nil,
                settled: false, awaitsObservation: false))
        }
        return .init(operation: Self.projected(record))
    }

    static func projected(_ record: MirrorOperation)
        -> AgentIntegrationMirrorDriveOperation {
        .init(id: record.id, outcome: record.outcome.rawValue,
              reason: record.reason,
              settled: record.outcome.isTerminal,
              awaitsObservation: true)
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
            let shape = MirrorObject.Menu(
                id: menu.id, title: menu.title, left: menu.left,
                isApple: menu.apple)
            return .resolved(.init(
                object: .menuItem(.init(
                    menu: shape, index: item.index, title: item.title,
                    cmd: item.cmd, isEnabled: item.enabled,
                    isSeparator: item.separator)),
                gesture: .click(count: 1, mods: 0,
                                at: .init(x: menu.left, y: 0))))

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
                  + "\(id ?? "(unnamed)"). Read now_mirror_snapshot again; "
                  + "the machine may have moved on.")
    }
}
