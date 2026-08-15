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
            FilesWorkspaceShell(
                model: model,
                sort: $sortOrder,
                chooseFileToSend: chooseFileToSend)
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
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            model.discoverLocationsIfNeeded()
        }
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
        .sheet(item: Binding(
            get: { model.newFolderPrompt },
            set: { if $0 == nil { model.cancelNewFolder() } })) { prompt in
            NewFolderSheet(
                initialName: prompt.initialName,
                create: { model.createFolderFromPrompt(named: $0) },
                cancel: { model.cancelNewFolder() })
        }
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
                      ? "Everything has been sent, but "
                        + "\(MachineNaming.sentence(model.connection)) "
                        + "reads far slower than this side writes. It "
                        + "confirms "
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
    @State private var name: String
    let create: (String) -> Void
    let cancel: () -> Void

    init(initialName: String,
         create: @escaping (String) -> Void,
         cancel: @escaping () -> Void) {
        _name = State(initialValue: initialName)
        self.create = create
        self.cancel = cancel
    }

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
