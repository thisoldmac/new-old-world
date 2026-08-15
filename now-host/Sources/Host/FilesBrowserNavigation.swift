import AppKit
import SwiftUI

enum FilesBrowserNavigationAction: Equatable {
    case back
    case forward
}

struct FilesBrowserNavigationHistory<Location: Equatable> {
    private(set) var backward: [Location] = []
    private(set) var forward: [Location] = []
    private let limit = 64

    var canGoBack: Bool { !backward.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    mutating func recordNavigation(from current: Location, to destination: Location) {
        guard current != destination else { return }
        backward.append(current)
        if backward.count > limit {
            backward.removeFirst(backward.count - limit)
        }
        forward.removeAll(keepingCapacity: true)
    }

    mutating func goBack(from current: Location) -> Location? {
        guard let destination = backward.popLast() else { return nil }
        forward.append(current)
        return destination
    }

    mutating func goForward(from current: Location) -> Location? {
        guard let destination = forward.popLast() else { return nil }
        backward.append(current)
        return destination
    }
}

/// Pure input mapping, kept separate from the AppKit responder so its
/// direction contract is testable without synthesizing hardware events.
enum FilesBrowserNavigationInput {
    static func action(forMouseButton button: Int) -> FilesBrowserNavigationAction? {
        switch button {
        case 3: return .back
        case 4: return .forward
        default: return nil
        }
    }

    static func action(forSwipeDeltaX delta: CGFloat) -> FilesBrowserNavigationAction? {
        // NSEvent defines -1 as a swipe right and +1 as a swipe left.
        if delta < 0 { return .back }
        if delta > 0 { return .forward }
        return nil
    }

}

/// A pane-root responder, so NSScrollView and NSBrowser forward horizontal
/// gesture scrolling only after their own content reaches an edge. That is
/// AppKit's native swipe-navigation contract and avoids stealing column
/// scrolling from the browser itself.
struct FilesBrowserNavigationHost<Content: View>:
    NSViewControllerRepresentable {
    let goBack: () -> Void
    let goForward: () -> Void
    let content: Content

    init(goBack: @escaping () -> Void,
         goForward: @escaping () -> Void,
         @ViewBuilder content: () -> Content) {
        self.goBack = goBack
        self.goForward = goForward
        self.content = content()
    }

    func makeNSViewController(context: Context) -> Controller<Content> {
        Controller(content: content, goBack: goBack, goForward: goForward)
    }

    func updateNSViewController(_ controller: Controller<Content>,
                                context: Context) {
        controller.hosting.rootView = content
        controller.navigationView.goBack = goBack
        controller.navigationView.goForward = goForward
    }

    @MainActor
    final class Controller<Hosted: View>: NSViewController {
        let hosting: NSHostingController<Hosted>
        let navigationView: NavigationView

        init(content: Hosted, goBack: @escaping () -> Void,
             goForward: @escaping () -> Void) {
            hosting = NSHostingController(rootView: content)
            navigationView = NavigationView(
                goBack: goBack, goForward: goForward)
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

        override func loadView() {
            view = navigationView
            addChild(hosting)
            let hosted = hosting.view
            hosted.translatesAutoresizingMaskIntoConstraints = false
            navigationView.addSubview(hosted)
            NSLayoutConstraint.activate([
                hosted.leadingAnchor.constraint(
                    equalTo: navigationView.leadingAnchor),
                hosted.trailingAnchor.constraint(
                    equalTo: navigationView.trailingAnchor),
                hosted.topAnchor.constraint(equalTo: navigationView.topAnchor),
                hosted.bottomAnchor.constraint(
                    equalTo: navigationView.bottomAnchor),
            ])
        }
    }

    @MainActor
    final class NavigationView: NSView {
        var goBack: () -> Void
        var goForward: () -> Void

        init(goBack: @escaping () -> Void,
             goForward: @escaping () -> Void) {
            self.goBack = goBack
            self.goForward = goForward
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

        override func wantsScrollEventsForSwipeTracking(
            on axis: NSEvent.GestureAxis
        ) -> Bool {
            axis == .horizontal
        }

        override func scrollWheel(with event: NSEvent) {
            guard NSEvent.isSwipeTrackingFromScrollEventsEnabled else {
                super.scrollWheel(with: event)
                return
            }
            event.trackSwipeEvent(
                options: [.lockDirection], dampenAmountThresholdMin: -1,
                max: 1) { [weak self] amount, _, complete, _ in
                    guard complete,
                          let action = FilesBrowserNavigationInput
                            .action(forSwipeDeltaX: amount) else { return }
                    self?.perform(action)
                }
        }

        override func swipe(with event: NSEvent) {
            guard let action = FilesBrowserNavigationInput
                .action(forSwipeDeltaX: event.deltaX) else {
                super.swipe(with: event)
                return
            }
            perform(action)
        }

        override func otherMouseDown(with event: NSEvent) {
            guard let action = FilesBrowserNavigationInput
                .action(forMouseButton: event.buttonNumber) else {
                super.otherMouseDown(with: event)
                return
            }
            perform(action)
        }

        private func perform(_ action: FilesBrowserNavigationAction) {
            switch action {
            case .back: goBack()
            case .forward: goForward()
            }
        }
    }
}

struct FilesNavigationButtons: View {
    let canGoBack: Bool
    let canGoForward: Bool
    let canGoUp: Bool
    let goBack: () -> Void
    let goForward: () -> Void
    let goUp: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            navigationButton("chevron.left", help: "Back",
                             enabled: canGoBack, action: goBack)
            Divider().frame(height: 18)
            navigationButton("chevron.right", help: "Forward",
                             enabled: canGoForward, action: goForward)
            Divider().frame(height: 18)
            navigationButton("chevron.up", help: "Enclosing folder",
                             enabled: canGoUp, action: goUp)
        }
        .padding(3)
        .nowGlassPanel(cornerRadius: FilesStyle.controlHeight)
    }

    private func navigationButton(_ symbol: String, help: String,
                                  enabled: Bool,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.plain)
            .frame(width: FilesStyle.controlHeight,
                   height: FilesStyle.controlHeight)
            .disabled(!enabled)
            .accessibilityLabel(help)
            .help(help)
    }
}
