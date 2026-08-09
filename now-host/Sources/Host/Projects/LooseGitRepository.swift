import CryptoKit
import Foundation
import zlib

/// A deliberately small writer for the stable loose-object/ref portion of Git.
/// It ships no command runner, reads no user configuration, and exposes no Git
/// vocabulary above the history adapter. System Git is only a test oracle.
struct LooseGitRepository {
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
        let treeID = try writeTree(working)
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

    private func writeTree(_ directory: URL) throws -> String {
        let children = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey,
                                          .isSymbolicLinkKey],
            options: [.skipsHiddenFiles])
            .sorted { $0.lastPathComponent.utf8.lexicographicallyPrecedes(
                $1.lastPathComponent.utf8) }
        var body = Data()
        for child in children {
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
            body.append(Data("\(mode) \(child.lastPathComponent)".utf8))
            body.append(0)
            body.append(try rawObjectID(object))
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
