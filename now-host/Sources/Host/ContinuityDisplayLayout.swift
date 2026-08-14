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

enum GuestDisplayScale: Double, CaseIterable, Identifiable, Sendable {
    case half = 0.5
    case actual = 1
    case double = 2
    case quadruple = 4

    var id: Double { rawValue }

    var label: String {
        switch self {
        case .half: return "50%"
        case .actual: return "100%"
        case .double: return "200%"
        case .quadruple: return "400%"
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
                                   scale: GuestDisplayScale) -> CGPoint {
        guard let host = hosts.max(by: { $0.frame.maxX < $1.frame.maxX }) else {
            return .zero
        }
        let height = guestSize.height * scale.rawValue
        return CGPoint(x: host.frame.maxX, y: host.frame.maxY - height)
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
                              scale: GuestDisplayScale,
                              hosts: [HostDisplayDescriptor],
                              threshold: CGFloat = 48) -> CGPoint {
        let size = CGSize(width: guestSize.width * scale.rawValue,
                          height: guestSize.height * scale.rawValue)
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
                               guestSize: CGSize, scale: GuestDisplayScale,
                               hosts: [HostDisplayDescriptor]) -> CGPoint {
        let size = CGSize(width: guestSize.width * scale.rawValue,
                          height: guestSize.height * scale.rawValue)
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
                                scale: GuestDisplayScale) -> CGPoint {
        let factor = CGFloat(scale.rawValue)
        let insetX = min(entryInsetPixels, max(0, guestPixels.width - 1))
        let insetY = min(entryInsetPixels, max(0, guestPixels.height - 1))
        switch edge.guestSide {
        case .left:
            return CGPoint(x: insetX,
                           y: clamped((guestFrame.maxY - hostPoint.y) / factor,
                                      upper: guestPixels.height - 1))
        case .right:
            return CGPoint(x: max(0, guestPixels.width - 1 - insetX),
                           y: clamped((guestFrame.maxY - hostPoint.y) / factor,
                                      upper: guestPixels.height - 1))
        case .bottom:
            return CGPoint(x: clamped((hostPoint.x - guestFrame.minX) / factor,
                                      upper: guestPixels.width - 1),
                           y: max(0, guestPixels.height - 1 - insetY))
        case .top:
            return CGPoint(x: clamped((hostPoint.x - guestFrame.minX) / factor,
                                      upper: guestPixels.width - 1),
                           y: insetY)
        }
    }

    static func hostReturnPoint(for guestPoint: CGPoint,
                                edge: ContinuitySharedEdge,
                                guestFrame: CGRect,
                                scale: GuestDisplayScale) -> CGPoint {
        let factor = CGFloat(scale.rawValue)
        switch edge.guestSide {
        case .left:
            return CGPoint(x: edge.host.frame.maxX - 1,
                           y: edge.overlap.clamped(
                            guestFrame.maxY - guestPoint.y * factor))
        case .right:
            return CGPoint(x: edge.host.frame.minX + 1,
                           y: edge.overlap.clamped(
                            guestFrame.maxY - guestPoint.y * factor))
        case .bottom:
            return CGPoint(x: edge.overlap.clamped(
                            guestFrame.minX + guestPoint.x * factor),
                           y: edge.host.frame.maxY - 1)
        case .top:
            return CGPoint(x: edge.overlap.clamped(
                            guestFrame.minX + guestPoint.x * factor),
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
    @Published private(set) var guestScale: GuestDisplayScale
    @Published private(set) var guestOrigin: CGPoint

    private let defaults: UserDefaults?
    private let displayProvider: @MainActor () -> [HostDisplayDescriptor]
    private var screenSubscription: AnyCancellable?

    private static let scaleKey = "mirror.continuity.guestDisplayScale"
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
        let resolvedScale: GuestDisplayScale
        if let raw = defaults?.double(forKey: Self.scaleKey),
           let stored = GuestDisplayScale(rawValue: raw), raw != 0 {
            resolvedScale = stored
        } else {
            resolvedScale = .actual
        }
        guestScale = resolvedScale
        if defaults?.bool(forKey: Self.hasOriginKey) == true {
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
               size: CGSize(width: guestSize.width * guestScale.rawValue,
                            height: guestSize.height * guestScale.rawValue))
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
        persistOrigin()
    }

    func selectScale(_ scale: GuestDisplayScale) {
        guard scale != guestScale else { return }
        let oldEdge = sharedEdge
        let oldFrame = guestFrame
        guestScale = scale
        preserve(edge: oldEdge, oldFrame: oldFrame)
        guestOrigin = ContinuityDisplayGeometry.resolvedOrigin(
            proposed: guestOrigin, previous: oldFrame.origin,
            guestSize: guestSize, scale: guestScale, hosts: hostDisplays)
        defaults?.set(scale.rawValue, forKey: Self.scaleKey)
        persistOrigin()
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
