import AppKit
import SwiftUI

/// The `.sidebar` vibrancy material `RightSidebarRailView` already uses
/// for the collapsed rail, made reusable as a plain SwiftUI background.
///
/// H2: the leading Places sidebars (`FilesPlacesSidebar`, `HostFilesSidebar`)
/// painted flat `controlBackgroundColor` behind a `.sidebar`-style `List`,
/// so they never matched the real vibrancy the collapsed rail already had —
/// same material, two different implementations, only one of them correct.
struct SidebarVibrancyBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// A secondary surface as a complete right sidebar. One AppKit split
/// controller owns its divider, full content, collapsed rail, and every
/// transition between them so collapse state cannot drift between two layout
/// systems.
///
/// **Two consumers, one implementation.** Files built this for "This Mac"
/// beside the guest browser; Connections uses the same component for its
/// machines roster beside the selected machine. The only thing that differs
/// is `trailingTitle`, which names the surface in the rail's tooltip, its
/// hover tag, the toggle's help, and both accessibility labels — so a second
/// consumer cannot arrive wearing the first one's words.
struct RightSidebarSplitView<Leading: View, Trailing: View>: View {
    let isTrailingCollapsed: Bool
    let onTrailingCollapseChanged: (Bool) -> Void
    @Binding var leadingFraction: CGFloat
    let trailingTitle: String
    let leading: Leading
    let trailing: Trailing

    var body: some View {
        RightSidebarNativeSplitView(
            isTrailingCollapsed: isTrailingCollapsed,
            onTrailingCollapseChanged: onTrailingCollapseChanged,
            leadingFraction: $leadingFraction,
            trailingTitle: trailingTitle,
            leading: leading,
            trailing: trailing)
    }
}

struct RightSidebarToggle: View {
    let isCollapsed: Bool
    let title: String
    let action: () -> Void

    private var label: String {
        (isCollapsed ? "Show " : "Hide ") + title
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.trailing")
                /* The host's containment metrics happen to live in
                   `FilesStyle`; this control is the same silhouette as
                   every other chrome control, so it reads them rather
                   than restating the numbers. */
                .frame(width: FilesStyle.controlHeight,
                       height: FilesStyle.controlHeight)
        }
        .nowGlassButton()
        .accessibilityLabel(label)
        .help(label)
    }
}

