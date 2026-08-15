import AppKit
import Combine
import Foundation

/* MirrorSurfaceMode is gone, and the arming lesson it carried moved to
   `NOWMirrorSource.armedPlanes`. Screen-edge Continuity is its own module
   now: it arms no Mirror planes at all — its guest intake claims its one
   plane on its own wire, and the 2026-08-13 measurement that every extra
   armed plane was paid for by the Macintosh and read by nobody is exactly
   why the module split removed the mode rather than keeping a narrowing
   enum for it. */

/* The arrangement is sized by INTENT, not by a number. A numeric zoom asked
   a person to solve "which of 50/100/200/400 makes my 640x480 guest meet the
   side of this display", which has no right answer on most arrangements and
   a different one on every host. The two states below are the only two
   answers anybody wanted: leave it true-size, or make it meet the edge. */
enum GuestDisplayScaleMode: String, CaseIterable, Identifiable, Sendable {
    /// The guest occupies its true pixel size — the old 100% scale.
    case native
    /// The guest is scaled up until its attached edge spans the whole host
    /// edge. Derived, not stored: see `ContinuityDisplayGeometry.fitScale`.
    case fit

    var id: String { rawValue }

    var label: String {
        switch self {
        case .native: return "Native"
        case .fit: return "Fit"
        }
    }
}

struct HostDisplayDescriptor: Identifiable, Equatable, Sendable {
    let id: UInt32
    let name: String
    let frame: CGRect
    let pixelSize: CGSize
    let isPrimary: Bool
}

enum GuestDisplaySide: String, Equatable, Sendable {
    case left
    case right
    case bottom
    case top
}

struct ContinuitySharedEdge: Equatable, Sendable {
    let host: HostDisplayDescriptor
    /// The side of the virtual guest display which touches the host.
    let guestSide: GuestDisplaySide
    let overlap: ClosedRange<CGFloat>
}

enum ContinuityDisplayGeometry {
    static let adjacencyTolerance: CGFloat = 0.5

    static func defaultGuestOrigin(hosts: [HostDisplayDescriptor],
                                   guestSize: CGSize,
                                   scale: CGFloat) -> CGPoint {
        guard let host = hosts.max(by: { $0.frame.maxX < $1.frame.maxX }) else {
            return .zero
        }
        let height = guestSize.height * scale
        return CGPoint(x: host.frame.maxX, y: host.frame.maxY - height)
    }

    /// The factor which makes the guest's attached edge span the whole of the
    /// host edge it touches. The shared edge decides the AXIS: a vertical
    /// shared edge (the guest's left or right side) matches heights, a
    /// horizontal one (top or bottom) matches widths.
    ///
    /// Two deliberate floors. Without a shared edge there is nothing to match,
    /// so Fit is Native until the guest is attached. And the result never goes
    /// below 1: a guest whose edge is already longer than the host's stays at
    /// its true pixel size rather than being shrunk, because shrinking throws
    /// away guest pixels the mirror is still delivering, and "Fit" was asked
    /// for to reach the edge, not to hide detail.
    static func fitScale(guestSize: CGSize,
                         edge: ContinuitySharedEdge?) -> CGFloat {
        guard let edge, guestSize.width > 0, guestSize.height > 0 else {
            return 1
        }
        let matched: CGFloat
        switch edge.guestSide {
        case .left, .right:
            matched = edge.host.frame.height / guestSize.height
        case .bottom, .top:
            matched = edge.host.frame.width / guestSize.width
        }
        return max(1, matched)
    }

