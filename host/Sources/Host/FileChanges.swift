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
///   it; this side remembers the order things happened in. The history is
///   session-local by design: it is a list of what *this* window did, and
///   it does not pretend to survive either side restarting.
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
            /// Reversed by the token the other side issued. A token is
            /// only meaningful while that process runs, which is why an
            /// undo can fail honestly rather than guess at a path.
            case trashed(path: String, token: Int)
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
        guard !rows.isEmpty else { return }
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
                        path: path, token: answer.token ?? 0)))
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
                        // An undo that cannot happen is not a reason to
                        // keep offering it: drop it, and say why.
                        if error.code == "unknown-token",
                           !self.history.isEmpty {
                            self.history.removeLast()
                        }
                        self.finishChanging(error: error.message)
                    }
                }
            }
        switch change.undo {
        case .moved(let from, let to):
            listener.moveFile(from: to, to: from, completion: done)
        case .trashed(_, let token):
            listener.restoreFile(token: token, completion: done)
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
    static let maxNameLength = 31

    static func leaf(_ path: String) -> String {
        path.split(separator: ":").last.map(String.init) ?? path
    }

    static func parent(_ path: String) -> String {
        var parts = path.split(separator: ":").map(String.init)
        guard parts.count > 1 else { return "" }
        parts.removeLast()
        return parts.joined(separator: ":")
    }

    static func join(_ folder: String, _ name: String) -> String {
        folder.isEmpty ? name : folder + ":" + name
    }

    /// A name HFS will take, or nil. Colons are the separator, so a name
    /// containing one is not a name.
    static func validate(_ name: String) -> String? {
        guard !name.isEmpty, !name.contains(":"),
              name.count <= maxNameLength else { return nil }
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