@MainActor
final class RightSidebarRailView: NSVisualEffectView,
    NSSpringLoadingDestination {
    static let hoverDelay: TimeInterval = 0.45
    static let hoverScale: CGFloat = 1.015

    var onExpand: () -> Void = {}
    /// What this rail reopens, in the person's words. Set by whoever
    /// installs the sidebar; every label the rail draws is derived from it,
    /// so a consumer cannot leave another consumer's noun behind.
    var title: String = "" {
        didSet { applyTitle() }
    }
    private let iconView = NSImageView()
    private let grip = NSBox()
    private var hoverWorkItem: DispatchWorkItem?
    private var trackingArea: NSTrackingArea?
    private var disclosurePopover: NSPopover?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .sidebar
        blendingMode = .withinWindow
        state = .active
        registerForDraggedTypes(
            [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map {
                NSPasteboard.PasteboardType($0)
            })
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: "chevron.left",
                                 accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 16, weight: .regular)
        iconView.contentTintColor = .secondaryLabelColor
        iconView.imageScaling = .scaleProportionallyDown
        grip.translatesAutoresizingMaskIntoConstraints = false
        grip.boxType = .separator
        addSubview(iconView)
        addSubview(grip)
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
            grip.leadingAnchor.constraint(equalTo: leadingAnchor),
            grip.topAnchor.constraint(equalTo: topAnchor),
            grip.bottomAnchor.constraint(equalTo: bottomAnchor),
            grip.widthAnchor.constraint(equalToConstant: 2),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        applyTitle()
        wantsLayer = true
        layer?.cornerRadius = FilesStyle.outerSurfaceCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { nil }

    private func applyTitle() {
        let label = "Show \(title)"
        toolTip = label
        iconView.image?.accessibilityDescription = label
        setAccessibilityLabel(label)
    }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited,
                      .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
        hoverWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.showDisclosure()
        }
        hoverWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverDelay,
                                      execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
        hoverWorkItem?.cancel()
        hideDisclosure()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        hoverWorkItem?.cancel()
        hideDisclosure()
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        expand()
    }

    override func accessibilityPerformPress() -> Bool {
        expand()
        return true
    }

    private func expand() {
        hoverWorkItem?.cancel()
        hideDisclosure()
        onExpand()
    }

    private func showDisclosure() {
        guard disclosurePopover == nil, window != nil else { return }
        let label = NSTextField(labelWithString: title)
        label.alignment = .center
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize,
                                 weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let controller = NSViewController()
        let content = NSView()
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor,
                                           constant: 12),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor,
                                            constant: -12),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        controller.view = content

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        /* Sized from the label rather than pinned at one width: the tag
           carries whatever the consumer named its sidebar, and a fixed box
           truncated the second consumer's noun. */
        popover.contentSize = NSSize(
            width: max(92, label.intrinsicContentSize.width + 24), height: 38)
        popover.contentViewController = controller
        let anchor = NSRect(x: bounds.minX, y: bounds.midY,
                            width: 1, height: 1)
        popover.show(relativeTo: anchor, of: self, preferredEdge: .minX)
        disclosurePopover = popover
    }

    private func hideDisclosure() {
        disclosurePopover?.performClose(nil)
        disclosurePopover = nil
    }

    private func setHovered(_ hovered: Bool) {
        let reduceMotion =
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let background = hovered
            ? NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
            : nil
        let scale = hovered && !reduceMotion ? Self.hoverScale : 1
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.14)
        CATransaction.setAnimationTimingFunction(
            CAMediaTimingFunction(name: .easeOut))
        layer?.backgroundColor = background
        layer?.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
        /* H10: the chevron itself bounces on hover, layered over the
           whole-rail scale + tint above rather than replacing either —
           the rail says "hoverable," the chevron says "this is the
           control that opens it." Reduce Motion turns off the rail's
           own scale animation already; the symbol effect honours the
           same signal rather than reading it a second, inconsistent
           way. macOS 14 is the SymbolEffect floor and this package's is
           13 (Package.swift `.v13`, MACOSX_DEPLOYMENT_TARGET 13.0), so
           it is additive polish, not a requirement. */
        if #available(macOS 14, *) {
            if hovered && !reduceMotion {
                iconView.addSymbolEffect(
                    .bounce.up, options: .nonRepeating)
            } else {
                iconView.removeAllSymbolEffects()
            }
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo)
        -> NSDragOperation { .generic }

    override func draggingUpdated(_ sender: NSDraggingInfo)
        -> NSDragOperation { .generic }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        clearSpringHighlight()
        return false
    }

    func springLoadingEntered(_ draggingInfo: NSDraggingInfo)
        -> NSSpringLoadingOptions { .enabled }

    func springLoadingUpdated(_ draggingInfo: NSDraggingInfo)
        -> NSSpringLoadingOptions { .enabled }

    func springLoadingActivated(_ activated: Bool,
                                draggingInfo: NSDraggingInfo) {
        if activated { expand() }
    }

    func springLoadingHighlightChanged(_ draggingInfo: NSDraggingInfo) {
        let highlight = draggingInfo.springLoadingHighlight
        layer?.backgroundColor = highlight == .none ? nil
            : NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
    }

    func springLoadingExited(_ draggingInfo: NSDraggingInfo) {
        clearSpringHighlight()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        clearSpringHighlight()
        hideDisclosure()
        super.draggingEnded(sender)
    }

    private func clearSpringHighlight() {
        setHovered(false)
    }
}

