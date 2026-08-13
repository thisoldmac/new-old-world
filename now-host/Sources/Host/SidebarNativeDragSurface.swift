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
    let performDrop: (NavigationDraggedItem, NavigationDropTarget) -> Bool
    var activate: (() -> Void)?
    var springLoad: (() -> Void)?
    var menuItems: [SidebarNativeMenuItem] = []

    func makeNSView(context: Context) -> NativeNavigationDragView {
        let view = NativeNavigationDragView()
        view.configuration = configuration
        return view
    }

    func updateNSView(_ view: NativeNavigationDragView, context: Context) {
        view.configuration = configuration
    }

    private var configuration: NativeNavigationDragView.Configuration {
        NativeNavigationDragView.Configuration(
            payload: payload,
            target: target,
            canDrop: canDrop,
            performDrop: performDrop,
            activate: activate,
            springLoad: springLoad,
            menuItems: menuItems)
    }
}

struct SidebarNativeMenuItem {
    let title: String
    let action: () -> Void
}

@MainActor
final class NativeNavigationDragView: NSView, NSDraggingSource,
                                      NSSpringLoadingDestination {
    struct Configuration {
        let payload: NavigationDraggedItem?
        let target: NavigationDropTarget?
        let canDrop: (NavigationDraggedItem, NavigationDropTarget) -> Bool
        let performDrop: (NavigationDraggedItem, NavigationDropTarget) -> Bool
        let activate: (() -> Void)?
        let springLoad: (() -> Void)?
        let menuItems: [SidebarNativeMenuItem]
    }

    static let pasteboardType = NSPasteboard.PasteboardType(
        "com.machineintent.newoldworld.navigation-item")

    var configuration: Configuration?
    private var mouseDownEvent: NSEvent?
    private var beganDrag = false
    private var feedback = NavigationDragFeedbackState()

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

    override func mouseDown(with event: NSEvent) {
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

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(string, forType: Self.pasteboardType)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let point = convert(event.locationInWindow, from: nil)
        let image = dragImage(for: payload)
        draggingItem.setDraggingFrame(
            NSRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24),
            contents: image)

        beganDrag = true
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if !beganDrag {
            if configuration?.menuItems.isEmpty == false {
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

    override func draggingEntered(_ sender: any NSDraggingInfo)
        -> NSDragOperation {
        guard let (_, target) = accepted(sender) else {
            feedback = NavigationDragFeedbackState()
            return []
        }
        feedback.enter(target)
        showDropHighlight(true)
        sender.numberOfValidItemsForDrop = 1
        return .move
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo)
        -> NSDragOperation {
        accepted(sender) == nil ? [] : .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        if let target = feedback.target { feedback.exit(target) }
        showDropHighlight(false)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo)
        -> Bool {
        accepted(sender) != nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let (payload, target) = accepted(sender) else { return false }
        let performed = configuration?.performDrop(payload, target) ?? false
        if let active = feedback.target { feedback.exit(active) }
        showDropHighlight(false)
        return performed
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        showDropHighlight(false)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        if let target = feedback.target { feedback.exit(target) }
        showDropHighlight(false)
    }

    override func wantsPeriodicDraggingUpdates() -> Bool { false }

    func springLoadingEntered(_ draggingInfo: any NSDraggingInfo)
        -> NSSpringLoadingOptions {
        guard accepted(draggingInfo) != nil,
              configuration?.target?.supportsSpringLoading == true else {
            return []
        }
        return .enabled
    }

    func springLoadingUpdated(_ draggingInfo: any NSDraggingInfo)
        -> NSSpringLoadingOptions {
        springLoadingEntered(draggingInfo)
    }

    func springLoadingActivated(_ activated: Bool,
                                draggingInfo: any NSDraggingInfo) {
        let target = accepted(draggingInfo)?.1
        guard NavigationSpringLoadActivation.shouldActivate(
            activated: activated, acceptedTarget: target,
            feedback: &feedback) else { return }
        flashTwice()
        configuration?.springLoad?()
    }

    func springLoadingHighlightChanged(_ draggingInfo: any NSDraggingInfo) {
        showDropHighlight(draggingInfo.springLoadingHighlight != .none)
    }

    func springLoadingExited(_ draggingInfo: any NSDraggingInfo) {
        if let target = feedback.target { feedback.exit(target) }
        showDropHighlight(false)
    }

    private func accepted(_ sender: any NSDraggingInfo)
        -> (NavigationDraggedItem, NavigationDropTarget)? {
        guard let configuration,
              let target = configuration.target,
              let value = sender.draggingPasteboard.string(
                forType: Self.pasteboardType),
              let payload = NavigationDraggedItem(pasteboardValue: value),
              configuration.canDrop(payload, target) else { return nil }
        return (payload, target)
    }

    private func dragImage(for payload: NavigationDraggedItem) -> NSImage {
        let symbol: String
        switch payload {
        case .module: symbol = "square.grid.2x2"
        case .shelf: symbol = "square.stack.3d.up"
        }
        return NSImage(systemSymbolName: symbol,
                       accessibilityDescription: "Move navigation item")
            ?? NSImage(size: NSSize(width: 24, height: 24))
    }

    private func showConfiguredMenu(with event: NSEvent) {
        guard let items = configuration?.menuItems, !items.isEmpty else { return }
        let menu = NSMenu()
        for (index, item) in items.enumerated() {
            let menuItem = NSMenuItem(title: item.title,
                                      action: #selector(chooseMenuItem(_:)),
                                      keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = index
            menu.addItem(menuItem)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func chooseMenuItem(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int,
              let items = configuration?.menuItems,
              items.indices.contains(index) else { return }
        items[index].action()
    }

    private func showDropHighlight(_ shown: Bool) {
        layer?.borderWidth = shown ? 1.5 : 0
        layer?.borderColor = shown
            ? NSColor.controlAccentColor.withAlphaComponent(0.72).cgColor
            : NSColor.clear.cgColor
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
