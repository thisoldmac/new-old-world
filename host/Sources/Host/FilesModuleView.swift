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
            case .connected(let name):
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
            Button {
                model.goUp()
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(model.breadcrumb.isEmpty || !model.canBrowse)
            .help("Enclosing folder")

            Button(model.shareRootName) { model.jump(toDepth: -1) }
                .buttonStyle(.plain)
                .foregroundStyle(model.breadcrumb.isEmpty
                                 ? .primary : Color.accentColor)

            ForEach(Array(model.breadcrumb.enumerated()), id: \.offset) {
                index, component in
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Button(component) { model.jump(toDepth: index) }
                    .buttonStyle(.plain)
                    .foregroundStyle(index == model.breadcrumb.count - 1
                                     ? .primary : Color.accentColor)
            }

            Spacer()
            if let row = selectedRow, !row.isFolder {
                Menu {
                    Button("Download") { model.download(row) }
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

            Button {
                chooseFileToSend()
            } label: {
                Label("Add File…", systemImage: "plus")
            }
            .disabled(!model.canBrowse || model.transfer != nil)
            .help("Send a file from this Mac into this folder")

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

    private var table: some View {
        FileBrowserTable(model: model,
                         rows: model.sorted(using: sortOrder),
                         onOpen: { row in
                             if row.isFolder {
                                 model.open(row)
                             } else {
                                 model.download(row)
                             }
                         },
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
        return counted + t.name + " — " + byteText(t.received) + " of "
            + byteText(t.expected)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let error = model.lastError, !model.rows.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
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
                Button(url.lastPathComponent) { choose(url) }
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
                Text(current.lastPathComponent)
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
        if !urls.contains(where: { $0.path == current.path }) {
            urls.insert(current, at: 0)
        }
        return urls
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
