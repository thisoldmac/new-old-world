import Darwin
import Foundation
import MirrorKitUI

/// Building an asset pack from the machine that is actually connected.
///
/// **What this is not.** It is not a second extractor. Every parse — what
/// an `icl8` means, which font strikes a pack must have, what the desktop
/// is set to — stays in `tools/extract-assets-offline`, which grew a
/// `--from-tree` acquisition for exactly this. Plan 017 proposed porting
/// the parsers to Swift and named the cost itself: two implementations of
/// `icl8` would eventually disagree, and produce art that is wrong in a
/// way nobody can see. So this object owns the TRANSPORT and nothing else.
///
/// The sequence is four steps and each one refuses by name:
///
/// 1. **Ask the extractor what it needs.** `--required-files` is the one
///    list; this side keeps no copy of it. A face added to `FACES` over
///    there changes what gets pulled here with no edit at all, which is
///    the drift this arrangement exists to prevent.
/// 2. **Ask whether the share can even reach it**, in one listing, before
///    any bytes move. See ``probeShare(for:)`` — this step exists because
///    a PowerBook 1400c refused the first pull and the refusal, though
///    correct, arrived after the run had begun and named a path instead
///    of a remedy.
/// 3. **Pull each file over `file.get`, forced to MacBinary**, and
///    reconstruct its resource fork on disk at the path the guest knows it
///    by. `container: "macbinary"` is not a preference: the art is in the
///    resource fork, and `auto` would hand back a bare data fork for
///    anything the guest judged forkless.
/// 4. **Run the extractor over the staged tree.** Its own gates decide
///    whether what arrived is a pack — a short pull fails there, loudly,
///    rather than becoming a half pack that resolves as present.
///
/// **Status: no pack has ever been ingested from a real Macintosh.** It
/// has been RUN against one — a PowerBook 1400c on 2026-08-14 — and
/// refused, because the machine shares a folder and its System Folder was
/// outside it. The refusal path is therefore the only part of this with
/// any metal behind it; the pull, the staging and the extraction have
/// still never seen a Macintosh, and nothing here should be read as a
/// claim that they have.
@MainActor
final class MirrorAssetIngestion: ObservableObject {
    /// Every way this can decline, carrying the code a person can quote
    /// and the sentence they can act on.
    struct Refusal: Error, Equatable {
        var code: String
        var message: String
    }

    /// One file the extractor named, as it arrived.
    struct RequiredFile: Decodable, Equatable {
        var path: String
        var role: String
        var required: Bool
        var why: String
    }

    enum Phase: Equatable {
        case idle
        /// Asking the extractor for its file list.
        case preparing
        /// Asking the machine what it is actually sharing, before
        /// spending a transfer finding out.
        case probing
        case pulling(done: Int, total: Int, name: String)
        case extracting
        case finished(pack: String)
        case refused(Refusal)
    }

    @Published private(set) var phase: Phase = .idle
    /// Optional files that did not arrive. The pack is still valid without
    /// them and says so in its own manifest, but a person looking at a
    /// desktop that came out plain deserves to see why here.
    @Published private(set) var notes: [String] = []

    private let listener: GuestListener
    private var task: Task<Void, Never>?

    init(listener: GuestListener) {
        self.listener = listener
    }

    var isRunning: Bool {
        switch phase {
        case .preparing, .probing, .pulling, .extracting: return true
        case .idle, .finished, .refused: return false
        }
    }

