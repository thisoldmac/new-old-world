import SwiftUI

struct ScreenshotsModuleView: View {
    @ObservedObject var model: ScreenshotModuleModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            Divider()
            if model.history.isEmpty {
                emptyState
            } else {
                history
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
                    Text("Capture and keep what is happening on your classic Mac.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                connectionBadge
            }

            HStack(spacing: 12) {
                Button("Capture Guest") { }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canCapture)

                Picker("Depth", selection: $model.selectedDepth) {
                    ForEach(CaptureDepth.allCases) { depth in
                        Text(depth.title).tag(depth)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 150)
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

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("No Screenshots Yet")
                .font(.title2.weight(.semibold))
            Text("The guest app can already capture itself. Host transport is the next module boundary, so this button stays disabled until a Mac is genuinely connected.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var history: some View {
        List(model.history) { record in
            HStack {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    Text(record.capturedAt, format: .dateTime)
                    Text("\(record.width) × \(record.height) · \(record.depth.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.inset)
    }
}
