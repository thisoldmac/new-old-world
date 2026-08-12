import AppKit
import Combine
import Foundation

enum MirrorSurfaceMode: String, CaseIterable, Identifiable, Sendable {
    case mirror
    case continuity

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mirror: return "Mirror"
        case .continuity: return "Continuity"
        }
    }
}

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
        var answers: [(CGFloat, CGPoint)] = []

        for host in hosts {
            let verticalOverlap = overlap(raw.minY ... raw.maxY,
                                          host.frame.minY ... host.frame.maxY)
            if verticalOverlap != nil {
                answers.append((abs(raw.minX - host.frame.maxX),
                                CGPoint(x: host.frame.maxX, y: proposed.y)))
                answers.append((abs(raw.maxX - host.frame.minX),
                                CGPoint(x: host.frame.minX - size.width,
                                        y: proposed.y)))
            }
            let horizontalOverlap = overlap(raw.minX ... raw.maxX,
                                            host.frame.minX ... host.frame.maxX)
            if horizontalOverlap != nil {
                answers.append((abs(raw.minY - host.frame.maxY),
                                CGPoint(x: proposed.x, y: host.frame.maxY)))
                answers.append((abs(raw.maxY - host.frame.minY),
                                CGPoint(x: proposed.x,
                                        y: host.frame.minY - size.height)))
            }
        }

        guard let closest = answers.min(by: { $0.0 < $1.0 }),
              closest.0 <= threshold else { return proposed }
        let snapped = CGRect(origin: closest.1, size: size)
        guard !hosts.contains(where: {
            positiveArea($0.frame.intersection(snapped))
        }) else { return proposed }
        return closest.1
    }

    static func guestEntryPoint(at hostPoint: CGPoint,
                                edge: ContinuitySharedEdge,
                                guestFrame: CGRect,
                                guestPixels: CGSize,
                                scale: GuestDisplayScale) -> CGPoint {
        let factor = CGFloat(scale.rawValue)
        switch edge.guestSide {
        case .left:
            return CGPoint(x: 0,
                           y: clamped((guestFrame.maxY - hostPoint.y) / factor,
                                      upper: guestPixels.height - 1))
        case .right:
            return CGPoint(x: max(0, guestPixels.width - 1),
                           y: clamped((guestFrame.maxY - hostPoint.y) / factor,
                                      upper: guestPixels.height - 1))
        case .bottom:
            return CGPoint(x: clamped((hostPoint.x - guestFrame.minX) / factor,
                                      upper: guestPixels.width - 1),
                           y: max(0, guestPixels.height - 1))
        case .top:
            return CGPoint(x: clamped((hostPoint.x - guestFrame.minX) / factor,
                                      upper: guestPixels.width - 1),
                           y: 0)
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
        persistOrigin()
    }

    func setGuestOrigin(_ origin: CGPoint) {
        guestOrigin = origin
    }

    func finishGuestMove() {
        guestOrigin = ContinuityDisplayGeometry.snappedOrigin(
            proposed: guestOrigin, guestSize: guestSize, scale: guestScale,
            hosts: hostDisplays)
        persistOrigin()
    }

    func selectScale(_ scale: GuestDisplayScale) {
        guard scale != guestScale else { return }
        let oldEdge = sharedEdge
        let oldFrame = guestFrame
        guestScale = scale
        preserve(edge: oldEdge, oldFrame: oldFrame)
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