/// AppKit owns sizing, cursor feedback, and the effective drag region. This
/// avoids synthesizing a second splitter interaction.
private struct RightSidebarNativeSplitView<Leading: View, Trailing: View>:
    NSViewControllerRepresentable {
    let isTrailingCollapsed: Bool
    let onTrailingCollapseChanged: (Bool) -> Void
    @Binding var leadingFraction: CGFloat
    let trailingTitle: String
    let leading: Leading
    let trailing: Trailing

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSViewController(context: Context)
        -> RightSidebarSplitController {
        let controller = RightSidebarSplitController()
        controller.leadingFractionChanged = {
            [weak coordinator = context.coordinator] fraction in
            coordinator?.setLeadingFraction(fraction)
        }
        controller.trailingCollapseRequested = {
            [weak coordinator = context.coordinator] collapsed in
            coordinator?.requestCollapse(collapsed)
        }
        let leadingHost = NSHostingController(rootView: leading)
        let trailingHost = NSHostingController(rootView: trailing)
        controller.install(
            leading: leadingHost,
            trailing: trailingHost,
            trailingCollapsed: isTrailingCollapsed,
            trailingTitle: trailingTitle,
            leadingFraction: leadingFraction)
        context.coordinator.leadingHost = leadingHost
        context.coordinator.trailingHost = trailingHost
        return controller
    }

    func updateNSViewController(_ controller: RightSidebarSplitController,
                                context: Context) {
        context.coordinator.parent = self
        context.coordinator.leadingHost?.rootView = leading
        context.coordinator.trailingHost?.rootView = trailing
        guard controller.isTrailingCollapsed != isTrailingCollapsed else {
            return
        }
        controller.setTrailingCollapsed(isTrailingCollapsed)
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: RightSidebarNativeSplitView
        var leadingHost: NSHostingController<Leading>?
        var trailingHost: NSHostingController<Trailing>?

        init(parent: RightSidebarNativeSplitView) {
            self.parent = parent
        }

        func requestCollapse(_ collapsed: Bool) {
            parent.onTrailingCollapseChanged(collapsed)
        }

        func setLeadingFraction(_ fraction: CGFloat) {
            guard abs(parent.leadingFraction - fraction) > 0.001 else { return }
            parent.leadingFraction = fraction
        }
    }
}

/// The trailing split item never disappears. This container swaps its full
/// browser for the narrow reopen rail while the split item itself stays in the
/// native hierarchy, avoiding a second divider or a stale collapsed item.
@MainActor
private final class RightSidebarContainerController: NSViewController {
    let railView = RightSidebarRailView()
    private let contentController: NSViewController
    private var collapsed = false
    private weak var displayedView: NSView?
    private var displayedConstraints: [NSLayoutConstraint] = []

    init(content: NSViewController) {
        contentController = content
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        view = container

        addChild(contentController)
        display(collapsed ? railView : contentController.view)
    }

    func setCollapsed(_ collapsed: Bool) {
        self.collapsed = collapsed
        guard isViewLoaded else { return }
        display(collapsed ? railView : contentController.view)
    }

    private func display(_ child: NSView) {
        guard displayedView !== child else { return }
        NSLayoutConstraint.deactivate(displayedConstraints)
        displayedView?.removeFromSuperview()

        child.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child)
        displayedConstraints = [
            child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.topAnchor.constraint(equalTo: view.topAnchor),
            child.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ]
        NSLayoutConstraint.activate(displayedConstraints)
        displayedView = child
    }
}

final class SidebarSplitView: NSSplitView {
    static let dividerHitSlop: CGFloat = 6
    static let sidebarDividerThickness: CGFloat = 8

    var usesSidebarHandle = false
    var allowsSidebarDividerResize = true

    override var dividerThickness: CGFloat {
        usesSidebarHandle ? Self.sidebarDividerThickness
                          : super.dividerThickness
    }

    override func drawDivider(in rect: NSRect) {
        guard usesSidebarHandle else {
            super.drawDivider(in: rect)
            return
        }

        NSColor.windowBackgroundColor.setFill()
        rect.fill()

        guard allowsSidebarDividerResize else { return }

        let length = max(0, min(28, rect.height - 12))
        let grip = NSRect(x: rect.midX - 1,
                          y: rect.midY - length / 2,
                          width: 2, height: length)
        NSColor.separatorColor.setFill()
        NSBezierPath(roundedRect: grip, xRadius: 1, yRadius: 1).fill()
    }

