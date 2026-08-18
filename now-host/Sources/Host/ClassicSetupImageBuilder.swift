import Foundation

struct ClassicSetupImageBuilder: Sendable {
    private static func instructions(host: String, port: UInt16,
                                     flavor: OnboardingGuestFlavor)
        -> String {
        switch flavor {
        case .powerpc:
            return """
            NEW OLD WORLD SETUP\r
            \r
            1. Copy New Old World anywhere on your hard disk.\r
            2. Put New Old World Prefs in System Folder:Preferences.\r
            3. Open New Old World. It will connect to \(host):\(port).\r
            \r
            OPTIONAL\r
            CodeKitten is a standalone IDE; copy it wherever you keep applications.\r
            Put NOW Extension in System Folder:Extensions and restart.\r
            Dependencies downloaded by the host are in the Dependencies folder.\r
            Run the CarbonLib installer if CarbonLib 1.6 is not installed.\r
            """
        case .m68k:
            // NOW-68K remembers nothing between launches on purpose, so
            // the address is written here for the human to type.
            return """
            NOW-68K SETUP\r
            \r
            1. Copy NOW-68K anywhere on your hard disk.\r
            2. Open NOW-68K. Type \(host) into Host and \(port) into Port.\r
            \r
            OPTIONAL\r
            Put NOW Extension in System Folder:Extensions and restart.\r
            """
        }
    }

