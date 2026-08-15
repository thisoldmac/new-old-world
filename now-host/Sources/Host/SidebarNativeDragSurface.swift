import AppKit
import QuartzCore
import SwiftUI

/// A native drag source and destination laid over the existing SwiftUI row.
/// Replacing the rendered sidebar with an outline view would duplicate all of
/// its shelf/tab presentation; this keeps AppKit in charge of the gesture,
/// pasteboard, spring loading, and drop while SwiftUI keeps presentation.
struct SidebarNativeDragSurface: NSViewRepresentable {
    let payload: NavigationDraggedItem?
    let target: NavigationDropTarget?
    let canDrop: (NavigationDraggedItem, NavigationDropTarget) -> Bool
    let previewDrop: (NavigationDraggedItem, NavigationDropTarget) -> Bool
    let performDrop: (NavigationDraggedItem, NavigationDropTarget) -> Bool
    var dragEnded: ((NavigationDraggedItem) -> Void)?
    var activate: (() -> Void)?
    var springLoad: (() -> Void)?
    var hoverChanged: ((Bool) -> Void)?
    var hoverDisclosure: SidebarHoverDisclosure? = nil
    var rowDropTargets: NavigationRowDropTargets? = nil
    var menuItems: [SidebarNativeMenuItem] = []
    var menuHitRegion: SidebarMenuHitRegion = .none

    func makeNSView(context: Context) -> NativeNavigationDragView {
        let view = NativeNavigationDragView()
        view.apply(configuration)
        return view
    }

    func updateNSView(_ view: NativeNavigationDragView, context: Context) {
        view.apply(configuration)
    }

    private var configuration: NativeNavigationDragView.Configuration {
        NativeNavigationDragView.Configuration(
            payload: payload,
            target: target,
            canDrop: canDrop,
            previewDrop: previewDrop,
            performDrop: performDrop,
            dragEnded: dragEnded,
            activate: activate,
            springLoad: springLoad,
            hoverChanged: hoverChanged,
            hoverDisclosure: hoverDisclosure,
            rowDropTargets: rowDropTargets,
            menuItems: menuItems,
            menuHitRegion: menuHitRegion)
    }
}

struct SidebarNativeMenuItem {
    let title: String
    let symbol: String
    let payload: NavigationDraggedItem
    let action: () -> Void
    let dragEnded: (NavigationDraggedItem) -> Void
}

enum SidebarMenuHitRegion {
    case none
    case leadingIcon
    case centeredIcon

    func contains(horizontalOffset x: CGFloat, width: CGFloat) -> Bool {
        switch self {
        case .none:
            false
        case .leadingIcon:
            (0...44).contains(x)
        case .centeredIcon:
            abs(x - width / 2) <= 22
        }
    }
}

