import Foundation

/// Somewhere on the other machine worth one click, and how we came to
/// believe it is there.
///
/// **The share root bounds all of this.** Every path on the wire is
/// relative to the folder that machine publishes, and a path outside it is
/// not merely refused — it is inexpressible (`contract/asyncapi.yaml`,
/// `hostBrowsesFiles`). So a sidebar of "System Folder", "Extensions",
/// "Applications" is a sidebar of places *inside the share*, and on a
/// machine sharing something narrower most of them will simply not be
/// there. That is the omission rule below, not a bug in it.
struct FileLocation: Identifiable, Codable, Equatable {
    /// Relative to the share root, exactly as `file.list` wants it; `""`
    /// is the root. Also the identity — two rows naming one folder are one
    /// row, whichever route found them.
    var path: String
    /// In the machine's own spelling wherever we could ask it for one.
    var name: String
    var symbol: String
    var origin: Origin

    /// How this row got here, kept because the three routes are not
    /// equally trustworthy and a person deserves to be told which one
    /// answered.
    enum Origin: String, Codable {
        /// The share root. Always present; there is nothing to discover.
        case root
        /// The **Folder Manager** answered. `FindFolder` resolved it on
        /// that machine, so the name is that machine's own — localised,
        /// renamed, wherever it actually lives.
        case folderManager
        /// A guessed name that turned out to exist. Honest about being a
        /// guess: nothing on classic Mac OS registers "Applications".
        case probed
        /// A person dragged it in.
        case pinned
    }

    var id: String { path }

    /// Discovered rows are replaced wholesale on every discovery; pinned
    /// ones are the person's and outlive it.
    var isPinned: Bool { origin == .pinned }
}

/// What is actually knowable about a classic Mac's folders, and by which
/// route.
///
/// The investigation this encodes, because the answer is not obvious and
/// getting it wrong means a sidebar full of folders that are not there:
///
/// - **The System Folder and its special children are tracked by the OS.**
///   `FindFolder(kSystemFolderType / kExtensionFolderType /
///   kControlPanelFolderType / kStartupFolderType /
///   kAppleMenuFolderType / kPreferencesFolderType / kFontsFolderType /
///   kDesktopFolderType, …)` answers with a real vRefNum and dirID
///   whatever the folder is *called*. Their names are localised on a
///   localised system and a person may rename several of them; the
///   Folder Manager keeps up, a hardcoded string does not.
/// - **`Applications` is not tracked by anything.** It is an ordinary
///   folder a person made, renamed and localised in practice
///   ("Applications (Mac OS 9)" after an OS X install is the common one),
///   and there is no OS call that answers "where do applications live".
///   Guessing is the only route, which is why guessing is a declared
///   `origin` here rather than hidden.
/// - **This contract exposes no FindFolder verb.** No message and no
///   `x-commands` verb asks "where is folder type X" — see
///   `docs/contract-coverage.md`. What it *does* expose is
///   `software.list`, whose `extensions` / `cdevs` / `startup` / `apple`
///   domains are documented as "enumerate the System Folder's special
///   folders" and whose entries carry a **full HFS path**. Both guests
///   resolve those domains with `FindFolder` (`now-guest-ppc/src/software/
///   software.c`, `now-guest-68k/src/software/n68_swenum.c`), so the
///   parent directory of any entry it returns *is* the Folder
///   Manager's answer, arrived at the long way round. That is the
///   `folderManager` route: real discovery, no contract change.
///
/// Everything else is probed — ask for the listing, keep it if it comes
/// back, omit it silently if it does not.
enum ClassicLocations {
    /// A guessed folder: what to call it, and the names to try in order.
    struct Candidate {
        var name: String
        var symbol: String
        /// Tried in order; the first that lists is the one we keep.
        var names: [String]
        /// True when these names hang off the System Folder rather than
        /// the share root, so the discovered System Folder path (which
        /// may be localised) is the prefix rather than the literal
        /// "System Folder".
        var insideSystemFolder = false
    }

    /// The System Folder itself, for the case where `software.list`
    /// refused and there is nothing but a guess left. Kept apart from
    /// `candidates` because its answer is the *prefix* for the rest.
    static let systemFolder = Candidate(
        name: "System Folder", symbol: "gearshape",
        names: ["System Folder", "Systemordner", "Dossier Système",
                "Cartella Sistema", "Carpeta Sistema",
                "Systeemmap", "Systemmapp"])

    /// The domains `software.list` serves that are FindFolder-resolved,
    /// paired with what the folder they live in should be called here.
    /// The 4CC-ish domain strings are the contract's, not ours.
    static let folderManagerDomains: [(domain: String, name: String,
                                       symbol: String)] = [
        ("extensions", "Extensions", "puzzlepiece.extension"),
        ("cdevs", "Control Panels", "slider.horizontal.3"),
        ("startup", "Startup Items", "power"),
        ("apple", "Apple Menu Items", "apple.logo"),
    ]

