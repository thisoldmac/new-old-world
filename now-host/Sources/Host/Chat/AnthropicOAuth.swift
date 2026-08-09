import CryptoKit
import Foundation

/* The Anthropic subscription sign-in, quarantined. Everything in this
   file is undocumented surface — the client id, the endpoints, the
   beta header, the paste-back flow — and any of it may change or be
   gated without notice. That is WHY it is one file: when it breaks,
   it breaks here, and the API-key path shares none of it.

   The flow is the manual-paste variant: open the authorize URL in the
   person's browser, they approve, the callback page shows them a
   "code#state" string, they paste it back. No loopback listener — an
   app whose safety story is about which sockets it holds does not
   grow one for a sign-in — and ASWebAuthenticationSession cannot
   intercept an https redirect to a domain this app cannot claim. */

enum AnthropicOAuth {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeBase = "https://claude.ai/oauth/authorize"
    static let redirectURI = "https://console.anthropic.com/oauth/code/callback"
    static let tokenEndpoint = "https://console.anthropic.com/v1/oauth/token"
    static let scope = "org:create_api_key user:profile user:inference"
    /// Requests bearing a subscription token send this instead of an
    /// x-api-key header.
    static let betaHeader = "oauth-2025-04-20"

    struct PKCE: Equatable, Sendable {
        let verifier: String
        let challenge: String
        let state: String
    }

    /// RNG injectable so a test's URLs are deterministic.
    static func makePKCE(
        randomBytes: (Int) -> [UInt8] = { count in
            (0..<count).map { _ in UInt8.random(in: .min ... .max) }
        }
    ) -> PKCE {
        let verifier = base64URL(Data(randomBytes(32)))
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = base64URL(Data(randomBytes(32)))
        return PKCE(verifier: verifier, challenge: challenge, state: state)
    }

    static func authorizeURL(pkce: PKCE) -> URL {
        var components = URLComponents(string: authorizeBase)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.state),
        ]
        return components.url!
    }

    /// Splits and checks the pasted "code#state". A bad paste is the
    /// flow's one failure mode, so its errors are sentences a person
    /// can act on.
    static func parsePasted(_ pasted: String, pkce: PKCE) throws -> String {
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "#", maxSplits: 1)
        guard parts.count == 2 else {
            throw ChatFault.refuse(
                code: "no-credentials",
                reason: "Paste the whole code, including the part after #")
        }
        guard parts[1] == pkce.state else {
            throw ChatFault.refuse(
                code: "no-credentials",
                reason: "That code is from a different sign-in attempt - start again")
        }
        return String(parts[0])
    }

    static func exchange(
        code: String, pkce: PKCE, transport: ChatHTTPTransport
    ) async throws -> ChatOAuthTokens {
        try await tokenRequest(
            [
                "grant_type": "authorization_code",
                "code": code,
                "state": pkce.state,
                "client_id": clientID,
                "redirect_uri": redirectURI,
                "code_verifier": pkce.verifier,
            ],
            keepRefreshToken: nil, transport: transport)
    }

    static func refresh(
        _ tokens: ChatOAuthTokens, transport: ChatHTTPTransport
    ) async throws -> ChatOAuthTokens {
        try await tokenRequest(
            [
                "grant_type": "refresh_token",
                "refresh_token": tokens.refreshToken,
                "client_id": clientID,
            ],
            keepRefreshToken: tokens.refreshToken, transport: transport)
    }

    private static func tokenRequest(
        _ body: [String: String], keepRefreshToken: String?,
        transport: ChatHTTPTransport
    ) async throws -> ChatOAuthTokens {
        var request = URLRequest(url: URL(string: tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else {
            throw ChatFault.refuse(
                code: response.statusCode == 401 || response.statusCode == 400
                    ? "auth-expired" : "provider-error",
                reason: "Sign-in endpoint answered \(response.statusCode)")
        }
        guard
            let object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let access = object["access_token"] as? String
        else {
            throw ChatFault.refuse(
                code: "provider-error",
                reason: "Sign-in endpoint answered something unreadable")
        }
        let expires = (object["expires_in"] as? Double) ?? 3600
        // Rotation is the server's choice; a refresh that returns no
        // new refresh token keeps the old one.
        let refresh = (object["refresh_token"] as? String)
            ?? keepRefreshToken ?? ""
        return ChatOAuthTokens(
            accessToken: access, refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(expires))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Serializes refreshes so two concurrent chats cannot race a token
/// rotation — the second caller waits for the first refresh and gets
/// its result.
actor AnthropicTokenRefresher {
    private struct RefreshFlight {
        let id: UUID
        let source: ChatOAuthTokens
        let task: Task<ChatOAuthTokens, Error>
    }

    private let store: ChatCredentialStore
    private var inFlight: RefreshFlight?
    private var lastRefresh: (
        source: ChatOAuthTokens, fresh: ChatOAuthTokens
    )?

    init(store: ChatCredentialStore) {
        self.store = store
    }

    /// Returns a live access token, refreshing (once) if the stored
    /// one has expired. Throws no-credentials when nobody is signed in.
    func liveTokens(
        stored data: Data, transport: ChatHTTPTransport
    ) async throws -> ChatOAuthTokens {
        guard var tokens = try? JSONDecoder().decode(
            ChatOAuthTokens.self, from: data)
        else {
            throw ChatFault.refuse(
                code: "no-credentials", reason: "Unreadable saved sign-in")
        }
        guard tokens.isExpired else { return tokens }
        // An operation cache may hand us the blob it read before another
        // operation refreshed. Prefer the authoritative no-UI value when
        // available, then retain the last successful source/result pair for
        // provider instances whose store is itself an operation cache.
        if let current = store.read(
            .anthropicOAuth, interaction: .forbid).data,
           let decoded = try? JSONDecoder().decode(
               ChatOAuthTokens.self, from: current) {
            tokens = decoded
        }
        guard tokens.isExpired else { return tokens }
        return try await refresh(tokens, transport: transport)
    }

    private func refresh(
        _ source: ChatOAuthTokens, transport: ChatHTTPTransport
    ) async throws -> ChatOAuthTokens {
        if let lastRefresh, lastRefresh.source == source {
            return lastRefresh.fresh
        }
        if let running = inFlight {
            let fresh = try await running.task.value
            lastRefresh = (running.source, fresh)
            if inFlight?.id == running.id { inFlight = nil }
            if running.source == source { return fresh }
            return try await refresh(source, transport: transport)
        }
        let id = UUID()
        let task = Task<ChatOAuthTokens, Error> {
            let fresh = try await AnthropicOAuth.refresh(
                source, transport: transport)
            try store.write(.anthropicOAuth, JSONEncoder().encode(fresh))
            return fresh
        }
        inFlight = RefreshFlight(id: id, source: source, task: task)
        do {
            let fresh = try await task.value
            lastRefresh = (source, fresh)
            if inFlight?.id == id { inFlight = nil }
            return fresh
        } catch {
            if inFlight?.id == id { inFlight = nil }
            throw error
        }
    }
}
