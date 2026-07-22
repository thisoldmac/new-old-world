import SwiftUI

/// This Mac's own event log, surfaced the way the guest's Logs page is: a
/// monospaced scrollback that follows the tail, an Invert switch for a dark
/// canvas, and a switch for whether the lines also reach the disk.
struct LogsModuleView: View {
    @ObservedObject var model: LogsModel
    @ObservedObject var log: HostLog

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(28)
            Divider()
            scrollback
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Logs")
                    .font(.largeTitle.weight(.semibold))
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            switches
        }
    }

    private var subtitle: String {
        if model.persistsToDisk, let path = log.url?.path {
            return "This Mac's event log — saving to \(path)"
        }
        return "This Mac's event log — in memory only, not written to disk"
    }

    private var switches: some View {
        HStack(spacing: 16) {
            Toggle("Invert", isOn: Binding(
                get: { model.invert },
                set: { model.setInvert($0) }))
            Toggle("Log to disk", isOn: Binding(
                get: { model.persistsToDisk },
                set: { model.setPersistsToDisk($0) }))
        }
        .toggleStyle(.checkbox)
    }

    private var scrollback: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(log.lines) { line in
                        Text(line.text)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(inkColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id(line.id)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(canvasColor)
            .onChange(of: log.lines) { _ in
                if let last = log.lines.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    /// The canvas flips fully when inverted — white ink on black — and
    /// otherwise sits on the theme's text background, primary ink.
    private var canvasColor: Color {
        model.invert ? .black : Color(nsColor: .textBackgroundColor)
    }

    private var inkColor: Color {
        model.invert ? .white : .primary
    }
}