    /// Everything with no OS call behind it. Order is the order the
    /// sidebar shows them in before a person rearranges it.
    static let candidates: [Candidate] = [
        Candidate(name: "Applications", symbol: "app.dashed",
                  names: ["Applications", "Applications (Mac OS 9)",
                          "Applications (Mac OS X)", "Programme",
                          "Aplicaciones", "Applicazioni",
                          "Programmes", "Apps"]),
        Candidate(name: "Documents", symbol: "doc.on.doc",
                  names: ["Documents", "Dokumente", "Documenti",
                          "Documentos"]),
        // Invisible in the Finder, and a real folder the Folder Manager
        // tracks (kDesktopFolderType) — a listing of the volume root may
        // not show it, so it is probed directly rather than looked for.
        Candidate(name: "Desktop Folder", symbol: "menubar.dock.rectangle",
                  names: ["Desktop Folder", "Schreibtisch-Ordner",
                          "Dossier Bureau"]),
        Candidate(name: "Trash", symbol: "trash",
                  names: ["Trash", "Papierkorb", "Corbeille", "Cestino",
                          "Papelera"]),
        // FindFolder tracks both of these (kPreferencesFolderType,
        // kFontsFolderType) and nothing on this wire will say so, so
        // their names are guessed even though the OS knows them. This is
        // the clearest thing a `folder.find` verb would buy.
        Candidate(name: "Preferences", symbol: "slider.horizontal.below.rectangle",
                  names: ["Preferences", "Preferences Folder",
                          "Voreinstellungen", "Préférences",
                          "Preferenze", "Preferencias"],
                  insideSystemFolder: true),
        Candidate(name: "Fonts", symbol: "textformat",
                  names: ["Fonts", "Zeichensätze", "Polices", "Caratteri",
                          "Fuentes"],
                  insideSystemFolder: true),
    ]

    /// The row that is always there: the folder the machine publishes.
    /// Named by the machine's own spelling of it when it has sent one.
    static func rootLocation(shareRoot: String?) -> FileLocation {
        let trimmed = shareRoot?.trimmingCharacters(in: .whitespaces) ?? ""
        return FileLocation(
            path: "",
            name: trimmed.isEmpty ? "Shared Folder" : leafName(of: trimmed),
            symbol: "externaldrive",
            origin: .root)
    }

    /// "Macintosh HD:Lab:" -> "Lab"; "Macintosh HD:" -> "Macintosh HD".
    static func leafName(of hfsPath: String) -> String {
        let parts = hfsPath.split(separator: ":", omittingEmptySubsequences: true)
        return parts.last.map(String.init) ?? hfsPath
    }
}

/// The pure half of discovery: turning what a machine said into a path
/// this browser can use. Separated from the asking so the rules can be
/// tested without a wire — the rules are where the mistakes live.
enum FileLocationResolver {
    /// A full HFS path from `software.listing`, expressed relative to the
    /// share root. Nil when the item is **outside the share**, which is
    /// the ordinary case on a machine that publishes one project folder
    /// rather than the whole disk — and the reason a location can be
    /// genuinely discovered and still not belong in this sidebar.
    ///
    /// Comparison is case-insensitive because HFS is, and a machine that
    /// spells its own volume "Macintosh HD:" in one message and
    /// "MACINTOSH HD:" in another is not describing two disks.
    static func relative(_ hfsPath: String, under shareRoot: String?)
        -> String? {
        let item = hfsPath.trimmingCharacters(in: .whitespaces)
        guard !item.isEmpty else { return nil }
        guard var root = shareRoot?.trimmingCharacters(in: .whitespaces),
              !root.isEmpty else { return nil }
        if !root.hasSuffix(":") { root += ":" }
        guard item.count > root.count,
              item.lowercased().hasPrefix(root.lowercased()) else {
            // The share root itself is not a location *inside* the share,
            // and anything above or beside it is unreachable from here.
            return nil
        }
        let rest = String(item.dropFirst(root.count))
        return rest.isEmpty ? nil : rest
    }

    /// The enclosing folder of a share-relative path; nil at the root,
    /// because the root has no parent that can be expressed on this wire.
    static func parent(of relative: String) -> String? {
        guard let colon = relative.lastIndex(of: ":") else { return nil }
        let parent = String(relative[relative.startIndex..<colon])
        return parent.isEmpty ? nil : parent
    }

