import Foundation
import MirrorKit

/// **Which glyphs in a render are the machine's and which are ours.**
///
/// The renderer substitutes, and until now it did so silently. Font id 0
/// is "the system font", which under the Appearance Manager on Mac OS
/// 8.5+ is **Charcoal**, and Charcoal ships TrueType-only — no
/// `bdat`/`bloc`, no NFNT strike anywhere on the guest to lift. So
/// `DisplayReplay.strike` fell back to Chicago. Chicago is wider. Where
/// an application clips its own text the extra width cuts the last glyph
/// off, and the render said "Use a Network Time Serve" over a machine
/// whose pixels said "Server".
///
/// That silence has been paid for once already: group-box frames
/// appeared to cross their own labels, three people read it as a chrome
/// defect, and it was Chicago overrunning a band the machine had sized
/// for a narrower face. A render drifting toward *plausible* rather than
/// *true*, with nothing on it that says which, is the exact failure the
/// rest of this arc names everywhere else.
///
/// **Substituting is an accepted product decision** (Michelle,
/// 2026-08-07: "our fonts are ok at this stage, im happy enough with
/// them"). Saying nothing about it is not. So this file adds no pixels
/// and changes none — it makes the substitution ANSWERABLE: what was
/// asked for, what was served, and whether the width a run was laid out
/// at came from the machine or from us.
///
/// **It is derived, never remembered**, and that is not decoration: the
/// pack gained a Charcoal rasterisation the day before this was written,
/// so a file that stated "we draw Chicago for the system font" as a
/// constant would have shipped false on arrival. It asks the renderer's
/// own mapping and the renderer's own rounding rule, and it says
/// whatever those say on the desk it is running on.

// MARK: - What the machine asked for

/// A QuickDraw font family id, as far as the id itself can say.
///
/// The three named cases are the ones the drawing stream's own contract
/// fixes: 0 and 1 are ROLES rather than families, and 3 is the one ROM
/// family this pack actually carries. **Every other id stays a number.**
/// That is deliberate and it is the rule the rest of this project calls
/// "never type a placeholder more precisely than the evidence allows":
/// font id 2002 draws the menu-bar clock, Appearance's "Current Theme:"
/// line and all 102 of Key Caps' key labels — every one of them a
/// system-font site, so it is almost certainly Charcoal under a
/// dynamically-assigned id — and ids at that magnitude are handed out by
/// the Font Manager at run time and are not stable across machines.
/// Mapping the number would be a guess dressed as a fact. It wants a
/// name from the guest, which the contract does not yet carry
/// (docs/open-issues.md, "the system font is Charcoal").
public enum RequestedFace: Equatable, Sendable {
    /// Font id 0 — "the system font". Under Appearance on Mac OS 8.5+,
    /// which is this project's whole guest range, that is Charcoal.
    case systemFont
    /// Font id 1 — `applFont`, which on a US Mac OS 9 system is Geneva.
    case applicationFont
    /// Font id 3 — Geneva by family number.
    case geneva
    /// Any other family id. The face has a name on the guest; we do not
    /// know it here, and the number is all this side may honestly say.
    case family(Int)

    public static func forID(_ id: Int) -> RequestedFace {
        switch id {
        case 0: return .systemFont
        case 1: return .applicationFont
        case 3: return .geneva
        default: return .family(id)
        }
    }

    /// The face the guest would name, where the id fixes one. `nil`
    /// where it does not — which is not the same as "no face".
    public var faceName: String? {
        switch self {
        case .systemFont: return "Charcoal"
        case .applicationFont, .geneva: return "Geneva"
        case .family: return nil
        }
    }

    public var described: String {
        switch self {
        case .systemFont: return "Charcoal (the system font, id 0)"
        case .applicationFont: return "Geneva (applFont, id 1)"
        case .geneva: return "Geneva (id 3)"
        case .family(let id): return "an unnamed family (id \(id))"
        }
    }
}

// MARK: - How far the strike we drew is from the one the machine used

