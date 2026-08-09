import Foundation

/// Changing the shared folder from here.
///
/// Three rules shape this file:
///
/// * **Nothing commits without being asked.** Renames are easy to mean;
///   moving and deleting are not, and a drag that lands one row off is
///   silent otherwise. Every change is described in words first.
/// * **Delete means the Trash.** It is what a human expects on that
///   machine, and it is the only honest basis for an undo — an unlinked
///   file has nowhere to come back from.
/// * **The history lives here, the mechanism lives there.** The other
///   machine performs the change and hands back what it needs to reverse
///   it; this side remembers the order things happened in. Every reversal
///   is expressed in names on both ends — including undoing a delete,
///   where the item is named by where it landed in the Trash — so a
///   change stays undoable across a restart of either side. The history
///   itself is session-local: it is a list of what *this* window did.
extension FilesModuleModel {

    /// A change described but not yet made. The wording is the point —
    /// this is what the confirmation reads out.
    struct PendingChange: Identifiable, Equatable {
        enum Kind: Equatable {
            case rename(path: String, to: String)
            case move(paths: [String], toFolder: String)
            case trash(paths: [String])
        }

        var id = UUID()
        var kind: Kind

        var title: String {
            switch kind {
            case .rename: return "Rename this item?"
            case .move(let paths, _):
                return paths.count == 1
                    ? "Move this item?" : "Move \(paths.count) items?"
            case .trash(let paths):
                return paths.count == 1
                    ? "Move this item to the Trash?"
                    : "Move \(paths.count) items to the Trash?"
            }
        }

        var detail: String {
            switch kind {
            case .rename(let path, let to):
                return "\"\(FileChangeNames.leaf(path))\" becomes \"\(to)\"."
            case .move(let paths, let folder):
                let into = folder.isEmpty
                    ? "the top of the shared folder" : "\"\(folder)\""
                return paths.count == 1
                    ? "\"\(FileChangeNames.leaf(paths[0]))\" moves to \(into)."
                    : "\(paths.count) items move to \(into)."
            case .trash(let paths):
                let names = paths.prefix(3)
                    .map { "\"\(FileChangeNames.leaf($0))\"" }
                    .joined(separator: ", ")
                let rest = paths.count > 3
                    ? " and \(paths.count - 3) more" : ""
                return names + rest
                    + " will be in the Trash, and can be put back until "
                    + "it is emptied."
            }
        }

        var confirmLabel: String {
            if case .trash = kind { return "Move to Trash" }
            if case .rename = kind { return "Rename" }
            return "Move"
        }
    }

    /// One completed change, and everything needed to reverse it.
    struct FileChange: Identifiable, Equatable {
        enum Undo: Equatable {
            /// Reversed by moving it back.
            case moved(from: String, to: String)
            /// Reversed by moving it back out of the Trash. Both halves
            /// are names — what it is called in there, and where it
            /// belongs — so this outlives a restart of either side.
            case trashed(path: String, trashedAs: String)
            /// Reversed by trashing what we made.
            case created(path: String)
        }

        var id = UUID()
        var undo: Undo
        var at = Date()

        var summary: String {
            switch undo {
            case .moved(let from, let to):
                let a = FileChangeNames.leaf(from)
                let b = FileChangeNames.leaf(to)
                return a == b
                    ? "Moved \"\(a)\"" : "Renamed \"\(a)\" to \"\(b)\""
            case .trashed(let path, _):
                return "Trashed \"\(FileChangeNames.leaf(path))\""
            case .created(let path):
                return "Created \"\(FileChangeNames.leaf(path))\""
            }
        }

        var undoLabel: String {
            switch undo {
            case .moved: return "Undo Move"
            case .trashed: return "Undo Delete"
            case .created: return "Undo New Folder"
            }
        }
    }

    // MARK: - Asking

