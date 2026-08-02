import Foundation

/// Everything the Mirror page decides that does not need a process, a
/// socket or a view: where Mirror's binary is, what to launch it against,
/// what the connected Mac is missing, and the sentence that says so.
///
/// Kept apart from `MirrorControlModel` for one reason — these are the
/// answers a person acts on, and a decision that can only be exercised by
/// spawning something is a decision nobody tests. The model owns the
/// wire, the child process and the clock; this file owns the judgements.

// MARK: - The resident components

/// One of the three INITs Mirror needs on the machine it draws.
///
/// They are Mirror's, not NOW's: each publishes a Gestalt selector at
/// startup, and Mirror's own agent finds its shared block through that
/// selector. NOW cannot read an arbitrary selector (see
/// `MirrorInitReport`), so this side identifies them by the file that
/// carries them.
enum MirrorInit: String, CaseIterable, Identifiable, Sendable {
    case axPeek
    case qdPeek
    case portal

    var id: String { rawValue }

    /// The name of the extension file, as `spin-up.sh` stages it and as
    /// the machine's own Extensions folder lists it.
    var fileName: String {
        switch self {
        case .axPeek: return "AXPeek"
        case .qdPeek: return "QDPeek"
        case .portal: return "Portal"
        }
    }

    /// The Gestalt selector it publishes once it is resident. Shown, not
    /// probed — it is how a person confirms the right INIT by hand.
    var selector: String {
        switch self {
        case .axPeek: return "TBax"
        case .qdPeek: return "TBqd"
        case .portal: return "TBpt"
        }
    }

    var purpose: String {
        switch self {
        case .axPeek:
            return "Reads the interface — windows, controls and menus — as "
                 + "structure rather than pixels."
        case .qdPeek:
            return "Records what QuickDraw actually drew, so window content "
                 + "can be mirrored."
        case .portal:
            return "Carries events back the other way, so the mirrored "
                 + "interface can be driven."
        }
    }
}

/// What this host can honestly say about one INIT.
///
/// **Read the case names literally.** `installed` is not `resident`: an
/// INIT loads at boot and nothing else, so a file that arrived after the
/// last restart is installed and doing nothing. NOW cannot tell those two
/// apart — see `MirrorInitReport` — and a state called "loaded" would be a
/// claim this side has no way to make.
enum MirrorInitState: Equatable, Sendable {
    /// In the Extensions folder and enabled. Loaded if — and only if — the
    /// machine has restarted since it arrived.
    case installed(version: String?)
    /// In an Extensions Manager disabled folder. Definitely not loaded.
    case disabled
    /// Not in either folder. Definitely not loaded.
    case missing
    /// The machine could not be asked, with the reason it could not.
    case unknown(String)

    /// True only for the states that RULE OUT a working Mirror. `unknown`
    /// is deliberately not one of them: a check that could not run must
    /// not read as a failed check, and must not block a launch.
    var isKnownAbsent: Bool {
        switch self {
        case .disabled, .missing: return true
        case .installed, .unknown: return false
        }
    }
}

struct MirrorInitRow: Identifiable, Equatable, Sendable {
    let component: MirrorInit
    var state: MirrorInitState
    var id: String { component.id }
}

/// Maps the connected Mac's Extensions inventory onto the three rows.
///
/// ## Why this is not a Gestalt probe
///
/// The obvious detection is to ask the machine for `Gestalt('TBax')` and
/// treat an answer as residency. NOW cannot: its `gestalt` verb takes no
/// selector — `run_gestalt` gathers a fixed set and slices it by group
/// (`now-guest-ppc/src/commands/commands.c`), and the census `selectors`
/// probe walks a closed documented list. An unknown argument on that verb
/// is IGNORED, not refused, so a host that sent one would get a perfectly
/// ok reply carrying every group and no evidence of the selector at all —
/// which is the worst possible answer, because it reads as a yes.
///
/// So this side asks the question it can actually get a true answer to:
/// `software.list` over the `extensions` domain, which walks the
/// Extensions folder AND its Extensions Manager disabled sibling and marks
/// which is which. That is honest about being one step short of residency,
/// and the page says so in as many words.
enum MirrorInitReport {

    /// The wire domain that lists the Extensions folder.
    static let domain = "extensions"

    static func rows(from entries: [SoftwareEntry]) -> [MirrorInitRow] {
        MirrorInit.allCases.map { component in
            MirrorInitRow(component: component,
                          state: state(of: component, in: entries))
        }
    }

    static func rows(unknown reason: String) -> [MirrorInitRow] {
        MirrorInit.allCases.map {
            MirrorInitRow(component: $0, state: .unknown(reason))
        }
    }