    func dividerInteractionRect(at dividerIndex: Int) -> NSRect? {
        guard arrangedSubviews.indices.contains(dividerIndex) else {
            return nil
        }
        let pane = arrangedSubviews[dividerIndex].frame
        let drawn = isVertical
            ? NSRect(x: pane.maxX, y: bounds.minY,
                     width: dividerThickness, height: bounds.height)
            : NSRect(x: bounds.minX, y: pane.maxY,
                     width: bounds.width, height: dividerThickness)
        return isVertical
            ? drawn.insetBy(dx: -Self.dividerHitSlop, dy: 0)
            : drawn.insetBy(dx: 0, dy: -Self.dividerHitSlop)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard allowsSidebarDividerResize else { return }
        let cursor = isVertical ? NSCursor.resizeLeftRight
                                : NSCursor.resizeUpDown
        for dividerIndex in 0..<max(0, arrangedSubviews.count - 1) {
            if let rect = dividerInteractionRect(at: dividerIndex) {
                addCursorRect(rect, cursor: cursor)
            }
        }
    }
}

class SidebarSplitViewController: NSSplitViewController {
    init() {
        super.init(nibName: nil, bundle: nil)
        splitView = SidebarSplitView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        splitView = SidebarSplitView()
    }

    override func splitView(_ splitView: NSSplitView,
                            effectiveRect proposedEffectiveRect: NSRect,
                            forDrawnRect drawnRect: NSRect,
                            ofDividerAt dividerIndex: Int) -> NSRect {
        let inherited = super.splitView(
            splitView, effectiveRect: proposedEffectiveRect,
            forDrawnRect: drawnRect, ofDividerAt: dividerIndex)
        let slop = SidebarSplitView.dividerHitSlop
        let nativeHandle = splitView.isVertical
            ? drawnRect.insetBy(dx: -slop, dy: 0)
            : drawnRect.insetBy(dx: 0, dy: -slop)
        return inherited.union(nativeHandle)
    }
}

final class RightSidebarSplitController: SidebarSplitViewController {
    static let defaultLeadingFraction: CGFloat = 0.5
    static let collapsedRailWidth: CGFloat = 54

    weak var trailingItem: NSSplitViewItem?
    var leadingFractionChanged: ((CGFloat) -> Void)?
    var trailingCollapseRequested: ((Bool) -> Void)?
    private var hasPlacedInitialDivider = false
    private var isChangingDivider = false
    private weak var trailingContainer: RightSidebarContainerController?
    private(set) var isTrailingCollapsed = false
    private(set) var expandedLeadingFraction =
        RightSidebarSplitController.defaultLeadingFraction

    @discardableResult
    func install(leading: NSViewController,
                 trailing: NSViewController,
                 trailingCollapsed: Bool,
                 trailingTitle: String = "",
                 leadingFraction: CGFloat =
                    RightSidebarSplitController.defaultLeadingFraction)
        -> NSSplitViewItem {
        expandedLeadingFraction = min(1, max(0, leadingFraction))
        let nativeSplit = splitView as? SidebarSplitView
        nativeSplit?.usesSidebarHandle = true
        splitView.dividerStyle = .thin
        splitView.isVertical = true
        let leadingItem = NSSplitViewItem(viewController: leading)
        let trailingContainer = RightSidebarContainerController(
            content: trailing)
        let trailingItem = NSSplitViewItem(viewController: trailingContainer)
        leadingItem.minimumThickness = 260
        leadingItem.preferredThicknessFraction = 0.5
        leadingItem.holdingPriority = .defaultLow
        trailingItem.preferredThicknessFraction = 0.5
        trailingItem.holdingPriority = .defaultLow
        // The rail is the collapsed state. Keeping the item present prevents
        // AppKit's collapsed-item divider from coexisting with another handle.
        trailingItem.canCollapse = false
        trailingItem.canCollapseFromWindowResize = false
        trailingItem.isSpringLoaded = false
        addSplitViewItem(leadingItem)
        addSplitViewItem(trailingItem)
        self.trailingItem = trailingItem
        self.trailingContainer = trailingContainer
        isTrailingCollapsed = trailingCollapsed
        trailingContainer.setCollapsed(trailingCollapsed)
        trailingContainer.railView.title = trailingTitle
        trailingContainer.railView.onExpand = { [weak self] in
            guard let self else { return }
            self.setTrailingCollapsed(false)
            self.trailingCollapseRequested?(false)
        }
        configureTrailingThickness(
            collapsed: trailingCollapsed,
            width: Self.collapsedRailWidth)
        nativeSplit?.allowsSidebarDividerResize = !trailingCollapsed
        return trailingItem
    }