    func requestRename(_ row: FileRow, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != row.name else { return }
        guard let checked = FileChangeNames.validate(trimmed) else {
            reportChangeFailure(FileChangeNames.nameComplaint(trimmed))
            return
        }
        pendingChange = .init(kind: .rename(path: row.path, to: checked))
    }

    func requestTrash(_ rows: [FileRow]) {
        guard canBrowse, !isChanging, !rows.isEmpty else { return }
        pendingChange = .init(kind: .trash(paths: rows.map(\.path)))
    }

    func requestMove(_ rows: [FileRow], toFolder folder: String) {
        let moving = rows.filter { row in
            // Moving a folder into itself is not a change, it is a loop.
            folder != row.path && !folder.hasPrefix(row.path + ":")
                && FileChangeNames.parent(row.path) != folder
        }
        guard !moving.isEmpty else { return }
        pendingChange = .init(kind: .move(paths: moving.map(\.path),
                                          toFolder: folder))
    }

    func cancelPendingChange() {
        pendingChange = nil
    }

    // MARK: - Committing

    func commitPendingChange() {
        guard let pending = pendingChange else { return }
        pendingChange = nil
        switch pending.kind {
        case .rename(let path, let name):
            let destination = FileChangeNames.join(
                FileChangeNames.parent(path), name)
            move(one: path, to: destination, remaining: [])
        case .move(let paths, let folder):
            guard let first = paths.first else { return }
            let rest = Array(paths.dropFirst())
            move(one: first,
                 to: FileChangeNames.join(folder,
                                          FileChangeNames.leaf(first)),
                 remaining: rest.map { (path: $0, folder: folder) })
        case .trash(let paths):
            trash(paths)
        }
    }

    /// One move at a time: the wire answers one change at a time, and
    /// running them in order is what lets a failure stop the rest rather
    /// than leave a half-done multi-select.
    private func move(one path: String, to destination: String,
                      remaining: [(path: String, folder: String)]) {
        isChanging = true
        listener.moveFile(from: path, to: destination) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success:
                    self.record(.init(undo: .moved(from: path,
                                                   to: destination)))
                    guard let next = remaining.first else {
                        self.finishChanging()
                        return
                    }
                    self.move(one: next.path,
                              to: FileChangeNames.join(
                                  next.folder,
                                  FileChangeNames.leaf(next.path)),
                              remaining: Array(remaining.dropFirst()))
                case .failure(let error):
                    self.finishChanging(error: error.message)
                }
            }
        }
    }

    private func trash(_ paths: [String]) {
        guard let path = paths.first else {
            finishChanging()
            return
        }
        isChanging = true
        listener.trashFile(path: path) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let answer):
                    self.record(.init(undo: .trashed(
                        path: path,
                        trashedAs: answer.trashedAs
                            ?? FileChangeNames.leaf(path))))
                    self.trash(Array(paths.dropFirst()))
                case .failure(let error):
                    self.finishChanging(error: error.message)
                }
            }
        }
    }

    func createFolder(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let checked = FileChangeNames.validate(trimmed) else {
            reportChangeFailure(FileChangeNames.nameComplaint(trimmed))
            return
        }
        let full = FileChangeNames.join(path, checked)
        isChanging = true
        listener.makeFolder(path: full) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success:
                    self.record(.init(undo: .created(path: full)))
                    self.finishChanging()
                case .failure(let error):
                    self.finishChanging(error: error.message)
                }
            }
        }
    }

    // MARK: - Undo

    var undoTitle: String? { history.last?.undoLabel }

    func undoLastChange() {
        guard let change = history.last else { return }
        isChanging = true
        let done: (Result<FileResult, GuestListener.FileFailure>) -> Void =
            { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    switch result {
                    case .success:
                        if !self.history.isEmpty { self.history.removeLast() }
                        self.finishChanging()
                    case .failure(let error):
                        // An undo that can never happen is not worth
                        // keeping on the stack: an item that has left the
                        // Trash is not coming back. Anything else might
                        // work on a second try, so it stays.
                        if error.code == "not-found", !self.history.isEmpty {
                            self.history.removeLast()
                        }
                        self.finishChanging(error: error.message)
                    }
                }
            }
        switch change.undo {
        case .moved(let from, let to):
            listener.moveFile(from: to, to: from, completion: done)
        case .trashed(let path, let trashedAs):
            listener.restoreFile(trashedAs: trashedAs, to: path,
                                 completion: done)
        case .created(let path):
            listener.trashFile(path: path, completion: done)
        }
    }

    func clearHistory() {
        history = []
    }

    // MARK: - Bookkeeping

    private func record(_ change: FileChange) {
        history.append(change)
        // A session's worth, not a lifetime's: the oldest entries are the
        // least likely to still be reversible anyway.
        if history.count > 50 { history.removeFirst() }
    }

    private func finishChanging(error: String? = nil) {
        isChanging = false
        if let error { reportChangeFailure(error) } else { reportChangeOK() }
        refresh()
    }
}