    static func state(of component: MirrorInit,
                      in entries: [SoftwareEntry]) -> MirrorInitState {
        /* Enabled wins over disabled when both folders somehow carry the
           name: what loads at the next boot is the enabled one, and the
           stale copy in the disabled folder is not the answer. */
        let matches = entries.filter {
            $0.name.compare(component.fileName,
                            options: .caseInsensitive) == .orderedSame
        }
        guard !matches.isEmpty else { return .missing }
        if let live = matches.first(where: { $0.off != true }) {
            return .installed(version: live.version)
        }
        return .disabled
    }
}

// MARK: - Where Mirror's agent listens

/// The address a Mirror host instance would dial to reach the agent
/// running on the machine NOW is connected to.
///
/// Two routes, and they are not interchangeable. On real hardware the
/// machine has an address of its own and the agent's own port is the
/// target. Behind QEMU's user-mode networking every guest arrives from
/// loopback and nothing on this Mac can dial INTO it — the only way in is
/// a host-side forward the emulator was started with, which is a fact
/// about the rig rather than about the machine, and therefore a setting.
enum MirrorEndpoint: Equatable, Sendable {

    /// What `mirror-agent` binds in the guest. Fixed on that side.
    static let agentPortInGuest = 1420

    /// The forward NOW's own rig opens to the guest's agent
    /// (`scripts/spin-up-ppc`, `NOW_MIRROR_AGENT_PORT`). Deliberately NOT
    /// 1724: that is Mirror's own spin-up's habitual pick, and on a desk
    /// running both rigs a 1724 default would reach the OTHER VM's agent —
    /// the wrong-machine trap AGENTS.md's metal rules exist for, one layer
    /// up. A default, not a constant — hence the setting on the page.
    static let defaultForwardedPort = 1730

    /// A machine with an address of its own: dial it directly.
    case direct(host: String, port: Int)
    /// A machine behind user-mode NAT: dial the host-side forward.
    case forwarded(host: String, port: Int, guestPort: Int)
    /// No address to derive one from, with the reason.
    case unavailable(reason: String)

    var target: (host: String, port: Int)? {
        switch self {
        case .direct(let host, let port): return (host, port)
        case .forwarded(let host, let port, _): return (host, port)
        case .unavailable: return nil
        }
    }

    /// The address in the form a person would type it, or nil.
    var addressText: String? {
        target.map { "\($0.host):\($0.port)" }
    }

    /// Why this address and not another. The page shows it because the
    /// emulator case is the one that surprises people.
    var route: String {
        switch self {
        case .direct(let host, _):
            return "\(host) answers on the network, so Mirror dials the "
                 + "agent's own port directly."
        case .forwarded(_, let port, let guestPort):
            return "This Mac arrived from loopback, so it is emulated and "
                 + "nothing can dial into it. Mirror goes through the "
                 + "emulator's host-side forward — port \(port) here, "
                 + "\(guestPort) inside."
        case .unavailable(let reason):
            return reason
        }
    }

    /// The whole derivation, in one place, from the two facts it needs.
    ///
    /// - Parameters:
    ///   - peer: the address the accepted connection came from — host
    ///     observed, never guest asserted.
    ///   - forwardedPort: the setting, used only for an emulated machine.
    static func derive(peer: GuestAddress?,
                       forwardedPort: Int) -> MirrorEndpoint {
        guard let peer else {
            return .unavailable(reason:
                "No Mac is connected, so there is no address to derive "
                + "Mirror's target from.")
        }
        guard !peer.isLoopback else {
            guard (1...65535).contains(forwardedPort) else {
                return .unavailable(reason:
                    "\(forwardedPort) is not a port. This Mac is emulated, "
                    + "so Mirror needs the host-side forward the emulator "
                    + "was started with.")
            }
            return .forwarded(host: "127.0.0.1", port: forwardedPort,
                              guestPort: agentPortInGuest)
        }
        return .direct(host: peer.text, port: agentPortInGuest)
    }
}

/// Whether a Mirror instance could actually reach the agent.
enum MirrorReachability: Equatable, Sendable {
    /// Nothing has been tried yet.
    case untried
    case checking
    case reachable
    /// Something answered the attempt with a no, in its own words.
    case refused(String)
    /// Deliberately not checked, with the reason. The agent accepts ONE
    /// client, so probing while our own instance holds the slot would
    /// either be refused or steal it — and either way the answer would be
    /// about us rather than about the machine.
    case paused(String)

