import AppKit
import SwiftUI

/// The host surface is a complete right sidebar. One AppKit split controller
/// owns its divider, full content, collapsed rail, and every transition between
/// them so collapse state cannot drift between two layout systems.
struct FilesRightSidebarSplitView<Leading: View, Trailing: View>: View {
    let isTrailingCollapsed: Bool
    let onTrailingCollapseChanged: (Bool) -> Void
    @Binding var leadingFraction: CGFloat
    let leading: Leading
    let trailing: Trailing

    var body: some View {
        FilesRightSidebarNativeSplitView(
            isTrailingCollapsed: isTrailingCollapsed,
            onTrailingCollapseChanged: onTrailingCollapseChanged,
            leadingFraction: $leadingFraction,
            leading: leading,
            trailing: trailing)
    }
}

struct FilesRightSidebarToggle: View {
    let isCollapsed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.trailing")
                .frame(width: FilesStyle.controlHeight,
                       height: FilesStyle.controlHeight)
        }
        .nowGlassButton()
        .accessibilityLabel(isCollapsed ? "Show This Mac" : "Hide This Mac")
        .help(isCollapsed ? "Show This Mac" : "Hide This Mac")
    }
}

@MainActor
private final class FilesRightSidebarRailView: NSVisualEffectView,
    NSSpringLoadingDestination {
    var onExpand: () -> Void = {}
    var onDisclosureChanged: (Bool) -> Void = { _ in }
    private let button = NSButton()
    private let label = NSTextField(labelWithString: "This Mac")
    private let grip = NSBox()
    private var hoverWorkItem: DispatchWorkItem?
    private var trackingArea: NSTrackingArea?
    private var isDisclosed = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .sidebar
        blendingMode = .withinWindow
        state = .active
        registerForDraggedTypes(
            [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map {
                NSPasteboard.PasteboardType($0)
            })
        button.translatesAutoresizingMaskIntoConstraints = false
        button.image = NSImage(systemSymbolName: "sidebar.trailing",
                               accessibilityDescription: "Show This Mac")
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.toolTip = "Show This Mac"
        button.target = self
        button.action = #selector(expand(_:))
        button.setAccessibilityLabel("Show This Mac")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize,
                                 weight: .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.alphaValue = 0
        grip.translatesAutoresizingMaskIntoConstraints = false
        grip.boxType = .separator
        addSubview(button)
        addSubview(label)
        addSubview(grip)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: topAnchor),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44),
            label.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: button.trailingAnchor,
                                           constant: 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor,
                                             constant: -8),
            grip.leadingAnchor.constraint(equalTo: leadingAnchor),
            grip.topAnchor.constraint(equalTo: topAnchor),
            grip.bottomAnchor.constraint(equalTo: bottomAnchor),
            grip.widthAnchor.constraint(equalToConstant: 2),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("This Mac sidebar")
        wantsLayer = true
        layer?.cornerRadius = FilesStyle.outerSurfaceCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { nil }

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
        hoverWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.setDisclosed(true)
        }
        hoverWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35,
                                      execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        hoverWorkItem?.cancel()
        setDisclosed(false, notify: false)
    }

    private func setDisclosed(_ disclosed: Bool, notify: Bool = true) {
        guard disclosed != isDisclosed else { return }
        isDisclosed = disclosed
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            label.animator().alphaValue = disclosed ? 1 : 0
        }
        if notify {
            onDisclosureChanged(disclosed)
        }
    }

    @objc private func expand(_ sender: Any?) {
        hoverWorkItem?.cancel()
        // Expansion restores the saved divider directly. Do not also animate
        // the disclosed rail back to its compact width: overlapping AppKit
        // divider animations can persist an intermediate split fraction.
        setDisclosed(false, notify: false)
        onExpand()
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
        if activated { expand(nil) }
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
        setDisclosed(false)
        super.draggingEnded(sender)
    }

    private func clearSpringHighlight() {
        layer?.backgroundColor = nil
    }
}

