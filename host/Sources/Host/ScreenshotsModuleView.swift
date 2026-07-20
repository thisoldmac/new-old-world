import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ScreenshotsModuleView: View {
    @ObservedObject var model: ScreenshotModuleModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Divider()
            if model.isStreaming, let frame = model.liveFrame {
                preview(frame)
                streamStatsRow
            } else if model.isStreaming {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Waiting for the first frame…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let shot = model.latest {
                preview(shot)
                statsRow(shot)
                actionRow(shot)
            } else {
                emptyState
            }
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Screenshots")
                        .font(.largeTitle.weight(.semibold))
                    Text("Capture the connected Mac's screen over the wire.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                connectionBadge
            }

            HStack(spacing: 12) {
                Button(model.isCapturing ? "Capturing…" : "Capture") {
                    model.capture()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canCapture)

                Button(model.isStreaming ? "Stop Streaming"
                                         : "Start Streaming") {
                    model.isStreaming ? model.stopStream()
                                      : model.startStream()
                }
                .disabled(!model.canStream)

                if model.isStreaming {
                    Button("Refresh") { model.refreshStream() }
                        .help("Ask the guest for a whole frame")
                }

                if model.isCapturing {
                    Button("Cancel") { model.cancel() }
                }

                Picker("Depth", selection: $model.selectedDepth) {
                    ForEach(CaptureDepth.allCases) { depth in
                        Text(depth.title).tag(depth)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 150)
                .disabled(model.isCapturing || model.isStreaming)

                if let error = model.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }

            if model.isCapturing || model.progress != nil {
                transferProgress
            }
            saveRow
        }
    }

    /// A capture over 802.11b takes long enough that silence reads as a
    /// hang — so show the bytes arriving. Before capture.begin lands there
    /// is no total to divide by, hence the indeterminate first phase.
    @ViewBuilder
    private var transferProgress: some View {
        if let progress = model.progress, progress.expected > 0 {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: progress.fraction)
                Text("\(progress.received / 1024) KB of "
                     + "\(progress.expected / 1024) KB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 420)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView().progressViewStyle(.linear)
                Text("Waiting for the guest to capture…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 420)
        }
    }

    /// The landing pad is not the toggle's: screenshots the guest sends
    /// always save to the folder, so the folder is always live. The toggle
    /// only governs captures taken from this panel.
    private var saveRow: some View {
        HStack(spacing: 16) {
            Toggle("Save captures", isOn: $model.autoSave)
            Toggle("Copy to clipboard", isOn: $model.autoCopy)
            Spacer()
            HStack(spacing: 8) {
                Text("Save screenshots to")
                folderPicker
            }
        }
        .font(.callout)
    }

    /// The system's folder-choosing idiom (as in Safari's download
    /// location): a pop-up of the likely folders, with Other… falling
    /// through to the real open panel.
    private var folderPicker: some View {
        Menu {
            ForEach(folderChoices, id: \.path) { url in
                Button { model.saveDirectory = url } label: {
                    Label {
                        Text(url.lastPathComponent)
                    } icon: {
                        Image(nsImage: NSWorkspace.shared
                            .icon(forFile: url.path))
                    }
                }
            }
            Divider()
            Button("Other…") { chooseDirectory() }
        } label: {
            HStack(spacing: 5) {
                Image(nsImage: NSWorkspace.shared
                    .icon(forFile: model.saveDirectory.path))
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(model.saveDirectory.lastPathComponent)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(model.saveDirectory.path)
    }

    /// The standard destinations, plus wherever the user already chose so
    /// the current folder is always in the list.
    private var folderChoices: [URL] {
        let standard: [FileManager.SearchPathDirectory] =
            [.desktopDirectory, .picturesDirectory, .downloadsDirectory,
             .documentDirectory]
        var urls = standard.compactMap {
            FileManager.default.urls(for: $0, in: .userDomainMask).first
        }
        if !urls.contains(where: { $0.path == model.saveDirectory.path }) {
            urls.insert(model.saveDirectory, at: 0)
        }
        return urls
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.saveDirectory
        panel.prompt = "Choose"
        panel.message = "Choose where New Old World saves captures."
        if panel.runModal() == .OK, let url = panel.url {
            model.saveDirectory = url
        }
    }

    @ViewBuilder
    private var connectionBadge: some View {
        switch model.connection {
        case .disconnected:
            Label("No Mac Connected", systemImage: "circle.fill")
                .foregroundStyle(.secondary)
        case .connecting:
            Label("Connecting", systemImage: "circle.dotted")
                .foregroundStyle(.orange)
        case .connected(let name):
            Label(name, systemImage: "circle.fill")
                .foregroundStyle(.green)
        }
    }

    private func preview(_ shot: ScreenshotRecord) -> some View {
        Image(decorative: shot.image, scale: 1.0)
            .resizable()
            .interpolation(.none)
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: 420)
            .border(Color.secondary.opacity(0.4))
    }

    private var streamStatsRow: some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 3) {
            if let stats = model.streamStats {
                GridRow {
                    Text("Stream").foregroundStyle(.secondary)
                    Text(String(format: "%.1f fps · %.0f KB/s · frame %d",
                                stats.fps, stats.kbPerSecond, stats.frames))
                }
                if let frame = model.liveFrame {
                    GridRow {
                        Text("Frame").foregroundStyle(.secondary)
                        Text("\(frame.width) × \(frame.height) · "
                             + "\(frame.format.depth)-bit · "
                             + "\(frame.wireBytes / 1024) KB · "
                             + "\(stats.lastFrameMs) ms")
                    }
                }
            }
        }
        .font(.callout)
    }

    private func statsRow(_ shot: ScreenshotRecord) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 3) {
            GridRow {
                Text("Image").foregroundStyle(.secondary)
                Text("\(shot.width) × \(shot.height) · "
                     + "\(shot.format.depth)-bit · "
                     + (shot.format.packed ? "PackBits" : "raw"))
            }
            GridRow {
                Text("Wire").foregroundStyle(.secondary)
                Text("\(shot.wireBytes / 1024) KB from "
                     + "\(shot.rawBytes / 1024) KB raw "
                     + String(format: "(%.1f×)", shot.compressionRatio))
            }
            GridRow {
                Text("Guest").foregroundStyle(.secondary)
                Text("capture \(shot.format.captureMs) ms · "
                     + "encode \(shot.format.encodeMs) ms")
            }
            GridRow {
                Text("Transfer").foregroundStyle(.secondary)
                Text("\(shot.transferMs) ms"
                     + (shot.transferMs > 0
                        ? String(format: " · %.0f KB/s",
                                 Double(shot.wireBytes) / 1024.0
                                 / (Double(shot.transferMs) / 1000.0))
                        : ""))
            }
        }
        .font(.callout)
    }

    private func actionRow(_ shot: ScreenshotRecord) -> some View {
        HStack(spacing: 12) {
            Button("Save as PNG…") { save(shot) }
            Button("Save to \(model.saveDirectory.lastPathComponent)") {
                model.write(shot, to: model.saveDirectory)
            }
            Button("Copy to Clipboard") { model.copyToPasteboard(shot) }
            Text(shot.capturedAt, format: .dateTime.hour().minute().second())
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("No Screenshots Yet")
                .font(.title2.weight(.semibold))
            Text(model.connection.canCapture
                 ? "Press Capture to pull the classic Mac's screen "
                   + "across the wire."
                 : "Connect a Mac first — the guest dials this host.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func save(_ shot: ScreenshotRecord) {
        guard let png = CaptureDecoder.pngData(shot.image) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "NOW Screenshot.png"
        if panel.runModal() == .OK, let url = panel.url {
            try? png.write(to: url)
        }
    }

}