    var blocksLaunch: Bool {
        if case .refused = self { return true }
        return false
    }
}

// MARK: - Mirror on this Mac

/// Mirror's checkout, found by a marker inside it rather than by name.
///
/// Only the dev toggle needs this — the default path is a built binary,
/// which a person may keep anywhere and name in the settings. So a
/// missing checkout is not an error here; it is one less place to look.
struct MirrorCheckout: Equatable, Sendable {
    let root: URL

    /// The file that proves a directory IS Mirror rather than merely
    /// named it.
    private static let marker = "host/MirrorKit/Package.swift"

    var package: URL { root.appendingPathComponent("host/MirrorKit") }

    /// Where `swift build -c release` leaves the product.
    var releaseProduct: URL {
        package.appendingPathComponent(".build/release/MirrorApp")
    }

    /// Where a build records the checkout it came from. The walk below
    /// only holds while the binary sits inside the repository, and a
    /// shipped app never does — so without this, a copied app reports
    /// "nowhere to look" even on the machine that built it. Written by
    /// whoever stages the app; an explicit setting still outranks it.
    static let rememberedRepoKey = "NOWMirrorRepoRoot"

    /// Walks up from the running binary looking for a repository with a
    /// `mirror/` in it, and falls back to the remembered checkout. Bounded
    /// generously rather than by a counted depth anyone would have to keep
    /// correct: `swift run` puts the executable at
    /// `now-host/.build/<config>/Host` and the Xcode app is deeper.
    static func locate(startingAt start: URL,
                       defaults: UserDefaults? = .standard,
                       fileManager: FileManager = .default) -> MirrorCheckout? {
        func isMirror(_ url: URL) -> Bool {
            fileManager.fileExists(
                atPath: url.appendingPathComponent(marker).path)
        }
        var dir = start.standardizedFileURL
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent("mirror")
            if isMirror(candidate) {
                return MirrorCheckout(root: candidate.standardizedFileURL)
            }
            let parent = dir.deletingLastPathComponent().standardizedFileURL
            if parent == dir { break }
            dir = parent
        }
        /* A remembered path that no longer holds Mirror is not an error:
           it falls through to nil the same way an absent one does, so a
           moved checkout degrades to "name a binary" rather than to a
           launch that fails somewhere less obvious. */
        if let remembered = defaults?.string(forKey: rememberedRepoKey),
           !remembered.isEmpty {
            let url = URL(fileURLWithPath: remembered).standardizedFileURL
            if isMirror(url) { return MirrorCheckout(root: url) }
        }
        return nil
    }
}

/// Which Mirror binary a launch would run, and how it was found.
struct MirrorProduct: Equatable, Sendable {
    enum Origin: Equatable, Sendable {
        /// The path in the settings.
        case named
        /// The release build inside the checkout above this app.
        case checkout
    }

    var executable: URL
    var origin: Origin
}

enum MirrorProductResolution: Equatable, Sendable {
    case found(MirrorProduct)
    case missing(String)

    var product: MirrorProduct? {
        if case .found(let product) = self { return product }
        return nil
    }
}

extension MirrorProduct {

    /// The default path: a BUILT Mirror, in the two places it can be.
    ///
    /// Order is settings first, then the checkout — an explicit answer
    /// always beats a discovered one, and a named path that no longer
    /// holds a binary says so rather than silently falling through to a
    /// different Mirror than the one that was asked for.
    static func resolve(named: String?,
                        checkout: MirrorCheckout?,
                        fileManager: FileManager = .default)
        -> MirrorProductResolution {
        if let named, !named.trimmingCharacters(in: .whitespaces).isEmpty {
            let url = URL(fileURLWithPath: named).standardizedFileURL
            guard let executable = executable(inside: url,
                                              fileManager: fileManager) else {
                return .missing(
                    "Nothing runnable at \(url.path). The Mirror app setting "
                    + "should name a built MirrorApp binary, or a .app "
                    + "bundle containing one.")
            }
            return .found(MirrorProduct(executable: executable, origin: .named))
        }
        guard let checkout else {
            return .missing(
                "No built Mirror was found, and this app is not running from "
                + "a checkout with `mirror/` in it — so there is nowhere to "
                + "look. Name a built MirrorApp below, or run this app from "
                + "the repository and turn on Build from source.")
        }
        let release = checkout.releaseProduct
        guard fileManager.isExecutableFile(atPath: release.path) else {
            return .missing(
                "Mirror is at \(checkout.root.path) but has not been built: "
                + "nothing runnable at \(release.path). Turn on Build from "
                + "source below, or name a built MirrorApp.")
        }
        return .found(MirrorProduct(executable: release, origin: .checkout))
    }

