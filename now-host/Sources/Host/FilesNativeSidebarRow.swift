import AppKit
import SwiftUI

/// One source-list row shared by the guest and host sidebars. AppKit owns
/// pointer hover, drag validation, spring-loading timing, and edge autoscroll;
/// the filesystem-specific closure only translates activation or acceptance.
struct FilesNativeSidebarRow: NSViewRepresentable {
    let title: String
    let symbolName: String
    let compact: Bool
    let isActive: Bool
    let isEnabled: Bool
    let toolTip: String
    let draggedTypes: [NSPasteboard.PasteboardType]
    let activate: () -> Void
    let validateDrop: (NSDraggingInfo) -> NSDragOperation
    let acceptDrop: (NSDraggingInfo) -> Bool

    func makeNSView(context: Context) -> FilesSidebarRowButton {
        let button = FilesSidebarRowButton()
        button.registerForDraggedTypes(draggedTypes)
        update(button)
        return button
    }

    func updateNSView(_ button: FilesSidebarRowButton, context: Context) {
        update(button)
    }

    private func update(_ button: FilesSidebarRowButton) {
        button.configure(title: title, symbolName: symbolName,
                         compact: compact, isActive: isActive,
                         isEnabled: isEnabled, toolTip: toolTip,
                         activate: activate, validateDrop: validateDrop,
                         acceptDrop: acceptDrop)
    }
}

@MainActor
final class FilesSidebarRowButton: NSButton, NSSpringLoadingDestination {
    private var activateHandler: () -> Void = {}
    private var validateDropHandler: (NSDraggingInfo) -> NSDragOperation = {
        _ in []
    }
    private var acceptDropHandler: (NSDraggingInfo) -> Bool = { _ in false }
    private var pointerInside = false
    private var active = false
    private var springHighlight: NSSpringLoadingHighlight = .none
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setButtonType(.momentaryChange)
        isBordered = false
        bezelStyle = .recessed
        imagePosition = .imageLeading
        alignment = .left
        font = .systemFont(ofSize: NSFont.systemFontSize)
        target = self
        action = #selector(activateRow(_:))
        wantsLayer = true
        layer?.cornerRadius = FilesStyle.rowSelectionCornerRadius
    }

    required init?(coder: NSCoder) { nil }

    func configure(
        title: String, symbolName: String, compact: Bool, isActive: Bool,
        isEnabled: Bool, toolTip: String,
        activate: @escaping () -> Void,
        validateDrop: @escaping (NSDraggingInfo) -> NSDragOperation,
        acceptDrop: @escaping (NSDraggingInfo) -> Bool
    ) {
        self.title = compact ? "" : title
        image = NSImage(systemSymbolName: symbolName,
                        accessibilityDescription: title)
        image?.isTemplate = true
        imagePosition = compact ? .imageOnly : .imageLeading
        alignment = compact ? .center : .left
        active = isActive
        refreshTint()
        self.isEnabled = isEnabled
        self.toolTip = toolTip
        setAccessibilityLabel(title)
        setAccessibilityRole(.button)
        setAccessibilitySelected(isActive)
        activateHandler = activate
        validateDropHandler = validateDrop
        acceptDropHandler = acceptDrop
        state = isActive ? .on : .off
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshTint()
    }

    private func refreshTint() {
        let semanticColor: NSColor = active ? .controlAccentColor
                                            : .secondaryLabelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            contentTintColor = semanticColor.usingColorSpace(.deviceRGB)
                ?? semanticColor
        }
    }

    @objc private func activateRow(_ sender: Any?) { activateHandler() }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(tracking)
        self.tracking = tracking
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = springHighlight != .none || pointerInside || state == .on
        if highlighted {
            let alpha: CGFloat = springHighlight == .emphasized ? 0.28
                : state == .on ? 0.17 : 0.10
            NSColor.controlAccentColor.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: bounds,
                         xRadius: FilesStyle.rowSelectionCornerRadius,
                         yRadius: FilesStyle.rowSelectionCornerRadius).fill()
        }
        super.draw(dirtyRect)
    }

    override func draggingEntered(_ sender: NSDraggingInfo)
        -> NSDragOperation {
        guard isEnabled else { return [] }
        let operation = validateDropHandler(sender)
        needsDisplay = true
        return operation
    }

    override func draggingUpdated(_ sender: NSDraggingInfo)
        -> NSDragOperation {
        guard isEnabled else { return [] }
        FilesNativeDragAutoscroll.update(self)
        return validateDropHandler(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        springHighlight = .none
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        springHighlight = .none
        needsDisplay = true
        return isEnabled && acceptDropHandler(sender)
    }

    override func wantsPeriodicDraggingUpdates() -> Bool { true }

    func springLoadingEntered(_ draggingInfo: NSDraggingInfo)
        -> NSSpringLoadingOptions {
        guard isEnabled else { return .disabled }
        return validateDropHandler(draggingInfo).isEmpty
            ? NSSpringLoadingOptions.disabled
            : NSSpringLoadingOptions.enabled
    }

    func springLoadingUpdated(_ draggingInfo: NSDraggingInfo)
        -> NSSpringLoadingOptions {
        springLoadingEntered(draggingInfo)
    }

    func springLoadingActivated(_ activated: Bool,
                                draggingInfo: NSDraggingInfo) {
        if activated { activateHandler() }
    }

    func springLoadingHighlightChanged(_ draggingInfo: NSDraggingInfo) {
        springHighlight = draggingInfo.springLoadingHighlight
        needsDisplay = true
    }

    func springLoadingExited(_ draggingInfo: NSDraggingInfo) {
        springHighlight = .none
        needsDisplay = true
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        springHighlight = .none
        needsDisplay = true
        super.draggingEnded(sender)
    }
}
