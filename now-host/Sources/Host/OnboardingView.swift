import AppKit
import SwiftUI

struct OnboardingSheet: View {
    @ObservedObject var portal: OnboardingPortal
    let wirePort: UInt16
    @Environment(\.dismiss) private var dismiss
    @State private var folderProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Set Up a New Mac")
                        .font(.title2.weight(.semibold))
                    Text("A temporary download page for a classic Mac "
                         + "on this LAN.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            statusCard
            packagesCard

            if let folderProblem {
                Text(folderProblem)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Open Packages Folder", action: openPackagesFolder)
                Spacer()
                if portal.endpoint != nil {
                    Button("Stop Onboarding", role: .destructive) {
                        portal.stop()
                    }
                } else {
                    Button("Start Onboarding") {
                        portal.start(wirePort: wirePort)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 610)
        .onAppear { portal.refreshAssets() }
    }

    @ViewBuilder
    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("On the classic Mac")
                .font(.headline)
            switch portal.state {
            case .stopped:
                Text("Start onboarding, then connect the classic Mac to "
                     + "the LAN and open the address shown here.")
                    .foregroundStyle(.secondary)
            case .starting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finding this Mac's LAN address and a free port…")
                }
            case .running(let endpoint):
                Text("Connect your classic Mac to the LAN, open a browser, "
                     + "and navigate to:")
                    .foregroundStyle(.secondary)
                HStack {
                    Text(endpoint.pageURL?.absoluteString ?? "")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button("Copy") { copy(endpoint.pageURL?.absoluteString) }
                    Button("Open") {
                        if let url = endpoint.pageURL {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                Text("The downloaded settings point NOW back to "
                     + "\(endpoint.host):\(endpoint.wirePort). The web "
                     + "page's \(endpoint.httpPort) port is temporary.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
        .cardStyle()
    }

    private var packagesCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Packages")
                    .font(.headline)
                Spacer()
                Button("Refresh") { portal.refreshAssets() }
                    .controlSize(.small)
            }
            packageLine("New Old World",
                        asset: portal.assets.application,
                        required: true)
            packageLine("NOW Extension",
                        asset: portal.assets.extensionComponent,
                        required: false)
            Divider()
            Text("Dependencies")
                .font(.subheadline.weight(.semibold))
            ForEach(OnboardingDependencyCatalog.all) { dependency in
                dependencyLine(dependency)
            }
            ForEach(OnboardingDependencyCatalog.additionalAssets(
                in: portal.assets)) { asset in
                packageLine(asset.fileName, asset: asset, required: false)
            }
            Text("Release packages can be placed in the app's "
                 + "Contents/Resources/Onboarding folder before signing. "
                 + "Local or licensed packages belong in the Application "
                 + "Support folder opened below. Get downloads are checksum-"
                 + "verified and saved directly in its Dependencies folder.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .cardStyle()
    }

    private func packageLine(_ title: String, asset: OnboardingAsset?,
                             required: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: asset == nil
                  ? "circle" : "checkmark.circle.fill")
                .foregroundStyle(asset == nil
                                 ? Color.secondary : Color.green)
            Text(title)
            if !required {
                Text("Optional")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let asset {
                Text(ByteCountFormatter.string(
                    fromByteCount: asset.byteCount,
                    countStyle: .file))
                    .foregroundStyle(.secondary)
            } else {
                Text(required ? "Missing" : "Not installed")
                    .foregroundStyle(required ? .red : .secondary)
            }
        }
    }

    private func dependencyLine(_ dependency: OnboardingDependency)
        -> some View {
        let asset = dependency.installedAsset(in: portal.assets)
        let state = portal.dependencyAcquisitions[dependency.id]
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: asset == nil
                      ? "circle" : "checkmark.circle.fill")
                    .foregroundStyle(asset == nil
                                     ? Color.secondary : Color.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(dependency.displayName)
                    Text(dependency.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let asset {
                    Text(ByteCountFormatter.string(
                        fromByteCount: asset.byteCount,
                        countStyle: .file))
                        .foregroundStyle(.secondary)
                } else if state == .downloading {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Source…") {
                        NSWorkspace.shared.open(dependency.sourcePageURL)
                    }
                    .controlSize(.small)
                    Button("Get…") { portal.acquire(dependency) }
                        .controlSize(.small)
                }
            }
            if case .failed(let message) = state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, 27)
            }
        }
    }

    private func copy(_ value: String?) {
        guard let value else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func openPackagesFolder() {
        do {
            folderProblem = nil
            let url = try portal.preparePackagesFolder()
            NSWorkspace.shared.open(url)
        } catch {
            folderProblem = "Could not open the packages folder: "
                + error.localizedDescription
        }
    }
}

private extension View {
    func cardStyle() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10,
                                         style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
    }
}
