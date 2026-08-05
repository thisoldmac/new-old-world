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
        case .finderOpen(let item, _):
            guard let finder = namedProcess("Finder") else { return nil }
            return presentOrCreated(owner: finder, title: item)
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