    /// A one-line account of where this got to, for the card.
    var statusLine: String {
        switch phase {
        case .idle: return ""
        case .preparing: return "Asking what this Mac needs to hand over…"
        case .probing: return "Checking what the classic Mac is sharing…"
        case let .pulling(done, total, name):
            return "Copying \(name) (\(done + 1) of \(total))…"
        case .extracting: return "Building the pack…"
        case let .finished(pack): return "Ingested \(pack)."
        case let .refused(refusal): return refusal.message
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        listener.cancelFile()
        phase = .refused(.init(
            code: "now-assets-cancelled",
            message: "Ingestion stopped. Nothing was written to the store."))
    }

    /// `machineName` is recorded in the pack's acquisition receipt, so a
    /// person can tell which Macintosh a pack came off later.
    func ingest(machineName: String) {
        guard !isRunning else { return }
        notes = []
        phase = .preparing
        task = Task { [weak self] in
            await self?.run(machineName: machineName)
        }
    }

    // MARK: - The sequence

    private func run(machineName: String) async {
        let staging: URL
        do {
            staging = try makeStagingDirectory()
        } catch {
            refuse("now-assets-staging",
                   "NOW could not make a staging folder on this Mac: "
                   + error.localizedDescription)
            return
        }
        defer { try? FileManager.default.removeItem(at: staging) }

        guard let extractor = Self.extractorURL() else {
            refuse("now-assets-extractor-missing",
                   "NOW could not find tools/extract-assets-offline. Asset "
                   + "ingestion runs the repository's extractor; set "
                   + "\(Self.extractorEnvironmentKey) to its path.")
            return
        }

        // 1. What does a machine have to hand over?
        let required: [RequiredFile]
        switch await Self.runExtractor(extractor, ["--required-files"]) {
        case let .failure(refusal):
            refuse(refusal.code, refusal.message)
            return
        case let .success(output):
            do {
                required = try JSONDecoder().decode(
                    [RequiredFile].self, from: Data(output.utf8))
            } catch {
                refuse("now-assets-extractor-failed",
                       "The extractor's file list could not be read. It is "
                       + "probably a different version than this app expects.")
                return
            }
        }
        guard !required.isEmpty else {
            refuse("now-assets-extractor-failed",
                   "The extractor named no files to collect.")
            return
        }

        // 2. Is any of it reachable? Ask before spending a transfer.
        phase = .probing
        if case let .failure(refusal) = await probeShare(for: required) {
            refuse(refusal.code, refusal.message)
            return
        }
        if Task.isCancelled { return }

        // 3. Pull them.
        let tree = staging.appendingPathComponent("volume", isDirectory: true)
        for (index, file) in required.enumerated() {
            if Task.isCancelled { return }
            phase = .pulling(done: index, total: required.count,
                             name: (file.path as NSString).lastPathComponent)
            let pulled = await pull(file, into: tree)
            if case let .failure(refusal) = pulled {
                if file.required {
                    refuse(refusal.code, refusal.message)
                    return
                }
                notes.append("\(file.path) — \(refusal.message) The pack "
                             + "will be built without \(file.why).")
            }
        }
        if Task.isCancelled { return }

        // 4. One extraction, the same one the disk-image route runs.
        phase = .extracting
        let packID = Self.newPackID()
        let result = await Self.runExtractor(extractor, [
            "--from-tree", tree.path,
            "--pack-id", packID,
            "--source-label", machineName,
        ])
        if Task.isCancelled { return }
        switch result {
        case let .failure(refusal):
            refuse(refusal.code, refusal.message)
        case .success:
            // The store the extractor writes to and the store AssetPack
            // reads are configured separately. Asking the CONSUMER whether
            // it can see the pack is the only thing that proves they agreed
            // — a receipt saying the extractor exited zero does not.
            guard let landed = AssetPack.availablePacks.first(where: {
                $0.id == packID
            }) else {
                refuse("now-assets-pack-not-visible",
                       "The extractor built \(packID), but it is not in the "
                       + "store this app reads. Check "
                       + "\(AssetPack.storeEnvironmentKey).")
                return
            }
            notes.append(contentsOf: Self.scopeNotes(at: landed.resourcesURL))
            phase = .finished(pack: packID)
        }
    }

    // MARK: - Is the art even in the share?

    /// **The defect this exists for, found on a PowerBook 1400c on
    /// 2026-08-14.** The share is a FOLDER chosen on the classic Mac, and
    /// every `file.get` path resolves inside it. This code originally
    /// assumed the share was the volume root, having read
    /// `now_files_share_root` returning `fsRtDirID` — but that is the
    /// FALLBACK when no folder has been chosen. A real desk has chosen
    /// one (`Lab`), so `System Folder/System` was simply not in the share
    /// and the first pull refused `no such item in the share`.
    ///
    /// That refusal was honest and arrived in the wrong place: after the
    /// run had started, naming a path rather than a remedy. Reachability
    /// is knowable in one cheap listing before any bytes move, so it is
    /// asked here.
    ///
    /// The roots come from the extractor's own required list, so a file
    /// added over there is checked here without an edit.
    private func probeShare(for required: [RequiredFile]) async
        -> Result<Void, Refusal> {
        let roots = Self.requiredRoots(required)
        guard !roots.isEmpty else { return .success(()) }

        var folders = Set<String>()
        var shareLabel: String?
        var cursor: Int?
        for _ in 0..<Self.sharePageLimit {
            let listing: FileListing
            switch await list(path: "", cursor: cursor) {
            case let .failure(failure):
                return .failure(.init(
                    code: "now-assets-share-\(failure.code)",
                    message: "NOW could not read what the classic Mac is "
                        + "sharing: \(failure.message)"))
            case let .success(value):
                listing = value
            }
            shareLabel = listing.root ?? shareLabel
            for entry in listing.entries where entry.isFolder {
                folders.insert(entry.name.lowercased())
            }
            guard listing.more, let next = listing.cursor else {
                let missing = roots
                    .filter { !folders.contains($0.lowercased()) }
                    .sorted()
                guard missing.isEmpty else {
                    return .failure(Self.shareRefusal(
                        missing: missing, share: shareLabel))
                }
                return .success(())
            }
            cursor = next
        }
        /* Out of pages with the listing still incomplete. Say nothing:
           refusing on a partial view would block a share that does hold
           the System Folder, and the pull answers the question for
           certain a moment later. */
        return .success(())
    }

    /// How many pages of the share root to walk before giving up on
    /// answering cheaply.
    private static let sharePageLimit = 20

    /// The top-level folders the share must contain, derived from the
    /// extractor's own list rather than named here.
    ///
    /// Only the REQUIRED files count. An optional file's absence is
    /// already a note rather than a refusal, so demanding its folder be
    /// present would refuse a share that can build a perfectly good pack.
    static func requiredRoots(_ required: [RequiredFile]) -> Set<String> {
        Set(required.filter(\.required).compactMap {
            $0.path.split(separator: "/").first.map(String.init)
        })
    }

    /// Names the remedy, not the path. A person reading this is at a Mac
    /// with a NOW preference they can change; "no such item in the share"
    /// told them where the failure happened and nothing about that.
    static func shareRefusal(missing: [String],
                             share: String?) -> Refusal {
        let named = missing.map { "“\($0)”" }
            .joined(separator: ", ")
        let current = share.map { " The shared folder is “\($0)”." } ?? ""
        return .init(
            code: "now-assets-not-in-share",
            message: "The classic Mac's art is outside the folder it is "
                + "sharing, so NOW cannot read it.\(current) It does not "
                + "contain \(named). On the classic Mac, set NOW's shared "
                + "folder to the whole disk — the volume itself rather "
                + "than a folder inside it — and ingest again. Nothing "
                + "has been copied.")
    }

    private func list(path: String, cursor: Int?) async
        -> Result<FileListing, GuestListener.FileFailure> {
        await withCheckedContinuation { continuation in
            listener.listFiles(path: path, cursor: cursor) {
                continuation.resume(returning: $0)
            }
        }
    }

    // MARK: - One file

    private func pull(_ file: RequiredFile,
                      into tree: URL) async -> Result<Void, Refusal> {
        let delivery: GuestListener.FileDelivery
        switch await getFile(path: file.path) {
        case let .failure(failure):
            return .failure(.init(
                code: "now-assets-pull-\(failure.code)",
                message: MachineNaming.startingSentence(
                    "\(MachineNaming.simpleReference) would not send \(file.path): "
                    + failure.message)))
        case let .success(value):
            delivery = value
        }

        let envelope = delivery.staged
        defer { envelope.discard() }
        guard let bytes = try? Data(contentsOf: envelope.url) else {
            return .failure(.init(
                code: "now-assets-staging",
                message: "NOW could not read the copy of \(file.path) it "
                    + "just received."))
        }
        /* A bare data fork is not an extraction failure to diagnose later:
           every asset in this list lives in the resource fork, so a file
           that arrived without one cannot contribute and says so now. */
        guard let decoded = try? MacBinaryFile.decode(bytes) else {
            return .failure(.init(
                code: "now-assets-macbinary",
                message: "\(file.path) did not arrive as MacBinary, so it "
                    + "carries no resource fork."))
        }
        guard !decoded.resourceFork.isEmpty else {
            return .failure(.init(
                code: "now-assets-no-resource-fork",
                message: "\(file.path) has no resource fork on that Mac."))
        }
        do {
            try write(decoded, to: tree.appendingPathComponent(file.path))
        } catch {
            return .failure(.init(
                code: "now-assets-staging",
                message: "NOW could not stage \(file.path) on this Mac: "
                    + error.localizedDescription))
        }
        return .success(())
    }

    private func getFile(path: String) async
        -> Result<GuestListener.FileDelivery, GuestListener.FileFailure> {
        await withCheckedContinuation { continuation in
            /* Forced, not `auto`. The whole artifact is the point. */
            listener.getFile(path: path, container: "macbinary",
                             stagingDirectory: nil) {
                continuation.resume(returning: $0)
            }
        }
    }

    /// Reconstructs one classic file where the extractor expects to find
    /// it: both forks, plus the FinderInfo its type and creator live in.
    private func write(_ file: MacBinaryFile, to destination: URL) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try file.dataFork.write(to: destination)
        try file.resourceFork.write(
            to: URL(fileURLWithPath: destination.path + "/..namedfork/rsrc"))

        var info = [UInt8](repeating: 0, count: 32)
        info.replaceSubrange(0..<4, with: Array(file.type.utf8.prefix(4)))
        info.replaceSubrange(4..<8, with: Array(file.creator.utf8.prefix(4)))
        info[8] = UInt8(file.finderFlags >> 8)
        info[9] = UInt8(file.finderFlags & 0xff)
        _ = destination.path.withCString { path in
            "com.apple.FinderInfo".withCString { attribute in
                info.withUnsafeBytes { bytes in
                    setxattr(path, attribute, bytes.baseAddress,
                             bytes.count, 0, 0)
                }
            }
        }
    }