/// The ladder, worst to best. Four states, and the third is the point of
/// this file.
///
/// **`substituted` is not `unknown`, and collapsing the two would throw
/// away the only useful half.** `unknown` is what this project says when
/// it could not establish something: a control whose kind no route
/// answered, a blit whose source world was never hooked. Nothing is
/// unestablished here. We know the machine asked for the system font, we
/// know that is Charcoal, we know Charcoal has no strike to lift, we
/// know we drew Chicago 12 instead, and we know the direction of the
/// error (Chicago is wider, so a clipped run loses its tail rather than
/// floating loose). A substitution is a DECISION we took with full
/// knowledge; `unknown` is a limit we hit. They want different repairs —
/// one wants a Charcoal rasterizer, the other wants evidence — and a
/// reader who cannot tell them apart cannot pick.
///
/// **It is also a second axis, not a fifth rung of
/// ``ProvenanceLadder``.** That ladder answers *who owns this
/// rectangle*, and for a text run the answer is always its top rung:
/// ink, from the machine, at the machine's own pen position. That
/// answer stays true of a substituted run and is the reason the
/// substitution was invisible — the rectangle really is the machine's
/// drawing. This says whose GLYPHS and whose WIDTH filled it, which the
/// ladder does not ask and should not be bent into asking.
public enum StrikeFidelity: String, Equatable, Sendable, CaseIterable {
    /// The machine's own face at the machine's own size. The only state
    /// in which the glyphs and the width are both the machine's.
    case exact
    /// Right face, nearest bundled size. The glyphs are the machine's;
    /// **the width is ours.** Chicago is the case that bites: the pack
    /// carries one strike, at 12, so every Chicago request answers at 12.
    case resized
    /// A face the pack does not carry, drawn in one it does. Both the
    /// glyphs and the width are ours, and we can name both sides.
    case substituted
    /// No strike at all — the caller falls back to the SwiftUI system
    /// font. This is the only state in which the width is not merely
    /// ours but unmeasured, because nothing here knows what that font
    /// will do.
    case unavailable

    /// Whether a run in this state was laid out at a width the machine
    /// did not choose. The question a clipped label actually asks.
    public var widthIsOurs: Bool { self != .exact }
}

// MARK: - One request, answered

/// What the renderer will draw a captured text op in, and how faithful
/// that is — computable without rendering a pixel and without the asset
/// pack being present.
@MainActor
public struct StrikeChoice: Equatable, Sendable {
    public let requested: RequestedFace
    /// The size the port asked for, after QuickDraw's own rule that
    /// `txSize` 0 means the port default of 12.
    public let requestedSize: Int
    /// The family we MEANT to answer with — the first of
    /// ``preferredFamilies(forID:)``.
    public let intendedFamily: String
    /// The family we actually answered with. Differs from
    /// ``intendedFamily`` only when the intended one has no strike on
    /// this desk and the declared fallback fired.
    public let servedFamily: String
    /// The bundled strike size, after ``FontBook/nearestSize(face:size:)``.
    /// `nil` when no family in the preference list has a strike at all.
    public let servedSize: Int?

    /// **The one place the family mapping lives**, in preference order.
    ///
    /// `DisplayReplay.strike` is derived from this rather than carrying
    /// a second copy of the switch. Two places that decide which face
    /// answers an id is precisely how a report comes to describe a
    /// render that is not the one on screen — a limit stated twice is
    /// this repository's most expensive recurring defect.
    ///
    /// Font 0 is the system font, which is Charcoal, and the pack now
    /// rasterises Charcoal from its own outlines. **Chicago behind it is
    /// the substitution this file exists to declare**: it fires on any
    /// desk whose pack predates that work, it is silent in the pixels,
    /// and Chicago is wider — so the run a Charcoal desk draws inside
    /// its clip a Chicago desk draws with the last glyph shorn off, and
    /// nothing on either screen says which one you are looking at.
    ///
    /// Geneva is the fallback for every family the pack does not carry,
    /// which is every family but those two.
    public static func preferredFamilies(forID id: Int) -> [String] {
        id == 0 ? ["charcoal", "chicago"] : ["geneva"]
    }

    public static func choice(font id: Int, size: Int) -> StrikeChoice {
        // `txSize` 0 means "the port's default size", which QuickDraw
        // resolves to 12; it is not a request for a zero-height strike.
        let wanted = size > 0 ? size : 12
        let families = preferredFamilies(forID: id)
        for family in families {
            if let size = FontBook.nearestSize(face: family, size: wanted) {
                return StrikeChoice(
                    requested: .forID(id), requestedSize: wanted,
                    intendedFamily: families[0], servedFamily: family,
                    servedSize: size)
            }
        }
        return StrikeChoice(
            requested: .forID(id), requestedSize: wanted,
            intendedFamily: families[0], servedFamily: families[0],
            servedSize: nil)
    }

    public var fidelity: StrikeFidelity {
        guard let servedSize else { return .unavailable }
        // The declared fallback fired: a face we can name, and did not draw.
        guard servedFamily == intendedFamily else { return .substituted }
        // An id whose face we cannot name is a face we did not draw
        // either — the pack has no strike for it and Geneva answered.
        guard let asked = requested.faceName,
              asked.lowercased() == servedFamily.lowercased() else {
            return .substituted
        }
        return servedSize == requestedSize ? .exact : .resized
    }

