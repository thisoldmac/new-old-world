import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let registry = ModuleRegistry.standard
    private lazy var state = HostAppState(registry: registry)
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private var flash: StatusItemFlash?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        openMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        openMainWindow()
        return false
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let resting = "▣ \(ProductIdentity.displayName)"
        item.button?.title = resting
        item.menu = makeStatusMenu()
        statusItem = item

        let flasher = StatusItemFlash(restingTitle: resting) { [weak item] in
            item?.button?.title = $0
        }
        flash = flasher
        state.quickCaptureFeedback = { [weak flasher] in
            flasher?.flash($0.flash)
        }
    }

    /// Built apart from the status item so a test can assemble the same menu
    /// and validate it without conjuring a real one into the menu bar.
    func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open \(ProductIdentity.displayName)",
                              action: #selector(openMainWindow),
                              keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        let shoot = NSMenuItem(title: "Screenshot Guest",
                               action: #selector(screenshotGuest),
                               keyEquivalent: "s")
        shoot.target = self
        menu.addItem(shoot)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit \(ProductIdentity.displayName)",
                              action: #selector(quit),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc func screenshotGuest() {
        state.quickCapture.run()
    }

    /// Test seam: the delegate's state is otherwise built lazily on launch.
    var appState: HostAppState { state }

    /// Pull-based enablement: NSMenu asks right before it draws, so the item
    /// always reflects the wire at the moment the menu opens without the
    /// delegate subscribing to anything.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(screenshotGuest) else { return true }
        return state.quickCapture.readiness.isEnabled
    }

    @objc private func openMainWindow() {
        if window == nil {
            let root = HostRootView(registry: registry, state: state)
            let controller = NSHostingController(rootView: root)
            let newWindow = NSWindow(contentViewController: controller)
            newWindow.title = ProductIdentity.displayName
            newWindow.setContentSize(NSSize(width: 980, height: 650))
            newWindow.setFrameAutosaveName(ProductIdentity.windowFrameName)
            newWindow.isReleasedWhenClosed = false
            newWindow.delegate = self
            window = newWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

@main
enum HostMain {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

