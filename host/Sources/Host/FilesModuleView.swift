import AppKit
import SwiftUI

struct FilesModuleView: View {
    @ObservedObject var model: FilesModuleModel
    @State private var sortOrder = [KeyPathComparator(\FileRow.name)]

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
            }
            footer
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { if model.rows.isEmpty { model.refresh() } }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Files")
                    .font(.largeTitle.weight(.semibold))
                Text("Browse the folder the classic Mac shares.")
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

            Button("Share") { model.jump(toDepth: -1) }
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
        Table(model.rows.sorted(using: sortOrder),
              selection: $model.selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                HStack(spacing: 6) {
                    Image(systemName: row.symbolName)
                        .foregroundStyle(row.isFolder ? Color.accentColor
                                                      : .secondary)
                        .frame(width: 16)
                    Text(row.name)
                    if let note = row.conversionNote {
                        Text(note)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15),
                                        in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            TableColumn("Kind", value: \.kind) { row in
                Text(row.kind).foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 120)
            TableColumn("Size", value: \.sizeBytes) { row in
                Text(row.isFolder ? "—" : byteText(row.sizeBytes))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)
            TableColumn("Modified") { row in
                Text(row.modified.map(dateText) ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 150)
        }
        .contextMenu(forSelectionType: FileRow.ID.self) { ids in
            if let row = model.rows.first(where: { ids.contains($0.id) }),
               !row.isFolder {
                Button("Download") { model.download(row) }
                Button("Download as MacBinary") {
                    model.download(row, container: "macbinary")
                }
                Divider()
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(row.path, forType: .string)
                }
            }
        } primaryAction: { ids in
            guard let row = model.rows.first(where: { ids.contains($0.id) })
            else { return }
            if row.isFolder {
                model.open(row)
            } else {
                model.download(row)
            }
        }
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
            Text("The classic Mac dials this host; its shared folder "
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
            ProgressView(value: transfer.fraction)
                .frame(maxWidth: 260)
            Text("\(transfer.name) — \(byteText(transfer.received)) of "
                 + byteText(transfer.expected))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Cancel") { model.cancelTransfer() }
                .controlSize(.small)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let error = model.lastError, !model.rows.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            Spacer()
            Text("Downloads to")
                .foregroundStyle(.secondary)
            Menu {
                ForEach(folderChoices, id: \.path) { url in
                    Button(url.lastPathComponent) {
                        model.downloadDirectory = url
                    }
                }
                Divider()
                Button("Other…") { chooseDirectory() }
            } label: {
                HStack(spacing: 5) {
                    Image(nsImage: NSWorkspace.shared
                        .icon(forFile: model.downloadDirectory.path))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(model.downloadDirectory.lastPathComponent)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(model.downloadDirectory.path)
        }
        .font(.callout)
    }

    private var folderChoices: [URL] {
        let standard: [FileManager.SearchPathDirectory] =
            [.downloadsDirectory, .desktopDirectory, .documentDirectory]
        var urls = standard.compactMap {
            FileManager.default.urls(for: $0, in: .userDomainMask).first
        }
        if !urls.contains(where: {
            $0.path == model.downloadDirectory.path
        }) {
            urls.insert(model.downloadDirectory, at: 0)
        }
        return urls
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.downloadDirectory
        panel.prompt = "Choose"
        panel.message = "Choose where files from the classic Mac land."
        if panel.runModal() == .OK, let url = panel.url {
            model.downloadDirectory = url
        }
    }

    private func byteText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes),
                                  countStyle: .file)
    }

    private func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
