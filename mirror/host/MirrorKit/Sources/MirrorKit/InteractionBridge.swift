import Foundation

/// **A plan, expressed in the older action vocabulary.**
///
/// The object model is the direction of travel; this exists so a driver
/// written against `MirrorAction` still works while it gets there. Every
/// plan that HAS an action form gets one; the two Finder-by-name cases do
/// not, and fall back to a positional click at the icon's own centre —
/// which is exactly what those drivers did before, so nothing regresses
/// and nothing silently improves either.
///
/// It takes the whole `Interaction` rather than just the plan because the
/// fallback needs the point, and the point lives with the gesture. That
/// asymmetry is the honest shape: a plan is what SHOULD happen, and the
/// interaction is what a person did.
public enum InteractionBridge {

    public static func actions(for plan: InteractionPlan,
                               interaction: Interaction) -> [MirrorAction] {
        switch plan {
        case .controlPart(let ref, let part, let mods):
            /* The part is the whole point of the semantic form, and a
               driver that cannot take one gets a press at the region the
               gesture landed on instead - the caller's availability check
               is what decides between them, not this. */
            return [.controlPart(ref: ref, part: part, mods: mods)]

        case .dialogItem:
            // The old action vocabulary has no Dialog Manager operation.
            // NOW's direct driver serves this typed plan itself; legacy
            // drivers must not collapse it into a generic coordinate click.
            return []

        case .windowAct(let ref, let act):
            return [.windowAct(ref: ref, act: act)]

        case .menuCommand(let id, let index, let left):
            return [.menuInvoke(menuID: id, itemIndex: index,
                                titleLeft: left)]

        case .keystroke(let code, let char, let mods):
            return [.key(code: code, char: char, mods: mods)]

        case .typeText(let text):
            return [.type(text: text)]

        case .setText(let ref, let text):
            return [.axdo(ref: ref, count: 1, mods: 0, text: text)]

        case .activateApp(let psn):
            return [.activate(psn: psn)]

        case .applicationVisibility:
            /* The old action vocabulary has no system Application-menu
               visibility operation. NOW's direct driver serves this typed
               plan through the guest; emitting menuInvoke would restore the
               route that reported success without changing the machine. */
            return []

        case .finderSelect, .finderOpen, .finderDeselect:
            /* No action case names a file. A driver that speaks to the
               Finder by name serves these itself; one that does not falls
               back to the icon's own centre, which is what it had. */
            guard case .finderItem(let item) = interaction.object else {
                if case .finderDeselect = plan,
                   case .click(_, let mods, let at) = interaction.gesture {
                    return [.click(x: at.x, y: at.y, count: 1, mods: mods)]
                }
                return []
            }
            if case .finderOpen = plan {
                return [.qmpDoubleClick(x: item.point.x, y: item.point.y)]
            }
            return [.click(x: item.point.x, y: item.point.y,
                           count: 1, mods: 0)]

        case .nothing, .unsupported:
            return []
        }
    }

    /// A short phrase for a status line: what was asked of what.
    public static func label(for interaction: Interaction) -> String {
        let subject = interaction.object.describedForAPerson
        switch interaction.gesture {
        case .click(let count, _, _):
            return count >= 2 ? "open \(subject)" : "click \(subject)"
        case .drag:
            switch interaction.object {
            case .window(let w) where w.part == .growBox:
                return "resize \(w.title)"
            case .window(let w) where w.part == .titleBar:
                return "move \(w.title)"
            default: return "drag \(subject)"
            }
        case .scroll(let notches, _):
            return "scroll \(subject) \(notches > 0 ? "down" : "up")"
        case .type(let text):
            return "type \"\(text)\""
        case .key(_, let char, let mods):
            let glyph = Character(UnicodeScalar(UInt8(clamping: char)))
            return mods & ActionModel.cmdKey != 0
                ? "⌘\(String(glyph).uppercased())"
                : "key \(glyph)"
        }
    }
}
