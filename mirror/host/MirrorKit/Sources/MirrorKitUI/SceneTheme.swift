import SwiftUI
import MirrorKit

/// The colours this render will use, and WHERE EACH ONE CAME FROM.
///
/// Two sources, never mixed silently. `meta.theme` is what the guest's own
/// Appearance Manager answered at capture time; `Platinum.*` is this side's
/// constant, correct for the shipped Platinum theme and nothing else. A
/// scene from a producer that does not ask, or from a machine that refused
/// a brush, falls back — and `provenance` says so per colour, so a sweep
/// can tell a rendered face that was asked for from one that was assumed.
///
/// WHY THE PROVENANCE IS PART OF THE TYPE. The whole defect being removed
/// here is a constant that looks right. A fallback that cannot be
/// distinguished from an answer reintroduces it one layer up: the render
/// would be just as wrong and the code would now claim to ask.
public struct SceneTheme: Equatable, Sendable {
    public enum Source: String, Equatable, Sendable {
        /// The guest named this colour.
        case machine
        /// The guest did not, and this side's Platinum constant stood in.
        case fallback
    }

    public var dialogFace: Color
    public var alertFace: Color
    public var documentFace: Color
    public var highlight: Color

    /// Per-colour, keyed by the same names as the wire.
    public var provenance: [String: Source]

    /// The screen depth the guest asked its brushes at, when it said. A
    /// colour compared against a screendump of a different depth is being
    /// compared against a different question.
    public var depth: Int?

    /// Everything from this side's constants. What a fixture with no
    /// `meta.theme` renders with, and what every path rendered with before
    /// the field existed.
    public static let platinum = SceneTheme(
        dialogFace: Platinum.dialogFace,
        alertFace: Platinum.alertFace,
        documentFace: Platinum.documentFace,
        highlight: Platinum.highlight,
        provenance: ["dialogBackground": .fallback,
                     "alertBackground": .fallback,
                     "documentBackground": .fallback,
                     "highlight": .fallback],
        depth: nil)

    public init(dialogFace: Color, alertFace: Color, documentFace: Color,
                highlight: Color, provenance: [String: Source],
                depth: Int?) {
        self.dialogFace = dialogFace
        self.alertFace = alertFace
        self.documentFace = documentFace
        self.highlight = highlight
        self.provenance = provenance
        self.depth = depth
    }

    /// Resolves a scene's declared theme against the fallbacks.
    public init(_ scene: MirrorKit.Scene) {
        self.init(scene.meta.theme)
    }

    public init(_ theme: MirrorKit.Scene.Theme?) {
        var provenance = SceneTheme.platinum.provenance
        /* One helper, and it returns rather than writing through an
           inout into the value being built - the first draft did both and
           tripped Swift's exclusivity check at runtime, which is a
           crashing test rather than a compile error. */
        func take(_ hex: String?, _ key: String,
                  else fallback: Color) -> Color {
            guard let color = SceneTheme.parse(hex) else { return fallback }
            provenance[key] = .machine
            return color
        }
        let dialog = take(theme?.dialogBackground, "dialogBackground",
                          else: Platinum.dialogFace)
        let alert = take(theme?.alertBackground, "alertBackground",
                         else: Platinum.alertFace)
        let document = take(theme?.documentBackground, "documentBackground",
                            else: Platinum.documentFace)
        let highlight = take(theme?.highlight, "highlight",
                             else: Platinum.highlight)
        self.init(dialogFace: dialog, alertFace: alert,
                  documentFace: document, highlight: highlight,
                  provenance: provenance, depth: theme?.depth)
    }

    /// `#RRGGBB` only. A malformed value is REFUSED to nil rather than
    /// coerced — a half-parsed colour is the one outcome worse than a
    /// fallback, because it would be published as `machine`.
    static func parse(_ hex: String?) -> Color? {
        guard var s = hex else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return Color(rgb: v)
    }

    /// The face a window with this `kind` was erased with.
    ///
    /// `kind` is the WindowRecord's own `windowKind`, read out of the
    /// machine. 2 is the Dialog Manager's, and a Dialog Manager window is
    /// erased with the dialog brush whether or not it has a title bar.
    /// Everything else — including application-defined kinds such as the
    /// Appearance control panel's 2000 — is a document window face, which
    /// is what `kThemeBrushDocumentWindowBackground` names. Before this
    /// method that second case was the literal white `Platinum.g0`, so a
    /// kind-2000 panel could only ever be white no matter what the theme
    /// said.
    public func face(forWindowKind kind: Int?) -> Color {
        kind == 2 ? dialogFace : documentFace
    }
}
