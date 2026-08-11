import Foundation

/// What the host knows about a captured `rgn` op's actual SHAPE.
///
/// The content contract never sends region data — a region is unbounded in
/// size and the ring is the measured limit — so the host receives a
/// bounding box and, since 2026-08-06, one cheap discriminator riding in
/// the payload's already-zeroed `ext1`: the region's own `rgnSize`.
/// QuickDraw stores a rectangular region as the minimum 10-byte Region
/// record, so that one number separates the case where the box IS the
/// shape from the case where it is an approximation.
///
/// The third state is the point of the type. Before the discriminator
/// existed, every region op arrived as a box and the renderer drew a hard
/// rectangle for all of them — silently right for most and silently wrong
/// for the rest, with nothing in the data to tell which. `.unreported` is
/// what a resident that predates the rule produces, and it must never
/// collapse into `.rectangular`: a zero pretending to be an answer is
/// exactly what this contract refuses everywhere else.
public enum RegionShape: Equatable, Sendable {
    /// `rgnSize == 10`: the bounding box is the whole region.
    case rectangular
    /// `rgnSize > 10`: the box is an approximation of a larger shape,
    /// and the byte count says roughly how much of it is hidden.
    case irregular(bytes: Int)
    /// `ext1 == 0`: a resident older than the discriminator. The box may
    /// be exact or may not, and the honest report is that nobody asked.
    case unreported

    /// QuickDraw's minimum Region record — `sizeof(short) + sizeof(Rect)`.
    public static let rectangularSize = 10

    public init(_ op: DisplayOp) {
        self.init(rgnSize: op.ext?.first ?? 0)
    }

    public init(rgnSize: Int) {
        switch rgnSize {
        case 0: self = .unreported
        case ..<Self.rectangularSize: self = .unreported
        case Self.rectangularSize: self = .rectangular
        default: self = .irregular(bytes: rgnSize)
        }
    }

    /// True when the renderer's rectangle is the region, not a stand-in.
    public var boundsAreExact: Bool { self == .rectangular }

    /// How this op reads in the deferred-op inventory, or nil when the
    /// renderer's output is the whole truth.
    public var undrawnName: String? {
        switch self {
        case .rectangular: return nil
        case .irregular: return "rgn (bounds only)"
        case .unreported: return "rgn (shape unreported)"
        }
    }
}