/// AppKit owns sizing, cursor feedback, and the effective drag region. This
/// avoids synthesizing a second splitter interaction.
private struct FilesRightSidebarNativeSplitView<Leading: View, Trailing: View>:
    NSViewControllerRepresentable {
    let isTrailingCollapsed: Bool
    let onTrailingCollapseChanged: (Bool) -> Void
    @Binding var leadingFraction: CGFloat
    let leading: Leading
    let trailing: Trailing

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSViewController(context: Context)
        -> FilesRightSidebarSplitController {
        let controller = FilesRightSidebarSplitController()
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
            leadingFraction: leadingFraction)
        context.coordinator.leadingHost = leadingHost
        context.coordinator.trailingHost = trailingHost
        return controller
    }

    func updateNSViewController(_ controller: FilesRightSidebarSplitController,
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
        var parent: FilesRightSidebarNativeSplitView
        var leadingHost: NSHostingController<Leading>?
        var trailingHost: NSHostingController<Trailing>?

        init(parent: FilesRightSidebarNativeSplitView) {
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
private final class FilesRightSidebarContainerController: NSViewController {
    let railView = FilesRightSidebarRailView()
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

final class FilesSplitView: NSSplitView {
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

class FilesSplitViewController: NSSplitViewController {
    init() {
        super.init(nibName: nil, bundle: nil)
        splitView = FilesSplitView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        splitView = FilesSplitView()
    }

    override func splitView(_ splitView: NSSplitView,
                            effectiveRect proposedEffectiveRect: NSRect,
                            forDrawnRect drawnRect: NSRect,
                            ofDividerAt dividerIndex: Int) -> NSRect {
        let inherited = super.splitView(
            splitView, effectiveRect: proposedEffectiveRect,
            forDrawnRect: drawnRect, ofDividerAt: dividerIndex)
        let slop = FilesSplitView.dividerHitSlop
        let nativeHandle = splitView.isVertical
            ? drawnRect.insetBy(dx: -slop, dy: 0)
            : drawnRect.insetBy(dx: 0, dy: -slop)
        return inherited.union(nativeHandle)
    }
}

final class FilesRightSidebarSplitController: FilesSplitViewController {
    static let defaultLeadingFraction: CGFloat = 0.5
    static let collapsedRailWidth: CGFloat = 54
    static let disclosedRailWidth: CGFloat = 112

    weak var trailingItem: NSSplitViewItem?
    var leadingFractionChanged: ((CGFloat) -> Void)?
    var trailingCollapseRequested: ((Bool) -> Void)?
    private var hasPlacedInitialDivider = false
    private var isChangingDivider = false
    private var railIsDisclosed = false
    private weak var trailingContainer: FilesRightSidebarContainerController?
    private(set) var isTrailingCollapsed = false
    private(set) var expandedLeadingFraction =
        FilesRightSidebarSplitController.defaultLeadingFraction

    @discardableResult
    func install(leading: NSViewController,
                 trailing: NSViewController,
                 trailingCollapsed: Bool,
                 leadingFraction: CGFloat =
                    FilesRightSidebarSplitController.defaultLeadingFraction)
        -> NSSplitViewItem {
        expandedLeadingFraction = min(1, max(0, leadingFraction))
        let nativeSplit = splitView as? FilesSplitView
        nativeSplit?.usesSidebarHandle = true
        splitView.dividerStyle = .thin
        splitView.isVertical = true
        let leadingItem = NSSplitViewItem(viewController: leading)
        let trailingContainer = FilesRightSidebarContainerController(
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
        trailingContainer.railView.onExpand = { [weak self] in
            guard let self else { return }
            self.setTrailingCollapsed(false)
            self.trailingCollapseRequested?(false)
        }
        trailingContainer.railView.onDisclosureChanged = { [weak self] in
            self?.setRailDisclosed($0)
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
            railIsDisclosed = false
            trailingContainer?.setCollapsed(true)
            configureTrailingThickness(collapsed: true,
                                       width: Self.collapsedRailWidth)
            animateDivider(to: dividerPosition(
                trailingWidth: Self.collapsedRailWidth))
        } else {
            isTrailingCollapsed = false
            railIsDisclosed = false
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
        let width = railIsDisclosed
            ? Self.disclosedRailWidth : Self.collapsedRailWidth
        return dividerPosition(trailingWidth: width)
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

    private func setRailDisclosed(_ disclosed: Bool) {
        guard isTrailingCollapsed, disclosed != railIsDisclosed else { return }
        railIsDisclosed = disclosed
        let width = disclosed ? Self.disclosedRailWidth
                              : Self.collapsedRailWidth
        configureTrailingThickness(collapsed: true, width: width)
        animateDivider(to: dividerPosition(trailingWidth: width))
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
        (splitView as? FilesSplitView)?.allowsSidebarDividerResize = !collapsed
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
