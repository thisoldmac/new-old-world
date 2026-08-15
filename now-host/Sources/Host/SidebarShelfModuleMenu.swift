import AppKit

/// A custom native menu row preserves ordinary menu presentation while also
/// acting as a first-class source for the existing navigation pasteboard type.
@MainActor
final class SidebarModuleMenuItemView: NSView, NSDraggingSource {
    private static let size = NSSize(width: 220, height: 30)
    private let item: SidebarNativeMenuItem
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private var mouseDownEvent: NSEvent?
    private var beganDrag = false
    private var hovering = false
    private var trackingArea: NSTrackingArea?

    init(item: SidebarNativeMenuItem) {
        self.item = item
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.size.width).isActive = true
        heightAnchor.constraint(equalToConstant: Self.size.height).isActive = true

        iconView.image = NSImage(systemSymbolName: item.symbol,
                                 accessibilityDescription: item.title)
        iconView.image?.isTemplate = true
        iconView.translatesAutoresizingMaskIntoConstraints = false
        titleField.stringValue = item.title
        titleField.lineBreakMode = .byTruncatingTail
        titleField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        addSubview(titleField)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor,
                                               constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor,
                                                constant: 8),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor,
                                                 constant: -10),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(item.title)
        refreshColors()
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { Self.size }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        refreshColors()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        refreshColors()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        beganDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !beganDrag, let start = mouseDownEvent,
              let value = item.payload.pasteboardValue else { return }
        let dx = event.locationInWindow.x - start.locationInWindow.x
        let dy = event.locationInWindow.y - start.locationInWindow.y
        guard hypot(dx, dy) >= 3 else { return }

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(
            value, forType: NativeNavigationDragView.pasteboardType)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(bounds, contents: snapshot())
        beganDrag = true
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard !beganDrag else { return }
        choose()
    }

    override func accessibilityPerformPress() -> Bool {
        choose()
        return true
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext)
        -> NSDragOperation { .move }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        enclosingMenuItem?.menu?.cancelTracking()
        item.dragEnded(item.payload)
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 2),
                         xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
    }

    private func refreshColors() {
        let color: NSColor = hovering
            ? .alternateSelectedControlTextColor : .labelColor
        iconView.contentTintColor = color
        titleField.textColor = color
    }

    private func choose() {
        enclosingMenuItem?.menu?.cancelTracking()
        item.action()
    }

    private func snapshot() -> NSImage {
        let image = NSImage(size: bounds.size)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if let representation = bitmapImageRepForCachingDisplay(in: bounds) {
                cacheDisplay(in: bounds, to: representation)
                image.addRepresentation(representation)
            }
        }
        return image
    }
}
