import Combine
import Foundation
import NOWAgentIntegration

/// The app's view of what has reached the local agent endpoint.
///
/// Thin on purpose: the ledger lives in `AgentIntegrationLocalServer`, where
/// the connections are, and this is the main-actor perch a pane can observe.
/// It exists at all — rather than the pane reading
/// `server.companionActivity` — because the interesting facts are
/// transitions, and a pane that polled a getter would miss every request,
/// each of which is over in milliseconds.
///
/// **It is present whether or not the server ever starts.** Failure to stand
/// up the local endpoint must never become a prerequisite for the human
/// product (see `startAgentIntegrationServer`), and a module reading this
/// then gets the honest `.neverAttached`, which is also the correct answer
/// for a host whose endpoint never opened: nothing has reached it.
@MainActor
final class AgentCompanionModel: ObservableObject {
    @Published private(set) var activity: AgentCompanionActivity = .none

    /// What to tell a person right now. A method rather than a published
    /// property because it is derived from the clock as well as the ledger:
    /// a companion goes from active to idle with nothing happening, so a
    /// stored value would be stale exactly when nothing was there to
    /// refresh it.
    func presence(asOf now: Date = Date()) -> AgentCompanionPresence {
        activity.presence(asOf: now)
    }

    func update(_ activity: AgentCompanionActivity) {
        self.activity = activity
    }
}
