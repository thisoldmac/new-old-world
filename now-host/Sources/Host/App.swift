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
    /// Where this delegate's settings live. The product's own domain by
    /// default, which is the shipping behaviour and unchanged.
    ///
    /// Injectable because a bare `AppDelegate()` was reaching the REAL
    /// preference domain from eight places in the test suite — and
    /// `listenAtLaunch` is true when unset, so touching `state` bound the
    /// product's port 5250 with a person's own settings behind it. Found
    /// on 2026-08-05 by running two suites at once: one run's port guard
    /// named the other's `xctest` holding 5250 (docs/open-issues.md).
    private let defaults: UserDefaults
    private lazy var appearancePreferences = AppearancePreferences(
        defaults: defaults)
    private lazy var state = HostAppState(registry: registry,
                                          defaults: defaults)
    /* The same defaults the rest of the delegate writes to, so the
       sidebar's shape travels with the port, the share and the selected
       module rather than landing in the generic domain — and so a test's
       injected suite carries the sidebar too. */
    private lazy var sidebarPreferences = SidebarPreferences(
        defaults: defaults,
        registry: registry)

    init(defaults: UserDefaults = UserDefaults(
        suiteName: ProductIdentity.preferencesSuite) ?? .standard,
         mcpTokenStore: MCPHTTPTokenStore? = try? MCPHTTPTokenStore()) {
        self.defaults = defaults
        self.mcpTokenStore = mcpTokenStore
        super.init()
    }
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private(set) var settingsWindowController: SettingsWindowController?
    private var flash: StatusItemFlash?
    private var statusWatch: AnyCancellable?
    private var mcpStdioBridgeServer: AgentIntegrationLocalServer?
    private var mcpHTTPListener: MCPHTTPListener?
    private var mcpHTTPRunID: UUID?
    private let mcpTokenStore: MCPHTTPTokenStore?
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Appearance is application-wide and must be set before either
        // hosting controller creates its first view hierarchy.
        _ = appearancePreferences
        installMainMenu()
        installStatusItem()
        /* The MCP pane's buttons, wired before the window opens so a person
           who lands on that page cannot press a control that has not been
           connected yet. The delegate owns the server object, so the pane
           reaches it through the app state rather than holding it. */
        state.configureMCPTransports(
            startStdio: { [weak self] in self?.startMCPStdio() },
            stopStdio: { [weak self] in self?.stopMCPStdio() },
            startHTTP: { [weak self] in self?.startMCPHTTP() },
            stopHTTP: { [weak self] in self?.stopMCPHTTP() })
        /* Not the activating variant. A launch the person performed is
           activated by macOS itself, and a launch they did NOT perform — a
           background `open`, a script restarting the app while they work
           elsewhere — should stay where it was put. */
        openMainWindow()
        /* Local Network is an app capability used by the guest link and
           optional modules. Ask at the app boundary, before starting any
           configured network service; Continuity may verify its own direct
           UDP path but must never own this permission. */
        state.localNetworkAccess.request()
        let preferences = MCPTransportPreferences(defaults: defaults)
        if preferences.stdioStartsAutomatically { startMCPStdio() }
        if preferences.httpStartsAutomatically { startMCPHTTP() }
    }

    /// A person granting Accessibility in System Settings brings THIS app
    /// back to the foreground to do it — Settings is a separate app, so
    /// returning here always fires activation. Continuity's edge controller
    /// uses the moment to pick its consuming tap back up without the person
    /// needing to toggle Continuity off and on to collect what they just
    /// granted.
    func applicationDidBecomeActive(_ notification: Notification) {
        state.continuity.applicationDidBecomeActive()
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.localNetworkAccess.cancel()
        state.shutDownModules()
        state.onboarding.stop()
        mcpStdioBridgeServer?.stop()
        mcpHTTPListener?.stop()
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
        state.shutDownModules()
        state.onboarding.stop()
        state.listener.shutDown { [weak sender] in
            sender?.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// A reopen IS a person asking for the window from outside the app — a
    /// Dock click, or opening the bundle again — so this one activates. The
    /// mirror window depends on it doing exactly that: `NOWMirrorWindow.show`
    /// deliberately does not activate, because activating trips this, and
    /// this raises the MAIN window over the mirror.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        openMainWindowFromOutsideTheApp()
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
                           showMirror: #selector(showMirror),
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

    /// Application appearance is a native window. Connection settings retain
    /// their stable module identity and later become Connections' hero.
    @objc func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                preferences: appearancePreferences)
        }
        settingsWindowController?.showWindow(self)
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
        state.runConsoleHelp()
    }

    @objc func toggleListening() {
        switch state.listener.state {
        case .idle, .failed:
            state.startListening()
        case .listening, .connected:
            state.stopListening()
        }
    }

    /// **The Window menu's face on `showMirror`.**
    ///
    /// One implementation, four faces — this, the Mirror page's button,
    /// the `mirror_open` agent verb and the guest's `host.show`. When it
    /// refuses (no Mac connected) the reason goes to the log and the
    /// Mirror page comes up, because a menu item that silently does
    /// nothing is indistinguishable from a broken one.
    @objc func showMirror() {
        let outcome = state.showMirror()
        guard !outcome.ok else { return }
        state.listener.note("Show Mirror: \(outcome.reason)", area: "host")
        show(moduleID: "mirror")
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
        state.setQuickCaptureFeedback { [weak flasher] in
            flasher?.flash($0.flash)
        }

        statusWatch = state.guestStatus.$status.sink { [weak self] _ in
            self?.refreshStatusItemTitle()
        }
        state.guestStatus.refresh()
        refreshStatusItemTitle()
    }

    /// Nothing, normally: the template glyph carries both the identity and
    /// the connection state, and a menu bar has no room for a sentence it
    /// does not need. Flashes still arrive as words and sit beside the icon
    /// for a couple of seconds.
    ///
    /// If the glyph cannot be loaded the old text comes back rather than
    /// leaving an invisible status item — a missing asset should degrade,
    /// not disappear.
    private var restingTitle: String {
        let status = state.guestStatus.status
        guard NSImage(named: status.statusImageName) == nil else { return "" }
        return "\(status.glyph) \(ProductIdentity.displayName)"
    }

    private func refreshStatusItemTitle() {
        // The image is set even mid-flash: a flash owns the words, not the
        // connection, and sitting on a state change for two seconds is the
        // staleness StatusItemFlash already exists to avoid.
        applyStatusImage()
        // A flash owns the title while it is up; settling restores whatever
        // the connection glyph has become in the meantime.
        guard flash?.isFlashing != true else { return }
        statusItem?.button?.title = restingTitle
    }

    private func applyStatusImage() {
        guard let button = statusItem?.button else { return }
        let status = state.guestStatus.status
        let image = NSImage(named: status.statusImageName)
        // Template rendering is declared in the asset catalog too; setting it
        // here means a hand-added image cannot quietly ship as a coloured one.
        image?.isTemplate = true
        // The words the character used to spell out. Without this the item
        // says only "New Old World" to VoiceOver, losing the state entirely.
        image?.accessibilityDescription = status.menuLine
        button.image = image
        button.imagePosition = .imageLeading
        button.toolTip = status.menuLine
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
        /* The status item is reached from whatever application the person
           was in, and a status menu does not activate its own app — so this
           is one of the two routes that must bring NOW forward itself. */
        let open = NSMenuItem(title: "Open \(ProductIdentity.displayName)",
                              action: #selector(openMainWindowFromOutsideTheApp),
                              keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        // The same words as the main menu's item: one command, one name.
        let shoot = NSMenuItem(title: "Capture Screen",
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
        state.runQuickCapture()
    }

    /// Test seam: the delegate's state is otherwise built lazily on launch.
    var appState: HostAppState { state }

    static let statusLineTag = 1001

    /// Pull-based enablement: NSMenu asks right before it draws, so the item
    /// always reflects the wire at the moment the menu opens without the
    /// delegate subscribing to anything.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(screenshotGuest) else { return true }
        return state.quickCaptureReadiness.isEnabled
    }

    /// Refresh the header the instant before it is read, so "quiet for 34s"
    /// is the truth at open time rather than at the last tick.
    func menuNeedsUpdate(_ menu: NSMenu) {
        state.guestStatus.refresh()
        menu.item(withTag: Self.statusLineTag)?.title =
            statusHeaderLine(status: state.guestStatus.status,
                             readiness: state.quickCaptureReadiness)
        if let toggle = menu.item(withTag: MainMenu.Tag.listenToggle.rawValue) {
            toggle.title = Self.listenToggleTitle(state.listener.state)
        }
        if let drive = menu.item(withTag: MainMenu.Tag.guestList.rawValue) {
            MainMenu.fillDriveMenu(drive, guests: state.listener.guests,
                                   target: self,
                                   action: #selector(driveGuest(_:)))
        }
    }

    /// Points the window at the Mac the item stands for. The item carries
    /// its SESSION id, not its title: a title is a label now and two of
    /// them can read the same.
    @objc func driveGuest(_ sender: NSMenuItem) {
        guard let sessionID = sender.representedObject as? String,
              let key = GuestKey.parse(sessionID) else { return }
        state.selectGuest(key)
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

    /// One local mutation request, revalidated through the same failable
    /// initialisers every other face uses.
    ///
    /// The codec has already checked the shape; this checks the *rules* —
    /// non-empty paths, a move that is neither its own source nor inside it,
    /// a trashed name that is a name — and it does so by asking the one type
    /// that owns them rather than restating any of it here. Nil is a refusal
    /// this host writes, not one the guest was troubled with.
    static func mutationRequest(
        _ mutation: AgentIntegrationGuestFileMutation,
        path: String,
        destination: String?,
        trashedAs: String?
    ) -> AgentIntegrationGuestFileMutationRequest? {
        switch mutation {
        case .move:
            guard let destination, trashedAs == nil else { return nil }
            return .move(path: path, toPath: destination)
        case .restore:
            guard let trashedAs, destination == nil else { return nil }
            return .restore(trashedAs: trashedAs, toPath: path)
        case .trash:
            guard destination == nil, trashedAs == nil else { return nil }
            return .trash(path: path)
        case .mkdir:
            guard destination == nil, trashedAs == nil else { return nil }
            return .makeFolder(path: path)
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
            let root = GlassPreferenceScope(
                preferences: appearancePreferences,
                content: HostRootView(registry: registry, state: state,
                                      sidebar: sidebarPreferences))
            let controller = NSHostingController(rootView: root)
            /* The WINDOW owns its size, not whichever pane is showing.
               NSHostingController defaults to .preferredContentSize, which
               republishes the SwiftUI view's ideal height as a window
               constraint every time the content changes - so selecting a pane
               whose ideal content is tall (Agent and Diagnostics both scroll a
               stack of cards) resized the window past the height of the
               display, with no way to drag it back. setContentSize below runs
               once at creation and was simply overridden on the next pane
               switch.

               Reported from a real machine 2026-07-31; the panes that looked
               fine were only the ones whose content happened to be short, so
               this was never about those two views. */
            controller.sizingOptions = []
            let newWindow = NSWindow(contentViewController: controller)
            newWindow.title = ProductIdentity.displayName
            /* The split view is the window's shell, so its chrome belongs to
               the window rather than to simulated bars inside the sidebar.
               A unified full-size titlebar lets AppKit carry the sidebar
               material through the toolbar on current macOS while
               NavigationSplitView still supplies the Ventura layout. */
            newWindow.styleMask.insert(.fullSizeContentView)
            newWindow.titleVisibility = .hidden
            newWindow.titlebarAppearsTransparent = true
            newWindow.toolbarStyle = .unified
            newWindow.titlebarSeparatorStyle = .none
            newWindow.setContentSize(NSSize(width: 980, height: 650))
            /* A floor, so the window cannot be dragged down to a size where
               the sidebar and the detail pane have nothing left to render. */
            newWindow.contentMinSize = NSSize(width: 720, height: 460)
            newWindow.setFrameAutosaveName(ProductIdentity.windowFrameName)
            newWindow.isReleasedWhenClosed = false
            newWindow.delegate = self
            window = newWindow
        }
        window?.makeKeyAndOrderFront(nil)
    }

    /// **The two routes where a person asked for this window from OUTSIDE
    /// the app** — the status item's "Open New Old World", and a Dock click
    /// or any other reopen — and therefore the only two allowed to take the
    /// front from whatever application they were using.
    ///
    /// This used to be in `openMainWindow` itself, so EVERY route ran it:
    /// launch, reopen, the status item, ⌘, for Settings, and every module
    /// item in the Windows menu. The last three arrive from this app's own
    /// menu bar, where it is already active and activating buys nothing —
    /// but `ignoringOtherApps: true` does not ask, so a launch in the
    /// background and a scripted `open` of the bundle both yanked the window
    /// in front of whatever the person was typing in. Reported as the app
    /// behaving as though it were always on top (2026-08-06); no window
    /// LEVEL was ever set — every window of it measures
    /// `CGWindowLayer 0` — and this was the only lever that could raise it.
    ///
    /// It stays `ignoringOtherApps: true` here on purpose. A status item's
    /// menu does not activate its application, so the polite form would be
    /// a no-op and "Open New Old World" would open the window behind
    /// everything — which is the shape of the two regressions this file
    /// already carries comments about.
    @objc func openMainWindowFromOutsideTheApp() {
        NSApp.activate(ignoringOtherApps: true)
        openMainWindow()
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    /// Failure keeps the human product intact; this optional surface must
    /// never become a prerequisite for launching or pairing NOW.
    private func startMCPStdio() {
        /* Idempotent since the MCP pane can ask: standing a second server on
           the same path would take the socket away from the one already
           serving, which is a worse outcome than a button that does nothing
           because there is nothing to do. */
        guard mcpStdioBridgeServer == nil else { return }
        do {
            let server = try AgentIntegrationLocalServer(
                /* The ledger is written on the accept thread; the pane that
                   will draw it lives on the main one. The hop is here, at
                   the one seam that knows about both, rather than inside a
                   module that has no business knowing a socket exists. */
                companionObserver: { [companions = state.agentCompanions]
                    activity in
                    Task { @MainActor in companions.update(activity) }
                }
            ) {
                [agentIntegration = state.agentIntegration,
                 guestFiles = state.guestFiles,
                 activity = state.agentActivity] request in
                /* Addressing is checked once, before any operation, so
                   no tool can be reached with a guest selector nobody
                   honoured. Session health is exempt: it is the call a
                   caller makes to DISCOVER the ids, and refusing it for
                   naming an id would be a closed loop. */
                /* Audit is exempt for a different reason than health: it
                   asks nothing of any guest, and a line about a call that
                   was refused BECAUSE no machine answered is exactly the
                   line the person needs. */
                /* And `hostLogTail` for the projects reason, one step
                   further: it reads this Mac's own log ring and reaches no
                   guest, so refusing it for naming a machine would deny the
                   record that says WHY that machine could not be
                   addressed. */
                if request.operation != .sessionHealth,
                   request.operation != .audit,
                   request.operation != .projects,
                   request.operation != .hostLogTail,
                   let refusal = agentIntegration.addressingRefusal(
                       request.guestSelector) {
                    return .notAddressed(refusal)
                }
                switch request.operation {
                case .projects:
                    guard let project = request.projectRequest else {
                        return .projects(.init(failure: .init(
                            code: "now-projects-invalid-request",
                            message: "The Projects request is missing.")))
                    }
                    return .projects(agentIntegration.projects(project))
                case .development:
                    guard let development = request.developmentRequest else {
                        return .development(.refused(.init(
                            code: "now-development-invalid-request",
                            message: "The Development request is missing.")))
                    }
                    return .development(
                        await agentIntegration.development(development))
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
                case .guestFileDownload:
                    /* The path is the whole request, and an absent one
                       never reached a machine — so the refusal is the
                       path's rather than the guest's. Shaped like the two
                       browse cases above rather than like the upload ones:
                       the download is a Files command with the same
                       guestRoot policy and the same receipt envelope. */
                    return .guestFileDownload(
                        await guestFiles.agentDownload(
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
                case .capture:
                    /* Three shapes, and the codec has already refused any
                       request that is more than one of them — so the order
                       here is a reading of validated fields rather than a
                       precedence. */
                    if request.captureAbandon == true {
                        return .capture(
                            agentIntegration.abandonCapture())
                    }
                    if let captureID = request.captureID,
                       let offset = request.captureOffset {
                        return .capture(
                            agentIntegration.capturePage(
                                captureID: captureID, offset: offset))
                    }
                    guard let depth = request.captureDepth else {
                        return .capture(.refused(.init(
                            code: "now-capture-request-invalid",
                            message: "The capture request named no depth, "
                                + "page or abandon")))
                    }
                    return .capture(
                        await agentIntegration.capture(depth: depth))
                case .audit:
                    /* Rule 3 of the parity slice, arriving: a face reports
                       what it was asked to do and this side writes it where
                       the person at the machine can read it. The line is
                       composed HERE, from typed fields the codec has already
                       validated, rather than accepted as text — the log is
                       the human's, and a reporting process does not get to
                       write arbitrary rows into it. */
                    guard let event = request.auditEvent else {
                        return .recorded
                    }
                    AgentIntegrationAuditLog.record(
                        event,
                        drivenGuest:
                            agentIntegration.activeReference()?.id,
                        stream: activity)
                    return .recorded
                case .bringToFront:
                    /* The first of P1a's eleven to be wired (plan 005,
                       P1b). Shaped like requestQuit above and for the same
                       reason: the reference is all a caller may send, and a
                       request without one never reached a machine, so the
                       refusal is the reference's rather than the guest's. */
                    guard let reference = request.processReference else {
                        return .bringToFront(.refused(.init(
                            code: "now-process-reference-stale",
                            message:
                                "The process reference is not current for this session")))
                    }
                    return .bringToFront(
                        await agentIntegration.bringToFront(
                            reference: reference))
                case .revealItem:
                    /* The target is all a caller may send, and a request
                       without one never reached a machine — so the refusal
                       is the target's rather than the guest's. The codec
                       has already bounded it; this is the shape check that
                       cannot be expressed in a strict key list. */
                    guard let target = request.revealTarget else {
                        return .revealItem(.refused(.init(
                            code: "now-reveal-target-invalid",
                            message:
                                "The reveal request named no target")))
                    }
                    return .revealItem(
                        await agentIntegration.revealItem(target: target))
                case .windowAct:
                    /* THE ACT LANE, arriving. The codec has already refused
                       every malformed act — a bare-string window reference,
                       a close carrying a width, a coordinate outside a
                       QuickDraw Rect — so this branch reads a validated
                       request and refuses only the one that named no act at
                       all, which never reached a machine and is therefore
                       the request's refusal rather than the guest's.

                       What a completed answer MEANS lives in
                       AgentIntegrationActControl: the event was handed to
                       the window's own application. Nothing here, and
                       nothing anywhere on this side, may say the window
                       moved. */
                    guard let act = request.windowActRequest else {
                        return .windowAct(.refused(.init(
                            code: "now-window-act-invalid",
                            message:
                                "The request named no window act")))
                    }
                    return .windowAct(
                        await agentIntegration.windowAct(act))
                case .controlAct:
                    guard let act = request.controlActRequest else {
                        return .controlAct(.refused(.init(
                            code: "now-control-act-invalid",
                            message:
                                "The request named no control act")))
                    }
                    return .controlAct(
                        await agentIntegration.controlAct(act))
                case .menuAct:
                    guard let act = request.menuActRequest else {
                        return .menuAct(.refused(.init(
                            code: "now-menu-act-invalid",
                            message: "The request named no menu act")))
                    }
                    return .menuAct(await agentIntegration.menuAct(act))
                case .textGet:
                    guard let element = request.actElement else {
                        return .textGet(.refused(.init(
                            code: "now-text-get-invalid",
                            message:
                                "The request named no text element")))
                    }
                    return .textGet(
                        await agentIntegration.getElementText(
                            element: element))
                case .textSet:
                    /* Both fields, and the text may be empty: emptying a
                       field is a real act, so `actText == ""` is a request
                       and an absent key is not. The codec draws the same
                       line; this is the shape check a strict key list
                       cannot express. */
                    guard let element = request.actElement,
                          let text = request.actText else {
                        return .textSet(.refused(.init(
                            code: "now-text-set-invalid",
                            message:
                                "The request named no element and replacement")))
                    }
                    return .textSet(
                        await agentIntegration.setElementText(
                            element: element, text: text))
                case .observeElements:
                    /* THE SHORTEST BRANCH ON THE ACT PLANE, and the only
                       one with no refusal this side can compose: an
                       observation that names no process is a COMPLETE
                       request meaning the frontmost application, and the
                       pair rule that makes half a serial number unspellable
                       was enforced where the caller's keys were first read.
                       So the field is forwarded exactly as it arrived,
                       absence included — a host that resolved "frontmost"
                       itself would be naming a process from a sample taken
                       at a different moment than the walk. */
                    return .observeElements(
                        await agentIntegration.observeElements(
                            process: request.observeProcess))
                case .transferCancel:
                    /* Says only its own name, and the codec has already
                       refused a request carrying anything else. There is
                       nothing to read off it here: the lane is one transfer
                       wide across both directions, so what to cancel is not
                       a caller's to name. */
                    return .transferCancel(
                        agentIntegration.cancelTransfer())
                case .guestFileMutation:
                    /* P1 #7, and the first MUTATING guest-Files verb here.
                       The codec has already refused every crossed shape —
                       a move with no destination, a restore with no trashed
                       name, either field on a trash — so this branch reads
                       validated fields and refuses only the request that
                       named no intention at all, which never reached a
                       machine and so is the request's refusal rather than
                       the guest's. The authority (guestRoot), the bounds
                       (one item, one attempt, never an overwrite) and the
                       receipt live in GuestFileMutationCommands. */
                    guard let mutation = request.guestFileMutation,
                          let path = request.guestFilePath,
                          let composed = Self.mutationRequest(
                            mutation,
                            path: path,
                            destination: request.guestFileDestinationPath,
                            trashedAs: request.guestFileTrashName) else {
                        return .guestFileMutation(.hostUnavailable(.init(
                            code: "now-files-mutation-invalid",
                            message:
                                "The file mutation did not name one bounded item and one intention")))
                    }
                    return .guestFileMutation(
                        await guestFiles.agentMutate(composed))
                case .catalogSearch:
                    /* Takes nothing, by the contract: `catsearch` has
                       `args: {}` and the volume is the guest's own choice.
                       So there is no field to validate here and no refusal
                       this side can compose — everything a caller could get
                       wrong was already refused by the codec's strict key
                       list. */
                    return .catalogSearch(
                        await agentIntegration.measureCatalogSearch())
                case .guestLogTail:
                    /* P1 #9. Nothing to read off the request but a count the
                       codec has already bounded, and nothing to refuse here:
                       a request that named no count is a COMPLETE request —
                       absent means the guest's own default of 20 — which is
                       what makes this the shortest branch in the switch. */
                    return .guestLogTail(
                        await agentIntegration.tailGuestLog(
                            lines: request.logLineCount,
                            area: request.logArea))
                case .census:
                    /* P1 #2. The probe is REQUIRED by the contract and by
                       the codec, so a request without one never reached a
                       machine and the refusal is the request's rather than
                       the guest's. The cursor is genuinely optional: absent
                       and 0 both start the probe over, by contract. */
                    guard let probe = request.censusProbe else {
                        return .census(.refused(.init(
                            code: "now-census-probe-invalid",
                            message:
                                "The census request named no probe")))
                    }
                    return .census(
                        await agentIntegration.census(
                            probe: probe, cursor: request.censusCursor))
                case .hostLogTail:
                    /* The host sibling of the branch above, and the one
                       read in this switch that asks no Macintosh anything:
                       it renders THIS process's own log ring. The codec has
                       already bounded both optional fields, and a request
                       that named neither is complete. The hop to the main
                       actor is here because that is where the ring lives. */
                    return .hostLogTail(.completed(
                        await MainActor.run {
                            HostLogTailReader.read(
                                lines: request.hostLogLineCount,
                                area: request.hostLogArea)
                        }))
                case .machineFacts:
                    /* P1 #10. Takes nothing, by the contract: `gestalt` has
                       `args: {}` and a typed call with no line returns every
                       group, so there is no field to validate here and no
                       refusal this side can compose — everything a caller
                       could get wrong was already refused by the codec's
                       strict key list. */
                    return .machineFacts(
                        await agentIntegration.machineFacts())
                case .developmentEnvironment:
                    return .developmentEnvironment(
                        await agentIntegration.developmentEnvironment())
                case .softwareInventory:
                    /* P1 #3. The domain is REQUIRED by the contract and by
                       the codec, so a request without one never reached a
                       machine and the refusal is the request's rather than
                       the guest's. The cursor is optional and its FLOOR is 1,
                       not 0 — unlike the census, absent and 0 are different
                       here, because the cursor indexes the guest's cached
                       inventory 1-based and 1 rebuilds it. */
                    guard let domain = request.softwareDomain else {
                        return .softwareInventory(.refused(.init(
                            code: "now-software-domain-invalid",
                            message:
                                "The software inventory request named no domain")))
                    }
                    return .softwareInventory(
                        await agentIntegration.softwareInventory(
                            domain: domain,
                            cursor: request.softwareCursor))
                case .diagnostics:
                    /* P1 #13, and the one P1a operation whose probe is a
                       CLOSED enum: the codec has already refused a request
                       that named none, so there is no shape left to check
                       here and no refusal this side can compose.

                       One operation, three capabilities. Which of them the
                       connected machine answers is not decided here and
                       cannot be: a guest without the verb refuses it by
                       name, and the capability ledger reads the same `help`
                       table before anyone calls. */
                    guard let probe = request.diagnosticProbe else {
                        return .diagnostics(.refused(.init(
                            code: "now-diagnostic-probe-invalid",
                            message:
                                "The diagnostics request named no probe")))
                    }
                    return .diagnostics(
                        await agentIntegration.runDiagnostic(probe))
                case .mirrorRead:
                    /* A read of state the Mirror engine has already
                       published. The codec owns the intention grammar; the
                       adapter owns session selection. This branch sends no
                       guest request and creates no observer. */
                    guard let read = request.mirrorReadRequest else {
                        return .mirrorRead(.init(unavailable: .init(
                            code: "now-mirror-read-invalid",
                            message:
                                "The Mirror read request named no intention")))
                    }
                    return .mirrorRead(
                        await agentIntegration.mirrorRead(read))
                case .mirrorDrive:
                    /* The mutation half, through the SAME executor a click
                       uses. Not beside the act lane's five: those address
                       an observation-minted element and settle for
                       nothing. */
                    guard let drive = request.mirrorDriveRequest else {
                        return .mirrorDrive(.init(unavailable: .init(
                            code: "now-mirror-drive-invalid",
                            message:
                                "The Mirror drive request named no gesture")))
                    }
                    return .mirrorDrive(
                        agentIntegration.driveMirror(drive))
                case .mirrorOpen:
                    /* No shape to check: the operation says only its own
                       name, and the codec has already refused a request
                       that carried anything else. The one branch here
                       that sends the classic Mac nothing. */
                    return .mirrorOpen(agentIntegration.openMirror())
                case .stream:
                    /* The bracket. The codec has already refused every
                       crossed shape — a stop carrying a depth, a page
                       naming an offset and no frame — so this branch reads
                       validated fields and refuses only the request that
                       named no intention, which never reached a machine.

                       Note which of the four does NOT return here directly:
                       a frame request is the only one that waits on the
                       Macintosh, because it sends stream.refresh and holds
                       the answer for the frame that follows. */
                    guard let intention = request.streamIntention else {
                        return .stream(.refused(.init(
                            code: "now-stream-intention-invalid",
                            message:
                                "The stream request named no intention")))
                    }
                    switch intention {
                    case .start:
                        guard let depth = request.streamDepth,
                              let interval = request.streamMinIntervalMs
                        else {
                            return .stream(.refused(.init(
                                code: "now-stream-start-invalid",
                                message: "The stream start named no depth "
                                    + "and pace")))
                        }
                        return .stream(
                            agentIntegration.startStream(
                                depth: depth, minIntervalMs: interval))
                    case .frame:
                        if let frameID = request.streamFrameID,
                           let offset = request.streamFrameOffset {
                            return .stream(
                                agentIntegration.streamFramePage(
                                    frameID: frameID, offset: offset))
                        }
                        return .stream(
                            await agentIntegration.nextStreamFrame())
                    case .stop:
                        return .stream(agentIntegration.stopStream())
                    }
                    /* P1a's `notWired` fallback used to sit here, and it is
                       GONE rather than moved: it was already unreachable —
                       the last of the eleven adapters landed and every
                       operation has a case — and it was stranded inside the
                       diagnostics case where nothing could reach it at all.
                       The switch's own exhaustiveness now carries what that
                       comment asked for: a new operation is a compile error
                       here, which is a better instruction than a paragraph.
                       `AgentIntegrationUnavailable.notWired` stays; it is
                       still the honest answer for a host older than a verb,
                       and the codec round-trip tests still exercise it. */
                }
            }
            try server.start()
            mcpStdioBridgeServer = server
            state.agentActivity.stdioOpened(
                at: server.endpoint.socketURL.path)
        } catch {
            let reason = "\(error)"
            HostLog.shared.write(
                .warn, "agent",
                "local agent integration unavailable: \(reason)")
            /* The Agent page is told, because otherwise it would report
               the honest "nothing has ever attached" beside a socket path
               naming a file that is not there — and send somebody
               configuring a client to look for it. */
            state.agentActivity.stdioUnavailable(reason)
        }
    }

    /// Switched off from the MCP pane.
    ///
    /// The socket goes and the record stays: what an agent already did to
    /// this Mac is not undone by closing the door it came through, so the
    /// activity stream and the presence ledger are left exactly as they are.
    private func stopMCPStdio() {
        guard let server = mcpStdioBridgeServer else {
            state.agentActivity.stdioStopped()
            return
        }
        server.stop()
        mcpStdioBridgeServer = nil
        HostLog.shared.write(.info, "agent",
                             "stdio MCP endpoint stopped from the MCP pane")
        state.agentActivity.stdioStopped()
    }

    /// HTTP is a transport of the server already owned by this app. It uses
    /// the in-process host adapter directly; no companion process, private
    /// socket or second tool registry sits between the listener and NOW.
    private func startMCPHTTP() {
        guard mcpHTTPListener == nil else { return }
        let preferences = MCPTransportPreferences(defaults: defaults)
        guard let mcpTokenStore else {
            state.agentActivity.httpUnavailable(
                "Application Support is unavailable for the MCP token.")
            return
        }
        do {
            let token = try mcpTokenStore.loadOrCreate()
            let port = preferences.httpPort
            let runID = UUID()
            mcpHTTPRunID = runID
            let client = HostAgentIntegrationClient(
                adapter: state.agentIntegration, guestFiles: state.guestFiles)
            let audit = HostMCPAuditSink(
                adapter: state.agentIntegration,
                activity: state.agentActivity)
            let listener = try MCPHTTPListener(
                configuration: .init(port: port, bearerToken: token),
                serverFactory: {
                    NOWMCPServer(client: client, audit: audit)
                },
                activityObserver: { [activity = state.agentActivity]
                    began, moment in
                    Task { @MainActor in
                        if began {
                            activity.httpRequestBegan(at: moment)
                        } else {
                            activity.httpRequestEnded(at: moment)
                        }
                    }
                },
                failureObserver: { [weak self] error in
                    Task { @MainActor in
                        guard let self, self.mcpHTTPRunID == runID else {
                            return
                        }
                        self.mcpHTTPListener = nil
                        self.mcpHTTPRunID = nil
                        self.state.agentActivity.httpUnavailable("\(error)")
                        HostLog.shared.write(
                            .warn, "mcp", "HTTP MCP failed: \(error)")
                    }
                })
            mcpHTTPListener = listener
            Task { [weak self, weak listener] in
                guard let self, let listener else { return }
                do {
                    try await listener.start()
                    await MainActor.run {
                        guard self.mcpHTTPListener === listener,
                              self.mcpHTTPRunID == runID else { return }
                        let endpoint = "http://127.0.0.1:\(port)/mcp"
                        self.state.agentActivity.httpOpened(
                            at: endpoint, bearerToken: token)
                        HostLog.shared.write(
                            .info, "mcp", "HTTP MCP listening at \(endpoint)")
                    }
                } catch {
                    await MainActor.run {
                        guard self.mcpHTTPListener === listener,
                              self.mcpHTTPRunID == runID else { return }
                        self.mcpHTTPListener = nil
                        self.mcpHTTPRunID = nil
                        self.state.agentActivity.httpUnavailable("\(error)")
                        HostLog.shared.write(
                            .warn, "mcp", "HTTP MCP unavailable: \(error)")
                    }
                }
            }
        } catch {
            mcpHTTPRunID = nil
            state.agentActivity.httpUnavailable("\(error)")
            HostLog.shared.write(.warn, "mcp",
                                 "HTTP MCP unavailable: \(error)")
        }
    }

    private func stopMCPHTTP() {
        mcpHTTPRunID = nil
        mcpHTTPListener?.stop()
        mcpHTTPListener = nil
        HostLog.shared.write(.info, "mcp",
                             "HTTP MCP stopped from the MCP pane")
        state.agentActivity.httpStopped()
    }
}

@main
enum HostMain {
    static func main() {
        if Array(CommandLine.arguments.dropFirst()) == ["--mcp-stdio"] {
            Task {
                await MCPStdioTransport.run()
                Foundation.exit(0)
            }
            dispatchMain()
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
