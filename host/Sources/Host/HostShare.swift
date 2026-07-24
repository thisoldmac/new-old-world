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

    /// One error, mapped once. Two envelopes carry it — file.refuse for
    /// a request we will not serve, file.result for a change that
    /// failed — and both used to re-derive the same two expressions,
    /// so a new ShareError case would have taught only one of them.
    struct WireFault {
        let code: String
        let reason: String

        init(_ error: Error) {
            let known = error as? HostShare.ShareError
            code = known?.code ?? "io-error"
            reason = known?.message ?? "\(error)"
        }
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
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: entry.path)
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
                    .flatMap(ClassicDate.guestWireSeconds(from:)),
                identity: Self.observationIdentity(
                    name: entry.lastPathComponent,
                    isDirectory: isDir,
                    attributes: attributes))
        }
        /* A page is bounded by BYTES as well as by count: sixteen long
           names plus their types and dates can exceed the control-frame
           cap, and a message the receiver cannot hold used to cost the
           whole connection.

           The size is MEASURED by encoding the candidate page, not
           estimated. An estimate is a second, approximate copy of the
           codec's rules, and it drifts silently the first time a field
           is added to an entry — in whichever direction is not safe. */
        var page: [FileEntry] = []
        for entry in entries {
            let candidate = page + [entry]
            let probe = FileListing(id: 0, path: path, entries: candidate,
                                    more: true, cursor: 0, root: root.path)
            let size = (try? ControlMessageCodec.encode(.fileListing(probe)))?
                .count ?? Int.max
            if !page.isEmpty && size > maxListingBytes { break }
            page.append(entry)
        }
        let served = start + page.count
        return (page, served < contents.count, served + 1)
    }

    /// The host half of FileEntry.identity. It is opaque on the wire and
    /// intentionally binds both file-system identity and this exact catalog
    /// observation, so a future mutation can recompute rather than trust a
    /// path-only snapshot.
    private static func observationIdentity(
        name: String,
        isDirectory: Bool,
        attributes: [FileAttributeKey: Any]?
    ) -> String? {
        guard let attributes,
              let fileNumber =
                (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        else { return nil }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?
            .timeIntervalSinceReferenceDate.bitPattern ?? 0
        let created = (attributes[.creationDate] as? Date)?
            .timeIntervalSinceReferenceDate.bitPattern ?? 0
        let material =
            "\(fileNumber)|\(size)|\(modified)|\(created)|"
                + "\(isDirectory ? 1 : 0)|\(name)"
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in material.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    // MARK: - Changing what we share

    /* The guest asks for these the same way the host does, and they mean
       the same thing whichever side serves them. Every one is
       reversible, which is what lets the asker offer undo. */

    /// Moves and/or renames. `toPath` is the full destination path
    /// including the new name. Parents are NOT created: moving into a
    /// folder that is not there is a mistake, not an instruction.
    func move(from: String, to: String, overwrite: Bool) throws -> String {
        let source = try resolve(from)
        let target = try resolve(to)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ShareError.notFound
        }
        let parent = target.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path,
                                             isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ShareError.notFound
        }
        if FileManager.default.fileExists(atPath: target.path) {
            guard overwrite else { throw ShareError.exists }
            /* Replacing keeps the old one, for the same reason a push
               does: the person who agreed is at the other machine and
               cannot see what they are replacing. */
            try FileManager.default.trashItem(at: target,
                                              resultingItemURL: nil)
        }
        do {
            try FileManager.default.moveItem(at: source, to: target)
        } catch {
            throw ShareError.io("\(error.localizedDescription)")
        }
        return relativePath(of: target)
    }

    /// Moves an item to the Trash and reports the name it landed under —
    /// which is not always the name it had, because the Trash may
    /// already hold one. That name is what a restore needs, so recording
    /// the name we ASKED for would eventually put something else back.
    func trash(path: String) throws -> String {
        let url = try resolve(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ShareError.notFound
        }
        var landed: NSURL?
        do {
            try FileManager.default.trashItem(at: url,
                                              resultingItemURL: &landed)
        } catch {
            throw ShareError.io("\(error.localizedDescription)")
        }
        return (landed as URL?)?.lastPathComponent ?? url.lastPathComponent
    }

    /// Puts a trashed item back. Both halves are names, so an undo
    /// survives a restart of either machine.
    func restore(trashedAs: String, to path: String) throws -> String {
        let target = try resolve(path)
        let trash = try FileManager.default.url(
            for: .trashDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false)
        let source = trash.appendingPathComponent(trashedAs)
        guard FileManager.default.fileExists(atPath: source.path) else {
            /* Emptied, or dragged out by hand. Not our failure, and the
               asker can say so precisely. */
            throw ShareError.notFound
        }
        if FileManager.default.fileExists(atPath: target.path) {
            throw ShareError.exists
        }
        do {
            try FileManager.default.moveItem(at: source, to: target)
        } catch {
            throw ShareError.io("\(error.localizedDescription)")
        }
        return relativePath(of: target)
    }

    /// Makes a folder, and the parents it needs.
    func makeFolder(path: String) throws -> String {
        let url = try resolve(path)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path,
                                          isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw ShareError.exists }
            return relativePath(of: url)   // already there is not a failure
        }
        do {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true)
        } catch {
            throw ShareError.io("\(error.localizedDescription)")
        }
        return relativePath(of: url)
    }

    /// A path back in the other machine's spelling, for reporting where
    /// something actually landed.
    private func relativePath(of url: URL) -> String {
        let base = root.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        guard full.hasPrefix(base + "/") else { return "" }
        return String(full.dropFirst(base.count + 1))
            .replacingOccurrences(of: "/", with: Self.separator)
    }

    /// The contract's control-frame cap, less room for the envelope the
    /// entries sit in (type, path, cursor, root, and the share label).
    /// The contract's control-frame cap. A listing must fit in one.
    ///
    /// With a 16-entry page and names the other machine can hold (31
    /// characters), a real listing does not come close — so this bound
    /// is defence against a future page size or a longer name, not
    /// something the current shape reaches. Settable so a test can prove
    /// the mechanism works rather than assert a threshold that cannot be
    /// crossed.
    var maxListingBytes = 4096


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
        var plan = OutboundFile.plan(url: url, data: data,
                                     convertText: convertText)
        /* Taken here, where the file was already resolved and read.
           Asking for it afterwards meant resolving the path a second
           time — and resolve reads a default and walks symlinks. */
        plan.modified = (try? url.resourceValues(
            forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
            .flatMap(ClassicDate.guestWireSeconds(from:))
        return plan
    }

    /// Where an incoming file should be written. The name arrives in
    /// MacRoman from a machine that allows characters this one uses for
    /// paths, so it is decoded and made safe before it touches disk.
    func destination(name: String, path: String,
                     createParents: Bool = true,
                     overwrite: Bool) throws -> URL {
        let folder = try resolve(path)
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: folder.path,
                                           isDirectory: &isDirectory) {
            guard createParents else { throw ShareError.notFound }
            do {
                try FileManager.default.createDirectory(
                    at: folder, withIntermediateDirectories: true)
            } catch {
                throw ShareError.io(error.localizedDescription)
            }
        }
        guard FileManager.default.fileExists(
                atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ShareError.notADirectory
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
