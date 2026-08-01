import Foundation
import NOWAgentIntegration

/*  Integrator note, 2026-07-31 — applied, and where.

    The mechanism landed on a branch that owned none of the panes it was
    written for, so for a day three views still decided for themselves. They
    no longer do. What each spends, so the next reader can find them:

    - `SoftwareModel.launchGate(_:)` → the Software page's Launch button.
      That is the reported defect closed: `isLaunchable` is only
      `!path.isEmpty`, so Launch was live on a system extension and the guest
      refused it after the round trip. **Reveal was left rule-free and must
      stay that way** — it opens nothing.
    - `ProcessesModel.bringToFrontGate(_:)` → the Processes page's Bring to
      Front. `isDrivable`/`isQuittable` are untouched: "this row sent no PSN"
      is a third fact about the listing and is not restated through here.
    - `DiagnosticsModel.gate(for:)` → each Diagnostics card's Run button, the
      capability axis only, over the `help` table that page already asked for
      (`commandNames:`), so no card costs a second `help`. The button used to
      be ABSENT on a verb the machine does not serve; it is now present and
      dark, because a control that vanishes moves the cards below it and
      cannot explain itself.

    Reached-ness is gated in `GuestItemGateWiringTests`; what a person still
    has to judge is docs/metal-and-ux-review.md §4c.                         */

/// **The second reason a control is dark, and it is not the first one.**
///
/// `GuestCapabilityGate` answers "can the Mac on the wire serve this". This
/// answers "does this action mean anything for THAT item" — and the two are
/// independent facts with different next actions for the person reading the
/// grey control. "Your Mac cannot stream" is answered by connecting the other
/// Mac; "an extension is not launched, it is loaded at startup" is answered by
/// not trying. One boolean for both would tell half the people the wrong
/// thing, and the half it misleads cannot tell which half they are in.
///
/// **Every fact here already exists in the product; none is invented.**
///
/// - A software item's kind is its Finder file type, which the guest already
///   sends (`SoftwareEntry.type`) and already enforces: asking it to launch a
///   file whose `fdType` is not `'APPL'` is refused with "not an application
///   (type ....)" — `now-guest-ppc/src/software/software.c`. So this is not a
///   new rule, it is the same rule stated before the round trip instead of
///   after it.
/// - A process's kind is the guest's own classification from `processMode`'s
///   `modeOnlyBackground` bit, which reaches the host as
///   `ProcessEntry.kind == "background"`
///   (`now-guest-ppc/src/processes/processes_module.c :: kind_of`). That file
///   is emphatic that the mode bit is the authority and the `'appe'` file type
///   is a guess, so nothing here reads a type code to decide what is faceless.
///
/// **Views must not ask these questions themselves.** `if entry.isExtension`
/// scattered across panes is the same anti-pattern as `if guest.isPPC`, one
/// axis over: the moment an action's applicability stops tracking the file
/// type, every copy of the check is wrong and no test knows where they are.
enum GuestItemKind: Equatable {
    /// A file the machine would launch, or a process with a face.
    case application
    /// The Finder. An application, and named separately because a person
    /// reads it as its own thing.
    case finder
    /// Faceless: no windows, no menu bar. The guest's own `modeOnlyBackground`
    /// classification, never a guess from a type code.
    case backgroundOnly
    /// A file the machine would not launch, carrying its Finder type when the
    /// machine sent one. Deliberately NOT called "extension": the fact the
    /// product has is "not an application", and an item in the Extensions
    /// folder that happens to be an 'APPL' is launchable.
    case notAnApplication(type: String?)
    /// The machine did not say. Absent, not a guess — and it must not disable
    /// anything, for the same reason `unsettled` does not.
    case unknown

    /// How to name it in a sentence a person reads.
    var description: String {
        switch self {
        case .application: return "an application"
        case .finder: return "the Finder"
        case .backgroundOnly: return "a background-only process"
        case .notAnApplication(let type):
            guard let type, !type.isEmpty else {
                return "not an application"
            }
            return "not an application (type \(type))"
        case .unknown: return "an item of an unstated kind"
        }
    }
}

/// One thing a person can ask of an item. Named per action rather than per
/// projection row because applicability is a property of the ACTION and the
/// item, and holds whichever Mac is attached — `launch` means nothing for an
/// extension on a Quadra and on a G3 alike.
enum GuestItemAction: Equatable {
    case launch
    case bringToFront
    case reveal
}

extension SoftwareEntry {
    /// What this catalog item is, from the type code the machine sent.
    ///
    /// Nil type is `unknown` and not "not an application": a responder that
    /// could not read a type has told us nothing, and turning that into a
    /// refusal would grey out real applications on any guest whose catalog
    /// walk left the field out.
    var itemKind: GuestItemKind {
        guard let type, !type.isEmpty else { return .unknown }
        return type == "APPL" ? .application : .notAnApplication(type: type)
    }
}

extension ProcessEntry {
    /// What this running process is, from the responder's own classification.
    var itemKind: GuestItemKind {
        switch kind {
        case "background": return .backgroundOnly
        case "finder": return .finder
        default: return .application
        }
    }
}

extension GuestCapabilityGate {
    /// Whether an action means anything for an item of this kind.
    ///
    /// Returns nil when it applies — including for every kind no rule names,
    /// which is the deliberate default. **A new action is applicable to
    /// everything until someone states otherwise**, so the extension
    /// enable/disable being designed elsewhere needs nothing here to be
    /// offered on an extension; and `reveal` is left rule-free on purpose,
    /// since it opens nothing and any item the machine can name can be shown
    /// in its own Finder.
    static func inapplicability(of action: GuestItemAction,
                                to kind: GuestItemKind,
                                named name: String) -> Decision? {
        let quoted = name.isEmpty ? "This item" : "“\(name)”"
        switch (action, kind) {
        case (.launch, .notAnApplication):
            /* The machine's own refusal, said before the round trip rather
               than after it. The second sentence is what keeps it from
               reading as a defect: the item is fine and so is the Mac. */
            return .inapplicable(
                "\(quoted) is \(kind.description). Extensions and control "
                + "panels are loaded by the system at startup rather than "
                + "launched, so there is nothing here to open.")
        case (.launch, .backgroundOnly), (.bringToFront, .backgroundOnly):
            return .inapplicable(
                "\(quoted) runs with no windows and no menu bar, so there is "
                + "nothing to bring forward.")
        case (.bringToFront, .notAnApplication):
            return .inapplicable(
                "\(quoted) is \(kind.description) and is not running as one, "
                + "so there is nothing to bring forward.")
        default:
            return nil
        }
    }

    /// **The whole decision for one control on one item**: what this action
    /// means for that item, then what the attached Mac can serve.
    ///
    /// Order matters and is stated rather than incidental. `noGuest` comes
    /// first because with nothing on the wire every control is dark for one
    /// reason and saying anything else is noise. Inapplicability comes next,
    /// because it holds whichever Mac is attached — telling someone their Mac
    /// cannot launch an extension would be true of every Mac ever made, and
    /// would send them to check the wrong thing.
    static func decide<Row: HostProjection>(
        _ row: Row.Type,
        performing action: GuestItemAction,
        on kind: GuestItemKind,
        named name: String,
        in evidence: GuestCapabilityEvidence
    ) -> Decision {
        let capability = decide(row, in: evidence)
        if case .noGuest = capability { return capability }
        if let inapplicable = inapplicability(of: action, to: kind,
                                              named: name) {
            return inapplicable
        }
        return capability
    }
}