    /// Where a fitted guest sits ALONG its shared edge.
    ///
    /// Deriving the factor is only half of Fit: a guest of exactly the right
    /// size sitting halfway up the edge is not fitted, it is merely the right
    /// size. The scale decides how long the guest's edge is; this decides
    /// where that edge starts, on the same axis the scale was derived from.
    ///
    /// - Parameter fittedSize: the guest's size WITH the fit scale already
    ///   applied — this reads the frame it is positioning, not the pixels.
    static func fittedOrigin(fittedSize: CGSize,
                             edge: ContinuitySharedEdge,
                             current: CGPoint) -> CGPoint {
        var origin = current
        switch edge.guestSide {
        case .left, .right:
            origin.y = alignedAlongEdge(guestLength: fittedSize.height,
                                        hostMin: edge.host.frame.minY,
                                        hostLength: edge.host.frame.height)
        case .bottom, .top:
            origin.x = alignedAlongEdge(guestLength: fittedSize.width,
                                        hostMin: edge.host.frame.minX,
                                        hostLength: edge.host.frame.width)
        }
        return origin
    }

    private static func alignedAlongEdge(guestLength: CGFloat,
                                         hostMin: CGFloat,
                                         hostLength: CGFloat) -> CGFloat {
        /* The ordinary case: the scale made these lengths equal, so starting
           at the host's own minimum makes the two edges flush end to end. */
        guard guestLength > hostLength else { return hostMin }
        /* The clamped case. The guest's edge is already longer than the
           host's and the floor at 1 forbids shrinking it, so spanning is
           arithmetically impossible - SOME overhang is going to exist. All
           this can choose is where it goes, and centring is the only choice
           that keeps the host edge fully covered while splitting the excess
           between both ends. Pinning to the host's minimum instead would
           pile the entire overhang onto one end, which reads as a guest
           mis-attached at that corner rather than one that is simply too
           big - the arrangement would look broken instead of looking honest
           about a guest the host edge cannot contain. */
        return hostMin + (hostLength - guestLength) / 2
    }

    static func placementIsFree(_ guest: CGRect,
                                hosts: [HostDisplayDescriptor]) -> Bool {
        collisionFree(guest, hosts: hosts)
    }

    static func sharedEdge(hosts: [HostDisplayDescriptor], guest: CGRect)
        -> ContinuitySharedEdge? {
        guard guest.width > 0, guest.height > 0,
              !hosts.contains(where: { positiveArea($0.frame.intersection(guest)) })
        else { return nil }

        var candidates: [(CGFloat, ContinuitySharedEdge)] = []
        for host in hosts {
            if abs(guest.minX - host.frame.maxX) <= adjacencyTolerance,
               let overlap = overlap(guest.minY ... guest.maxY,
                                     host.frame.minY ... host.frame.maxY) {
                candidates.append((overlap.upperBound - overlap.lowerBound,
                                   .init(host: host, guestSide: .left,
                                         overlap: overlap)))
            }
            if abs(guest.maxX - host.frame.minX) <= adjacencyTolerance,
               let overlap = overlap(guest.minY ... guest.maxY,
                                     host.frame.minY ... host.frame.maxY) {
                candidates.append((overlap.upperBound - overlap.lowerBound,
                                   .init(host: host, guestSide: .right,
                                         overlap: overlap)))
            }
            if abs(guest.minY - host.frame.maxY) <= adjacencyTolerance,
               let overlap = overlap(guest.minX ... guest.maxX,
                                     host.frame.minX ... host.frame.maxX) {
                candidates.append((overlap.upperBound - overlap.lowerBound,
                                   .init(host: host, guestSide: .bottom,
                                         overlap: overlap)))
            }
            if abs(guest.maxY - host.frame.minY) <= adjacencyTolerance,
               let overlap = overlap(guest.minX ... guest.maxX,
                                     host.frame.minX ... host.frame.maxX) {
                candidates.append((overlap.upperBound - overlap.lowerBound,
                                   .init(host: host, guestSide: .top,
                                         overlap: overlap)))
            }
        }
        return candidates.max(by: { $0.0 < $1.0 })?.1
    }