    /// A `.app` bundle, or a bare executable. Both are things a person
    /// reasonably drags into a path field.
    private static func executable(inside url: URL,
                                   fileManager: FileManager) -> URL? {
        if url.pathExtension == "app" {
            let macOS = url.appendingPathComponent("Contents/MacOS")
            let names = (try? fileManager.contentsOfDirectory(atPath: macOS.path))
                ?? []
            /* MirrorApp by name first, so a bundle carrying helpers cannot
               have one of them picked; otherwise the only executable in
               there, which is what a single-binary bundle has. */
            let preferred = names.contains("MirrorApp")
                ? "MirrorApp"
                : (names.count == 1 ? names[0] : nil)
            guard let preferred else { return nil }
            let candidate = macOS.appendingPathComponent(preferred)
            return runnable(candidate, fileManager) ? candidate : nil
        }
        return runnable(url, fileManager) ? url : nil
    }

    /// `isExecutableFile` says yes to a DIRECTORY — the execute bit on one
    /// means searchable — so a person who names a folder would otherwise
    /// get a resolved product and a launch that fails with `EACCES` from
    /// somewhere that never mentions the path they typed.
    private static func runnable(_ url: URL,
                                 _ fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path,
                                     isDirectory: &isDirectory),
              !isDirectory.boolValue else { return false }
        return fileManager.isExecutableFile(atPath: url.path)
    }
}

// MARK: - What gets run

/// A command this page is about to run, resolved.
///
/// It carries no display form on purpose. The old page printed the shell
/// line it was about to spawn, which made a launcher out of a script
/// document; what a person needs is the state, not the argv.
struct MirrorInvocation: Equatable, Sendable {
    var executable: URL
    var arguments: [String]
    var workingDirectory: URL?

    /// The live window: Mirror pointed at one machine, drawing its
    /// interface and its content, updating on an interval.
    ///
    /// `--scope all` matters. `front` walks only the front application, so
    /// every other app's windows are missing from the scene, which reads
    /// as a rendering fault and was once mistaken for one
    /// (mirror/docs/TEST-DRIVE.md).
    static func liveWindow(_ product: MirrorProduct,
                           host: String, port: Int,
                           machine: String) -> MirrorInvocation {
        MirrorInvocation(
            executable: product.executable,
            arguments: ["--host", host, "--port", String(port),
                        "--machine", machine, "--scope", "all",
                        "--window", "--display", "--islands",
                        "--interval", "0.7"],
            workingDirectory: nil)
    }

    /// The dev toggle's first half. Release, because the default path
    /// launches the release product and a debug build here would leave the
    /// two disagreeing about which binary "built" means.
    static func build(_ checkout: MirrorCheckout) -> MirrorInvocation {
        MirrorInvocation(
            executable: URL(fileURLWithPath: "/usr/bin/swift"),
            arguments: ["build", "-c", "release",
                        "--package-path", checkout.package.path],
            workingDirectory: checkout.root)
    }
}

/// Why a launch will not happen, in the words the button's neighbour
/// carries. One case per cause, because "cannot launch" with a shrug is
/// the failure this page was rewritten to stop repeating.
enum MirrorLaunchRefusal: Equatable, Sendable {
    case noGuest
    case noEndpoint(String)
    case unreachable(address: String, reason: String)
    case initsAbsent([MirrorInit])
    case noProduct(String)
    case noCheckout
    case alreadyRunning

    var message: String {
        switch self {
        case .noGuest:
            return "No Mac is connected. Mirror draws the machine this app "
                 + "is talking to, so there is nothing yet for it to point "
                 + "at."
        case .noEndpoint(let reason):
            return reason
        case .unreachable(let address, let reason):
            return "Mirror's agent is not answering at \(address) — "
                 + "\(reason). The agent is a program that runs ON that "
                 + "Mac; start it there, then check again."
        case .initsAbsent(let missing):
            let names = missing.map(\.fileName).joined(separator: ", ")
            return "Mirror cannot read that Mac without its extensions. "
                 + "Not loaded: \(names). Install them in the Extensions "
                 + "folder and restart that Mac — an INIT loads at boot and "
                 + "at no other time."
        case .noProduct(let reason):
            return reason
        case .noCheckout:
            return "Build from source is on, but Mirror's checkout is not "
                 + "above this app. Turn the toggle off and name a built "
                 + "MirrorApp instead, or run this app from the repository."
        case .alreadyRunning:
            return "A Mirror instance from this page is already running."
        }
    }
}
