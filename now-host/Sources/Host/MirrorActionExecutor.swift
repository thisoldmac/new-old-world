import Foundation
import MirrorKit

/// Resolves a direct gesture against the exact immutable projection it was
/// drawn from. If this cannot mint a stable entity and observable
/// postcondition, the caller must keep the action non-green.
enum MirrorActionExecutor {
    /// These plans mutate entities whose success can only be established from
    /// a later guest observation. They must never fall through to the legacy
    /// dispatch-and-label path merely because the displayed scene lacks a
    /// stable identity.
    static func requiresTypedSettlement(for interaction: Interaction,
                                        plan: InteractionPlan) -> Bool {
        switch plan {
        case .activateApp, .activateWindow, .applicationVisibility,
             .openAppleMenuItem,
             .finderOpen:
            return true
        case .windowAct(_, let act):
            if case .close = act { return true }
            return false
        case .menuCommand:
            if case .menuItem(let item) = interaction.object {
                return item.title == "Workshop"
            }
            return false
        default:
            return false
        }
    }

    /// The items a scene publishes for a Finder container, or **nil when
    /// it has not read them**. The difference is the whole reason for the
    /// optional: an unread container cannot say an item is absent, and a
    /// caller that flattened nil to `[]` would refuse acts on the strength
    /// of a read that never happened.
    static func publishedItems(of container: InteractionPlan.FinderContainer,
                               in scene: MirrorKit.Scene)
        -> [MirrorKit.Scene.DesktopItem]? {
        switch container {
        case .desktop:
            return scene.desktopItems
        case .window(let title):
            return scene.windows.first { $0.title == title }?.items
        }
    }

    /// Whether opening this item raises its OWN application rather than a
    /// Finder window. Convenience over `ownApplicationName`, for the
    /// callers that only need the yes/no.
    static func opensAsItsOwnApplication(
        _ item: String,
        in container: InteractionPlan.FinderContainer,
        scene: MirrorKit.Scene) -> Bool? {
        ownApplicationName(item, in: container, scene: scene).map { _ in true }
    }

    /// The name of the process opening this item will raise, or **nil when
    /// the scene cannot say** — which is the answer far more often than it
    /// looks.
    ///
    /// Only a positive signal moves the prediction, because the cost of
    /// being wrong is symmetric (a 15 s timeout either way) and the cost
    /// of being wrong about something that used to work is not:
    ///
    /// - The Finder's own `kind` reaches us reduced to four words
    ///   (`NOWMirrorSource.parseIcons`), and **a control panel is none of
    ///   them** — it arrives as a plain `file`. So kind alone cannot
    ///   answer the case this exists for.
    /// - `type` can: `APPL` and `appe` are the Finder's file types for an
    ///   application and a background-only one, and `cdev` is a control
    ///   panel. Those three, and the Finder calling something an
    ///   application in its own words, are the whole positive set.
    /// - **An alias reports its own kind and never its target's**, so an
    ///   alias to a folder and an alias to a control panel cannot be told
    ///   apart from the alias file alone. They are told apart from
    ///   `aliasTarget`, when the producer resolved one: the target is
    ///   classified by the SAME two rules, and the name that comes back
    ///   is the target's, because a process is named after the
    ///   application and not after whatever the alias was renamed to.
    ///   An unresolved alias stays unknown, exactly as before.
    /// - Everything else — documents, the Trash, an item this scene never
    ///   read — stays unknown and keeps the Finder-window prediction it
    ///   has always had. For a document that prediction is still wrong;
    ///   it is not wrong in a NEW way, and nothing measured says what the
    ///   right one is.
    ///
    /// The alias leg is what closes the false negative sweep A priced:
    /// `open "Mail"` reported **timedOut after 18 s having worked**,
    /// because the desktop's `Mail` is an alias, an alias was
    /// unclassifiable, and unclassifiable predicted a Finder window
    /// titled `Mail` that no Finder ever makes. (The window Mail raises
    /// having no title is a second, separate defect: the prediction named
    /// the wrong OWNER, so a titled window would not have matched it
    /// either.) Measured on the emulator 2026-08-07: the alias's original
    /// is an `APPL` named `Mail`, and opening it puts a process named
    /// `Mail` at the front.
    static func ownApplicationName(
        _ item: String,
        in container: InteractionPlan.FinderContainer,
        scene: MirrorKit.Scene) -> String? {
        guard let entry = publishedItems(of: container, in: scene)?
            .first(where: { $0.name == item }) else {
            return nil
        }
        if entry.alias {
            guard let target = entry.aliasTarget else { return nil }
            return isApplication(kind: target.kind, type: target.type)
                ? target.name : nil
        }
        return isApplication(kind: entry.kind, type: entry.type)
            ? item : nil
    }

    /// What the Finder will call the window it opens, when it opens one.
    ///
    /// Almost always the item's own name — except for an alias, where the
    /// Finder titles the window after the TARGET. An alias named `Docs`
    /// pointing at `Documents` opens a window called `Documents`, so
    /// predicting `Docs` is a postcondition that can never match. Only a
    /// RESOLVED alias moves this; an unresolved one keeps the item's name,
    /// which is the answer it has always had.
    static func finderWindowTitle(
        for item: String,
        in container: InteractionPlan.FinderContainer,
        scene: MirrorKit.Scene) -> String {
        guard let entry = publishedItems(of: container, in: scene)?
            .first(where: { $0.name == item }), entry.alias,
              let target = entry.aliasTarget else {
            return item
        }
        return target.name
    }

