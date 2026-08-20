import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The Screen page: one still capture, or the live stream, of the machine
/// being driven.
///
/// The file keeps its old name (the projection rows in
/// `CaptureScreenProjection` and `StreamScreenProjection` name it, and
/// `HostFaceParityTests` reads it) — the MODULE is "Screen", because the
/// page carries the stream and its recording as well as the stills.
///
/// Three bands, top to bottom, and the order is the point: what you ask for,
/// what came back, and what happens to it. The controls that decide the
/// NEXT capture live in the bottom band with the output because that is
/// where a person is looking when they decide to change one.
struct ScreenshotsModuleView: View {
    @ObservedObject var model: ScreenshotModuleModel

    /* View state, not a preference: an app that reopened with its settings
       sheet already up would be presenting a modal nobody asked for. */
    @State private var showingSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Divider()
            output
            Divider()
            outputRow
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showingSettings) { settingsSheet }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Screen")
                        .font(.largeTitle.weight(.semibold))
                    Text("Screen capture from \(model.connection.peerLabel), over the wire.")
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

                Button(model.streamButtonTitle) {
                    model.toggleStream()
                }
                .disabled(!model.canStream)
                /* Present and dark rather than gone. Hiding it would move
                   every control beside it as machines connect, and would make
                   a capability the driven machine lacks indistinguishable
                   from one NOW
                   does not have. The reason is on the button for a pointer
                   and in the line below for the eye. */
                /* The screen being watched is the driven machine's, not
                   this one's. */
                .help(model.streamGateTooltip
                      ?? "Stream \(MachineNaming.possessive(model.connection)) "
                         + "screen live")

                if model.isStreaming {
                    Button("Refresh") { model.refreshStream() }
                        .help("Request a full frame")
                }

                if model.isCapturing {
                    Button("Cancel") { model.cancel() }
                }

                Spacer()

                settingsButton

                if let error = model.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }

            /* Said in a sentence rather than left to be inferred from a
               Capture button that has quietly gone grey. A live view that
               started by itself is otherwise indistinguishable from a
               fault, and the person's own next click — Capture — is the one
               the open bracket refuses. */
            if let note = model.streamOwnerNote {
                Label(note, systemImage: "person.wave.2")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            /* **A dark control that says nothing is indistinguishable from a
               bug**, and the person's conclusion is that the app is broken.
               So the machine's own refusal is stated in place, beside the
               button it explains — not as an error, because nothing is wrong:
               it is a difference between the two guests. Shown only for the
               states that disable the button; a control that merely has not
               been proven yet still works, and does not get to nag. */
            if let note = model.streamUnavailableNote {
                Label(note, systemImage: "minus.circle")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.isCapturing || model.progress != nil {
                transferProgress
            }
            if let recording = model.recording {
                recordingRow(recording)
            }
        }
    }

    /// The middle band: whatever there is to look at, filling the space.
    @ViewBuilder
    private var output: some View {
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

    // MARK: - Settings

    /// The driven machine as the owner of something, at the head of a
    /// sentence — hoisted because the call does not fit in a string
    /// interpolation on one line.
    private var drivenMachinePossessive: String {
        MachineNaming.startingSentence(
            MachineNaming.possessive(model.connection))
    }

    private var settingsButton: some View {
        Button {
            showingSettings = true
        } label: {
            Label("Settings", systemImage: "slider.horizontal.3")
        }
        .help("Capture and transfer settings")
    }

    /// The wire plumbing, and nothing else.
    ///
    /// Depth is NOT in here, deliberately: it is the one knob a person
    /// changes to answer a question about the picture they are looking at
    /// ("would this read better in colour?"), so it lives beside the picture.
    /// What is left is how the bytes travel — chunking, pacing, the frame
    /// ceiling and the three encodings — which is set once and forgotten.
    private var settingsSheet: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Chunk size", selection: $model.chunkKB) {
                        ForEach([1, 2, 4, 8, 16, 32], id: \.self) { kb in
                            Text("\(kb) K").tag(kb)
                        }
                    }
                    Picker("Pacing", selection: $model.paceMs) {
                        ForEach([0, 2, 5, 10, 20], id: \.self) { ms in
                            Text(ms == 0 ? "None" : "\(ms) ms").tag(ms)
                        }
                    }
                } header: {
                    Text("Transfer")
                } footer: {
                    Text("Smaller chunks and a longer pause keep "
                         + "\(MachineNaming.sentence(model.connection)) "
                         + "responsive while sending; larger ones finish "
                         + "sooner.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Picker("Frame ceiling", selection: $model.maxFps) {
                        ForEach(ScreenshotModuleModel.fpsChoices,
                                id: \.self) { fps in
                            Text("\(fps) fps").tag(fps)
                        }
                    }
                } header: {
                    Text("Stream")
                } footer: {
                    /* A guard rail rather than a target — see maxFps. */
                    Text("Upper bound, not a target. Limits repeated "
                         + "frames on the wire; the hardware captures well "
                         + "below it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Compress", isOn: $model.compress)
                    Toggle("Predictive", isOn: $model.predictive)
                    Toggle("Interlace", isOn: $model.interlace)
                } header: {
                    Text("Encoding")
                } footer: {
                    Text("Sent with every request; the requesting side "
                         + "decides. \(drivenMachinePossessive) own panel "
                         + "governs only captures it starts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            /* Locked while bytes are in flight for the same reason the old
               inline row was: these travel WITH a request, and changing one
               mid-transfer would describe a transfer that is not happening. */
            .disabled(model.isCapturing || model.isStreaming)

            Divider()
            HStack {
                if model.isCapturing || model.isStreaming {
                    Label("Locked while a transfer is running",
                          systemImage: "lock")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                Spacer()
                Button("Done") { showingSettings = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 460, height: 480)
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

    // MARK: - The output row

    /// What becomes of the picture: the depth it arrives at, whether it is
    /// kept and copied, and where it is kept.
    ///
    /// **Present and live before the first capture**, unchanged. Every
    /// control here governs the NEXT capture rather than describing the last
    /// one — depth is sent with the request, the two toggles decide what
    /// happens when bytes land, and the folder is already the landing pad for
    /// screenshots the driven machine pushes unasked, which arrive whether
    /// this page has ever taken one or not. There is nothing here to grey out
    /// for want of an image; the buttons that DO need one (Save as PNG…, Copy
    /// to Clipboard) are in `actionRow`, above, which is simply absent until
    /// there is a picture for them to act on.
    private var outputRow: some View {
        HStack(spacing: 16) {
            /* Left of the toggles, and out of the settings sheet: depth is
               the knob a person reaches for while LOOKING at a capture —
               "would this read better in colour?" — so it belongs with the
               picture, not behind a modal. */
            Picker("Depth", selection: $model.selectedDepth) {
                ForEach(CaptureDepth.allCases) { depth in
                    Text(depth.title).tag(depth)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(model.isCapturing || model.isStreaming)
            .help("Colour depth sent by "
                  + "\(MachineNaming.sentence(model.connection)). "
                  + "Fewer colours, less to carry.")

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
    ///
    /// The landing pad is not the toggle's: screenshots the driven machine
    /// sends always save to the folder, so the folder is always live. The
    /// toggle only governs captures taken from this panel.
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
        panel.message = "Destination for saved captures."
        if panel.runModal() == .OK, let url = panel.url {
            model.saveDirectory = url
        }
    }

    @ViewBuilder
    private var connectionBadge: some View {
        switch model.connection {
        case .disconnected:
            Label("No \(MachineNaming.properNoun) Connected", systemImage: "circle.fill")
                .foregroundStyle(.secondary)
        case .connecting:
            Label("Connecting", systemImage: "circle.dotted")
                .foregroundStyle(.orange)
        case .connected(let name, _):
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
                Text("Machine").foregroundStyle(.secondary)
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

    /// What can be done with THIS picture. Absent without one — unlike the
    /// output row below, every button here needs an image to act on.
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
            Text("No Captures")
                .font(.title2.weight(.semibold))
            Text(model.connection.canCapture
                 ? "Press Capture to read "
                   + "\(MachineNaming.possessive(model.connection)) screen "
                   + "across the wire."
                 : "Not connected. "
                   + "\(MachineNaming.startingSentence(MachineNaming.simpleReference)) "
                   + "connects to \(MachineNaming.thisMac).")
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
