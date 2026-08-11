import CryptoKit
import Foundation
import zlib

/// A deliberately small writer for the stable loose-object/ref portion of Git.
/// It ships no command runner, reads no user configuration, and exposes no Git
/// vocabulary above the history adapter. System Git is only a test oracle.
struct LooseGitRepository {
    private struct TreeEntry {
        let mode: String
        let name: String
        let object: String
    }

    private struct ClassicArchive: Encodable {
        let schema = "ckproject.git-classic-archive/1"
        let files: [ClassicArchiveEntry]
    }

    private struct ClassicArchiveEntry: Encodable {
        let path: String
        let package: String
        let type: String
        let creator: String
        let finderFlags: UInt16
        let dataDigest: String
        let resourceDigest: String
    }

    let url: URL
    private let fileManager: FileManager

    init(url: URL, fileManager: FileManager = .default) throws {
        self.url = url
        self.fileManager = fileManager
        try fileManager.createDirectory(at: url.appendingPathComponent("objects"),
                                        withIntermediateDirectories: true)
        try fileManager.createDirectory(at: url.appendingPathComponent("refs/heads"),
                                        withIntermediateDirectories: true)
        try Data("ref: refs/heads/main\n".utf8)
            .write(to: url.appendingPathComponent("HEAD"), options: .atomic)
        if !fileManager.fileExists(atPath: url.appendingPathComponent("config").path) {
            try Data("[core]\n\trepositoryformatversion = 0\n\tbare = true\n".utf8)
                .write(to: url.appendingPathComponent("config"), options: .atomic)
        }
    }

    func commit(tree working: URL, parent: String?, message: String,
                date: Date = Date()) throws -> String {
        let treeID = try writeTree(working, includeClassicArchive: true)
        let stamp = Int(date.timeIntervalSince1970)
        let safeMessage = message.replacingOccurrences(of: "\n", with: " ")
        var text = "tree \(treeID)\n"
        if let parent { text += "parent \(parent)\n" }
        text += "author New Old World <now@localhost> \(stamp) +0000\n"
        text += "committer New Old World <now@localhost> \(stamp) +0000\n\n"
        text += safeMessage + "\n"
        return try writeObject(type: "commit", contents: Data(text.utf8))
    }

    func update(branch: String, to commit: String) throws {
        guard !branch.isEmpty,
              branch.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw ProjectStoreError.invalidProject("Invalid internal history branch.")
        }
        let ref = url.appendingPathComponent("refs/heads")
            .appendingPathComponent(branch)
        try fileManager.createDirectory(at: ref.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        try Data((commit + "\n").utf8).write(to: ref, options: .atomic)
    }