    static func snappedOrigin(proposed: CGPoint, guestSize: CGSize,
                              scale: CGFloat,
                              hosts: [HostDisplayDescriptor],
                              threshold: CGFloat = 48) -> CGPoint {
        let size = CGSize(width: guestSize.width * scale,
                          height: guestSize.height * scale)
        let raw = CGRect(origin: proposed, size: size)
        var answers: [(distance: CGFloat, aligned: Bool, origin: CGPoint)] = []

        for host in hosts {
            let alignedY = nearest(proposed.y,
                                   to: [host.frame.minY,
                                        host.frame.maxY - size.height],
                                   threshold: threshold)
            for (y, aligned) in snapValues(raw: proposed.y,
                                           aligned: alignedY) {
                answers.append((abs(raw.minX - host.frame.maxX), aligned,
                                CGPoint(x: host.frame.maxX, y: y)))
                answers.append((abs(raw.maxX - host.frame.minX), aligned,
                                CGPoint(x: host.frame.minX - size.width,
                                        y: y)))
            }

            let alignedX = nearest(proposed.x,
                                   to: [host.frame.minX,
                                        host.frame.maxX - size.width],
                                   threshold: threshold)
            for (x, aligned) in snapValues(raw: proposed.x,
                                           aligned: alignedX) {
                answers.append((abs(raw.minY - host.frame.maxY), aligned,
                                CGPoint(x: x, y: host.frame.maxY)))
                answers.append((abs(raw.maxY - host.frame.minY), aligned,
                                CGPoint(x: x,
                                        y: host.frame.minY - size.height)))
            }
        }

        let valid = answers.filter { answer in
            guard answer.distance <= threshold else { return false }
            let frame = CGRect(origin: answer.origin, size: size)
            return collisionFree(frame, hosts: hosts)
                && sharedEdge(hosts: hosts, guest: frame) != nil
        }
        guard let closest = valid.min(by: {
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            return $0.aligned && !$1.aligned
        }) else { return proposed }
        return closest.origin
    }

    static func resolvedOrigin(proposed: CGPoint, previous: CGPoint,
                               guestSize: CGSize, scale: CGFloat,
                               hosts: [HostDisplayDescriptor]) -> CGPoint {
        let size = CGSize(width: guestSize.width * scale,
                          height: guestSize.height * scale)
        let snapped = snappedOrigin(proposed: proposed, guestSize: guestSize,
                                    scale: scale, hosts: hosts)
        if collisionFree(CGRect(origin: snapped, size: size), hosts: hosts) {
            return snapped
        }

        var xValues = [proposed.x]
        var yValues = [proposed.y]
        for host in hosts {
            xValues.append(contentsOf: [host.frame.minX - size.width,
                                        host.frame.maxX])
            yValues.append(contentsOf: [host.frame.minY - size.height,
                                        host.frame.maxY])
        }
        let candidates = xValues.flatMap { x in
            yValues.map { CGPoint(x: x, y: $0) }
        }.filter {
            collisionFree(CGRect(origin: $0, size: size), hosts: hosts)
        }
        if let closest = candidates.min(by: {
            squaredDistance($0, proposed) < squaredDistance($1, proposed)
        }) {
            return snappedOrigin(proposed: closest, guestSize: guestSize,
                                 scale: scale, hosts: hosts)
        }

        let previousFrame = CGRect(origin: previous, size: size)
        return collisionFree(previousFrame, hosts: hosts) ? previous
            : defaultGuestOrigin(hosts: hosts, guestSize: guestSize,
                                 scale: scale)
    }

    /* Entry seeds the pointer INSIDE the boundary, not on it. Seeding at
       width-1 parked re-entries one pixel from the exit test, and the
       physical wiggle of a click (+4 px measured) tipped straight back
       across - seven "clicks send me home" returns in one minute of the
       2026-08-13 202005 run. A deliberate exit still only costs this many
       pixels of motion toward the edge. */
    static let entryInsetPixels: CGFloat = 24

