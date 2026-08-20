import Foundation

/// The main-actor perch for OAuth consent. The authority parks each
/// /authorize request until a person answers the row this model publishes;
/// Approve and Deny resolve that parked connection.
@MainActor
final class MCPOAuthConsentModel: ObservableObject {
    @Published private(set) var pending: [MCPOAuthConsentRequest] = []

    private var authority: MCPOAuthAuthority?

    func attach(_ authority: MCPOAuthAuthority) {
        self.authority = authority
        let apply: @Sendable ([MCPOAuthConsentRequest]) -> Void = {
            [weak self] requests in
            guard let self else { return }
            Task { @MainActor in self.pending = requests }
        }
        Task { await authority.setConsentObserver(apply) }
    }

    func detach() {
        authority = nil
        pending = []
    }

    func approve(_ id: String) { resolve(id, approved: true) }
    func deny(_ id: String) { resolve(id, approved: false) }

    func revokeEverything() {
        guard let authority else { return }
        Task { await authority.revokeEverything() }
    }

    private func resolve(_ id: String, approved: Bool) {
        guard let authority else { return }
        Task { await authority.resolveConsent(id: id, approved: approved) }
    }
}
