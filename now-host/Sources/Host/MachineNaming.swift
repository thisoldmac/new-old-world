import Foundation

/// What to call a machine, anywhere a person reads it.
///
/// Every sentence in this app has two candidate referents — the Mac it runs
/// on and the Mac it drives — and the copy used to choose a phrase per site:
/// "the other Mac", "the connected Mac", "the classic Mac", "the guest",
/// and "this Mac" for BOTH of them. Some of that was merely inconsistent.
/// Some of it named the wrong machine, which a reader has no way to detect.
///
/// The rule lives here so a call site picks a POSITION rather than a phrase:
///
/// - The machine being driven is called by **its own name** whenever the
///   host knows one. A name beats every generic phrase — "Zulu's screen",
///   never "the old world mac's screen", once Zulu has said who it is.
/// - With no name there are two registers, and they are not
///   interchangeable: `Old World Mac` is the proper noun, for title and
///   name position, and `the old world mac` is the plain reference, for
///   running prose. The lowercase is deliberate; it is a description there,
///   not a name.
/// - The machine this app runs on is `this Mac`, and nothing else ever is.
///
/// "Guest" and "host" stay out of what a person reads. They are the words
/// this codebase thinks in, and on screen they name neither machine.
enum MachineNaming {

    /// The Mac this app is running on. One phrase, no synonyms — "the local
    /// Mac", "this machine" and "this side" all mean it too, and having
    /// four ways to say it is how a reader stopped being able to tell which
    /// machine any given sentence was about.
    static let thisMac = "this Mac"

    /// Name position: a title, a heading, a menu item, a column label —
    /// anywhere the phrase stands where a name would stand.
    static let properNoun = "Old World Mac"
    static let properNounPlural = "Old World Macs"

    /// Sentence position, article supplied by the call site ("no old world
    /// mac", "another old world mac").
    static let commonNoun = "old world mac"
    static let commonNounPlural = "old world macs"

    /// Sentence position, the ordinary case: "waiting for the old world mac
    /// to answer".
    static let simpleReference = "the \(commonNoun)"

    /// The machine in name position: its own name if it has one, otherwise
    /// the proper noun.
    static func title(_ name: String?) -> String {
        normalized(name) ?? properNoun
    }

    /// The machine in sentence position: its own name if it has one,
    /// otherwise the plain reference.
    static func sentence(_ name: String?) -> String {
        normalized(name) ?? simpleReference
    }

    /// The machine as the owner of something — "Zulu's screen", "the old
    /// world mac's share".
    ///
    /// A machine name ending in `s` takes the bare apostrophe, because the
    /// alternative is `Atlas's`, and these names are read at a glance in a
    /// table cell rather than in prose.
    static func possessive(_ name: String?) -> String {
        possessiveForm(sentence(name))
    }

    /// Several machines in one sentence, and the none case beside them,
    /// because a list of connected machines is empty far more often than a
    /// site remembers to handle separately.
    ///
    /// Unnamed machines collapse rather than repeat: two of them written
    /// out in full would be "the old world mac and the old world mac",
    /// which reads as one machine counted twice.
    static func several(_ names: [String?]) -> String {
        let named = names.compactMap(normalized)
        let unnamed = names.count - named.count
        var parts = named
        if unnamed == 1 {
            parts.append("an unnamed \(properNoun)")
        } else if unnamed > 1 {
            parts.append("\(unnamed) unnamed \(properNounPlural)")
        }
        guard let last = parts.last else { return "no \(commonNoun)" }
        guard parts.count > 1 else { return last }
        return parts.dropLast().joined(separator: ", ") + " and \(last)"
    }

    /// The same phrase where a sentence begins.
    ///
    /// Only the first character moves, so "the old world mac’s" becomes
    /// "The old world mac’s" and a machine's own name is left exactly as it
    /// spells itself — a site that reached for `.capitalized` instead would
    /// turn "pb1400c" into "Pb1400C".
    static func startingSentence(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased() + text.dropFirst()
    }

    // MARK: - The connection a module already holds

    /// A module holds `GuestConnectionState`, not a name, and each of them
    /// was unwrapping it into a phrase of its own. These three are the same
    /// three accessors reading that state, so a page never has to decide
    /// what "disconnected" is called.
    static func title(_ state: GuestConnectionState) -> String {
        title(name(of: state))
    }

    static func sentence(_ state: GuestConnectionState) -> String {
        sentence(name(of: state))
    }

    static func possessive(_ state: GuestConnectionState) -> String {
        possessive(name(of: state))
    }

    private static func name(of state: GuestConnectionState) -> String? {
        if case .connected(let name, _) = state { return name }
        return nil
    }

    /// Nil for every string that is not actually a name.
    ///
    /// The placeholders matter as much as the empty string: the host writes
    /// `Session.unnamedGuest` into its own registry when a machine says
    /// nothing about itself, so that value reaches display code as a
    /// perfectly ordinary name and would otherwise be shown as one.
    private static func normalized(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !placeholders.contains(trimmed.lowercased())
        else { return nil }
        return trimmed
    }

    private static let placeholders: Set<String> = [
        Session.unnamedGuest.lowercased(), "classic mac", "unknown",
        properNoun.lowercased(),
    ]

    private static func possessiveForm(_ text: String) -> String {
        text.lowercased().hasSuffix("s") ? "\(text)’" : "\(text)’s"
    }
}