    static func guestEntryPoint(at hostPoint: CGPoint,
                                edge: ContinuitySharedEdge,
                                guestFrame: CGRect,
                                guestPixels: CGSize,
                                scale: CGFloat) -> CGPoint {
        let insetX = min(entryInsetPixels, max(0, guestPixels.width - 1))
        let insetY = min(entryInsetPixels, max(0, guestPixels.height - 1))
        switch edge.guestSide {
        case .left:
            return CGPoint(x: insetX,
                           y: clamped((guestFrame.maxY - hostPoint.y) / scale,
                                      upper: guestPixels.height - 1))
        case .right:
            return CGPoint(x: max(0, guestPixels.width - 1 - insetX),
                           y: clamped((guestFrame.maxY - hostPoint.y) / scale,
                                      upper: guestPixels.height - 1))
        case .bottom:
            return CGPoint(x: clamped((hostPoint.x - guestFrame.minX) / scale,
                                      upper: guestPixels.width - 1),
                           y: max(0, guestPixels.height - 1 - insetY))
        case .top:
            return CGPoint(x: clamped((hostPoint.x - guestFrame.minX) / scale,
                                      upper: guestPixels.width - 1),
                           y: insetY)
        }
    }

    static func hostReturnPoint(for guestPoint: CGPoint,
                                edge: ContinuitySharedEdge,
                                guestFrame: CGRect,
                                scale: CGFloat) -> CGPoint {
        switch edge.guestSide {
        case .left:
            return CGPoint(x: edge.host.frame.maxX - 1,
                           y: edge.overlap.clamped(
                            guestFrame.maxY - guestPoint.y * scale))
        case .right:
            return CGPoint(x: edge.host.frame.minX + 1,
                           y: edge.overlap.clamped(
                            guestFrame.maxY - guestPoint.y * scale))
        case .bottom:
            return CGPoint(x: edge.overlap.clamped(
                            guestFrame.minX + guestPoint.x * scale),
                           y: edge.host.frame.maxY - 1)
        case .top:
            return CGPoint(x: edge.overlap.clamped(
                            guestFrame.minX + guestPoint.x * scale),
                           y: edge.host.frame.minY + 1)
        }
    }

    static func crossedBack(_ point: CGPoint, through side: GuestDisplaySide,
                            guestPixels: CGSize) -> Bool {
        switch side {
        case .left: return point.x < 0
        case .right: return point.x >= guestPixels.width
        case .bottom: return point.y >= guestPixels.height
        case .top: return point.y < 0
        }
    }

    private static func positiveArea(_ rect: CGRect) -> Bool {
        !rect.isNull && rect.width > adjacencyTolerance
            && rect.height > adjacencyTolerance
    }

    private static func collisionFree(_ guest: CGRect,
                                      hosts: [HostDisplayDescriptor]) -> Bool {
        !hosts.contains { positiveArea($0.frame.intersection(guest)) }
    }

    private static func nearest(_ value: CGFloat, to candidates: [CGFloat],
                                threshold: CGFloat) -> CGFloat? {
        guard let answer = candidates.min(by: {
            abs($0 - value) < abs($1 - value)
        }), abs(answer - value) <= threshold else { return nil }
        return answer
    }

    private static func snapValues(raw: CGFloat, aligned: CGFloat?)
        -> [(CGFloat, Bool)] {
        guard let aligned, aligned != raw else { return [(raw, false)] }
        return [(aligned, true), (raw, false)]
    }

    private static func squaredDistance(_ lhs: CGPoint,
                                        _ rhs: CGPoint) -> CGFloat {
        let x = lhs.x - rhs.x
        let y = lhs.y - rhs.y
        return x * x + y * y
    }

    private static func overlap(_ lhs: ClosedRange<CGFloat>,
                                _ rhs: ClosedRange<CGFloat>)
        -> ClosedRange<CGFloat>? {
        let lower = max(lhs.lowerBound, rhs.lowerBound)
        let upper = min(lhs.upperBound, rhs.upperBound)
        guard upper - lower > adjacencyTolerance else { return nil }
        return lower ... upper
    }

    private static func clamped(_ value: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(0, value), max(0, upper))
    }
}

