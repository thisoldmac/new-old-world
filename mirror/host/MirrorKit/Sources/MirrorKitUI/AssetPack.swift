import Foundation

/// Where the extracted Platinum asset pack is, and what to do when it is
/// not anywhere.
///
/// **The pack is a dependency, not repository content.** It is Apple's
/// bitmaps — the System file's icons and cursors, each application's own
/// `icl8`, the NFNT strikes the guest draws its text with — pulled off a
/// disk image by `tools/extract-assets-offline`. The rule it inherits
/// (docs/mirror-assets.md) is that it stays private, never ships as an
/// artifact and never goes upstream, and it was committed to this
/// repository as a side effect of wiring the pack up rather than as a
/// decision. So it lives outside git, and this type is the seam that
/// makes that workable: nothing else in the renderer knows where the
/// bitmaps come from.
///
/// It is regenerable, which is what makes not-in-git viable at all.
/// `tools/extract-assets-offline` rebuilds it byte-identically from a
/// local OS 9 image, and its default output directory is search step 3
/// below — so "run the extractor" is the whole recovery procedure.
///
/// **Absent is a first-class state, and it is loud.** A missing
/// dependency that looks like working software is the failure this
/// project keeps paying for, so a pack that cannot be found is reported
/// on stderr the first time anything asks, is readable as
/// ``AssetPack/status``, and is meant to be shown to the person looking
/// at the mirror. What must NOT happen is generic art appearing where
/// the guest's own art belongs, with nothing saying so — the drawing
/// would be a claim about the guest that no capture supports.
public enum AssetPack {

    /// What the search found.
    public enum Status: Equatable, Sendable {
        /// The pack directory, and which search step produced it.
        case resolved(URL, via: String)
        /// Nothing was found; these are the places that were looked at,
        /// in order, so the message can say where to put it.
        case absent(searched: [String])

        public var isPresent: Bool {
            if case .resolved = self { return true }
            return false
        }
    }

    /// The environment variable that wins over everything. Point it at a
    /// directory holding `fonts/`, `icons/`, `appicons/`, `cursors/`,
    /// `patterns/` and `manifest.json`.
    public static let environmentKey = "NOW_MIRROR_ASSETS"

    /// The documented store: packs live beside the qcow2 images, newest
    /// `pack-*` wins. This is a path on a desk rather than a fact about
    /// the software, which is exactly why it is only step 2 — the
    /// environment variable is the supported way to say something else.
    static let defaultStore = "~/Lab/Assets/now-mirror-assets"

    /// Resolved once. The pack does not appear mid-run, and a renderer
    /// that re-stats a directory per icon would spend its frame budget
    /// asking a question with a fixed answer.
    public static let status: Status = resolve()

    /// The pack directory, or nil.
    public static var root: URL? {
        if case let .resolved(url, _) = status { return url }
        return nil
    }

