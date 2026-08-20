import Darwin
import Foundation
import NOWAgentIntegration

/// Where an agent's download lands, and the only place it may.
///
/// **The caller never names a destination.** That is the whole authority
/// answer for the pull direction, and it is the exact mirror of the upload
/// lane's: `now_guest_files_upload_begin` accepts bytes and never a
/// modern-host path (docs/agent-integration.md, "Local trust boundary"), so
/// the download accepts a guest path and never a host one. A tool that took
/// both ends would be the file transport this companion is explicitly not.
///
/// Three consequences worth stating rather than discovering:
///
/// - **The person's own Downloads folder is not this.** `FilesModel` writes a
///   human's download into `files.downloadDirectory`, which they chose; an
///   agent call filing into it would put an agent's fetch into somebody's
///   folder, the same line `CaptureScreenProjection` refuses to cross with
///   the screenshot history.
/// - **The bytes live for the host launch.** The root is per-process and is
///   removed when this store is deallocated, which for the app means quit. A
///   caller that wants to keep a file copies it; nothing here promises a
///   file will outlive the host that authorized fetching it.
/// - **A landed file is read-only** (mode `0400`, inside a mode-`0700`
///   directory), so the thing a caller reads cannot be the thing something
///   else is still writing.
///
/// It is `@MainActor` rather than an actor, unlike `GuestUploadStagingStore`,
/// and the difference is real rather than an inconsistency: that store
/// receives and hashes the bytes itself, while everything here is a capacity
/// stat, a same-volume rename and a `chmod`. The BYTES are written by
/// `InboundFileSink` inside the transfer, straight into this root — which is
/// the reuse that matters, because a second byte path is exactly what
/// docs/reverse-file-streaming.md's integration note says not to build.
@MainActor
final class AgentDownloadStore {
    struct Failure: Error, Equatable {
        let code: String
        let message: String
    }

    struct Landing: Equatable {
        let url: URL
        let bytes: Int
    }

    /// The most one agent download may bring across, and why that number:
    /// `AgentDownloadPolicy`. It is stated there rather than here because a
    /// caller reads it out of the projection's schema, in another target.
    static let maximumBytes = AgentDownloadPolicy.maximumBytes

    /// Leave the same five percent of important-usage capacity the upload
    /// lane leaves, rather than inventing a second host-disk policy.
    private static let headroomDivisor: Int64 = 20

    /// The directory the transfer stages into and the landing sits in.
    /// Non-isolated because `GuestListener.getFile` takes it as a plain
    /// argument on the same actor; nothing mutable is exposed.
    nonisolated let rootURL: URL

    private nonisolated let removeRootOnDeinit: Bool
    private let availableBytes: () throws -> Int64

    init(
        rootURL: URL? = nil,
        expectedUID: uid_t = geteuid(),
        availableBytes: (() throws -> Int64)? = nil
    ) throws {
        if let rootURL {
            self.rootURL = rootURL
            removeRootOnDeinit = false
        } else {
            let endpoint = try AgentIntegrationEndpoint.currentUser(
                uid: expectedUID)
            try Self.createPrivateDirectory(
                endpoint.directoryURL, uid: expectedUID)
            self.rootURL = endpoint.directoryURL.appendingPathComponent(
                "downloads-\(getpid())-\(UUID().uuidString.lowercased())",
                isDirectory: true)
            removeRootOnDeinit = true
        }
        try Self.createPrivateDirectory(self.rootURL, uid: expectedUID)
        if let availableBytes {
            self.availableBytes = availableBytes
        } else {
            let root = self.rootURL
            self.availableBytes = {
                guard let available = try PrivateStagingCapacity
                    .availableBytes(at: root) else {
                    throw Failure(
                        code: "now-download-host-space-unknown",
                        message:
                            "NOW could not determine private download capacity")
                }
                return available
            }
        }
    }

    deinit {
        guard removeRootOnDeinit else { return }
        try? FileManager.default.removeItem(at: rootURL)
    }

