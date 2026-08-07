import SwiftUI
import MirrorKit

/// **Who owns a rectangle, decided once.**
///
/// This replaces five predicates that grew separately and answered
/// overlapping questions — `semanticOwnsDisplay`, `dialogItemOwnsDisplay`,
/// `Coverage`, `semanticSupersedesResource`, `displayableTitle`. They are
/// all still here; what changed is that they are now INPUTS to one ordered
/// resolution instead of five independent gates, each of which could be
/// right on its own and wrong beside the others. Both of this project's
/// 2026-08-06 render defects were that shape.
///
/// Every rectangle gets **(source, epoch, confidence)** and one rule
/// decides. Highest claim first:
///
/// 1. **Ink from the current epoch.** The machine drew it and we have the
///    drawing: text, primitives, and a composite that JOINED. Nothing beats
///    it, because nothing else is evidence of what the window looks like.
/// 2. **A semantic control that owns its display.** P2 carries enough to
///    draw the whole rectangle — a checkbox with a title, a popup with a
///    value, a list with cells.
/// 3. **Asset-pack art addressed BY IDENTITY.** Something named this
///    rectangle: a DITL row typed `icon`, a typed control. Never a size,
///    never a shape.
/// 4. **The marked unknown.** Styled once, in ``UnknownVisual`` — lane C
///    of this plan chose that look over real captures, and both renderers
///    go through it, so there is exactly one place for the decision to
///    live.
///
/// ## Rung 1 beats rung 2, and that is a deliberate reversal
///
/// The precedence used to run the other way: P2 first, P3 where P2 was
/// silent. That was written when the only thing P3 could offer for a
/// control was "somebody blitted 14×14 here", and it cost Date & Time its
/// date, its time, both group boxes and every field on 2026-08-06 — twenty
/// DITL rows silenced the drawing that was the only thing anyone knew about
/// those rectangles.
///
/// The reversal is safe because of what rung 1 now excludes: **an unjoined
/// blit is not ink.** A blit carries geometry and no pixels. Where it
/// joined, it IS the machine's drawing and outranks any description of it;
/// where it did not, it is not evidence at all and drops to rung 3 or 4,
/// which is where the old P2-first rule was really earning its keep.
///
/// ## What was deleted, and on what evidence
///
/// **Size-based blit classification.** The replay asserted "document icon"
/// for any near-square blit between 12 and 36 points, and "Platinum plate"
/// for anything roughly control-shaped. The first is a confident wrong
/// answer and sweep A found it four times in fifteen windows — Mouse's
/// three tracking pictures, Sherlock 2's nine channel buttons, the IE TLS
/// alert's stop sign, Set Time Zone's caution triangle — plus the Finder's
/// scroll arrows, which are 16×16 blits and were being painted as pages.
/// An icon-sized blit of unknown identity is an **unknown**.
///
/// The plate survives, and only where something NAMED the rectangle. That
/// is the whole change: the claim "this is a control" now rests on the
/// semantic plane saying so, not on the blit being 20 points tall.
///
/// ## What was NOT deleted, and why — read before deprecating it again
///
/// The guest's `now_content_blit_source` route 2 (`ext/src/now_content_logic.c`)
/// matches a blit to a hooked world by SHAPE, and plan 018 lists it as
/// contingently deprecated. **It must stay**, and this is not a judgement
/// call: `docs/toolbox-and-gworld.md` §6 measured that `LockPixels`
/// relocates the PixMap RECORD, not merely its pixels, so the pointer a
/// blit hands you is a snapshot of a moved block — `RecoverHandle` on it
/// fails and its `baseAddr` will not equal the one read later. Pointer
/// identity (route 1) measured FALSE on a purpose-built control. **What
/// survives relocation is shape.** Route 2 is not a size guess in disguise:
/// it demands the pixmap bounds, `rowBytes`, the owning port's rect and the
/// port version to agree four ways, and it REFUSES on a second claimant
/// rather than picking. Deleting it deletes the join.
///
/// See `docs/render-composition.md`, which owns this policy.
public struct ProvenanceLadder {

    /// The rungs, ordered. `Comparable` so a resolution reads as a
    /// comparison rather than as a chain of `if`s.
    public enum Rung: Int, Comparable, Sendable {
        case unknown = 0
        case namedArt = 1
        case semantics = 2
        case ink = 3

        public static func < (a: Rung, b: Rung) -> Bool {
            a.rawValue < b.rawValue
        }
    }

    /// What the semantic plane said is at a rectangle — the identity rung 3
    /// draws from. Deliberately coarse: the drawing stream cannot support
    /// finer, and a placeholder typed more precisely than its evidence is
    /// the rule this whole page exists to enforce.
    public enum NamedArt: Equatable, Sendable {
        /// A row the guest typed as an icon. It said an icon is there; it
        /// did not say WHICH, so the generic stub is the honest maximum.
        case icon
        /// A typed control. Drawn as an untyped Platinum plate — the shape
        /// a field, a button and a popup all share.
        case control
    }

    /// Rectangles a semantic row owns outright: it will draw the whole
    /// thing, so P3 underneath it is excluded. `semanticOwnsDisplay` and
    /// `dialogItemOwnsDisplay` are what fill this.
    public var owning: [CGRect]
    /// Rectangles something NAMED without drawing them.
    public var named: [(rect: CGRect, art: NamedArt)]
    /// Whether the display ops being replayed belong to the epoch this
    /// scene describes (``MirrorKit/DisplayEpoch``). When false the machine
    /// has moved past these pixels: they are still the last coherent frame
    /// and are still drawn, but they no longer outrank a semantic row, so a
    /// window mid-view-switch shows what P2 knows rather than what P3 drew
    /// for a view that is gone.
    public var inkIsCurrent: Bool

    public init(owning: [CGRect] = [],
                named: [(rect: CGRect, art: NamedArt)] = [],
                inkIsCurrent: Bool = true) {
        self.owning = owning
        self.named = named
        self.inkIsCurrent = inkIsCurrent
    }

    /// The strongest claim on a blit's destination rectangle, given that
    /// the blit did NOT join (a joined blit never reaches here — the join
    /// replaced it with the ops it revealed, which are ink).
    ///
    /// Containment, not intersection: a name covers a rectangle only if it
    /// covers all of it. A row that merely overlaps is describing something
    /// else nearby, and letting it claim the blit is how a hit rect two
    /// pixels wide came to speak for a window.
    public func owner(ofUnjoinedBlit frame: CGRect) -> Rung {
        art(at: frame) == nil ? .unknown : .namedArt
    }

    /// The art a named rectangle resolves to, or nil for the unknown.
    public func art(at frame: CGRect) -> NamedArt? {
        named.first { $0.rect.contains(frame) }?.art
    }
}
