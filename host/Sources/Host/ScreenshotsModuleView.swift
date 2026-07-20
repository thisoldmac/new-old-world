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
                    Text("Capture \(model.connection.peerLabel)'s screen over the wire.")
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
                        .help("Ask for a whole frame")
                }

                if model.isCapturing {
                    Button("Cancel") { model.cancel() }
                }

                if let error = model.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }

            settingsDisclosure
            if model.showSettings {
                tuningRow
            }

            if model.isCapturing || model.progress != nil {
                transferProgress
            }
            if let recording = model.recording {
                recordingRow(recording)
            }
            saveRow
        }
    }

    private var settingsDisclosure: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                model.showSettings.toggle()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: model.showSettings
                      ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                Text("Settings")
            }
            .foregroundStyle(.secondary)
            .font(.callout)
        }
        .buttonStyle(.plain)
    }

    /// The same knobs the guest's panel has; sent with every request and
    /// stream, so the side that initiates decides.
    private var tuningRow: some View {
        HStack(spacing: 14) {
            Picker("Depth", selection: $model.selectedDepth) {
                ForEach(CaptureDepth.allCases) { depth in
                    Text(depth.title).tag(depth)
                }
            }
            .frame(width: 130)
            Picker("Chunk", selection: $model.chunkKB) {
                ForEach([1, 2, 4, 8, 16, 32], id: \.self) { kb in
                    Text("\(kb) K").tag(kb)
                }
            }
            .frame(width: 120)
            Picker("Pacing", selection: $model.paceMs) {
                ForEach([0, 2, 5, 10, 20], id: \.self) { ms in
                    Text(ms == 0 ? "None" : "\(ms) ms").tag(ms)
                }
            }
            .frame(width: 130)
            Picker("Max fps", selection: $model.maxFps) {
                ForEach(ScreenshotModuleModel.fpsChoices, id: \.self) { fps in
                    Text("\(fps) fps").tag(fps)
                }
            }
            .frame(width: 130)
            Toggle("Compress", isOn: $model.compress)
            Toggle("Predictive", isOn: $model.predictive)
            Toggle("Interlace", isOn: $model.interlace)
        }
        .pickerStyle(.menu)
        .font(.callout)
        .disabled(model.isCapturing || model.isStreaming)
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
                Text("Waiting for the capture…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 420)
        }
    }

    /// The landing pad is not the toggle's: screenshots the guest sends
    /// always save to the folder, so the folder is always live. The toggle
    /// only governs captures taken from this panel.
    /// The finished movie of the stream that just ended, already encoded:
    /// saving is a file move, declining deletes the temp.
    private func recordingRow(_ recording: StreamRecorder.Recording)
        -> some View {
        HStack(spacing: 12) {
            Label(String(format: "Recording — %.0f s · %d frames · %.1f MB",
                         recording.duration, recording.frames,
                         Double(recording.bytes) / 1_048_576),
                  systemImage: "record.circle")
                .foregroundStyle(.secondary)
            Button("Save As…") { saveRecording(recording) }
            Button("Discard") { model.discardRecording() }
        }
        .font(.callout)
    }

    private func saveRecording(_ recording: StreamRecorder.Recording) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.directoryURL = model.saveDirectory
        panel.nameFieldStringValue = model.suggestedRecordingName
        if panel.runModal() == .OK, let url = panel.url {
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                try FileManager.default.moveItem(at: recording.url, to: url)
                model.discardRecordingReference()
            } catch {
                // The temp survives; the row stays for another try.
            }
        }
    }

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

    /// Fills whatever space the window gives it; nearest-neighbor keeps
    /// the classic pixels crisp at any scale.
    private func preview(_ shot: ScreenshotRecord) -> some View {
        Image(decorative: shot.image, scale: 1.0)
            .resizable()
            .interpolation(.none)
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                 ? "Press Capture to pull \(model.connection.peerLabel)'s screen "
                   + "across the wire."
                 : "Connect a Mac first — it dials this one.")
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
        panel.nameFieldStringValue = model.suggestedScreenshotName
        if panel.runModal() == .OK, let url = panel.url {
            try? png.write(to: url)
        }
    }

}