    private func writeTree(_ directory: URL,
                           includeClassicArchive: Bool = false) throws -> String {
        let children = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey,
                                          .isSymbolicLinkKey],
            options: [])
            .sorted { $0.lastPathComponent.utf8.lexicographicallyPrecedes(
                $1.lastPathComponent.utf8) }
        var entries: [TreeEntry] = []
        for child in children {
            if child.lastPathComponent.hasPrefix(".") { continue }
            let values = try child.resourceValues(forKeys: [.isDirectoryKey,
                                                             .isRegularFileKey,
                                                             .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                throw ProjectStoreError.linkEscape(child.lastPathComponent)
            }
            let mode: String
            let object: String
            if values.isDirectory == true {
                mode = "40000"
                object = try writeTree(child)
            } else if values.isRegularFile == true {
                mode = "100644"
                object = try writeObject(type: "blob",
                                         contents: Data(contentsOf: child))
            } else {
                continue
            }
            entries.append(.init(mode: mode, name: child.lastPathComponent,
                                 object: object))
        }
        if includeClassicArchive {
            entries.append(.init(mode: "40000", name: ".now-classic",
                                 object: try writeClassicArchive(for: directory)))
        }
        return try writeTreeObject(entries)
    }

    /// Git only knows data-fork bytes. Keep a complete MacBinary copy of each
    /// logical project file in a reserved tree so a commit is still a
    /// recoverable classic source revision, including an empty resource fork
    /// and Finder identity. The normal paths remain ordinary Git blobs for
    /// agents and human tools.
    private func writeClassicArchive(for root: URL) throws -> String {
        let document = try CKProjectDocument.parse(Data(contentsOf:
            root.appendingPathComponent("Project.ckp")))
        guard let walk = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []) else {
            throw ProjectStoreError.unavailable(
                "The classic source archive cannot be enumerated.")
        }
        var archiveEntries: [ClassicArchiveEntry] = []
        var packageEntries: [TreeEntry] = []
        for case let file as URL in walk {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey,
                                                            .isSymbolicLinkKey])
            let path = file.pathComponents.suffix(walk.level).joined(separator: "/")
            if path.split(separator: "/").contains(where: {
                $0.hasPrefix(".")
            }) {
                if values.isRegularFile != true { walk.skipDescendants() }
                continue
            }
            if path == "Build" || path.hasPrefix("Build/") {
                if values.isRegularFile != true { walk.skipDescendants() }
                continue
            }
            if values.isSymbolicLink == true {
                throw ProjectStoreError.linkEscape(path)
            }
            guard values.isRegularFile == true else { continue }
            let identity: ClassicProjectFile.Identity
            if path == "Project.ckp" {
                identity = .init(type: "TEXT", creator: "NOWD", finderFlags: 0)
            } else if let declared = document.fileIdentities[path] {
                identity = .init(type: declared.type, creator: declared.creator,
                                 finderFlags: declared.finderFlags)
            } else if let actual = ClassicProjectFile.identity(at: file) {
                identity = actual
            } else {
                identity = .init(type: "????", creator: "????", finderFlags: 0)
            }
            let dataFork = try Data(contentsOf: file)
            let resourceFork = try ClassicProjectFile.resourceFork(at: file)
            guard let package = MacBinaryEncoder.data(
                name: file.lastPathComponent, type: identity.type,
                creator: identity.creator, finderFlags: identity.finderFlags,
                dataFork: dataFork, resourceFork: resourceFork) else {
                throw ProjectStoreError.invalidProject(
                    "The classic file \(path) cannot be represented as MacBinary.")
            }
            let packageName = ProjectDigest.sha256(Data(path.utf8)) + ".bin"
            packageEntries.append(.init(
                mode: "100644", name: packageName,
                object: try writeObject(type: "blob", contents: package)))
            archiveEntries.append(.init(
                path: path, package: "files/\(packageName)",
                type: identity.type, creator: identity.creator,
                finderFlags: identity.finderFlags,
                dataDigest: ProjectDigest.sha256(dataFork),
                resourceDigest: ProjectDigest.sha256(resourceFork)))
        }
        let packages = try writeTreeObject(packageEntries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let index = try encoder.encode(ClassicArchive(
            files: archiveEntries.sorted { $0.path < $1.path }))
        let indexObject = try writeObject(type: "blob", contents: index)
        return try writeTreeObject([
            .init(mode: "40000", name: "files", object: packages),
            .init(mode: "100644", name: "index.json", object: indexObject),
        ])
    }

    private func writeTreeObject(_ entries: [TreeEntry]) throws -> String {
        var body = Data()
        for entry in entries.sorted(by: { $0.name.utf8.lexicographicallyPrecedes(
            $1.name.utf8) }) {
            body.append(Data("\(entry.mode) \(entry.name)".utf8))
            body.append(0)
            body.append(try rawObjectID(entry.object))
        }
        return try writeObject(type: "tree", contents: body)
    }

    private func writeObject(type: String, contents: Data) throws -> String {
        var object = Data("\(type) \(contents.count)\0".utf8)
        object.append(contents)
        let id = Insecure.SHA1.hash(data: object)
            .map { String(format: "%02x", $0) }.joined()
        let objectURL = url.appendingPathComponent("objects")
            .appendingPathComponent(String(id.prefix(2)))
            .appendingPathComponent(String(id.dropFirst(2)))
        if !fileManager.fileExists(atPath: objectURL.path) {
            try fileManager.createDirectory(at: objectURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            try zlib(object).write(to: objectURL, options: .atomic)
        }
        return id
    }

    private func rawObjectID(_ hex: String) throws -> Data {
        guard hex.count == 40 else {
            throw ProjectStoreError.invalidProject("Invalid internal object identity.")
        }
        var result = Data(capacity: 20)
        var index = hex.startIndex
        for _ in 0..<20 {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                throw ProjectStoreError.invalidProject("Invalid internal object identity.")
            }
            result.append(byte)
            index = next
        }
        return result
    }

    private func zlib(_ source: Data) throws -> Data {
        var destinationLength = compressBound(uLong(source.count))
        var destination = Data(count: Int(destinationLength))
        let status = source.withUnsafeBytes { sourceBytes in
            destination.withUnsafeMutableBytes { destinationBytes in
                compress2(
                    destinationBytes.bindMemory(to: UInt8.self).baseAddress!,
                    &destinationLength,
                    sourceBytes.bindMemory(to: UInt8.self).baseAddress!,
                    uLong(source.count), Z_BEST_SPEED)
            }
        }
        guard status == Z_OK else {
            throw ProjectStoreError.unavailable("Git object compression failed.")
        }
        destination.count = Int(destinationLength)
        return destination
    }
}