    /// The whole positive set, in one place because the alias leg and the
    /// plain leg must not drift into two answers for one question.
    ///
    /// - The Finder's own `kind` reaches us reduced to four words, and
    ///   `application` is the only one of them that settles this.
    /// - `type` settles the rest: `APPL` and `appe` are an application
    ///   and a background-only one, `cdev` is a control panel.
    private static func isApplication(kind: String, type: String?) -> Bool {
        if kind == "application" { return true }
        switch type {
        case "APPL", "appe", "cdev": return true
        default: return false
        }
    }

    @MainActor
    /// `source` is WHICH FACE drove this, and it was hardcoded to `.human`
    /// until 2026-08-05 — so every act an agent drove was recorded as a
    /// person's. That reading is what the journal is for, and it is the
    /// only thing that can tell a hand-driven act from an MCP-driven one
    /// after the fact.
    static func operation(for interaction: Interaction,
                          plan: InteractionPlan,
                          engine: MirrorStateEngine,
                          source: MirrorOperationSource = .human,
                          id: String = UUID().uuidString.lowercased(),
                          at date: Date = Date()) -> MirrorOperation? {
        guard let snapshot = engine.snapshot, let replica = engine.replica else {
            return nil
        }

        func process(_ psn: String) -> MirrorProcessIdentity? {
            replica.applications.values.first { $0.app.psn == psn }?.identity
        }
        func namedProcess(_ name: String) -> MirrorProcessIdentity? {
            replica.applications.values.first { $0.app.name == name }?.identity
        }
        func window(_ ref: String) -> MirrorWindowIdentity? {
            replica.windows.values.first { $0.window.ref == ref }?.identity
        }
        func make(target: MirrorEntityIdentity,
                  postcondition: MirrorOperationPostcondition)
            -> MirrorOperation {
            .init(id: id, source: source,
                  displayedSnapshotID: snapshot.id,
                  displayedSequence: snapshot.sequence,
                  target: target, postcondition: postcondition,
                  enqueuedAt: date)
        }
        func presentOrCreated(owner: MirrorProcessIdentity, title: String)
            -> MirrorOperation {
            if let existing = replica.windows.values.first(where: {
                $0.identity.process == owner && $0.window.title == title
            })?.identity {
                return make(target: .window(existing),
                            postcondition: .windowFront(existing))
            }
            return make(target: .process(owner), postcondition:
                .windowNamedPresent(owner: owner, title: title))
        }

        switch plan {
        case .activateApp(let psn):
            guard let identity = process(psn) else { return nil }
            return make(target: .process(identity),
                        postcondition: .processFront(identity))
        case .activateWindow(_, let ref):
            guard let identity = window(ref) else { return nil }
            return make(target: .window(identity),
                        postcondition: .windowFront(identity))
        case .applicationVisibility(let visibility):
            switch visibility {
            case .hide(let psn, let incarnation, _, _, _, _):
                guard let identity = process(psn),
                      incarnation == nil
                        || identity.incarnation == incarnation else {
                    return nil
                }
                return make(target: .process(identity),
                            postcondition: .processVisibility([
                                identity: false,
                            ]))
            case .hideOthers(let psn, let incarnation, _, _, _, _):
                guard let identity = process(psn),
                      incarnation == nil
                        || identity.incarnation == incarnation else {
                    return nil
                }
                let expected = Dictionary(uniqueKeysWithValues:
                    replica.applications.keys.map {
                        ($0, $0 == identity)
                    })
                return make(target: .process(identity),
                            postcondition: .processVisibility(expected))
            case .showAll:
                guard let front = replica.applications.values.first(where: {
                    $0.app.front
                })?.identity else { return nil }
                let expected = Dictionary(uniqueKeysWithValues:
                    replica.applications.keys.map { ($0, true) })
                return make(target: .process(front),
                            postcondition: .processVisibility(expected))
            }
        case .openAppleMenuItem(let name):
            guard let front = replica.applications.values.first(where: {
                $0.app.front
            })?.identity else { return nil }
            return make(target: .process(front),
                        postcondition: .processNamedPresent(name))
        case .windowAct(let ref, let act):
            guard case .close = act, let identity = window(ref) else {
                return nil
            }
            return make(target: .window(identity),
                        postcondition: .windowAbsent(identity))
        case .finderOpen(let item, let container):
            /* **A Finder-open does not always make a Finder window.** This
               predicted one for everything, and a control panel opens as
               its OWN application — a snapshot taken while Date & Time was
               up shows that window owned by a process named `Date & Time`,
               not by the Finder. The postcondition could never match, so
               every panel open burned its whole 15 s timeout HAVING
               WORKED, and because the mutation FIFO is one lane those
               timeouts stacked into waits of up to 51.8 s behind it
               (Michelle's 2026-08-05 drive).

               The shape for that is not new: `openAppleMenuItem` already
               predicts `processNamedPresent`, and opening Date & Time from
               the Apple menu's Control Panels is the same event as opening
               it from a Finder window. This case was the outlier. */
            guard let finder = namedProcess("Finder") else { return nil }
            if let process = ownApplicationName(item, in: container,
                                                scene: snapshot.scene) {
                return make(target: .process(finder),
                            postcondition: .processNamedPresent(process))
            }
            return presentOrCreated(
                owner: finder,
                title: finderWindowTitle(for: item, in: container,
                                         scene: snapshot.scene))
        case .menuCommand:
            guard case .menuItem(let item) = interaction.object,
                  item.title == "Workshop",
                  let front = replica.applications.values.first(where: {
                      $0.app.front
                  })?.identity else { return nil }
            return presentOrCreated(owner: front, title: "New Old World")
        default:
            return nil
        }
    }
}
