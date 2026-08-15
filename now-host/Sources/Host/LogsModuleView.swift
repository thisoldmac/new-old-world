import SwiftUI

/// This Mac's own event log, surfaced the way the guest's Logs page is: a
/// monospaced scrollback that follows the tail and an Invert switch for a
/// dark canvas. Whether the lines also reach disk is a Settings tab now.
struct LogsModuleView: View {
    @ObservedObject var model: LogsModel
    @ObservedObject var log: HostLog
    @ObservedObject var continuity: MirrorContinuityController
    /// Nil in a preview or a test with no Settings window to open.
    var openSettings: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(28)
            ContinuityDiagnosticsView(controller: continuity)
                .padding(.horizontal, 28)
                .padding(.bottom, 18)
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
            return "\(MachineNaming.thisMac)'s event log — saving to \(path)"
        }
        return "\(MachineNaming.thisMac)'s event log — in memory only, "
            + "not written to disk"
    }

    /// "Log to disk" moved to Settings (a disk-writing preference); Invert
    /// stays — it is display state a person wants to see change while
    /// they're looking at the scrollback it repaints.
    private var switches: some View {
        HStack(spacing: 16) {
            Toggle("Invert", isOn: Binding(
                get: { model.invert },
                set: { model.setInvert($0) }))
                .toggleStyle(.checkbox)
            if let openSettings {
                Button("Settings…", action: openSettings)
                    .controlSize(.small)
            }
        }
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

/// Advanced logging controls belong beside the output they produce. This
/// view intentionally receives the app-owned controller rather than reaching
/// through the Mirror module and constructing its scene runtime as a side
/// effect of opening Logs.
private struct ContinuityDiagnosticsView: View {
    @ObservedObject var controller: MirrorContinuityController

    var body: some View {
        DisclosureGroup("Advanced continuity diagnostics") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(ContinuityOptionCatalog.options(in: .diagnostic)) {
                    option in
                    Toggle(option.label, isOn: Binding(
                        get: { controller[keyPath: option.keyPath] },
                        set: { controller[keyPath: option.keyPath] = $0 }))
                        .help(option.detail)
                }
                Text("These settings re-arm an active continuity session. "
                     + "Deep click logging can be high volume and remains "
                     + "off by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 8)
        }
    }
}