@MainActor
final class ContinuityDisplayLayout: ObservableObject {
    @Published private(set) var hostDisplays: [HostDisplayDescriptor]
    @Published private(set) var guestSize: CGSize
    @Published private(set) var scaleMode: GuestDisplayScaleMode
    /// The factor actually applied to `guestSize` — 1 under Native, derived
    /// from the shared edge under Fit. Everything downstream (the arrangement
    /// frame, the snapping, and the pointer/edge mapping in
    /// `ContinuityEdgeController`) reads THIS and not the mode, so Fit is a
    /// real coordinate scale rather than a drawing trick.
    @Published private(set) var guestScale: CGFloat
    @Published private(set) var guestOrigin: CGPoint
    /// True once a placement has been WRITTEN to defaults — by a drag, a
    /// resize, a scale change, or a display-change recovery. False only for
    /// a fresh install (or a fresh prefs domain that has never run), which
    /// is the one case `attachToDefaultEdgeIfNeverPlaced` exists for. This
    /// is deliberately about what was PERSISTED, not what the constructor
    /// computed in memory: the constructor's own default is only as good as
    /// the `displayProvider()` read it was built from, and nothing wrote it
    /// down, so a `hostDisplays` snapshot taken before the window server was
    /// ready would otherwise stay uncorrected for the life of the process.
    private(set) var hasPersistedPlacement: Bool

    private let defaults: UserDefaults?
    private let displayProvider: @MainActor () -> [HostDisplayDescriptor]
    private var screenSubscription: AnyCancellable?

    private static let scaleModeKey = "mirror.continuity.guestDisplayScaleMode"
    /// The numeric zoom this pill replaced. Read once, only to be discarded.
    private static let legacyScaleKey = "mirror.continuity.guestDisplayScale"
    private static let originXKey = "mirror.continuity.guestDisplayOriginX"
    private static let originYKey = "mirror.continuity.guestDisplayOriginY"
    private static let hasOriginKey = "mirror.continuity.hasGuestDisplayOrigin"

    init(hostDisplays: [HostDisplayDescriptor]? = nil,
         guestSize: CGSize = CGSize(width: 800, height: 600),
         defaults: UserDefaults? = ProductIdentity.defaults,
         observeScreens: Bool = true,
         displayProvider: @escaping @MainActor () -> [HostDisplayDescriptor]
            = ContinuityDisplayLayout.liveDisplays) {
        self.defaults = defaults
        self.displayProvider = displayProvider
        let resolvedHosts = hostDisplays ?? displayProvider()
        let resolvedGuestSize = Self.validGuestSize(guestSize)
        self.hostDisplays = resolvedHosts
        self.guestSize = resolvedGuestSize
        /* Migration: a stored numeric zoom becomes Native, whatever number it
           held. 200% is not "Fit" on some other arrangement and 50% has no
           successor at all, so there is no honest mapping from the old value
           to the new pair — and Native is the one state that means the same
           thing it always did (the old 100%). The stale key is removed so the
           next launch takes the ordinary path. */
        let storedMode = defaults?.string(forKey: Self.scaleModeKey)
            .flatMap(GuestDisplayScaleMode.init(rawValue:))
        if storedMode == nil, defaults?.object(forKey: Self.legacyScaleKey) != nil {
            defaults?.removeObject(forKey: Self.legacyScaleKey)
        }
        let resolvedMode = storedMode ?? .native
        scaleMode = resolvedMode
        /* Fit needs a shared edge to derive from and the edge needs a frame,
           so the guest starts at its native size and the fit factor is taken
           below, once there is a resolved placement to read an edge from. */
        let resolvedScale: CGFloat = 1
        guestScale = resolvedScale
        let storedPlacement = defaults?.bool(forKey: Self.hasOriginKey) == true
        hasPersistedPlacement = storedPlacement
        if storedPlacement {
            guestOrigin = CGPoint(
                x: defaults?.double(forKey: Self.originXKey) ?? 0,
                y: defaults?.double(forKey: Self.originYKey) ?? 0)
        } else {
            guestOrigin = ContinuityDisplayGeometry.defaultGuestOrigin(
                hosts: resolvedHosts, guestSize: resolvedGuestSize,
                scale: resolvedScale)
        }
        let safeDefault = ContinuityDisplayGeometry.defaultGuestOrigin(
            hosts: resolvedHosts, guestSize: resolvedGuestSize,
            scale: resolvedScale)
        guestOrigin = ContinuityDisplayGeometry.resolvedOrigin(
            proposed: guestOrigin, previous: safeDefault,
            guestSize: resolvedGuestSize, scale: resolvedScale,
            hosts: resolvedHosts)
        applyFitScaleIfNeeded()
        if observeScreens {
            screenSubscription = NotificationCenter.default.publisher(
                for: NSApplication.didChangeScreenParametersNotification)
                .sink { [weak self] _ in
                    Task { @MainActor in self?.refreshDisplays() }
                }
        }
    }