    /// Refuses before a byte moves: over the ceiling, or more than this Mac
    /// can spare.
    ///
    /// `bytes` is what the guest's own listing observed, so this is
    /// composition over data the guest just supplied rather than a host
    /// guess — and it is a *pre*-check, which is why the ceiling is stated
    /// twice. The post-check in `land` exists because a source can grow
    /// between the listing and the transfer, and because MacBinary adds a
    /// header and padding the fork sizes do not include.
    func reserve(bytes: Int) throws {
        guard bytes >= 0 else {
            throw Failure(
                code: "now-download-size-invalid",
                message: "The observed size of that item is not a size")
        }
        guard bytes <= Self.maximumBytes else {
            throw Failure(
                code: "now-download-too-large",
                message: "That item is \(bytes) bytes and the agent "
                    + "download ceiling is \(Self.maximumBytes)")
        }
        let available = try availableBytes()
        let usable = max(0, available - available / Self.headroomDivisor)
        guard Int64(bytes) <= usable else {
            throw Failure(
                code: "now-download-insufficient-host-space",
                message: "Private download storage cannot take that item")
        }
    }

    /// Moves a completed transfer's staged file to its landing, and reports
    /// where.
    ///
    /// The rename is same-directory, so it is atomic and cannot half-happen:
    /// a caller either gets a path to a whole file or gets a failure and no
    /// path. `relinquish` is called only after the move succeeds — until
    /// then the staged file keeps its own cleanup, which is what removes the
    /// bytes when the ceiling refuses them here.
    func land(_ staged: InboundFileSink.StagedFile, named leaf: String)
        throws -> Landing {
        guard staged.byteCount <= Self.maximumBytes else {
            throw Failure(
                code: "now-download-too-large",
                message: "The file arrived at \(staged.byteCount) bytes, "
                    + "over the \(Self.maximumBytes) ceiling, and was "
                    + "discarded")
        }
        let destination = try uniqueDestination(for: leaf)
        do {
            try FileManager.default.moveItem(at: staged.url, to: destination)
        } catch {
            throw Failure(
                code: "now-download-landing-failed",
                message: "NOW could not place the downloaded file")
        }
        staged.relinquish()
        /* Best effort on purpose: the file IS the answer and it is already
           in a mode-0700 directory, so failing the whole download because
           the mode bits did not take would trade a delivered file for a
           refusal that helps nobody. */
        _ = chmod(destination.path, 0o400)
        return Landing(url: destination, bytes: staged.byteCount)
    }

    /// Removes only a settled file that this store could have minted.
    ///
    /// API transfer retention must not turn a serialized host path back into
    /// deletion authority. Re-resolving the parent and rejecting symlinks
    /// keeps cleanup inside this store's private, flat landing directory.
    func releaseLanding(at url: URL) -> Bool {
        let candidate = url.standardizedFileURL
        guard candidate.deletingLastPathComponent() == rootURL.standardizedFileURL
        else { return false }
        var status = stat()
        guard lstat(candidate.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG else { return false }
        do {
            try FileManager.default.removeItem(at: candidate)
            return true
        } catch {
            return false
        }
    }

    /// A host filename derived from the guest's name, never the guest's name
    /// used as a path.
    ///
    /// Everything that is not a plain name is replaced rather than escaped:
    /// a classic HFS name may legally contain `/` and control bytes, and one
    /// of those reaching `appendingPathComponent` is a directory traversal
    /// written by the other machine.
    private func uniqueDestination(for leaf: String) throws -> URL {
        let safe = Self.hostFilename(for: leaf)
        for attempt in 0...64 {
            let name = attempt == 0 ? safe : "\(safe)-\(attempt)"
            let candidate = rootURL.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: candidate.path)
            else { return candidate }
        }
        throw Failure(
            code: "now-download-landing-failed",
            message: "Too many downloads of that name in this host launch")
    }

    static func hostFilename(for leaf: String) -> String {
        var out = ""
        for scalar in leaf.unicodeScalars {
            let dangerous = scalar == "/" || scalar == ":"
                || scalar == "\\" || scalar.value < 0x20
                || scalar.value == 0x7F
            out.unicodeScalars.append(dangerous ? "_" : scalar)
        }
        // "." and ".." are names on a Macintosh and paths here.
        let trimmed = out.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "." || trimmed == ".." {
            return "download"
        }
        return String(trimmed.unicodeScalars.prefix(64))
    }

    private static func createPrivateDirectory(
        _ url: URL,
        uid: uid_t
    ) throws {
        let result = mkdir(url.path, 0o700)
        guard result == 0 || errno == EEXIST else {
            throw Failure(
                code: "now-download-staging-unavailable",
                message: "NOW could not create private download storage")
        }
        var status = stat()
        guard lstat(url.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == uid,
              status.st_mode & 0o077 == 0 else {
            throw Failure(
                code: "now-download-staging-unsafe",
                message: "The private download directory is unsafe")
        }
    }
}
