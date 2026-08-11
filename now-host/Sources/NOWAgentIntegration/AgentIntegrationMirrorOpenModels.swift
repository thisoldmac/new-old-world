import Foundation

/// What asking the host to open its Mirror produced.
///
/// **The one operation on this surface whose whole effect is on the
/// MODERN machine.** `reveal_item` is the closest relative and it still
/// crosses the wire — it asks the classic Mac's Finder. This one sends
/// nothing to a guest at all: it opens a window on the Mac the agent is
/// already talking to.
///
/// It exists because there was no way to. `--open-mirror` covers a
/// launch and a click covers a person sitting here; an agent on the
/// socket had neither, and the gap was closed in practice by scripting
/// macOS accessibility to press the button on somebody's actual
/// desktop. A missing affordance became a documented habit.
///
/// `alreadyOpen` is reported and is NOT a failure: the caller asked for
/// the Mirror to be showing, and it is. It rides along because an agent
/// that opened the window is in a different state to one that found it
/// open — the first has a poll that has just started and no scene yet.
public struct AgentIntegrationMirrorOpenResult:
    Codable, Equatable, Sendable {
    public let showing: Bool
    public let alreadyOpen: Bool
    /// The host's own sentence, the same one the guest's status line and
    /// this Mac's log get. One wording, three readers.
    public let detail: String
    public let unavailable: AgentIntegrationUnavailable?

    public init(alreadyOpen: Bool, detail: String) {
        showing = true
        self.alreadyOpen = alreadyOpen
        self.detail = detail
        unavailable = nil
    }

    public init(unavailable: AgentIntegrationUnavailable) {
        showing = false
        alreadyOpen = false
        detail = unavailable.message
        self.unavailable = unavailable
    }
}
