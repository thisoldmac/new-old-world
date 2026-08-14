import AppKit
import SwiftUI

/// The native parent of the sidebar's SwiftUI list is the fallback drop
/// destination for every point not covered by a row. Making the registered
/// view an ancestor matters: an overlay or a SwiftUI `onDrop` attached to the
/// list can sit behind `NSScrollView`'s empty document area and never receive
/// the drag.
struct SidebarCanvasDropHost<Content: View>: NSViewRepresentable {
    let upperItemCount: Int
    let lowerItemCount: Int
    let dragActions: SidebarNavigationDragActions
    let content: Content

    init(upperItemCount: Int,
         lowerItemCount: Int,
         dragActions: SidebarNavigationDragActions,
         @ViewBuilder content: () -> Content) {
        self.upperItemCount = upperItemCount
        self.lowerItemCount = lowerItemCount
        self.dragActions = dragActions
        self.content = content()
    }

    func makeNSView(context: Context) -> NativeSidebarCanvasDropView<Content> {
        NativeSidebarCanvasDropView(
            rootView: content,
            configuration: configuration)
    }

    func updateNSView(_ view: NativeSidebarCanvasDropView<Content>,
                      context: Context) {
        view.rootView = content
        view.configuration = configuration
    }

    private var configuration: SidebarCanvasDropConfiguration {
        SidebarCanvasDropConfiguration(
            upperItemCount: upperItemCount,
            lowerItemCount: lowerItemCount,
            canDrop: dragActions.canDrop,
            performDrop: dragActions.performDrop)
    }
}

struct SidebarCanvasDropConfiguration {
    let upperItemCount: Int
    let lowerItemCount: Int
    let canDrop: (NavigationDraggedItem, NavigationDropTarget) -> Bool
    let performDrop: (NavigationDraggedItem, NavigationDropTarget) -> Bool
}

@MainActor
final class NativeSidebarCanvasDropView<Content: View>: NSView {
    var configuration: SidebarCanvasDropConfiguration
    private let hostingView: NSHostingView<Content>

    var rootView: Content {
        get { hostingView.rootView }
        set { hostingView.rootView = newValue }
    }

    init(rootView: Content, configuration: SidebarCanvasDropConfiguration) {
        self.configuration = configuration
        hostingView = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        registerForDraggedTypes([NativeNavigationDragView.pasteboardType])
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func draggingEntered(_ sender: any NSDraggingInfo)
        -> NSDragOperation {
        guard accepted(sender) != nil else { return [] }
        sender.numberOfValidItemsForDrop = 1
        return .move
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo)
        -> NSDragOperation {
        accepted(sender) == nil ? [] : .move
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo)
        -> Bool {
        accepted(sender) != nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let (payload, target) = accepted(sender) else { return false }
        return configuration.performDrop(payload, target)
    }

    private func accepted(_ sender: any NSDraggingInfo)
        -> (NavigationDraggedItem, NavigationDropTarget)? {
        guard bounds.height > 0,
              let value = sender.draggingPasteboard.string(
                forType: NativeNavigationDragView.pasteboardType),
              let payload = NavigationDraggedItem(pasteboardValue: value)
        else { return nil }
        let point = convert(sender.draggingLocation, from: nil)
        let target = NavigationSidebarDropResolver.target(
            distanceFromTop: point.y,
            height: bounds.height,
            upperItemCount: configuration.upperItemCount,
            lowerItemCount: configuration.lowerItemCount)
        guard configuration.canDrop(payload, target) else { return nil }
        return (payload, target)
    }
}