    var guestFrame: CGRect {
        CGRect(origin: guestOrigin,
               size: CGSize(width: guestSize.width * guestScale,
                            height: guestSize.height * guestScale))
    }

    var sharedEdge: ContinuitySharedEdge? {
        ContinuityDisplayGeometry.sharedEdge(hosts: hostDisplays,
                                             guest: guestFrame)
    }

    var arrangementBounds: CGRect {
        (hostDisplays.map(\.frame) + [guestFrame]).reduce(.null) {
            $0.union($1)
        }
    }

    func refreshDisplays() {
        let refreshed = displayProvider()
        guard !refreshed.isEmpty else { return }
        hostDisplays = refreshed
        if sharedEdge == nil {
            guestOrigin = ContinuityDisplayGeometry.defaultGuestOrigin(
                hosts: refreshed, guestSize: guestSize, scale: guestScale)
            persistOrigin()
        }
        // A display can change size without the guest moving, and Fit is a
        // function of the host edge it is attached to.
        applyFitScaleIfNeeded()
    }

    /// Call once, when the arrangement page first appears. A fresh install
    /// (or a fresh prefs domain) has never had a placement WRITTEN, so the
    /// constructor's own default — attached to the widest host's own right
    /// edge — is only ever held in memory until something persists it. If
    /// nothing ever does, the guest is an island that looked attached in
    /// the geometry the instant the constructor ran but is one stale
    /// `displayProvider()` read away from staying that way for the rest of
    /// the process — the constructor can run before the window server has
    /// settled, well before a person ever sees the page. This re-reads the
    /// CURRENT display list, re-derives the attach against it, and makes it
    /// durable, so a first appearance always shows an attached guest and
    /// every appearance after is a no-op.
    ///
    /// A placement that was ever written — including one that deliberately
    /// floated the guest away from every edge — is left exactly alone.
    func attachToDefaultEdgeIfNeverPlaced() {
        guard !hasPersistedPlacement else { return }
        let refreshed = displayProvider()
        if !refreshed.isEmpty {
            hostDisplays = refreshed
        }
        guestOrigin = ContinuityDisplayGeometry.defaultGuestOrigin(
            hosts: hostDisplays, guestSize: guestSize, scale: guestScale)
        applyFitScaleIfNeeded()
        persistOrigin()
    }

    func updateGuestSize(_ proposed: CGSize) {
        let valid = Self.validGuestSize(proposed)
        guard valid != guestSize else { return }
        let oldEdge = sharedEdge
        let oldFrame = guestFrame
        guestSize = valid
        preserve(edge: oldEdge, oldFrame: oldFrame)
        guestOrigin = ContinuityDisplayGeometry.resolvedOrigin(
            proposed: guestOrigin, previous: oldFrame.origin,
            guestSize: guestSize, scale: guestScale, hosts: hostDisplays)
        // The guest's own resolution changed, so the fit factor did too.
        applyFitScaleIfNeeded()
        persistOrigin()
    }

    func setGuestOrigin(_ origin: CGPoint) {
        guestOrigin = ContinuityDisplayGeometry.resolvedOrigin(
            proposed: origin, previous: guestOrigin, guestSize: guestSize,
            scale: guestScale, hosts: hostDisplays)
    }