    enum BuildError: LocalizedError {
        case missingApplication
        case packageTooLarge
        case commandFailed(String)
        case missingDevice
        case couldNotEncode
        case invalidStarterPack(String)

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
                return "The setup image could not be wrapped for " + MachineNaming.simpleReference + "."
            case .invalidStarterPack(let reason):
                return "The Development starter pack was refused: \(reason)"
            }
        }
    }

    static let downloadFileName = "New Old World Setup.img.bin"
    static let classicImageName = "New Old World Setup.img"
    static let volumeName = "NOW Setup"

    static func classicImageName(for flavor: OnboardingGuestFlavor)
        -> String {
        switch flavor {
        case .powerpc: return "New Old World Setup.img"
        case .m68k: return "NOW-68K Setup.img"
        }
    }

    static func downloadFileName(for flavor: OnboardingGuestFlavor)
        -> String {
        classicImageName(for: flavor) + ".bin"
    }
    static let maximumImageBytes = 128 * 1_024 * 1_024

    private var fileManager: FileManager { .default }

    func build(host: String, wirePort: UInt16,
               assets: OnboardingAssetSnapshot,
               flavor: OnboardingGuestFlavor = .powerpc)
        async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try buildSynchronously(host: host, wirePort: wirePort,
                                   assets: assets, flavor: flavor)
        }.value
    }

    private func buildSynchronously(host: String, wirePort: UInt16,
                                    assets: OnboardingAssetSnapshot,
                                    flavor: OnboardingGuestFlavor)
        throws -> Data {
        guard assets.application(for: flavor) != nil else {
            throw BuildError.missingApplication
        }
        try DevelopmentStarterPackManifest.validate(in: assets)
        let selectedDependencies = OnboardingDependencyCatalog.setupAssets(
            in: assets)

        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("NOW-Setup-\(UUID().uuidString)",
                                    isDirectory: true)
        try fileManager.createDirectory(
            at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }
        let contents = workspace.appendingPathComponent(
            "contents", isDirectory: true)
        try fileManager.createDirectory(
            at: contents, withIntermediateDirectories: true)
        try populate(destination: contents, host: host, wirePort: wirePort,
                     assets: assets, flavor: flavor,
                     dependencies: selectedDependencies)

        let rawImage = workspace.appendingPathComponent(
            "setup.raw", isDirectory: false)
        try buildFittedHFSVolume(from: contents, at: rawImage,
                                 in: workspace)

        let disk = try Data(contentsOf: rawImage, options: [.mappedIfSafe])
        guard let image = NDIFImage.macBinary(
            name: Self.classicImageName(for: flavor),
            volumeName: Self.volumeName,
            disk: disk) else { throw BuildError.couldNotEncode }
        return image
    }

    private func populate(destination: URL, host: String, wirePort: UInt16,
                          assets: OnboardingAssetSnapshot,
                          flavor: OnboardingGuestFlavor,
                          dependencies selectedDependencies:
                            [OnboardingAsset]) throws {
        guard let application = assets.application(for: flavor) else {
            throw BuildError.missingApplication
        }
        switch flavor {
        case .powerpc:
            try writeMacBinary(application.fileURL, to: destination)
            if let codeKitten = assets.codeKitten {
                try writeMacBinary(codeKitten.fileURL, to: destination,
                                   nameOverride: "CodeKitten")
            }
            guard let preferences = OnboardingPreferences.macBinary(
                host: host, port: wirePort) else {
                throw BuildError.couldNotEncode
            }
            _ = try MacBinaryFile.decode(preferences).write(to: destination)
            if let extensionComponent = assets.extensionComponent {
                try writeMacBinary(extensionComponent.fileURL,
                                   to: destination,
                                   nameOverride: "NOW Extension")
            }

            let dependencies = destination.appendingPathComponent(
                "Dependencies", isDirectory: true)
            try fileManager.createDirectory(
                at: dependencies, withIntermediateDirectories: true)
            for asset in selectedDependencies {
                try installDependency(
                    asset, in: dependencies,
                    workspace: destination.deletingLastPathComponent())
            }
        case .m68k:
            // The build-tree artifact carries its target name; a deploy
            // stamp carries a version. Either way the disk shows the
            // product's name.
            try writeMacBinary(application.fileURL, to: destination,
                               nameOverride: "NOW-68K")
            if let extensionComponent = assets.extensionComponent {
                try writeMacBinary(extensionComponent.fileURL,
                                   to: destination,
                                   nameOverride: "NOW Extension")
            }
        }

        let readMe = MacBinaryFile(
            name: "Read Me First", type: "TEXT", creator: "ttxt",
            finderFlags: 0,
            dataFork: Self.instructions(host: host, port: wirePort,
                                        flavor: flavor)
                .data(using: .macOSRoman) ?? Data(),
            resourceFork: Data())
        _ = try readMe.write(to: destination)
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

    /* hdiutil create is not used: on current macOS its legacy path fails
       from an application context with a bare "Operation not permitted",
       and its own warning text points at diskutil - whose create knows
       only APFS/ExFAT/MS-DOS. So the volume is made the way the OS still
       fully supports: a raw file, attached as a device, formatted with
       newfs_hfs, mounted, and written through the same fork-preserving
       writer as everything else. The raw file then IS the disk - no
       conversion step and nothing to extract. */
    private func buildFittedHFSVolume(from contents: URL, at rawImage: URL,
                                      in workspace: URL) throws {
        let kibibyte = 1_024
        let allocationBlock = 4 * kibibyte
        let minimumHFSVolume = 512 * kibibyte
        let hfsStructures = 192 * kibibyte
        let growthStep = 32 * kibibyte
        let maximumFreeBytes = 64 * kibibyte
        let allocated = try allocatedBytes(in: contents)
        var capacity = max(minimumHFSVolume,
            roundUp(allocated + hfsStructures, to: allocationBlock))
        var insufficientCapacity = 0

        /* The prepared native files are the measurement. The structure
           estimate avoids a knowingly-too-small first attempt; a copy that
           runs out of blocks is authoritative when the catalog or allocation
           bitmap needs more. After a successful copy, measured HFS free
           blocks tighten the result again so the estimate can never become
           transfer padding. */
        while capacity <= Self.maximumImageBytes {
            try? fileManager.removeItem(at: rawImage)
            try Data(count: capacity).write(to: rawImage)
            let device = try attach(rawImage, mountPoint: nil)
            do {
                let raw = "/dev/r" + URL(fileURLWithPath: device)
                    .lastPathComponent
                try run("/sbin/newfs_hfs",
                        ["-v", Self.volumeName, raw])
                let mountPoint = workspace.appendingPathComponent(
                    "volume", isDirectory: true)
                try? fileManager.removeItem(at: mountPoint)
                try fileManager.createDirectory(
                    at: mountPoint, withIntermediateDirectories: true)
                try run("/usr/sbin/diskutil", [
                    "mount", "-mountPoint", mountPoint.path, device])
                do {
                    try copyTree(of: contents, to: mountPoint)
                } catch {
                    // Any failed write on a fresh volume is treated as the
                    // volume being too small; a genuine fault surfaces as
                    // packageTooLarge with the step ceiling reached.
                    try eject(device)
                    insufficientCapacity = max(insufficientCapacity,
                                               capacity)
                    capacity += growthStep
                    continue
                }
                let attributes = try fileManager.attributesOfFileSystem(
                    forPath: mountPoint.path)
                let free = (attributes[.systemFreeSize] as? NSNumber)?
                    .intValue ?? 0
                try eject(device)
                let fitted = max(insufficientCapacity + growthStep, roundUp(
                    capacity - max(0, free - maximumFreeBytes),
                    to: allocationBlock))
                if fitted < capacity {
                    capacity = fitted
                    continue
                }
                return
            } catch {
                try? eject(device)
                throw error
            }
        }
        throw BuildError.packageTooLarge
    }

    /// FileManager.copyItem carries both forks and Finder info, which is
    /// the whole point of this volume.
    private func copyTree(of source: URL, to destination: URL) throws {
        for entry in try fileManager.contentsOfDirectory(
            at: source, includingPropertiesForKeys: nil,
            options: []) {
            try fileManager.copyItem(
                at: entry,
                to: destination.appendingPathComponent(
                    entry.lastPathComponent))
        }
    }

    private func allocatedBytes(in directory: URL) throws -> Int {
        let output = try run("/usr/bin/du", ["-sk", directory.path])
        guard let text = String(data: output, encoding: .utf8),
              let field = text.split(whereSeparator: { $0.isWhitespace }).first,
              let kibibytes = Int(field) else {
            throw BuildError.commandFailed(
                "macOS could not measure the prepared setup files.")
        }
        return kibibytes * 1_024
    }

    private func roundUp(_ value: Int, to multiple: Int) -> Int {
        (value + multiple - 1) / multiple * multiple
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

}
