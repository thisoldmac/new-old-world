import Foundation

struct ClassicSetupImageBuilder: Sendable {
    enum BuildError: LocalizedError {
        case missingApplication
        case packageTooLarge
        case commandFailed(String)
        case missingDevice
        case couldNotEncode

        var errorDescription: String? {
            switch self {
            case .missingApplication:
                return "New Old World is not installed in the packages folder."
            case .packageTooLarge:
                return "The installed packages are too large for one setup image."
            case .commandFailed(let detail):
                return "The setup image could not be created: \(detail)"
            case .missingDevice:
                return "macOS did not return the setup image device."
            case .couldNotEncode:
                return "The setup image could not be wrapped for the classic Mac."
            }
        }
    }

    static let downloadFileName = "New Old World Setup.img.bin"
    static let classicImageName = "New Old World Setup.img"
    static let volumeName = "NOW Setup"
    static let maximumImageBytes = 128 * 1_024 * 1_024

    private var fileManager: FileManager { .default }

    func build(host: String, wirePort: UInt16,
               assets: OnboardingAssetSnapshot) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try buildSynchronously(host: host, wirePort: wirePort,
                                   assets: assets)
        }.value
    }

    private func buildSynchronously(host: String, wirePort: UInt16,
                                    assets: OnboardingAssetSnapshot)
        throws -> Data {
        guard let application = assets.application else {
            throw BuildError.missingApplication
        }
        let selectedDependencies = OnboardingDependencyCatalog.setupAssets(
            in: assets)
        let estimatedContents = [application, assets.extensionComponent]
            .compactMap { $0 }.map(estimatedInstalledBytes).reduce(0, +)
            + selectedDependencies.map(estimatedInstalledBytes).reduce(0, +)
        let capacity = imageCapacity(for: estimatedContents)
        guard capacity <= Self.maximumImageBytes else {
            throw BuildError.packageTooLarge
        }

        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("NOW-Setup-\(UUID().uuidString)",
                                    isDirectory: true)
        try fileManager.createDirectory(
            at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }
        let rawImage = workspace.appendingPathComponent(
            "setup.raw", isDirectory: false)
        let mountPoint = workspace.appendingPathComponent(
            "volume", isDirectory: true)

        try run("/usr/sbin/diskutil", [
            "image", "create", "blank", "--format", "RAW", "--fs", "None",
            "--size", String(capacity), rawImage.path
        ])
        let formatAttachment = try attach(rawImage, mountPoint: nil)
        defer { try? eject(formatAttachment) }
        try run("/sbin/newfs_hfs", [
            "-v", Self.volumeName, "/dev/r\(formatAttachment)"
        ])
        try eject(formatAttachment)

        let mountedDevice = try attach(rawImage, mountPoint: mountPoint)
        do {
            try populate(mountPoint: mountPoint, host: host,
                         wirePort: wirePort, assets: assets,
                         dependencies: selectedDependencies)
            try eject(mountedDevice)
        } catch {
            try? eject(mountedDevice)
            throw error
        }

        let disk = try Data(contentsOf: rawImage, options: [.mappedIfSafe])
        guard let image = NDIFImage.macBinary(
            name: Self.classicImageName, volumeName: Self.volumeName,
            disk: disk) else { throw BuildError.couldNotEncode }
        return image
    }

    private func populate(mountPoint: URL, host: String, wirePort: UInt16,
                          assets: OnboardingAssetSnapshot,
                          dependencies selectedDependencies:
                            [OnboardingAsset]) throws {
        guard let application = assets.application else {
            throw BuildError.missingApplication
        }
        try writeMacBinary(application.fileURL, to: mountPoint)
        guard let preferences = OnboardingPreferences.macBinary(
            host: host, port: wirePort) else {
            throw BuildError.couldNotEncode
        }
        _ = try MacBinaryFile.decode(preferences).write(to: mountPoint)
        if let extensionComponent = assets.extensionComponent {
            try writeMacBinary(extensionComponent.fileURL, to: mountPoint,
                               nameOverride: "NOW Extension")
        }

        let dependencies = mountPoint.appendingPathComponent(
            "Dependencies", isDirectory: true)
        try fileManager.createDirectory(
            at: dependencies, withIntermediateDirectories: true)
        for asset in selectedDependencies {
            try installDependency(asset, in: dependencies,
                                  workspace: mountPoint.deletingLastPathComponent())
        }

        let readMe = MacBinaryFile(
            name: "Read Me First", type: "TEXT", creator: "ttxt",
            finderFlags: 0,
            dataFork: instructions(host: host, port: wirePort)
                .data(using: .macOSRoman) ?? Data(),
            resourceFork: Data())
        _ = try readMe.write(to: mountPoint)
    }

    private func writeMacBinary(_ url: URL, to directory: URL,
                                nameOverride: String? = nil) throws {
        let raw = try Data(contentsOf: url, options: [.mappedIfSafe])
        _ = try MacBinaryFile.decode(raw).write(
            to: directory, nameOverride: nameOverride)
    }

    private func isStuffIt(_ file: MacBinaryFile) -> Bool {
        file.name.lowercased().hasSuffix(".sit")
            || file.type.uppercased().hasPrefix("SIT")
    }

    private func installDependency(_ asset: OnboardingAsset,
                                   in dependencies: URL,
                                   workspace: URL) throws {
        let raw = try Data(contentsOf: asset.fileURL,
                           options: [.mappedIfSafe])
        if let file = try? MacBinaryFile.decode(raw) {
            if isStuffIt(file), let unar = unarURL() {
                let archives = workspace.appendingPathComponent(
                    "archives", isDirectory: true)
                try fileManager.createDirectory(
                    at: archives, withIntermediateDirectories: true)
                let archive = try file.write(to: archives)
                try extract(archive, with: unar, to: dependencies)
            } else {
                _ = try file.write(to: dependencies)
            }
            return
        }

        if asset.fileURL.pathExtension.lowercased() == "sit",
           let unar = unarURL() {
            try extract(asset.fileURL, with: unar, to: dependencies)
        } else {
            try fileManager.copyItem(
                at: asset.fileURL,
                to: dependencies.appendingPathComponent(asset.fileName))
        }
    }

    private func extract(_ archive: URL, with unar: URL,
                         to destination: URL) throws {
        try run(unar.path, ["-f", "-o", destination.path, archive.path])
    }

    private func unarURL() -> URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("unar"),
            URL(fileURLWithPath: "/opt/homebrew/bin/unar"),
            URL(fileURLWithPath: "/usr/local/bin/unar")
        ].compactMap { $0 }
        return candidates.first {
            fileManager.isExecutableFile(atPath: $0.path)
        }
    }

    private func imageCapacity(for packageBytes: Int64) -> Int {
        let minimum = 8 * 1_024 * 1_024
        let desired = Int(min(Int64(Int.max), packageBytes
            + 1 * 1_024 * 1_024))
        let megabyte = 1_024 * 1_024
        return max(minimum, (desired + megabyte - 1) / megabyte * megabyte)
    }

    private func estimatedInstalledBytes(_ asset: OnboardingAsset) -> Int64 {
        guard let raw = try? Data(contentsOf: asset.fileURL,
                                  options: [.mappedIfSafe]),
              let file = try? MacBinaryFile.decode(raw) else {
            return asset.byteCount * 2
        }
        if isStuffIt(file) {
            return Int64(file.dataFork.count) * 3
        }
        return Int64(file.dataFork.count + file.resourceFork.count + 4_096)
    }

    private func attach(_ image: URL, mountPoint: URL?) throws -> String {
        var arguments = ["image", "attach", "--plist", "--nobrowse"]
        if let mountPoint {
            arguments += ["--mountPoint", mountPoint.path]
        } else {
            arguments.append("--noMount")
        }
        arguments.append(image.path)
        let output = try run("/usr/sbin/diskutil", arguments)
        guard let plist = try PropertyListSerialization.propertyList(
            from: output, options: [], format: nil) as? [String: Any],
              let entities = plist["system-entities"]
                as? [[String: Any]],
              let device = entities.compactMap({
                  $0["dev-entry"] as? String
              }).first else { throw BuildError.missingDevice }
        return device
    }

    private func eject(_ device: String) throws {
        _ = try run("/usr/sbin/diskutil", ["eject", device])
    }

    @discardableResult
    private func run(_ executable: String, _ arguments: [String]) throws
        -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw BuildError.commandFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw BuildError.commandFailed(message?.isEmpty == false
                ? message! : executable)
        }
        return stdout
    }

    private func instructions(host: String, port: UInt16) -> String {
        """
        NEW OLD WORLD SETUP\r
        \r
        1. Copy New Old World anywhere on your hard disk.\r
        2. Put New Old World Prefs in System Folder:Preferences.\r
        3. Open New Old World. It will connect to \(host):\(port).\r
        \r
        OPTIONAL\r
        Put NOW Extension in System Folder:Extensions and restart.\r
        Dependencies downloaded by the host are in the Dependencies folder.\r
        CarbonLib belongs in System Folder:Extensions; restart after adding it.\r
        """
    }
}
