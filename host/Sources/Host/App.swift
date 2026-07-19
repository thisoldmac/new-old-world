import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let registry = ModuleRegistry.standard
    private lazy var state = HostAppState(registry: registry)
    private var statusItem: NSStatusItem?
    private var window: NSWindow?

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
        item.button?.title = "▣ \(ProductIdentity.displayName)"

        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Screenshots",
                              action: #selector(openMainWindow),
                              keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit \(ProductIdentity.displayName)",
                              action: #selector(quit),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
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