    /// One line a report can print, naming both sides. Never "unknown" —
    /// a substitution knows exactly what it did.
    public var described: String {
        let asked = "\(requested.described) at \(requestedSize)"
        guard let servedSize else {
            return "\(asked) → no bundled strike (drawn in the host's own "
                + "system font; its width is neither the machine's nor "
                + "measured here)"
        }
        let served = "\(servedFamily) \(servedSize)"
        switch fidelity {
        case .exact:
            return "\(asked) → \(served) (the machine's own strike)"
        case .resized:
            return "\(asked) → \(served) (right face, nearest bundled "
                + "size — this run's width is ours)"
        case .substituted:
            return "\(asked) → \(served) (SUBSTITUTED for "
                + "\(intendedFamily) — these glyphs and this width are "
                + "ours, not the machine's)"
        case .unavailable:
            return "\(asked) → nothing"
        }
    }
}

// MARK: - Saying so where a person is already looking

/// The declaration itself: the banner line, and the per-render tally.
@MainActor
public enum FontSubstitution {

    /// The face the guest's system font really is, on this project's
    /// guest range. Stated once, here, because the banner, the report
    /// and ``RequestedFace/faceName`` must not be able to disagree.
    public static let systemFaceName = "Charcoal"

    /// **The banner.** Sibling of ``AssetPack/bannerText`` and there for
    /// the same reason: a picture of another machine drawn from art that
    /// machine does not own is a CLAIM, and an unmarked one is the
    /// failure this project keeps paying for. It is deliberately NOT in
    /// `SceneView` — the render screenshots must stay pixel-comparable,
    /// and a legend painted into the picture would be the mirror talking
    /// about itself inside a picture of the machine.
    ///
    /// It is DERIVED, not remembered: it asks what the system font would
    /// actually be drawn in on this desk right now. So it says nothing
    /// on a desk whose pack rasterises Charcoal, it says so on a desk
    /// whose pack predates that, and it needs no edit either way. A
    /// hard-coded "we substitute Chicago" would have become a lie the
    /// day the Charcoal work landed — which was the day before this was
    /// written.
    ///
    /// Size 12 is the probe because it is the system font's own default
    /// and every corpus capture draws chrome at it; a desk that has
    /// Charcoal at all has it across 9–24.
    public static var bannerText: String? {
        let systemFont = StrikeChoice.choice(font: 0, size: 12)
        guard systemFont.fidelity == .substituted else { return nil }
        return "System-font text is drawn in "
            + "\(systemFont.servedFamily.capitalized): the guest's system "
            + "font is \(systemFaceName), which ships TrueType-only with "
            + "no NFNT strike to lift, and this asset pack carries no "
            + "rasterised \(systemFaceName) either. Accepted substitution "
            + "— but these glyphs and the widths they are laid out at are "
            + "ours, not the machine's, so a run the application clips "
            + "may lose its last glyph here and not there."
    }

    /// Every distinct face+size a captured op list will be drawn in,
    /// with how faithful each is — the report half of the declaration.
    ///
    /// Keyed and sorted so two runs of the same window produce the same
    /// text; a report that reorders itself cannot be diffed, and a
    /// report nobody can diff is one nobody checks.
    public static func choices(in ops: [DisplayOp]) -> [StrikeChoice] {
        var seen: [String: StrikeChoice] = [:]
        for op in ops where op.op == "text" {
            guard let text = op.text, !text.isEmpty else { continue }
            let c = StrikeChoice.choice(font: op.font ?? 3,
                                        size: op.size ?? 12)
            seen["\(op.font ?? 3)/\(c.requestedSize)"] = c
        }
        return seen.keys.sorted().compactMap { seen[$0] }
    }

    /// How many text runs each state accounts for. The count is what
    /// makes the tally readable as a proportion rather than a list of
    /// curiosities: 251 of 266 runs in one state is a different fact
    /// from one of 266.
    public static func tally(in ops: [DisplayOp]) -> [StrikeFidelity: Int] {
        var counts: [StrikeFidelity: Int] = [:]
        for op in ops where op.op == "text" {
            guard let text = op.text, !text.isEmpty else { continue }
            let c = StrikeChoice.choice(font: op.font ?? 3,
                                        size: op.size ?? 12)
            counts[c.fidelity, default: 0] += 1
        }
        return counts
    }

    /// The whole declaration for one window's ops, as text. Empty when
    /// the window drew no text at all — there is nothing to declare, and
    /// a report that says "0 substitutions" for a window with no words
    /// in it is noise that hides the windows that have some.
    public static func report(for ops: [DisplayOp]) -> String {
        let counts = tally(in: ops)
        let total = counts.values.reduce(0, +)
        guard total > 0 else { return "" }
        var lines: [String] = []
        let ours = counts.filter { $0.key.widthIsOurs }
            .values.reduce(0, +)
        lines.append("\(total) text run(s); \(ours) laid out at a width "
                     + "this host chose")
        for state in StrikeFidelity.allCases {
            guard let n = counts[state] else { continue }
            lines.append("  \(state.rawValue): \(n)")
        }
        for c in choices(in: ops) {
            lines.append("  \(c.described)")
        }
        return lines.joined(separator: "\n")
    }
}