    /// A file inside the pack — the one lookup the renderer performs.
    /// Returns nil when the pack is absent OR when the pack has no such
    /// file, and the caller must treat both as "draw the procedural
    /// fallback", because a third-party application genuinely has no
    /// extracted icon even with a complete pack.
    public static func url(forResource name: String,
                           withExtension ext: String,
                           subdirectory subdir: String) -> URL? {
        guard let root else { return nil }
        let url = root.appendingPathComponent(subdir)
            .appendingPathComponent(name)
            .appendingPathExtension(ext)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// One line for a person looking at the mirror. nil when the pack is
    /// present — there is nothing to say about a dependency that is
    /// where it should be.
    public static var bannerText: String? {
        guard case let .absent(searched) = status else { return nil }
        return "Platinum asset pack not found — icons, cursors and text "
            + "are procedural stand-ins, not the guest's own art. "
            + "Set \(environmentKey), or run tools/extract-assets-offline. "
            + "Looked in: \(searched.joined(separator: ", "))"
    }

    /// Set `NOW_REQUIRE_ASSET_PACK=1` to make an absent pack a test
    /// FAILURE instead of a named skip.
    ///
    /// The pack gates cannot simply be deleted — they are the only thing
    /// asserting that a reported creator signature reaches that
    /// application's own icon, and that the 16×16 art is its own drawing
    /// rather than the 32×32 resampled. They also cannot simply pass on
    /// a machine with no pack. So they skip, loudly and by name, and a
    /// machine that HAS the pack sets this to turn "skipped" back into
    /// "must hold". `scripts/test-mirrorkit` sets it automatically when
    /// a pack resolves, so the default desk enforces them and a fresh
    /// clone still gets a green, honest run.
    public static var isRequired: Bool {
        let raw = ProcessInfo.processInfo
            .environment["NOW_REQUIRE_ASSET_PACK"] ?? ""
        return raw == "1" || raw.lowercased() == "true"
    }

    /// One line naming the pack's state, for a gate to print. A gate
    /// that quietly declines to run is how a missing dependency comes to
    /// look like working software.
    public static var summaryLine: String {
        switch status {
        case let .resolved(url, via):
            return "asset pack: \(url.path) (via \(via))"
        case .absent:
            return "asset pack: ABSENT — pack-dependent tests will "
                + (isRequired ? "FAIL (NOW_REQUIRE_ASSET_PACK)" : "SKIP")
        }
    }

    // MARK: - Resolution

    private static func resolve() -> Status {
        var searched: [String] = []

        func accept(_ url: URL, via: String) -> Status? {
            searched.append(url.path)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path,
                                                 isDirectory: &isDir),
                  isDir.boolValue else { return nil }
            // A directory alone is not a pack. `manifest.json` is what
            // the extractor writes last, so its presence is the signal
            // that an extraction finished rather than died halfway.
            let manifest = url.appendingPathComponent("manifest.json")
            guard FileManager.default.fileExists(atPath: manifest.path)
            else { return nil }
            return .resolved(url, via: via)
        }

        // 1. Explicit. Whoever set it meant it, so a bad value is an
        //    error worth naming rather than something to search past.
        //
        //    `none` is a real setting, not a test hook wearing one: it is
        //    the only way to SEE the honest-degradation path on a machine
        //    that has a pack, and a degradation path nobody can reach is
        //    a degradation path nobody has watched work. The gate uses it
        //    for exactly that (scripts/test-host, scripts/test-mirrorkit).
        if ProcessInfo.processInfo.environment[environmentKey] == "none" {
            return .absent(searched: ["\(environmentKey)=none"])
        }
        if let raw = ProcessInfo.processInfo.environment[environmentKey],
           !raw.isEmpty {
            let url = URL(fileURLWithPath: (raw as NSString)
                .expandingTildeInPath)
            if let ok = accept(url, via: environmentKey) { return ok }
            warn("\(environmentKey)=\(raw) is not a pack directory "
                 + "(no manifest.json) — continuing the search")
        }

        // 2. The documented store, newest pack first.
        let store = URL(fileURLWithPath:
                            (defaultStore as NSString).expandingTildeInPath)
        let packs = ((try? FileManager.default.contentsOfDirectory(
            atPath: store.path)) ?? [])
            .filter { $0.hasPrefix("pack-") }
            .sorted(by: >)
        for pack in packs {
            let url = store.appendingPathComponent(pack)
                .appendingPathComponent("Resources")
            if let ok = accept(url, via: "\(defaultStore)/\(pack)") {
                return ok
            }
        }
        if packs.isEmpty { searched.append("\(store.path)/pack-*/Resources") }

        // 3. The extractor's own default output, in a working checkout.
        //    `#filePath` is the source location of this file, so this
        //    step exists for a developer who has just run the extractor
        //    and is building from the same tree; a shipped app resolves
        //    by 1 or 2, and it must never ship the pack inside itself.
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        if let ok = accept(here.appendingPathComponent("Resources"),
                           via: "checkout (tools/extract-assets-offline "
                           + "default output)") {
            return ok
        }

        warn("Platinum asset pack NOT FOUND. The mirror will draw "
             + "procedural stand-ins, NOT the guest's own art. Set "
             + "\(environmentKey), or run tools/extract-assets-offline. "
             + "Looked in: \(searched.joined(separator: ", "))")
        return .absent(searched: searched)
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write(
            Data(("MirrorKit: " + message + "\n").utf8))
    }
}
