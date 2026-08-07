import Foundation
import Combine

/// How much of the guest's screen a point on this Mac's screen is worth.
///
/// **Every numbered stop is a power of two on purpose.** The mirror is a
/// picture of a machine whose whole visual language is one-pixel rules —
/// a Platinum frame, a divider, the hairline under a menu title. At 50,
/// 100, 200 and 400 percent, nearest-neighbour sampling maps each guest
/// pixel onto a whole number of host pixels, so a 1px line becomes a
/// crisp 2px line rather than a two-pixel smear. A stop like 150% cannot
/// do that for any sampling mode, which is why there isn't one.
///
/// `fit` is the exception and is allowed to be fractional: it exists so
/// the whole desktop is visible in whatever box it has been given, and a
/// person choosing it has already chosen "all of it" over "exactly".
enum MirrorZoom: String, CaseIterable, Identifiable, Sendable {
    case fit
    case half
    case actual
    case double
    case quadruple

    var id: String { rawValue }

    /// The multiplier, or nil for `fit` — which has no fixed number
    /// because it is whatever the container happens to be.
    var factor: CGFloat? {
        switch self {
        case .fit: return nil
        case .half: return 0.5
        case .actual: return 1
        case .double: return 2
        case .quadruple: return 4
        }
    }

    var label: String {
        switch self {
        case .fit: return "Fit"
        case .half: return "50%"
        case .actual: return "100%"
        case .double: return "200%"
        case .quadruple: return "400%"
        }
    }
}

/// **Where the Mirror is shown, and at what size.**
///
/// One of the two axes the Mirror now has, and deliberately not the other
/// one. This says *where you can see it*; `MirrorRunControl` says
/// *whether it is running*. They were one thing while a window implied a
/// poll, and separating them is the whole point: an agent driving the
/// Mirror over MCP needs the poll and has no opinion about windows, and a
/// person closing a window is saying something about their screen rather
/// than about the classic Mac.
///
/// Persisted through the same `UserDefaults` `HostAppState` already
/// holds, so `NOW_PREFS_SUFFIX` scoping comes free — two host processes
/// on one Mac do not overwrite each other's answer.
/// `SidebarPreferences` is the pattern this follows, including
/// sanitisation as a pure static so the rule is testable without a suite.
@MainActor
final class MirrorPresentation: ObservableObject {

    /// Shown in its own window rather than in the module's pane.
    @Published var isDetached: Bool {
        didSet { defaults.set(isDetached, forKey: Self.detachedKey) }
    }

    /// How much of the guest's screen one host point is worth.
    @Published var zoom: MirrorZoom {
        didSet { defaults.set(zoom.rawValue, forKey: Self.zoomKey) }
    }

    private let defaults: UserDefaults
    private static let detachedKey = "mirrorDetached"
    private static let zoomKey = "mirrorZoom"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isDetached = defaults.bool(forKey: Self.detachedKey)
        zoom = Self.sanitised(defaults.string(forKey: Self.zoomKey))
    }

    /// A stored zoom made whole. Pure and static so the rule — and in
    /// particular *what an unreadable stored value means* — is testable
    /// without a defaults suite.
    ///
    /// An absent or unrecognised value is `fit` rather than 100%, and
    /// that is the deliberate half: an 832×624 guest at 100% does not fit
    /// the main window's default detail column, so a first run that
    /// defaulted to `actual` would greet a person with a scrollbar
    /// instead of a Macintosh.
    static func sanitised(_ stored: String?) -> MirrorZoom {
        stored.flatMap(MirrorZoom.init(rawValue:)) ?? .fit
    }
}
