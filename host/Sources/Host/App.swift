import AppKit
import Combine
#if canImport(NOWAgentIntegration)
import NOWAgentIntegration
#endif
import SwiftUI

extension String {
    /// For splicing a standalone sentence into the tail of another one.
    var lowercasedFirst: String {
        isEmpty ? self : prefix(1).lowercased() + dropFirst()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
                         NSMenuDelegate {
    private let registry = ModuleRegistry.standard
    private lazy var state = HostAppState(registry: registry)
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private var flash: StatusItemFlash?
    private var statusWatch: AnyCancellable?
    private var agentIntegrationServer: AgentIntegrationLocalServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        openMainWindow()
        startAgentIntegrationServer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        agentIntegrationServer?.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        openMainWindow()
        return false
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = makeStatusMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        let flasher = StatusItemFlash { [weak self] in
            self?.restingTitle ?? ProductIdentity.displayName
        } apply: { [weak item] in
            item?.button?.title = $0
        }
        flash = flasher
        state.quickCaptureFeedback = { [weak flasher] in
            flasher?.flash($0.flash)
        }

        statusWatch = state.guestStatus.$status.sink { [weak self] _ in
            self?.refreshStatusItemTitle()
        }
        state.guestStatus.refresh()
        refreshStatusItemTitle()
    }

    /// Glyph first, so the connection reads at a glance without opening
    /// anything — which is the whole point of a menu-bar app.
    private var restingTitle: String {
        "\(state.guestStatus.status.glyph) \(ProductIdentity.displayName)"
    }

    private func refreshStatusItemTitle() {
        // A flash owns the title while it is up; settling restores whatever
        // the connection glyph has become in the meantime.
        guard flash?.isFlashing != true else { return }
        statusItem?.button?.title = restingTitle
    }

    /// Built apart from the status item so a test can assemble the same menu
    /// and validate it without conjuring a real one into the menu bar.
    func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        let status = NSMenuItem(title: state.guestStatus.status.menuLine,
                                action: nil, keyEquivalent: "")
        status.isEnabled = false
        status.tag = Self.statusLineTag
        menu.addItem(status)
        menu.addItem(.separator())
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

    static let statusLineTag = 1001

    /// Pull-based enablement: NSMenu asks right before it draws, so the item
    /// always reflects the wire at the moment the menu opens without the
    /// delegate subscribing to anything.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(screenshotGuest) else { return true }
        return state.quickCapture.readiness.isEnabled
    }

    /// Refresh the header the instant before it is read, so "quiet for 34s"
    /// is the truth at open time rather than at the last tick.
    func menuNeedsUpdate(_ menu: NSMenu) {
        state.guestStatus.refresh()
        menu.item(withTag: Self.statusLineTag)?.title =
            statusHeaderLine(status: state.guestStatus.status,
                             readiness: state.quickCapture.readiness)
    }

    /// The header carries the connection, and — when Screenshot Guest is
    /// greyed out for a reason the connection alone does not explain (a
    /// stream or a transfer holding the one lane) — that reason too, so the
    /// grey-out is never a mystery.
    func statusHeaderLine(status: GuestStatus,
                          readiness: QuickCaptureReadiness) -> String {
        guard !readiness.isEnabled, status.isConnected,
              let reason = readiness.reason else {
            return status.menuLine
        }
        return "\(status.menuLine) — \(reason.lowercasedFirst)"
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

    /// Failure keeps the human product intact; this optional surface must
    /// never become a prerequisite for launching or pairing NOW.
    private func startAgentIntegrationServer() {
        do {
            let server = try AgentIntegrationLocalServer {
                [agentIntegration = state.agentIntegration] operation in
                switch operation {
                case .sessionHealth:
                    return .sessionHealth(
                        agentIntegration.sessionHealth())
                case .listProcesses:
                    return .processList(
                        await agentIntegration.processList())
                }
            }
            try server.start()
            agentIntegrationServer = server
        } catch {
            HostLog.shared.write(
                .warn, "agent",
                "local agent integration unavailable: \(error)")
        }
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