    // MARK: - Plumbing

    private func refuse(_ code: String, _ message: String) {
        phase = .refused(.init(code: code, message: message))
    }

    private func makeStagingDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-asset-ingest-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    /// What the pack that just landed actually contains, read from its own
    /// manifest rather than from what this code believes it asked for.
    ///
    /// **This exists because of how packs are chosen.** `AssetPack` takes
    /// the newest valid pack in the store, and a wire pull is a strict
    /// SUBSET of a disk-image pack: identical art, minus everything that
    /// comes from sweeping the whole volume — measured on 2026-08-14 as
    /// 12 application icons against the same image's 512, with every
    /// shared file byte-identical. Nothing is wrong in it; things are
    /// missing from it. Ingesting would therefore silently demote a
    /// richer pack, and the count lives only inside the manifest, so a
    /// person choosing between two `pack-` directories cannot see it.
    /// Saying it out loud here is the cheap half of that fix.
    static func scopeNotes(at resources: URL) -> [String] {
        guard let data = try? Data(
                contentsOf: resources.appendingPathComponent("manifest.json")),
              let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            return ["NOW could not read the new pack's manifest, so it "
                    + "cannot say what the pack contains."]
        }
        func count(_ key: String) -> Int {
            ((root[key] as? [String: Any])?["count"] as? Int) ?? 0
        }
        return ["\(count("icons")) generic icons, \(count("cursors")) "
                + "cursors, \(count("appicons")) application icons. "
                + "Application and custom Finder icons come from sweeping "
                + "a whole volume, which this route does not do — a pack "
                + "built from a disk image will have far more of them."]
    }

    /// The directory the pack is written to.
    ///
    /// `AssetPack` searches for the `pack-` prefix and takes the newest by
    /// sorting the ids as STRINGS, so this stamp must be fixed-width and
    /// zero-padded or "newest" quietly stops meaning newest. The date is a
    /// parameter so that property can be tested against two known times
    /// rather than against whatever second the suite happens to run in.
    static func newPackID(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "pack-\(formatter.string(from: date))"
    }

    /// Read from the detached process launch too, so not actor-bound.
    nonisolated static let extractorEnvironmentKey = "NOW_ASSET_EXTRACTOR"
    nonisolated static let pythonEnvironmentKey = "NOW_ASSET_PACK_PYTHON"

    /// The extractor is repository tooling, not a bundled resource — the
    /// pack itself is a private developer dependency and this is the tool
    /// that rebuilds it. `#filePath` finds it in a working checkout; the
    /// environment key covers every other case rather than guessing.
    static func extractorURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let raw = environment[extractorEnvironmentKey], !raw.isEmpty {
            let url = URL(fileURLWithPath:
                (raw as NSString).expandingTildeInPath)
            return FileManager.default.isExecutableFile(atPath: url.path)
                ? url : nil
        }
        // now-host/Sources/Host/<this file> -> repository root
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Host
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // now-host
            .deletingLastPathComponent()   // root
        let url = root.appendingPathComponent("tools/extract-assets-offline")
        return FileManager.default.isExecutableFile(atPath: url.path)
            ? url : nil
    }

    private static func runExtractor(_ tool: URL, _ arguments: [String])
        async -> Result<String, Refusal> {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            let environment = ProcessInfo.processInfo.environment
            let python = environment[pythonEnvironmentKey] ?? ""
            if python.isEmpty {
                process.executableURL = tool
                process.arguments = arguments
            } else {
                process.executableURL = URL(fileURLWithPath: python)
                process.arguments = [tool.path] + arguments
            }
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            do {
                try process.run()
            } catch {
                return .failure(.init(
                    code: "now-assets-extractor-failed",
                    message: "NOW could not run the extractor: "
                        + error.localizedDescription))
            }
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                /* The extractor's own gates are the good failure messages
                   here — missing font strikes, no `Mac OS Default` ppat,
                   Pillow absent. Passing them through beats restating
                   them worse. */
                let reason = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return .failure(.init(
                    code: "now-assets-extractor-failed",
                    message: reason.isEmpty
                        ? "The extractor stopped without building a pack."
                        : reason))
            }
            return .success(String(data: outData, encoding: .utf8) ?? "")
        }.value
    }
}
