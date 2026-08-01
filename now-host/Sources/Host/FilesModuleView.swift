import AppKit
import Combine
import SwiftUI

struct FilesModuleView: View {
    @ObservedObject var model: FilesModuleModel
    @State private var sortOrder = [KeyPathComparator(\FileRow.name)]
    /// Ticks while a transfer waits, so the elapsed time visibly moves
    /// and a slow tail does not read as a freeze.
    @State private var elapsed = Date()
    /// Ticks only while something is in flight. It exists to make a
    /// stalled transfer visibly still moving; running it for the life of
    /// the pane invalidated `body` once a second forever, and `body`
    /// sorts the row array.
    private var clock: AnyPublisher<Date, Never> {
        model.transfer == nil
            ? Empty().eraseToAnyPublisher()
            : Timer.publish(every: 1, on: .main, in: .common)
                .autoconnect().eraseToAnyPublisher()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            breadcrumbBar
            Divider()
            if model.canBrowse {
                table
            } else {
                disconnectedState
            }
            if let transfer = model.transfer {
                transferRow(transfer)
            } else if !model.queue.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("\(model.queue.count) file"
                         + (model.queue.count == 1 ? "" : "s") + " waiting")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Stop") { model.clearQueue() }
                        .controlSize(.small)
                }
            }
            footer
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { if model.rows.isEmpty { model.refresh() } }
        .onReceive(clock) { elapsed = $0 }
        .confirmationDialog(
            "Replace “\(model.overwritePrompt?.name ?? "")”?",
            isPresented: Binding(
                get: { model.overwritePrompt != nil },
                set: { if !$0 { model.cancelOverwrite() } }),
            presenting: model.overwritePrompt) { prompt in
            Button("Replace", role: .destructive) {
                model.confirmOverwrite()
            }
            if (model.overwritePrompt?.remaining ?? 0) > 0 {
                Button("Skip") { model.skipOverwrite() }
            }
            Button("Cancel", role: .cancel) { model.cancelOverwrite() }
        } message: { prompt in
            Text("A file of that name is already in "
                 + (prompt.folder.isEmpty ? "the shared folder"
                                          : prompt.folder) + "."
                 + (prompt.remaining > 0
                    ? " \(prompt.remaining) more waiting." : ""))
        }
        // Changing the share is asked about before it happens. This is a
        // question, not a failure, so it is a sheet on the window rather
        // than an alert.
        .sheet(item: $model.pendingChange) { pending in
            ChangeConfirmation(
                pending: pending,
                confirm: { model.commitPendingChange() },
                cancel: { model.cancelPendingChange() })
        }
        .sheet(isPresented: Binding(
            get: { model.newFolderName != nil },
            set: { if !$0 { model.newFolderName = nil } })) {
            NewFolderSheet(
                name: Binding(get: { model.newFolderName ?? "" },
                              set: { model.newFolderName = $0 }),
                create: { name in
                    model.newFolderName = nil
                    model.createFolder(named: name)
                },
                cancel: { model.newFolderName = nil })
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Files")
                    .font(.largeTitle.weight(.semibold))
                Text("Browse the folder \(model.connection.peerLabel) shares.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch model.connection {
            case .connected(let name, _):
                Label(name, systemImage: "circle.fill")
                    .foregroundStyle(.green)
            case .connecting:
                Label("Connecting", systemImage: "circle.dotted")
                    .foregroundStyle(.orange)
            case .disconnected:
                Label("No Mac Connected", systemImage: "circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var breadcrumbBar: some View {
        HStack(spacing: 6) {
            /* The up button stays. The parent is always a crumb away, so
               this is not the only way out any more — but it is a fixed
               target that does not move as the path changes shape, and
               removing a control that works to make room for a new one
               is not a trade anybody asked for. */
            Button {
                model.goUp()
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(model.breadcrumb.isEmpty || !model.canBrowse)
            .help("Enclosing folder")

            pathBar

            Spacer()
            if let row = selectedRow, !row.isFolder {
                Menu {
                    Button("Open on This Mac") { model.openOnThisMac(row) }
                    Divider()
                    Button("Download to "
                           + model.downloadDirectory.lastPathComponent) {
                        model.download(row)
                    }
                    Button("Download as MacBinary") {
                        model.download(row, container: "macbinary")
                    }
                    Divider()
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(row.path,
                                                       forType: .string)
                    }
                } label: {
                    Label(row.name, systemImage: "square.and.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Button {
                model.newFolderName = "untitled folder"
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .labelStyle(.iconOnly)
            .disabled(!model.canBrowse || model.isChanging)
            .help("New folder here")

            if let title = model.undoTitle {
                // The button undoes the last change; the menu is what
                // this window has done, most recent first, so "what did
                // I just do" has an answer that is not memory.
                Menu {
                    Button(title) { model.undoLastChange() }
                    Divider()
                    Section("This session") {
                        ForEach(model.history.reversed()) { change in
                            Text(change.summary)
                        }
                    }
                    Divider()
                    Button("Clear History") { model.clearHistory() }
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                } primaryAction: {
                    model.undoLastChange()
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(model.isChanging)
                .help(title)
            }

            Menu {
                Button("Approve One-Time Agent Transfer…") {
                    chooseFileToApprove()
                }
            } label: {
                Label("Add File…", systemImage: "plus")
            } primaryAction: {
                chooseFileToSend()
            }
            .menuStyle(.borderlessButton)
            .disabled(!model.canBrowse || model.transfer != nil)
            .help("Send now, or approve one private staged copy for an agent")

            if model.isLoading {
                ProgressView().controlSize(.small)
            }
            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(!model.canBrowse)
            .help("Refresh")
        }
        .font(.callout)
    }

    /// Where you are, disk first, with every place you are allowed to go
    /// one click away. The decomposition and the folding are
    /// `FilePathBar`; this draws what it decided.
    private var pathBar: some View {
        HStack(spacing: 4) {
            ForEach(Array(model.pathItems.enumerated()), id: \.element.id) {
                offset, item in
                if offset > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                switch item {
                case .crumb(let crumb):
                    crumbView(crumb)
                case .elision(let hidden):
                    elisionMenu(hidden)
                }
            }
            pathStatusNote
        }
        .lineLimit(1)
        .help(model.fullPath.isEmpty
              ? "The folder \(model.connection.peerLabel) shares"
              : model.fullPath)
    }

    @ViewBuilder
    private func crumbView(_ crumb: FilePathBar.Crumb) -> some View {
        let label = HStack(spacing: 4) {
            if crumb.isVolume {
                // The top of the tree on that machine is a disk with a
                // name, not a slash.
                Image(systemName: "externaldrive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(crumb.name)
        }

        if crumb.isPlaceholder {
            label
                .foregroundStyle(.secondary)
                .help("\(model.connection.peerLabel) has not said which "
                      + "folder it shares yet.")
        } else if let depth = crumb.depth {
            Button { model.jump(toDepth: depth) } label: { label }
                .buttonStyle(.plain)
                .foregroundStyle(isCurrent(crumb)
                                 ? AnyShapeStyle(.primary)
                                 : AnyShapeStyle(Color.accentColor))
                .disabled(!model.canBrowse)
                .help(crumb.role == .shareRoot
                      ? "The folder \(model.connection.peerLabel) shares"
                      : "Go to \(crumb.name)")
        } else {
            /* Above the shared folder. It is a real place on that Mac
               and naming it is the point — but the share boundary stops
               here, so it is not offered as somewhere to click. */
            label
                .foregroundStyle(.secondary)
                .help(crumb.isVolume
                      ? "The disk on \(model.connection.peerLabel). "
                        + "Browsing starts at the folder it shares."
                      : "On \(model.connection.peerLabel), outside the "
                        + "folder it shares")
        }
    }

    /// The folded middle of a deep path. Nothing is lost — it is a menu
    /// of exactly the crumbs the bar did not have room to draw.
    private func elisionMenu(_ hidden: [FilePathBar.Crumb]) -> some View {
        Menu {
            ForEach(hidden) { crumb in
                if let depth = crumb.depth {
                    Button(crumb.name) { model.jump(toDepth: depth) }
                } else {
                    Text(crumb.name)
                }
            }
        } label: {
            Text("…")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(hidden.count == 1
              ? "1 folder not shown: " + hidden[0].name
              : "\(hidden.count) folders not shown: "
                + hidden.map(\.name).joined(separator: ", "))
    }

    /// The bar never goes blank. Before the first listing, and after a
    /// failed one, it says which of those happened.
    @ViewBuilder
    private var pathStatusNote: some View {
        switch model.pathStatus {
        case .ready:
            EmptyView()
        case .noGuest:
            Text("— no Mac connected")
                .foregroundStyle(.secondary)
        case .loading:
            Text("— listing…")
                .foregroundStyle(.secondary)
        case .unlisted:
            Text("— nothing listed yet")
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label("not listed", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .help(message)
        }
    }

    /// The folder actually on screen — the deepest crumb, which is the
    /// share root itself when nothing has been opened.
    private func isCurrent(_ crumb: FilePathBar.Crumb) -> Bool {
        crumb.depth == model.breadcrumb.count - 1
    }

    private var table: some View {
        FileBrowserTable(model: model,
                         rows: model.sorted(using: sortOrder),
                         // A double-click means "let me look at this":
                         // a folder opens, a file comes to the folder
                         // this Mac shares and opens here.
                         onOpen: { model.openOnThisMac($0) },
                         sort: $sortOrder)
            .overlay {
                if model.rows.isEmpty && !model.isLoading {
                    emptyState
                }
            }
            .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: model.lastError == nil
                  ? "folder" : "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(model.lastError ?? "This folder is empty")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 420)
    }

    private var disconnectedState: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("No Mac Connected")
                .font(.title2.weight(.semibold))
            Text("The other Mac dials this one; its shared folder "
                 + "appears here once it does.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func transferRow(_ transfer: FilesModuleModel.TransferState)
        -> some View {
        HStack(spacing: 12) {
            Image(systemName: transfer.direction == .incoming
                  ? "arrow.down.circle" : "arrow.up.circle")
                .foregroundStyle(.secondary)
            if transfer.isAwaitingReceipt {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 240)
            } else {
                ProgressView(value: transfer.fraction)
                    .frame(maxWidth: 240)
            }
            Text(transferLabel(transfer))
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(transfer.isAwaitingReceipt
                      ? "Everything has been sent, but the classic Mac "
                        + "reads far slower than we write. It confirms "
                        + "once the file is written and named."
                      : "Bytes handed to the network so far.")
            Button("Cancel") { model.cancelTransfer() }
                .controlSize(.small)
            if !model.queue.isEmpty {
                Button("Stop All") {
                    model.clearQueue()
                    model.cancelTransfer()
                }
                .controlSize(.small)
            }
        }
    }

    private var selectedRow: FileRow? {
        model.rows.first { $0.id == model.selection }
    }

    private func transferLabel(_ t: FilesModuleModel.TransferState)
        -> String {
        let counted = t.index.map { i in
            "(\(i) of \(t.total ?? i)) " } ?? ""
        if t.isAwaitingReceipt {
            let secs = Int(elapsed.timeIntervalSince(t.startedAt))
            return counted + t.name + " — sent, "
                + model.connection.peerLabel + " is still receiving ("
                + String(format: "%d:%02d", secs / 60, secs % 60) + ")"
        }
        /* A double-click on a big file is a long wait with nothing on
           screen to explain it, which is indistinguishable from a broken
           control. The row says what the wait is FOR, and the Cancel
           button beside it is how it ends early — a stopped transfer
           opens nothing. */
        let then = t.opensWhenDone ? ", then opens here" : ""
        return counted + t.name + " — " + byteText(t.received) + " of "
            + byteText(t.expected) + then
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let error = model.lastError, !model.rows.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            // Not a failure, so not red, and it is dismissible: a file
            // that landed somewhere real is news, not a fault.
            if let notice = model.lastNotice {
                Label(notice, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .onTapGesture { model.lastNotice = nil }
                    .help("Click to dismiss")
            }
            Toggle("Convert text files", isOn: $model.convertText)
                .help("Line endings and encoding, both directions")
            Spacer()
            Text("Sharing")
                .foregroundStyle(.secondary)
            folderMenu(current: model.shareDirectory) {
                model.shareDirectory = $0
            }
            .help("What \(model.connection.peerLabel) can browse and "
                  + "write into: "
                  + model.shareDirectory.path)
            Divider().frame(height: 16)
            Text("Downloads to")
                .foregroundStyle(.secondary)
            folderMenu(current: model.downloadDirectory) {
                model.downloadDirectory = $0
            }
            .help(model.downloadDirectory.path)
        }
        .font(.callout)
    }

    /// A folder picker that looks like the Finder's: the usual places,
    /// the current one if it is somewhere else, and a way out to any
    /// folder at all.
    private func folderMenu(current: URL,
                            choose: @escaping (URL) -> Void) -> some View {
        Menu {
            ForEach(folderChoices(including: current), id: \.path) { url in
                /* The Finder's name for the folder, not the path's:
                   iCloud Drive's directory is literally named
                   "com~apple~CloudDocs". */
                Button(FileManager.default.displayName(atPath: url.path)) {
                    choose(url)
                }
            }
            Divider()
            Button("Other…") {
                if let url = askForDirectory(startingAt: current) {
                    choose(url)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: current.path))
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(FileManager.default.displayName(atPath: current.path))
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func askForDirectory(startingAt url: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = url
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func folderChoices(including current: URL) -> [URL] {
        let standard: [FileManager.SearchPathDirectory] =
            [.downloadsDirectory, .desktopDirectory, .documentDirectory]
        var urls = standard.compactMap {
            FileManager.default.urls(for: $0, in: .userDomainMask).first
        }
        if let cloud = Self.iCloudDrive { urls.append(cloud) }
        if !urls.contains(where: { $0.path == current.path }) {
            urls.insert(current, at: 0)
        }
        return urls
    }

    /// The travel visa itself: share this and the classic Mac browses
    /// iCloud Drive. Present only when this Mac is signed in — the
    /// share already knows how to list placeholders and fetch on
    /// demand, so no more ceremony is needed here.
    private static var iCloudDrive: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Mobile Documents/com~apple~CloudDocs")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path,
                                             isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return url
    }

    private func chooseFileToSend() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Send"
        panel.message = "Choose a file to send to "
            + model.connection.peerLabel + "."
        if panel.runModal() == .OK, let url = panel.url {
            model.send(url)
        }
    }

    private func chooseFileToApprove() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Approve"
        panel.message =
            "Choose one regular file to stage privately for a one-time "
            + "agent transfer into this guest folder. No transfer starts now."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let alert = NSAlert()
        switch model.approveForAgent(url) {
        case .success(let approval):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                approval.receipt, forType: .string)
            alert.messageText = "Artifact Approval Copied"
            let destination = approval.destination.isEmpty
                ? "the guest share root" : approval.destination
            var detail =
                "A private read-only copy of “\(approval.name)” is approved "
                + "once for \(destination) for 10 minutes. "
                + "The receipt contains no source or guest path."
            if let conversion = approval.conversion {
                detail += " Transfer will apply: \(conversion)."
            }
            alert.informativeText = detail
            alert.alertStyle = .informational
        case .failure(.refused(let message)),
             .failure(.unavailable(let message)):
            alert.messageText = "Artifact Not Approved"
            alert.informativeText = message
            alert.alertStyle = .warning
        }
        alert.runModal()
    }

    private func byteText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes),
                                  countStyle: .file)
    }

}




/// The question asked before anything in the share changes. Two buttons,
/// the safe one default: a confirmation that is easy to dismiss without
/// reading is not a confirmation.
private struct ChangeConfirmation: View {
    let pending: FilesModuleModel.PendingChange
    let confirm: () -> Void
    let cancel: () -> Void

    private var isDestructive: Bool {
        if case .trash = pending.kind { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: isDestructive ? "trash" : "arrow.right.doc.on.clipboard")
                    .font(.system(size: 28))
                    .foregroundStyle(isDestructive ? Color.red : Color.accentColor)
                VStack(alignment: .leading, spacing: 6) {
                    Text(pending.title).font(.headline)
                    Text(pending.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(pending.confirmLabel, action: confirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 400)
    }
}

private struct NewFolderSheet: View {
    @Binding var name: String
    let create: (String) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Name of the new folder").font(.headline)
            TextField("untitled folder", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { create(name) }
            Text("Up to \(FileChangeNames.maxNameLength) characters, and no "
                 + "colons.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create(name) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces)
                                  .isEmpty)
            }
        }
        .padding(22)
        .frame(width: 360)
    }
}