    /// The Folder Manager's answer behind one `software.listing` page:
    /// the folder its entries live in, share-relative.
    ///
    /// **Disabled siblings are skipped.** Those domains enumerate
    /// "Extensions (Disabled)" alongside "Extensions", and taking the
    /// parent of a disabled entry would name the wrong folder — one that
    /// exists, which is worse than one that does not. Entries with an
    /// empty path are skipped too: the guest sends those when it could not
    /// walk the parent chain honestly, and a truncated path is not a
    /// shorter path.
    static func folder(fromSoftware entries: [SoftwareEntry],
                       shareRoot: String?) -> String? {
        for entry in entries where entry.off != true && !entry.path.isEmpty {
            guard let relative = relative(entry.path, under: shareRoot),
                  let parent = parent(of: relative) else { continue }
            return parent
        }
        return nil
    }

    /// Joins a share-relative folder to a child name. `""` is the root, so
    /// a child of it carries no leading colon — an empty segment is a
    /// `bad-path` refusal by contract, not a no-op.
    static func join(_ folder: String, _ child: String) -> String {
        folder.isEmpty ? child : folder + ":" + child
    }

    /// Wire failures that mean "ask again later", as against "that folder
    /// is not there". Everything else is an ordinary refusal and the
    /// location is omitted; these abandon the whole sweep, because a
    /// discovery run that carried on through a disconnect would record
    /// every remaining location as missing on the strength of the wire
    /// having gone away.
    static let fatalCodes: Set<String> = [
        "disconnected", "timeout", "cancelled",
    ]

    static func isFatal(_ code: String) -> Bool { fatalCodes.contains(code) }
}

/// What a person did to their sidebar, per machine, across restarts.
///
/// Three lists rather than one, because the three survive different
/// things. Discovery is re-run on every connection and its results are
/// never stored — a folder that was there last week and is not there today
/// must not linger. What IS stored is only what a person decided:
/// somewhere they added, somewhere they threw out, and the arrangement.
///
/// The ordering rule is `SidebarPreferences.sanitised` in another
/// vocabulary, and deliberately the same rule: ids nobody recognises are
/// dropped, ids nobody arranged are appended in discovery order. That is
/// what lets a NEW location — a System Folder that appeared because
/// somebody widened the share — arrive at the foot of an arrangement
/// already saved, instead of invalidating it.
///
/// **Keyed by MACHINE, not by session.** `GuestKey` is per connection, so
/// keying on it would give a person a fresh empty sidebar every time their
/// Mac dialled back in.
@MainActor
final class FileLocationsStore {
    struct Stored: Codable, Equatable {
        var pinned: [FileLocation] = []
        /// Paths of discovered locations a person threw out. Stored rather
        /// than forgotten, so the next discovery does not put them back.
        var hidden: [String] = []
        /// Arrangement, by path.
        var order: [String] = []
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = ProductIdentity.defaults) {
        self.defaults = defaults
    }

    /// One machine's file, under its stable handle. A machine with no
    /// handle (nothing connected) reads and writes nothing.
    private func key(for machine: GuestID?) -> String? {
        machine.map { "files.locations.\($0.slug)" }
    }

    func load(for machine: GuestID?) -> Stored {
        guard let key = key(for: machine),
              let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return Stored() }
        return stored
    }

    func save(_ stored: Stored, for machine: GuestID?) {
        guard let key = key(for: machine) else { return }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: key)
    }

    /// What the sidebar shows: this run's discoveries minus what was
    /// thrown out, plus what a person pinned, in the arrangement they
    /// chose.
    ///
    /// Pure and static so the rule can be tested without a defaults suite
    /// — the part worth testing is the merge, not the plumbing.
    static func merge(discovered: [FileLocation],
                      stored: Stored) -> [FileLocation] {
        let hidden = Set(stored.hidden)
        var byPath: [String: FileLocation] = [:]
        var discoveryOrder: [String] = []
        for location in discovered where !hidden.contains(location.path) {
            if byPath[location.path] == nil { discoveryOrder.append(location.path) }
            byPath[location.path] = location
        }
        /* A pin never masks a discovery. If a person pinned "System
           Folder:Extensions" by hand and the Folder Manager later named
           the same folder, that is ONE row and the discovered one wins:
           its name came from the machine. */
        for pin in stored.pinned where byPath[pin.path] == nil {
            byPath[pin.path] = pin
            discoveryOrder.append(pin.path)
        }
        var seen = Set<String>()
        var result: [FileLocation] = []
        for path in stored.order {
            guard let location = byPath[path], seen.insert(path).inserted
            else { continue }
            result.append(location)
        }
        for path in discoveryOrder where !seen.contains(path) {
            guard let location = byPath[path] else { continue }
            seen.insert(path)
            result.append(location)
        }
        return result
    }
}
