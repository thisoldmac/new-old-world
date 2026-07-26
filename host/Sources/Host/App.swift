import AppKit
import Combine
import NOWAgentIntegration
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
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        installStatusItem()
        openMainWindow()
        startAgentIntegrationServer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        agentIntegrationServer?.stop()
    }

    /// ⌘Q, and every other route to quitting.
    ///
    /// A live guest is told before the process goes: `bye` is a write, and a
    /// write needs a turn of the run loop to leave, so terminating in the same
    /// turn drops the wire abortively — the guest then sits reconnecting to a
    /// host that no longer exists until its keepalive gives up. `terminateLater`
    /// buys the farewell that turn; `GuestListener.shutDown` bounds the wait,
    /// because a guest wedged badly enough to need telling is exactly the one
    /// that will not read.
    func applicationShouldTerminate(_ sender: NSApplication)
        -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateNow }
        isTerminating = true
        state.listener.shutDown { [weak sender] in
            sender?.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        openMainWindow()
        return false
    }

    /// Test seam, like makeStatusMenu below: the same menu a real launch
    /// installs, assembled without a menu bar to put it in.
    func makeMainMenu() -> NSMenu {
        MainMenu.make(
            appName: ProductIdentity.displayName,
            registry: registry,
            target: self,
            actions: .init(about: #selector(showAbout),
                           openWindow: #selector(openMainWindow),
                           showSettings: #selector(showSettings),
                           screenshotGuest: #selector(screenshotGuest),
                           askGuestForHelp: #selector(askGuestForHelp),
                           toggleListening: #selector(toggleListening),
                           revealSharedFolder: #selector(revealSharedFolder),
                           revealLogFolder: #selector(revealLogFolder),
                           quit: #selector(quit)))
    }

    private func installMainMenu() {
        let menu = makeMainMenu()
        menu.delegate = self
        for item in menu.items {
            item.submenu?.delegate = self
        }
        NSApp.mainMenu = menu
        // Handed over by identity so NSApplication keeps the window list in
        // it current; it also puts the standard window items in the right
        // order relative to ours.
        NSApp.windowsMenu = MainMenu.windowsMenu(in: menu)
    }

    @objc func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    /// Settings are a page in the window, not a separate panel: the wire's
    /// port and state belong beside the modules that run over it. ⌘, opens
    /// the window on that page, which is what the standard item promises.
    @objc func showSettings() {
        show(moduleID: "settings")
    }

    @objc func showModule(_ sender: NSMenuItem) {
        let index = sender.tag - MainMenu.Tag.moduleFirst.rawValue
        guard registry.modules.indices.contains(index) else { return }
        show(moduleID: registry.modules[index].id)
    }

    private func show(moduleID: String) {
        guard registry.module(id: moduleID) != nil else { return }
        state.selectedModuleID = moduleID
        openMainWindow()
    }

    /// Discovery comes from the guest, at runtime: the console has no command
    /// list of its own, so this is the same `help` request a human types.
    @objc func askGuestForHelp() {
        show(moduleID: "console")
        state.console.runHelp()
    }

    @objc func toggleListening() {
        switch state.listener.state {
        case .idle, .failed:
            state.startListening()
        case .listening, .connected:
            state.stopListening()
        }
    }

    @objc func revealSharedFolder() {
        NSWorkspace.shared.activateFileViewerSelecting(
            [state.listener.share.root])
    }

    /// The log folder, not the log file: one file per launch lives there, and
    /// the interesting one after a crash is rarely the current one.
    @objc func revealLogFolder() {
        guard let file = HostLog.shared.url else {
            state.listener.note("No log file: writing to disk is off",
                                area: "host")
            show(moduleID: "logs")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([file])
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
        if let toggle = menu.item(withTag: MainMenu.Tag.listenToggle.rawValue) {
            toggle.title = Self.listenToggleTitle(state.listener.state)
        }
    }

    /// One item, two truths — and the truth is read as the menu opens rather
    /// than tracked, so a connection that dropped a moment ago cannot leave
    /// the menu offering to stop a listener that is already gone.
    static func listenToggleTitle(_ state: GuestListener.State) -> String {
        switch state {
        case .idle, .failed: return "Start Listening"
        case .listening, .connected: return "Stop Listening"
        }
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

    @objc func openMainWindow() {
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

    @objc func quit() {
        NSApp.terminate(nil)
    }

    /// Failure keeps the human product intact; this optional surface must
    /// never become a prerequisite for launching or pairing NOW.
    private func startAgentIntegrationServer() {
        do {
            let server = try AgentIntegrationLocalServer {
                [agentIntegration = state.agentIntegration,
                 guestFiles = state.guestFiles] request in
                switch request.operation {
                case .sessionHealth:
                    return .sessionHealth(
                        agentIntegration.sessionHealth())
                case .sessionCapabilities:
                    return .sessionCapabilities(
                        await agentIntegration.sessionCapabilities(
                            probeCostly: request.probeCostly ?? false))
                case .listProcesses:
                    return .processList(
                        await agentIntegration.processList())
                case .launchSoftware:
                    guard let selection = request.launchSelection else {
                        return .launchSoftware(.refused(.init(
                            code: "now-software-selection-invalid",
                            message: "Software launch selection is missing")))
                    }
                    return .launchSoftware(
                        await agentIntegration.launchSoftware(selection))
                case .requestQuit:
                    guard let reference = request.processReference else {
                        return .requestQuit(.stale(.init(
                            code: "now-process-reference-stale",
                            message:
                                "The process reference is not current for this session")))
                    }
                    return .requestQuit(
                        await agentIntegration.requestQuit(
                            reference: reference))
                case .transferApprovedArtifact:
                    guard let receipt = request.approvalReceipt else {
                        return .transferApprovedArtifact(.refused(.init(
                            code: "now-artifact-approval-invalid",
                            message:
                                "The artifact approval receipt is invalid")))
                    }
                    return .transferApprovedArtifact(
                        await agentIntegration.transferApprovedArtifact(
                            receipt: receipt))
                case .guestFilesCapabilities:
                    return .guestFilesCapabilities(
                        await guestFiles.agentCapabilities())
                case .guestFilesList:
                    return .guestFilesList(
                        await guestFiles.agentList(
                            path: request.guestFilePath ?? "",
                            cursor: request.guestFileCursor))
                case .guestFilesStat:
                    return .guestFilesStat(
                        await guestFiles.agentStat(
                            path: request.guestFilePath ?? ""))
                case .guestFilesUploadBegin:
                    guard let upload = request.guestFileUpload else {
                        return .guestFilesUploadStage(.completed(
                            receipt: AgentIntegrationGuestFileReceipt(
                                commandID: UUID(),
                                sessionID: nil,
                                policyVersion: 1,
                                operation: .put,
                                startedAt: Date(),
                                completedAt: Date(),
                                outcome: .refused,
                                wireRequestCount: 0),
                            value: nil,
                            failure: .init(
                                code: "now-files-upload-invalid",
                                message:
                                    "Upload begin request is missing")))
                    }
                    return .guestFilesUploadStage(
                        await guestFiles.agentBeginUpload(upload))
                case .guestFilesUploadAppend:
                    guard let uploadID = request.guestFileUploadID,
                          let offset = request.guestFileUploadOffset,
                          let encoded = request.guestFileUploadChunk,
                          let bytes = Data(base64Encoded: encoded) else {
                        return .guestFilesUploadStage(.hostUnavailable(
                            .init(
                                code: "now-files-upload-invalid",
                                message: "Upload chunk is invalid")))
                    }
                    return .guestFilesUploadStage(
                        await guestFiles.agentAppendUpload(
                            uploadID: uploadID,
                            offset: offset,
                            bytes: bytes))
                case .guestFilesUploadCommit:
                    guard let uploadID = request.guestFileUploadID else {
                        return .guestFilesUploadCommit(.hostUnavailable(
                            .init(
                                code: "now-files-upload-invalid",
                                message: "Upload ID is missing")))
                    }
                    return .guestFilesUploadCommit(
                        await guestFiles.agentCommitUpload(
                            uploadID: uploadID))
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