/// Path arithmetic for the guest's share: colon-separated, relative to
/// the share root, and bounded by what HFS will accept.
enum FileChangeNames {

    /// The named segments of an HFS colon-path, in order.
    ///
    /// This is the host's ONE splitter, and everything that needs the
    /// pieces of a path asks it rather than spelling `split` again — the
    /// path bar included. The rule it splits by is
    /// `contract/share_path.h` (`now_share_path_ok`), which both guests
    /// compile and `now-guest-ppc/tests/share_path_test.c` pins:
    ///
    /// * `:` separates, and is therefore the one character a name cannot
    ///   contain. Nothing else is special — `.`, `..`, `/`, spaces and
    ///   high-MacRoman bytes are all ordinary characters in an HFS name,
    ///   which is exactly why a POSIX-minded splitter must not be used
    ///   here. `Lab:..:Code` is three real folders, not a traversal.
    /// * A TRAILING colon names a folder and adds no segment, so
    ///   `"Macintosh HD:"` is one segment, the volume.
    /// * Any OTHER empty segment means "the parent", which the guest
    ///   refuses outright — such a path never becomes a listing, so it
    ///   never reaches a crumb. Dropping empties here matches that: what
    ///   is left is the named segments, and there is nothing to name in
    ///   an ascent the other machine would not perform.
    static func components(_ path: String) -> [String] {
        path.split(separator: ":").map(String.init)
    }

    static func leaf(_ path: String) -> String {
        components(path).last ?? path
    }

    static func parent(_ path: String) -> String {
        var parts = components(path)
        guard parts.count > 1 else { return "" }
        parts.removeLast()
        return parts.joined(separator: ":")
    }

    static func join(_ folder: String, _ name: String) -> String {
        folder.isEmpty ? name : folder + ":" + name
    }

    /// A name HFS will take, or nil. Colons are the separator, so a name
    /// containing one is not a name.
    /// What a person is told the limit is. The enforced rule is
    /// `hfsName`, which counts BYTES — this is the same number in the
    /// common case and the honest way to say it in a sentence.
    static let maxNameLength = 31

    /// A name is acceptable exactly when the conversion would leave it
    /// alone.
    ///
    /// This used to have its own rule — no colon, 31 CHARACTERS — while
    /// `OutboundFile.hfsName` enforced 31 BYTES. An accented name of 31
    /// characters passed here and was then silently truncated on the way
    /// out, so the file that arrived was not the one that was named. Two
    /// spellings of one rule always drift; this asks the rule itself.
    static func validate(_ name: String) -> String? {
        guard !name.isEmpty, !name.contains(HostShare.separator),
              OutboundFile.hfsName(name) == name else { return nil }
        return name
    }

    static func nameComplaint(_ name: String) -> String {
        if name.isEmpty { return "A name cannot be empty." }
        if name.contains(":") {
            return "Names on that machine cannot contain a colon."
        }
        return "Names on that machine are limited to "
            + "\(maxNameLength) characters."
    }
}
