import Foundation

/// One catalog mutation, as a caller may state it — and the bound every
/// face applies before a Macintosh hears about it.
///
/// It exists as a type rather than four parameters because the **authority
/// model is per-intention and the key sets differ**: a `move` names where it
/// is going, a `restore` names what the Trash calls it, and `trash`/`mkdir`
/// name one path and nothing else. The local wire already refuses the
/// crossed forms (`AgentIntegrationLocalRequest`'s `guestFileMutation`
/// branch); this is the same rule stated once on this side, so a face that
/// composes a request cannot invent a shape the wire will reject and a
/// second face cannot invent a laxer one.
///
/// **The initialisers are failable on purpose.** There is no way to hold an
/// invalid mutation: every refusal below is a refusal the caller gets before
/// anything is sent, and a projection that gets `nil` knows only that it may
/// not proceed — which is exactly what it should tell its caller.
public struct AgentIntegrationGuestFileMutationRequest:
    Codable, Equatable, Sendable {
    public let mutation: AgentIntegrationGuestFileMutation
    /// The item the mutation is about, root-relative — or, for a `restore`,
    /// where the item is going back to. Never empty: `guestRoot` itself is
    /// not something an agent may move, trash or recreate.
    public let path: String
    /// Where a `move` is going, including the item's new name. Nil on every
    /// other intention.
    public let destinationPath: String?
    /// The name a `trash` reported, which is the only key a `restore` takes.
    /// Nil on every other intention.
    public let trashedAs: String?

    private init(mutation: AgentIntegrationGuestFileMutation,
                 path: String,
                 destinationPath: String?,
                 trashedAs: String?) {
        self.mutation = mutation
        self.path = path
        self.destinationPath = destinationPath
        self.trashedAs = trashedAs
    }

    /// Move or rename. `toPath` carries the destination **including the new
    /// name**, because on this file system a rename and a move are one
    /// operation (docs/files.md).
    ///
    /// Three refusals, and each is the host bounding what the guest is asked
    /// rather than predicting what it would answer:
    ///
    /// - an empty source or destination, which would name `guestRoot`;
    /// - a destination equal to the source, which is not a change;
    /// - a destination **inside** the source, which is not a move but a
    ///   loop, and is the one shape of this request that can leave a folder
    ///   unreachable rather than merely misplaced.
    ///
    /// Note what is NOT refused here: a destination that already exists.
    /// That is the guest's answer, given atomically at the moment it acts
    /// (`exists`), and a host that checked first would be substituting a
    /// stale observation for a live one.
    public static func move(path: String, toPath: String) -> Self? {
        guard isAddressable(path), isAddressable(toPath),
              toPath != path, !toPath.hasPrefix(path + ":") else {
            return nil
        }
        return .init(mutation: .move, path: path,
                     destinationPath: toPath, trashedAs: nil)
    }

    /// To the Trash, reversibly. There is deliberately no unlink on this
    /// surface: the contract's verb is `file.trash`, and the reply's
    /// `trashedAs` is the only key that undoes it.
    public static func trash(path: String) -> Self? {
        guard isAddressable(path) else { return nil }
        return .init(mutation: .trash, path: path,
                     destinationPath: nil, trashedAs: nil)
    }

    /// Back out of the Trash, by the name the trashing reported, to where it
    /// came from. The host remembers no trash keys — the contract keeps that
    /// state on neither side — so possession of the name IS the authority to
    /// restore, and it belongs to whoever performed the trash.
    public static func restore(trashedAs: String, toPath: String) -> Self? {
        guard isAddressable(toPath), isTrashName(trashedAs) else {
            return nil
        }
        return .init(mutation: .restore, path: toPath,
                     destinationPath: nil, trashedAs: trashedAs)
    }

    /// Create one folder. One, and not a tree: a missing parent is a typo,
    /// and building the path it implies is how a wrong tree gets made
    /// quietly (docs/files.md, "Shape on the wire").
    public static func makeFolder(path: String) -> Self? {
        guard isAddressable(path) else { return nil }
        return .init(mutation: .mkdir, path: path,
                     destinationPath: nil, trashedAs: nil)
    }

    /// Non-empty and within the wire's path bound. Canonical HFS spelling
    /// and the composition beneath `guestRoot` are the command layer's —
    /// `GuestFilePath` owns that rule and there is only one of it.
    private static func isAddressable(_ path: String) -> Bool {
        !path.isEmpty
            && AgentIntegrationGuestFilePolicy.isBoundedPath(path)
    }

    /// A name inside the Trash is a NAME, not a path: one HFS segment, no
    /// separator. A colon here would be a caller trying to reach out of the
    /// Trash folder through the one field that is not composed beneath
    /// `guestRoot`.
    private static func isTrashName(_ value: String) -> Bool {
        !value.isEmpty
            && value.unicodeScalars.count
                <= AgentIntegrationGuestFilePolicy.maximumSegmentScalars
            && !value.contains(":")
    }
}