    func finishGuestMove() {
        guestOrigin = ContinuityDisplayGeometry.resolvedOrigin(
            proposed: guestOrigin, previous: guestOrigin,
            guestSize: guestSize, scale: guestScale, hosts: hostDisplays)
        // The attachment settled here: a different edge, or a different host
        // on the same side, is a different fit. Deliberately not during the
        // drag - resizing the tile under the pointer fights the gesture.
        applyFitScaleIfNeeded()
        persistOrigin()
    }

    func selectScaleMode(_ mode: GuestDisplayScaleMode) {
        guard mode != scaleMode else { return }
        scaleMode = mode
        defaults?.set(mode.rawValue, forKey: Self.scaleModeKey)
        switch mode {
        case .native: apply(scale: 1)
        case .fit: applyFitScaleIfNeeded()
        }
        persistOrigin()
    }

    private func applyFitScaleIfNeeded() {
        guard scaleMode == .fit else { return }
        apply(scale: ContinuityDisplayGeometry.fitScale(guestSize: guestSize,
                                                        edge: sharedEdge))
        alignFittedOrigin()
    }

    /// Fit places the guest as well as sizing it. Separate from `apply` on
    /// purpose: a scale that did not change still needs aligning, because the
    /// guest may have been dragged along an edge it was already fitted to.
    ///
    /// Unattached is left alone - Fit is Native until there is an edge, and
    /// that includes the position.
    private func alignFittedOrigin() {
        guard scaleMode == .fit, let edge = sharedEdge else { return }
        let aligned = ContinuityDisplayGeometry.fittedOrigin(
            fittedSize: guestFrame.size, edge: edge, current: guestOrigin)
        guard aligned != guestOrigin else { return }
        /* Sliding along the edge cannot collide with the host it is attached
           to, but in a multi-display arrangement it can walk into a THIRD
           display. A fitted position is not worth an overlapping one. */
        let frame = CGRect(origin: aligned, size: guestFrame.size)
        guard ContinuityDisplayGeometry.placementIsFree(frame,
                                                        hosts: hostDisplays)
        else { return }
        guestOrigin = aligned
    }

    /// Changing the scale keeps the ATTACHED edge where it is and grows away
    /// from it, so a resize never silently detaches the guest.
    private func apply(scale: CGFloat) {
        guard scale != guestScale else { return }
        let oldEdge = sharedEdge
        let oldFrame = guestFrame
        guestScale = scale
        preserve(edge: oldEdge, oldFrame: oldFrame)
        guestOrigin = ContinuityDisplayGeometry.resolvedOrigin(
            proposed: guestOrigin, previous: oldFrame.origin,
            guestSize: guestSize, scale: guestScale, hosts: hostDisplays)
    }

    private func preserve(edge: ContinuitySharedEdge?, oldFrame: CGRect) {
        guard let edge else { return }
        switch edge.guestSide {
        case .left, .bottom:
            break
        case .right:
            guestOrigin.x = oldFrame.maxX - guestFrame.width
        case .top:
            guestOrigin.y = oldFrame.maxY - guestFrame.height
        }
    }

    private func persistOrigin() {
        defaults?.set(guestOrigin.x, forKey: Self.originXKey)
        defaults?.set(guestOrigin.y, forKey: Self.originYKey)
        defaults?.set(true, forKey: Self.hasOriginKey)
        hasPersistedPlacement = true
    }

    private static func validGuestSize(_ size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else {
            return CGSize(width: 800, height: 600)
        }
        return size
    }

    static func liveDisplays() -> [HostDisplayDescriptor] {
        NSScreen.screens.enumerated().map { index, screen in
            let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            let id = number?.uint32Value ?? UInt32(index)
            return HostDisplayDescriptor(
                id: id, name: screen.localizedName, frame: screen.frame,
                pixelSize: CGSize(width: CGDisplayPixelsWide(id),
                                  height: CGDisplayPixelsHigh(id)),
                isPrimary: index == 0)
        }
    }
}

private extension ClosedRange where Bound == CGFloat {
    func clamped(_ value: CGFloat) -> CGFloat {
        Swift.min(Swift.max(lowerBound, value), upperBound)
    }
}
