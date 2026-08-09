import Foundation

/// Refusing a parameter we do not understand, instead of ignoring it.
///
/// This exists because of a measured near-miss on 2026-07-31. A caller sent
/// `mirror.act.key {key: "q", modifiers: ["command"]}` — the contract's name for
/// that field is `mods` — and an unread `modifiers` is indistinguishable from
/// "no modifiers". So the service pressed an unmodified `q`, typed a literal
/// character into an open document, dirtied it, raised a save-changes alert,
/// and reported `performed: true`.
///
/// A misspelled *value* was already caught (`unknown mod command`). A misspelled
/// *key* was not, and that is the worse half, because the failure mode of a
/// dropped modifier is not "nothing happens" — it is "a different thing happens,
/// silently, and the reply says it worked". ⌘Q becomes typing `q`.
///
/// The rule this encodes: on a mutating surface, an input we do not recognise is
/// an error, never a default. An agent cannot see the machine, so a quiet wrong
/// action is far more expensive than a loud refusal.
public enum ParamCheck {

    /// Parameter names every method accepts: the request envelope rather than
    /// any one method's arguments.
    ///
    /// `settleTimeoutMs` is here because `performAct` reads it *after* the
    /// method has run, so a method's own signature never mentions it — and a
    /// gate that only knew the arguments a method reads directly would reject a
    /// parameter that has always worked. Finding this is the argument for
    /// deriving these sets from the code rather than from the contract prose.
    public static let envelope: Set<String> = ["session", "settle",
                                               "settleTimeoutMs"]

    /// The unrecognised keys in `params`, sorted for a stable message.
    /// Empty means the call is well-formed.
    public static func unknown(_ params: Set<String>,
                               known: Set<String>) -> [String] {
        params.subtracting(known).subtracting(envelope).sorted()
    }

    /// The refusal text. It names what we got *and* what the method accepts,
    /// because the whole point is to turn a typo into a fixable message — a
    /// bare "unknown parameter" leaves the caller guessing which spelling is
    /// the real one.
    public static func message(method: String,
                               got: [String],
                               known: Set<String>) -> String {
        let g = got.joined(separator: ", ")
        let w = known.sorted().joined(separator: ", ")
        return "\(method): unknown parameter(s) [\(g)]; accepts [\(w)]"
    }
}