    func setTrailingCollapsed(_ collapsed: Bool) {
        guard let trailingItem, collapsed != isTrailingCollapsed else {
            return
        }
        if collapsed {
            rememberExpandedDivider()
            isTrailingCollapsed = true
            trailingContainer?.setCollapsed(true)
            configureTrailingThickness(collapsed: true,
                                       width: Self.collapsedRailWidth)
            animateDivider(to: dividerPosition(
                trailingWidth: Self.collapsedRailWidth))
        } else {
            isTrailingCollapsed = false
            configureTrailingThickness(collapsed: false, width: 0)
            trailingContainer?.setCollapsed(false)
            restoreExpandedDivider(animated: view.window != nil)
        }
        trailingItem.isCollapsed = false
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !hasPlacedInitialDivider,
              splitView.arrangedSubviews.count == 2 else { return }
        let requiredWidth = isTrailingCollapsed
            ? 260 + splitView.dividerThickness + Self.collapsedRailWidth
            : 520
        guard splitView.bounds.width >= requiredWidth else { return }
        hasPlacedInitialDivider = true
        if isTrailingCollapsed {
            setDividerImmediately(to: dividerPosition(
                trailingWidth: Self.collapsedRailWidth))
        } else {
            restoreExpandedDivider(animated: false)
        }
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        guard hasPlacedInitialDivider,
              !isTrailingCollapsed,
              !isChangingDivider else { return }
        rememberExpandedDivider()
    }

    override func splitView(_ splitView: NSSplitView,
                            constrainSplitPosition proposedPosition: CGFloat,
                            ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard isTrailingCollapsed else { return proposedPosition }
        return dividerPosition(trailingWidth: Self.collapsedRailWidth)
    }

    private func rememberExpandedDivider() {
        guard splitView.arrangedSubviews.count == 2 else { return }
        let available = splitView.bounds.width - splitView.dividerThickness
        guard available > 0 else { return }
        expandedLeadingFraction = splitView.arrangedSubviews[0].frame.width
            / available
        leadingFractionChanged?(expandedLeadingFraction)
    }

    private func restoreExpandedDivider(animated: Bool) {
        let available = splitView.bounds.width - splitView.dividerThickness
        guard available > 0 else { return }
        let proposed = available * expandedLeadingFraction
        let position = min(splitView.maxPossiblePositionOfDivider(at: 0),
                           max(splitView.minPossiblePositionOfDivider(at: 0),
                               proposed))
        if animated {
            animateDivider(to: position)
        } else {
            setDividerImmediately(to: position)
        }
    }

    private func configureTrailingThickness(collapsed: Bool, width: CGFloat) {
        guard let trailingItem else { return }
        if collapsed {
            trailingItem.maximumThickness = NSSplitViewItem
                .unspecifiedDimension
            trailingItem.minimumThickness = width
            trailingItem.maximumThickness = width
        } else {
            trailingItem.maximumThickness = NSSplitViewItem
                .unspecifiedDimension
            trailingItem.minimumThickness = 260
        }
        (splitView as? SidebarSplitView)?.allowsSidebarDividerResize = !collapsed
        splitView.window?.invalidateCursorRects(for: splitView)
    }

    private func dividerPosition(trailingWidth: CGFloat) -> CGFloat {
        max(0, splitView.bounds.width - splitView.dividerThickness
            - trailingWidth)
    }

    private func setDividerImmediately(to position: CGFloat) {
        isChangingDivider = true
        splitView.setPosition(position, ofDividerAt: 0)
        splitView.layoutSubtreeIfNeeded()
        isChangingDivider = false
    }

    private func animateDivider(to position: CGFloat) {
        guard view.window != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            setDividerImmediately(to: position)
            return
        }
        isChangingDivider = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            splitView.animator().setPosition(position, ofDividerAt: 0)
        } completionHandler: { [weak self] in
            Task { @MainActor in
                self?.isChangingDivider = false
            }
        }
    }
}
