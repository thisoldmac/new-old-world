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
                /* Addressing is checked once, before any operation, so
                   no tool can be reached with a guest selector nobody
                   honoured. Session health is exempt: it is the call a
                   caller makes to DISCOVER the ids, and refusing it for
                   naming an id would be a closed loop. */
                /* Audit is exempt for a different reason than health: it
                   asks nothing of any guest, and a line about a call that
                   was refused BECAUSE no machine answered is exactly the
                   line the person needs. */
                if request.operation != .sessionHealth,
                   request.operation != .audit,
                   let refusal = agentIntegration.addressingRefusal(
                       request.guestSelector) {
                    return .notAddressed(refusal)
                }
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
                            agentIntegration.activeReference()?.id)
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
                case .guestLogTail:
                    /* P1 #9. Nothing to read off the request but a count the
                       codec has already bounded, and nothing to refuse here:
                       a request that named no count is a COMPLETE request —
                       absent means the guest's own default of 20 — which is
                       what makes this the shortest branch in the switch. */
                    return .guestLogTail(
                        await agentIntegration.tailGuestLog(
                            lines: request.logLineCount))
                case .census, .softwareInventory,
                     .machineFacts, .catalogSearch,
                     .diagnostics:
                    /* P1a landed the SERIALIZATION for eleven capabilities
                       and none of their adapters (plan 005): eleven agents
                       each
                       adding a verb to the same three list tails is eleven
                       conflicts, so the verbs went in as one commit and the
                       capabilities follow one row at a time.

                       A typed refusal and not an empty success. Nothing can
                       reach this from a face — a verb with no projection row
                       is unreachable from all four — so the only caller is
                       a process composing the request itself, and what it
                       must be told is that this host does not serve the
                       operation YET. An empty answer would read as a fact
                       about the Mac.

                       WIRING ONE: replace its case here with the adapter
                       call, and add its projection row. Nothing else in
                       this file needs to change. */
                    return .notImplemented(
                        .notWired(request.operation.rawValue))
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
