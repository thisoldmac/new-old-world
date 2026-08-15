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
                    Text("A temporary download page for a \(MachineNaming.commonNoun) "
                         + "on this LAN.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            statusCard
            packagesCard
            setupImageCard

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
            Text("On \(MachineNaming.simpleReference)")
                .font(.headline)
            switch portal.state {
            case .stopped:
                Text("Start onboarding, then connect \(MachineNaming.simpleReference) to "
                     + "the LAN and open the address shown here.")
                    .foregroundStyle(.secondary)
            case .starting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finding this Mac's LAN address and a free port…")
                }
            case .running(let endpoint):
                Text("Connect your \(MachineNaming.commonNoun) to the LAN, open a browser, "
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
            packageLine("CodeKitten",
                        asset: portal.assets.codeKitten,
                        required: false)
            packageLine("NOW Extension",
                        asset: portal.assets.extensionComponent,
                        required: false)
            Divider()
            Text("System dependencies")
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
            selectionControl(asset, required: required)
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
                selectionControl(asset, required: false)
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

    @ViewBuilder
    private func selectionControl(_ asset: OnboardingAsset?, required: Bool)
        -> some View {
        if let asset {
            Toggle("", isOn: Binding(
                get: { portal.isSelected(asset) },
                set: { portal.setSelected($0, asset: asset) }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(required)
                .help(required
                      ? "New Old World is required in every install image."
                      : "Include this item in the next install image.")
        } else {
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
                .frame(width: 16)
        }
    }

    private var setupImageCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Install Image")
                    .font(.headline)
                Spacer()
                Button(setupImageButtonTitle, action: rebuildSetupImage)
                    .controlSize(.small)
                    .disabled(portal.endpoint == nil || isBuildingSetupImage)
            }
            switch portal.setupImageState {
            case .notBuilt:
                Text("Start onboarding to build the HFS install image served "
                     + "at /now/setup.img.")
                    .foregroundStyle(.secondary)
            case .building:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Building the fork-preserving HFS image…")
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            case .ready(let image):
                imageDetails(image)
            }
        }
        .cardStyle()
    }

    private var setupImageButtonTitle: String {
        portal.currentSetupImage() == nil
            ? "Build Install Image" : "Rebuild Install Image"
    }

    private var isBuildingSetupImage: Bool {
        if case .building = portal.setupImageState { return true }
        return false
    }

    private func imageDetails(_ image: OnboardingSetupImage) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if portal.hasPendingSetupImageChanges {
                Label("Package selections changed; rebuild to update the "
                      + "served image.", systemImage: "arrow.triangle.2.circlepath")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            detailLine("File", image.fileName)
            detailLine("Disk", byteCount(image.diskByteCount))
            detailLine("Download", byteCount(image.transferByteCount)
                       + " MacBinary")
            detailLine("Built", DateFormatter.localizedString(
                from: image.builtAt, dateStyle: .none, timeStyle: .medium))
            detailLine("Contains", image.includedItems.joined(separator: ", "))
            HStack {
                Spacer()
                Button("Save a Copy…", action: saveSetupImage)
                    .controlSize(.small)
            }
        }
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .frame(width: 72, alignment: .trailing)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
        .font(.callout)
    }

    private func byteCount(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
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

    private func rebuildSetupImage() {
        folderProblem = nil
        Task { @MainActor in
            do {
                _ = try await portal.rebuildSetupImage()
            } catch {
                folderProblem = "Could not rebuild the install image: "
                    + error.localizedDescription
            }
        }
    }

    private func saveSetupImage() {
        guard let image = portal.currentSetupImage() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ClassicSetupImageBuilder.downloadFileName
        panel.canCreateDirectories = true
        panel.prompt = "Save"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try image.write(to: url, options: [.atomic])
        } catch {
            folderProblem = "Could not save the install image: "
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