@MainActor
final class NativeNavigationDragView: NSView, NSDraggingSource,
                                      NSSpringLoadingDestination {
    struct Configuration {
        let payload: NavigationDraggedItem?
        let target: NavigationDropTarget?
        let canDrop: (NavigationDraggedItem, NavigationDropTarget) -> Bool
        let previewDrop: (NavigationDraggedItem, NavigationDropTarget) -> Bool
        let performDrop: (NavigationDraggedItem, NavigationDropTarget) -> Bool
        let dragEnded: ((NavigationDraggedItem) -> Void)?
        let activate: (() -> Void)?
        let springLoad: (() -> Void)?
        let hoverChanged: ((Bool) -> Void)?
        let hoverDisclosure: SidebarHoverDisclosure?
        let rowDropTargets: NavigationRowDropTargets?
        let menuItems: [SidebarNativeMenuItem]
        let menuHitRegion: SidebarMenuHitRegion
    }

    static let pasteboardType = NSPasteboard.PasteboardType(
        "com.machineintent.newoldworld.navigation-item")

    var configuration: Configuration?
    private var mouseDownEvent: NSEvent?
    private var beganDrag = false
    private var feedback = NavigationDragFeedbackState()
    /// Spring loading is armed against the row, insertion feedback against
    /// the band under the pointer. One state could not hold both: crossing a
    /// band boundary has to reset the insertion line, and resetting the arm
    /// with it is what re-fires the flash — or, more often, never lets the
    /// dwell finish at all.
    private var springFeedback = NavigationDragFeedbackState()
    private var hoverTrackingArea: NSTrackingArea?
    private let hoverDisclosurePresenter = SidebarHoverDisclosurePresenter()
    private var dropFeedback: NavigationRowDropTargets.Feedback?

    /// AppKit's modal menu tracking cannot run inside a test, and the defect
    /// this seam exists for is a state reset that must happen *after* it
    /// returns. Presenting through a replaceable closure lets the ordering be
    /// asserted rather than asserted about.
    var presentMenu: (NSMenu, NSPoint, NSView) -> Void = { menu, point, view in
        menu.popUp(positioning: nil, at: point, in: view)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([Self.pasteboardType])
        wantsLayer = true
        layer?.cornerRadius = 7
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([Self.pasteboardType])
        wantsLayer = true
        layer?.cornerRadius = 7
    }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func apply(_ newConfiguration: Configuration) {
        configuration = newConfiguration
        hoverDisclosurePresenter.update(
            disclosure: newConfiguration.hoverDisclosure,
            anchor: self)
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow,
                      .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            configuration?.hoverChanged?(false)
            hoverDisclosurePresenter.pointerExited()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func mouseEntered(with event: NSEvent) {
        configuration?.hoverChanged?(true)
        hoverDisclosurePresenter.pointerEntered()
    }

    override func mouseExited(with event: NSEvent) {
        configuration?.hoverChanged?(false)
        hoverDisclosurePresenter.pointerExited()
    }

    override func mouseDown(with event: NSEvent) {
        hoverDisclosurePresenter.cancel()
        mouseDownEvent = event
        beganDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !beganDrag, let start = mouseDownEvent,
              let payload = configuration?.payload,
              let string = payload.pasteboardValue else { return }
        let dx = event.locationInWindow.x - start.locationInWindow.x
        let dy = event.locationInWindow.y - start.locationInWindow.y
        guard hypot(dx, dy) >= 3 else { return }
        hoverDisclosurePresenter.cancel()

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(string, forType: Self.pasteboardType)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let point = convert(event.locationInWindow, from: nil)
        let startPoint = convert(start.locationInWindow, from: nil)
        let image = renderedElementSnapshot()
            ?? NSImage(size: bounds.size)
        draggingItem.setDraggingFrame(
            NSRect(
                origin: NSPoint(x: point.x - startPoint.x,
                                y: point.y - startPoint.y),
                size: bounds.size),
            contents: image)

        beganDrag = true
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if !beganDrag {
            let point = convert(event.locationInWindow, from: nil)
            if configuration?.menuItems.isEmpty == false,
               configuration?.menuHitRegion.contains(
                horizontalOffset: point.x, width: bounds.width) == true {
                showConfiguredMenu(with: event)
            } else {
                configuration?.activate?()
            }
        }
        mouseDownEvent = nil
        beganDrag = false
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext)
        -> NSDragOperation {
        .move
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        // Ordinary drag is the product gesture. Option/Control must not turn
        // a navigation move into a copy or a second mode.
        true
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        guard let payload = configuration?.payload else { return }
        configuration?.dragEnded?(payload)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo)
        -> NSDragOperation {
        guard let (payload, target) = accepted(sender),
              configuration?.previewDrop(payload, target) == true else {
            clearDropFeedback()
            return []
        }
        transitionFeedback(to: target)
        sender.numberOfValidItemsForDrop = 1
        return .move
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo)
        -> NSDragOperation {
        guard let (payload, target) = accepted(sender),
              configuration?.previewDrop(payload, target) == true else {
            clearDropFeedback()
            return []
        }
        transitionFeedback(to: target)
        return .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        clearSpringLoadArming()
        clearDropFeedback()
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo)
        -> Bool {
        accepted(sender) != nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let (payload, target) = accepted(sender) else { return false }
        let performed = configuration?.performDrop(payload, target) ?? false
        clearSpringLoadArming()
        clearDropFeedback()
        return performed
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        clearSpringLoadArming()
        clearDropFeedback()
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        clearSpringLoadArming()
        clearDropFeedback()
    }

    override func wantsPeriodicDraggingUpdates() -> Bool { false }

    func springLoadingEntered(_ draggingInfo: any NSDraggingInfo)
        -> NSSpringLoadingOptions {
        guard let target = springLoadingTarget(draggingInfo) else {
            clearSpringLoadArming()
            return []
        }
        if springFeedback.target != target { springFeedback.enter(target) }
        // Continuous activation because arming and activation now answer to
        // different questions: the row stays armed wherever the pointer is,
        // while activation waits for it to be over the row's own band. A
        // single activation spent while the person was aiming at the gap
        // above the row would otherwise be the only one this entry ever got.
        return [.enabled, .continuousActivation]
    }

    func springLoadingUpdated(_ draggingInfo: any NSDraggingInfo)
        -> NSSpringLoadingOptions {
        springLoadingEntered(draggingInfo)
    }

    func springLoadingActivated(_ activated: Bool,
                                draggingInfo: any NSDraggingInfo) {
        guard let target = springLoadingTarget(draggingInfo),
              pointerIsOverRowsOwnTarget(draggingInfo, target: target) else {
            return
        }
        guard NavigationSpringLoadActivation.shouldActivate(
            activated: activated, acceptedTarget: target,
            feedback: &springFeedback) else { return }
        flashTwice()
        configuration?.springLoad?()
    }

    /// Whether the pointer is resting on the row itself rather than on the
    /// gap either side of it.
    ///
    /// Arming deliberately ignores the bands — that is what keeps AppKit's
    /// dwell running across a boundary crossing — but *opening* the row on a
    /// dwell spent aiming at an insertion would be the H7 defect wearing a
    /// different hat: the shelf springs open, the sidebar relayouts, and the
    /// stack moves out from under a pointer that was aiming between two rows.
    /// Finder shows the same restraint; an insertion line does not open
    /// anything.
    private func pointerIsOverRowsOwnTarget(
        _ sender: any NSDraggingInfo, target: NavigationDropTarget
    ) -> Bool {
        guard configuration?.rowDropTargets != nil else { return true }
        return accepted(sender)?.1 == target
    }

    /// What this row would spring-load into, independent of which insertion
    /// band the pointer happens to be over. `accepted(_:)` answers the band,
    /// which is the right answer for the insertion line and the wrong one for
    /// arming: two of the three bands are `.zone` targets that never support
    /// spring loading.
    private func springLoadingTarget(_ sender: any NSDraggingInfo)
        -> NavigationDropTarget? {
        guard let configuration, configuration.springLoad != nil,
              let value = sender.draggingPasteboard.string(
                forType: Self.pasteboardType),
              let payload = NavigationDraggedItem(pasteboardValue: value)
        else { return nil }
        if let targets = configuration.rowDropTargets {
            return targets.springLoadingTarget {
                configuration.canDrop(payload, $0)
            }
        }
        guard let fallback = configuration.target,
              fallback.supportsSpringLoading,
              configuration.canDrop(payload, fallback) else { return nil }
        return fallback
    }

    func springLoadingHighlightChanged(_ draggingInfo: any NSDraggingInfo) {
        guard draggingInfo.springLoadingHighlight != .none,
              let target = accepted(draggingInfo)?.1 else { return }
        showDropFeedback(for: target)
    }

    func springLoadingExited(_ draggingInfo: any NSDraggingInfo) {
        clearSpringLoadArming()
        clearDropFeedback()
    }

    /// Only a drag that has left this row or finished disarms it. Crossing a
    /// band boundary must not, or the dwell never completes.
    private func clearSpringLoadArming() {
        if let armed = springFeedback.target { springFeedback.exit(armed) }
    }

    private func accepted(_ sender: any NSDraggingInfo)
        -> (NavigationDraggedItem, NavigationDropTarget)? {
        guard let configuration,
              let fallbackTarget = configuration.target,
              let value = sender.draggingPasteboard.string(
                forType: Self.pasteboardType),
              let payload = NavigationDraggedItem(pasteboardValue: value),
              let target = resolvedTarget(
                sender, configuration: configuration,
                fallback: fallbackTarget, payload: payload) else { return nil }
        return (payload, target)
    }

    private func resolvedTarget(
        _ sender: any NSDraggingInfo,
        configuration: Configuration,
        fallback: NavigationDropTarget,
        payload: NavigationDraggedItem
    ) -> NavigationDropTarget? {
        guard let targets = configuration.rowDropTargets else {
            return configuration.canDrop(payload, fallback) ? fallback : nil
        }
        let location = convert(sender.draggingLocation, from: nil)
        return targets.acceptedTarget(
            at: location.y, height: bounds.height,
            previous: feedback.target) {
                configuration.canDrop(payload, $0)
            }
    }

    /// The representable itself is transparent because it sits over the
    /// SwiftUI row or pill. Snapshot the same rectangle from the window's
    /// content view so AppKit drags the element the person actually grabbed.
    private func renderedElementSnapshot() -> NSImage? {
        guard !bounds.isEmpty,
              let contentView = window?.contentView else { return nil }
        let sourceRect = convert(bounds, to: contentView)
        var snapshot: NSImage?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let representation = contentView
                .bitmapImageRepForCachingDisplay(in: sourceRect) else { return }
            contentView.cacheDisplay(in: sourceRect, to: representation)
            let image = NSImage(size: sourceRect.size)
            image.addRepresentation(representation)
            snapshot = image
        }
        return snapshot
    }

    func showConfiguredMenu(with event: NSEvent) {
        guard let items = configuration?.menuItems, !items.isEmpty else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            let menuItem = NSMenuItem(title: item.title,
                                      action: nil, keyEquivalent: "")
            menuItem.isEnabled = true
            menuItem.view = SidebarModuleMenuItemView(item: item)
            menu.addItem(menuItem)
        }
        let point = convert(event.locationInWindow, from: nil)
        presentMenu(menu, NSPoint(x: point.x, y: bounds.maxY), self)
        synchroniseHoverWithPointer()
    }

    /// The menu's modal tracking loop takes mouse dispatch for its lifetime,
    /// so the `mouseExited` that would clear this row's highlight is spent
    /// there and never reaches the tracking area. Where the enter/exit pair
    /// cannot be trusted the pointer itself is the only honest source — and
    /// it has to be asked, not assumed `false`, because the pointer is
    /// commonly still resting on the row when the menu closes.
    func synchroniseHoverWithPointer() {
        let inside = pointerIsInsideRow
        configuration?.hoverChanged?(inside)
        // A disclosure card is a dwell affordance rather than a hover state:
        // re-arming it as the menu dismisses would pop it over the dismissal.
        if inside {
            hoverDisclosurePresenter.cancel()
        } else {
            hoverDisclosurePresenter.pointerExited()
        }
    }

    private var pointerIsInsideRow: Bool {
        guard let window else { return false }
        return bounds.contains(
            convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let dropFeedback,
              dropFeedback != .center else { return }
        let lineHeight: CGFloat = 2
        let y = dropFeedback == .insertionBefore
            ? 0 : max(0, bounds.height - lineHeight)
        NSColor.controlAccentColor.setFill()
        NSRect(x: 7, y: y,
               width: max(0, bounds.width - 14),
               height: lineHeight).fill()
    }

    private func transitionFeedback(to target: NavigationDropTarget) {
        if let active = feedback.target, active != target {
            feedback.exit(active)
        }
        if feedback.target != target {
            feedback.enter(target)
        }
        showDropFeedback(for: target)
    }

    private func showDropFeedback(for target: NavigationDropTarget) {
        let presentation = configuration?.rowDropTargets?
            .feedback(for: target) ?? .center
        dropFeedback = presentation
        let showsCenter = presentation == .center
        layer?.borderWidth = showsCenter ? 1.5 : 0
        layer?.borderColor = showsCenter
            ? NSColor.controlAccentColor.withAlphaComponent(0.72).cgColor
            : NSColor.clear.cgColor
        needsDisplay = true
    }

    private func clearDropFeedback() {
        if let active = feedback.target { feedback.exit(active) }
        dropFeedback = nil
        layer?.borderWidth = 0
        layer?.borderColor = NSColor.clear.cgColor
        needsDisplay = true
    }

    private func flashTwice() {
        guard let layer else { return }
        let animation = CABasicAnimation(keyPath: "backgroundColor")
        animation.fromValue = NSColor.clear.cgColor
        animation.toValue = NSColor.controlAccentColor
            .withAlphaComponent(0.28).cgColor
        animation.duration = 0.13
        animation.autoreverses = true
        animation.repeatCount = NavigationSpringLoadFlash.animationRepeatCount
        layer.add(animation, forKey: "navigation-double-flash")
    }
}
