import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ScreenshotsModuleView: View {
    @ObservedObject var model: ScreenshotModuleModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Divider()
            if let shot = model.latest {
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
                Button(model.isCapturing ? "Capturing…" : "Capture Guest") {
                    model.capture()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canCapture)

                Picker("Depth", selection: $model.selectedDepth) {
                    ForEach(CaptureDepth.allCases) { depth in
                        Text(depth.title).tag(depth)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 150)
                .disabled(model.isCapturing)

                if let error = model.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
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
            Button("Copy") { copy(shot) }
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
                 ? "Press Capture Guest to pull the classic Mac's screen "
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

    private func copy(_ shot: ScreenshotRecord) {
        let rep = NSBitmapImageRep(cgImage: shot.image)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }
}
