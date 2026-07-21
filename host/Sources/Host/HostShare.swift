import AppKit
import Foundation

/// The folder this Mac shares with the classic one.
///
/// Symmetric with the guest's share root and bounded the same way: it is
/// what the other machine may reach on its own initiative — list, pull,
/// write into — and never a limit on what a human here deliberately
/// sends. Paths on the wire are relative to it, so anything outside is
/// not expressible rather than filtered.
@MainActor
final class HostShare {
    /// Wire paths use ":" between components, because that is what the
    /// other machine's file system uses and one side has to choose.
    static let separator = ":"

    private let defaults: UserDefaults
    private static let key = "files.hostShareDirectory"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var root: URL {
        get {
            if let stored = defaults.string(forKey: Self.key) {
                return URL(fileURLWithPath: stored)
            }
            return FileManager.default.urls(for: .downloadsDirectory,
                                            in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
        }
        set { defaults.set(newValue.path, forKey: Self.key) }
    }

    enum ShareError: Error {
        case badPath, notFound, notADirectory, exists, io(String)

        var code: String {
            switch self {
            case .badPath: return "bad-path"
            case .notFound: return "not-found"
            case .notADirectory: return "bad-path"
            case .exists: return "exists"
            case .io: return "io-error"
            }
        }

        var message: String {
            switch self {
            case .badPath: return "that path is not inside the shared folder"
            case .notFound: return "no such item in the shared folder"
            case .notADirectory: return "that is not a folder"
            case .exists: return "a file of that name is already there"
            case .io(let why): return why
            }
        }
    }

    /// Resolves a wire path against the share. Rejects anything that
    /// climbs out — the guest's own resolver makes traversal
    /// inexpressible by construction; here the path arrives as text, so
    /// it has to be checked.
    func resolve(_ path: String) throws -> URL {
        var url = root.standardizedFileURL
        guard !path.isEmpty else { return url }
        for component in path.components(separatedBy: Self.separator) {
            /* A segment is one component. A "/" inside one is this
               file system's separator arriving through the other one's,
               which is how a path outside the share gets spelled. */
            guard !component.isEmpty, component != ".", component != "..",
                  !component.contains("/") else {
                throw ShareError.badPath
            }
            url.appendPathComponent(component)
        }
        /* Compare what the path actually reaches, not what it says: a
           symlink inside the share can name anything on this disk, and
           the guest cannot see that it did. */
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard resolved.path == base
            || resolved.path.hasPrefix(base + "/") else {
            throw ShareError.badPath
        }
        return url.standardizedFileURL
    }

    /// One page of a folder, in the shape file.listing carries. Hidden
    /// files are left out: the other machine has no use for them and
    /// they are noise in a browser that small.
    func list(path: String, cursor: Int, limit: Int)
        throws -> (entries: [FileEntry], more: Bool, next: Int) {
        let url = try resolve(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path,
                                             isDirectory: &isDirectory)
        else { throw ShareError.notFound }
        guard isDirectory.boolValue else { throw ShareError.notADirectory }

        let contents = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey,
                                         .contentModificationDateKey],
            options: [.skipsHiddenFiles])
            .sorted { $0.lastPathComponent.localizedStandardCompare(
                $1.lastPathComponent) == .orderedAscending }

        let start = max(0, cursor - 1)
        let end = min(start + limit, contents.count)
        guard start < contents.count else {
            return ([], false, contents.count + 1)
        }
        let entries = contents[start..<end].map { entry -> FileEntry in
            let values = try? entry.resourceValues(
                forKeys: [.isDirectoryKey, .fileSizeKey,
                          .contentModificationDateKey])
            let isDir = values?.isDirectory ?? false
            // The classic side names files in 31 MacRoman characters;
            // send what it can actually hold rather than a name it will
            // have to mangle on arrival.
            let (type, creator) = isDir ? (nil, nil)
                : OutboundFile.classicType(for: entry.lastPathComponent)
            return FileEntry(
                name: OutboundFile.hfsName(entry.lastPathComponent),
                kind: isDir ? "folder" : "file",
                fileType: type, creator: creator,
                dataBytes: isDir ? nil : (values?.fileSize ?? 0),
                rsrcBytes: isDir ? nil : 0,
                modified: values?.contentModificationDate
                    .flatMap(ClassicDate.macSeconds(from:)))
        }
        return (Array(entries), end < contents.count, end + 1)
    }

    /// Reads a file for the other machine, converted the way a download
    /// is: this is the same journey, in the same direction, started from
    /// the other end.
    func read(path: String, convertText: Bool) throws -> OutboundFile.Plan {
        let url = try resolve(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path,
                                             isDirectory: &isDirectory)
        else { throw ShareError.notFound }
        guard !isDirectory.boolValue else { throw ShareError.notADirectory }
        guard let data = try? Data(contentsOf: url) else {
            throw ShareError.io("could not read that file")
        }
        return OutboundFile.plan(url: url, data: data,
                                 convertText: convertText)
    }

    /// Where an incoming file should be written. The name arrives in
    /// MacRoman from a machine that allows characters this one uses for
    /// paths, so it is decoded and made safe before it touches disk.
    func destination(name: String, path: String,
                     overwrite: Bool) throws -> URL {
        let folder = try resolve(path)
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: folder.path,
                                           isDirectory: &isDirectory) {
            try? FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true)
        }
        /* The name arrives from the other machine, where "/" is an
           ordinary character and ":" is the separator — exactly
           inverted. Swapping is not enough on its own: a name is one
           component here, so it must not begin a path or hide itself. */
        var safe = name.replacingOccurrences(of: "/", with: ":")
        if safe.hasPrefix(".") { safe = "_" + safe.dropFirst() }
        guard !safe.isEmpty, safe != "_", !safe.contains("/") else {
            throw ShareError.badPath
        }
        let url = folder.appendingPathComponent(safe)
        if FileManager.default.fileExists(atPath: url.path) {
            guard overwrite else { throw ShareError.exists }
            /* Replacing puts the old one in the Trash rather than
               destroying it. The person who agreed to this is sitting
               at the OTHER machine, looking at a list of names — they
               cannot see what they are about to lose, so the answer
               has to be recoverable from this end. */
            try FileManager.default.trashItem(at: url,
                                              resultingItemURL: nil)
        }
        return url
    }
}
