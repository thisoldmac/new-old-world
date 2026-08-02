import SwiftUI

/// The Mirror page: what the connected Mac is missing, whether Mirror can
/// reach it, and the one instance this page starts and stops.
///
/// It draws no mirror — everything a person sees of Mirror is Mirror's own
/// window, opened by Mirror's own binary. What it draws is the readiness
/// of the machine on the other end, which is the question that was
/// unanswerable before and is the whole reason a launch used to fail
/// without a reason.
struct MirrorControlView: View {
    @ObservedObject var model: MirrorControlModel
    @State private var showsDiagnostics = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    statusCard
                    lifecycleCard
                    configCard
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        }
        .onAppear { model.check() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Mirror").font(.headline)
                Spacer()
                if model.isChecking { ProgressView().controlSize(.small) }
                Button("Check Again") { model.check() }
                    .disabled(model.isChecking)
            }
            Text("Mirror is a separate application that draws this Mac's "
                 + "live interface from structure rather than pixels. This "
                 + "page runs one Mirror against the machine you are "
                 + "connected to, and says whether that machine is ready "
                 + "for it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    // MARK: - Status

    private var statusCard: some View {
        card {
            Text("The machine").font(.headline)

            row(icon: "desktopcomputer",
                title: model.connection.canCapture
                    ? model.connection.peerLabel : "No Mac connected",
                badge: model.connection.canCapture
                    ? Badge("connected", .green) : Badge("none", .gray),
                detail: model.connection.canCapture
                    ? "Mirror would be told to call it "
                      + "\(model.machineLabel)."
                    : "Connect a Mac and this page fills in.")

            Divider()

            ForEach(model.initRows) { initRow in
                row(icon: "puzzlepiece.extension",
                    title: "\(initRow.component.fileName) "
                         + "(\u{2018}\(initRow.component.selector)\u{2019})",
                    badge: badge(for: initRow.state),
                    detail: detail(for: initRow))
            }

            /* The same sentence the Mac's own Mirror page carries
               (now_mirror_ext_note), because the two pages describe the
               same three extensions and a person reading both must not
               have to reconcile them. What differs is the last line, and
               it differs honestly: that page reads Gestalt on the machine
               itself and can say RESIDENT; this one reads the Extensions
               folder across the wire and cannot. */
            Text("An extension is loaded only at startup, and nothing can "
                 + "switch one on or off while the Mac is running. This "
                 + "app reads that Mac's Extensions folder, so it can say "
                 + "what is installed and not what is loaded — the Mirror "
                 + "page on the Mac itself says which.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            row(icon: "bolt.horizontal.circle",
                title: "Mirror agent",
                badge: agentBadge,
                detail: agentDetail)

            row(icon: "point.3.connected.trianglepath.dotted",
                title: model.endpoint.addressText.map { "Agent at \($0)" }
                    ?? "No address",
                badge: reachabilityBadge,
                detail: reachabilityDetail)
        }
    }

    private func detail(for initRow: MirrorInitRow) -> String {
        switch initRow.state {
        case .installed(let version):
            let stamp = version.map { " (version \($0))" } ?? ""
            return "In the Extensions folder\(stamp). "
                 + initRow.component.purpose
        case .disabled:
            return "Present but turned off in Extensions Manager, so it "
                 + "will not load. " + initRow.component.purpose
        case .missing:
            return "Not in the Extensions folder. "
                 + initRow.component.purpose
        case .unknown(let reason):
            return reason
        }
    }

    private func badge(for state: MirrorInitState) -> Badge {
        switch state {
        case .installed: return Badge("installed", .green)
        case .disabled: return Badge("disabled", .orange)
        case .missing: return Badge("missing", .red)
        case .unknown: return Badge("not checked", .gray)
        }
    }

    private var agentBadge: Badge {
        switch model.agent {
        case .running: return Badge("running", .green)
        case .notRunning: return Badge("not running", .orange)
        case .untried: return Badge("not checked", .gray)
        case .unknown: return Badge("unknown", .gray)
        }
    }

    private var agentDetail: String {
        switch model.agent {
        case .running:
            return "\(MirrorControlModel.agentProcessName) is in that Mac's "
                 + "process list."
        case .notRunning:
            return "\(MirrorControlModel.agentProcessName) is not running on "
                 + "that Mac. Mirror talks to it, not to this app's "
                 + "connection, so it has to be started there."
        case .untried:
            return "Nothing asked yet."
        case .unknown(let reason):
            return reason
        }
    }

    private var reachabilityBadge: Badge {
        switch model.reachability {
        case .reachable: return Badge("reachable", .green)
        case .refused: return Badge("no answer", .red)
        case .checking: return Badge("checking", .gray)
        case .paused: return Badge("in use", .blue)
        case .untried: return Badge("not checked", .gray)
        }
    }

    private var reachabilityDetail: String {
        switch model.reachability {
        case .reachable: return model.endpoint.route
        case .refused(let reason):
            return "\(reason). " + model.endpoint.route
        case .checking: return "Trying the connection…"
        case .paused(let reason): return reason
        case .untried: return model.endpoint.route
        }
    }

    // MARK: - Lifecycle

    private var lifecycleCard: some View {
        card {
            HStack(alignment: .firstTextBaseline) {
                Text("Mirror").font(.headline)
                Spacer()
                if model.run.isLive {
                    Button("Quit") { model.quit() }
                } else {
                    Button("Launch") { model.launch() }
                        .disabled(!model.canLaunch)
                        .keyboardShortcut(.defaultAction)
                }
            }

            HStack(spacing: 8) {
                if model.run == .building || model.run == .launching {
                    ProgressView().controlSize(.small)
                }
                Text(runTitle).font(.callout.weight(.medium))
                runBadge
            }

            if let detail = runDetail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let refusal = model.refusal, !model.run.isLive {
                Text(refusal.message)
                    .font(.callout)
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.diagnostics.isEmpty {
                DisclosureGroup("Output from Mirror",
                                isExpanded: $showsDiagnostics) {
                    ScrollView {
                        Text(model.diagnostics.joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 100, maxHeight: 220)
                }
                .font(.callout)
            }
        }
    }

    private var runTitle: String {
        switch model.run {
        case .notRunning: return "Not running"
        case .building: return "Building Mirror"
        case .launching: return "Starting"
        case .running: return "Running"
        case .exited(let status, _):
            return status == 0 ? "Closed" : "Stopped"
        case .failed: return "Did not start"
        }
    }

    @ViewBuilder
    private var runBadge: some View {
        switch model.run {
        case .running(let pid):
            badgeView(Badge("pid \(pid)", .green))
        case .exited(let status, _) where status != 0:
            badgeView(Badge("exit \(status)", .orange))
        case .failed:
            badgeView(Badge("failed", .red))
        default:
            EmptyView()
        }
    }

    private var runDetail: String? {
        switch model.run {
        case .notRunning:
            guard model.refusal == nil else { return nil }
            return "Launch opens Mirror's own window against "
                 + (model.endpoint.addressText ?? "that Mac") + "."
        case .building:
            return "Building from source, because the toggle below is on."
        case .launching:
            return "Waiting for Mirror to come up."
        case .running:
            return "Mirror's window is Mirror's own. Quit asks it to close; "
                 + "it is only forced if it will not."
        case .exited(let status, _):
            return status == 0
                ? "Mirror closed on its own."
                : "Mirror stopped with status \(status). Its own last words "
                  + "are in the output below."
        case .failed(let reason):
            return reason
        }
    }

    // MARK: - Config

    private var configCard: some View {
        card {
            Text("Settings").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Mirror agent port (emulated Macs)")
                    .font(.callout.weight(.medium))
                HStack {
                    TextField("", value: Binding(
                        get: { model.forwardedAgentPort },
                        set: { model.forwardedAgentPort = $0 }),
                              format: .number.grouping(.never))
                        .frame(width: 90)
                    Spacer()
                }
                Text("An emulated Mac cannot be dialled directly, so Mirror "
                     + "goes through the forward the emulator was started "
                     + "with. A Mac on the network ignores this and is "
                     + "dialled at \(MirrorEndpoint.agentPortInGuest).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Mirror app").font(.callout.weight(.medium))
                TextField("A built MirrorApp, or leave empty",
                          text: $model.namedAppPath)
                Text(productDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Build from source before launching",
                       isOn: $model.buildFromSource)
                Text(model.checkout == nil
                     ? "For development. Unavailable here — this app is not "
                       + "running from a checkout with Mirror in it."
                     : "For development. Builds Mirror from "
                       + "\(model.checkout!.root.path) first, which takes a "
                       + "while the first time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var productDetail: String {
        switch model.productResolution {
        case .found(let product):
            switch product.origin {
            case .named:
                return "Launching \(product.executable.path)."
            case .checkout:
                return "Launching the build in Mirror's checkout: "
                     + "\(product.executable.path)."
            }
        case .missing(let reason):
            return reason
        }
    }

    // MARK: - Pieces

    private struct Badge {
        let text: String
        let color: Color
        init(_ text: String, _ color: Color) {
            self.text = text
            self.color = color
        }
    }

    private func badgeView(_ badge: Badge) -> some View {
        Text(badge.text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(badge.color.opacity(0.15))
            .foregroundStyle(badge.color)
            .clipShape(Capsule())
    }

    private func row(icon: String, title: String, badge: Badge,
                     detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title).font(.body.weight(.medium))
                    badgeView(badge)
                }
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func card<Content: View>(
        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.06)))
    }
}
