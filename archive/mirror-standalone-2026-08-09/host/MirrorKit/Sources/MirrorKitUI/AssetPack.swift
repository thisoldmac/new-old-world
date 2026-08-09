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
    public struct Choice: Identifiable, Equatable, Sendable {
        public let id: String
        public let resourcesURL: URL

        public init(id: String, resourcesURL: URL) {
            self.id = id
            self.resourcesURL = resourcesURL
        }
    }

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
    public static let selectionDefaultsKey = "NOWSelectedMirrorAssetPack"

    /// The documented store: packs live beside the qcow2 images, newest
    /// `pack-*` wins. This is a path on a desk rather than a fact about
    /// the software, which is exactly why it is only step 2 — the
    /// environment variable is the supported way to say something else.
    static let defaultStore = "~/Lab/Assets/now-mirror-assets"

    /// Resolved once. The pack does not appear mid-run, and a renderer
    /// that re-stats a directory per icon would spend its frame budget
    /// asking a question with a fixed answer.
    public static let status: Status = resolve()

    public static var isEnvironmentManaged: Bool {
        ProcessInfo.processInfo.environment[environmentKey] != nil
    }

    /// Valid extracted packs in the standard Lab store, newest first.
    /// The pack identity is discovered from the directory, never compiled in.
    public static var availablePacks: [Choice] {
        discover(in: storeURL())
    }

    public static var selectedPackID: String? {
        UserDefaults.standard.string(forKey: selectionDefaultsKey)
    }

    /// Selection applies on the next launch because the renderer intentionally
    /// resolves art once and caches decoded bitmaps for the process lifetime.
    public static func selectPack(id: String?) {
        if let id { UserDefaults.standard.set(id, forKey: selectionDefaultsKey) }
        else { UserDefaults.standard.removeObject(forKey: selectionDefaultsKey) }
    }

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
            return isPack(url) ? .resolved(url, via: via) : nil
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
        let store = storeURL()
        let packs = discover(in: store)
        if let selectedPackID,
           let selected = packs.first(where: { $0.id == selectedPackID }),
           let ok = accept(selected.resourcesURL,
                           via: "selected pack \(selected.id)") {
            return ok
        }
        if let selectedPackID, !packs.contains(where: { $0.id == selectedPackID }) {
            warn("selected asset pack \(selectedPackID) is unavailable; "
                 + "using the newest valid extracted pack")
        }
        for pack in packs {
            if let ok = accept(pack.resourcesURL,
                               via: "\(defaultStore)/\(pack.id)") {
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

    static func storeURL() -> URL {
        URL(fileURLWithPath:
                (defaultStore as NSString).expandingTildeInPath)
    }

    static func discover(in store: URL) -> [Choice] {
        ((try? FileManager.default.contentsOfDirectory(
            atPath: store.path)) ?? [])
            .filter { $0.hasPrefix("pack-") }
            .sorted(by: >)
            .compactMap { id in
                let resources = store.appendingPathComponent(id)
                    .appendingPathComponent("Resources")
                return isPack(resources)
                    ? Choice(id: id, resourcesURL: resources) : nil
            }
    }

    /// Whether a directory is a finished pack.
    ///
    /// A directory alone is not one. `manifest.json` is what the
    /// extractor writes LAST, so its presence is the signal that an
    /// extraction finished rather than died halfway — and a
    /// half-extracted directory resolving as a present pack would be the
    /// silent-degradation case wearing a different hat: most of the art
    /// missing, and nothing saying so.
    ///
    /// Separate from `resolve()` so it can be tested against a directory
    /// made on the spot. `status` is memoised on purpose, so a test that
    /// could only read it would be testing one machine's filesystem
    /// rather than the rule.
    static func isPack(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path,
                                             isDirectory: &isDir),
              isDir.boolValue else { return false }
        return FileManager.default.fileExists(
            atPath: url.appendingPathComponent("manifest.json").path)
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write(
            Data(("MirrorKit: " + message + "\n").utf8))
    }
}
