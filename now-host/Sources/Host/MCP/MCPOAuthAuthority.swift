import CryptoKit
import Foundation
import Security

/// One OAuth consent a person has not yet answered. The MCP page renders one
/// row per pending request; Approve or Deny resolves the parked /authorize
/// connection.
struct MCPOAuthConsentRequest: Identifiable, Equatable, Sendable {
    let id: String
    let clientID: String
    let clientName: String
}

struct MCPOAuthClientRegistration: Codable, Equatable, Sendable {
    let clientID: String
    var clientName: String
    var redirectURIs: [String]
    var registeredAt: Date
    var lastUsed: Date
}

/// One issued access/refresh pair. Only digests are persisted, so the state
/// file never holds a usable credential.
struct MCPOAuthTokenGrant: Codable, Equatable, Sendable {
    let accessTokenDigest: String
    let refreshTokenDigest: String
    let clientID: String
    var accessExpiresAt: Date
    var refreshExpiresAt: Date
}

struct MCPOAuthPersistentState: Codable, Equatable, Sendable {
    var schema = "mcp-oauth-state-v1"
    var clients: [MCPOAuthClientRegistration] = []
    var grants: [MCPOAuthTokenGrant] = []
}

/// The OAuth state file beside the bearer token: same directory, same 0600
/// discipline. A corrupt or missing file means an empty state, never a
/// failure to start the listener.
struct MCPOAuthStateStore: Sendable {
    let url: URL

    init(url: URL? = nil, fileManager: FileManager = .default) throws {
        if let url {
            self.url = url
            return
        }
        guard let support = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
        else { throw MCPHTTPTokenStoreError.noApplicationSupport }
        self.url = support
            .appendingPathComponent(ProductIdentity.displayName,
                                    isDirectory: true)
            .appendingPathComponent("mcp-oauth-state.json", isDirectory: false)
    }

    func load(fileManager: FileManager = .default) -> MCPOAuthPersistentState {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder.withDates()
                .decode(MCPOAuthPersistentState.self, from: data) else {
            return MCPOAuthPersistentState()
        }
        return state
    }

    func save(_ state: MCPOAuthPersistentState,
              fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600],
                                      ofItemAtPath: url.path)
    }
}

private extension JSONDecoder {
    static func withDates() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// NOW's own authorization server for the HTTP transport's oauth mode.
///
/// Everything here answers requests that already passed the transport's
/// loopback Host check. Clients are public (RFC 7591 registration, no
/// secret), the only flow is authorization code + PKCE S256, and a code is
/// minted only after a person approves the consent row the MCP page shows.
/// Tokens are opaque random values; the persisted state holds digests only.
actor MCPOAuthAuthority {
    enum AuthorizeOutcome: Equatable {
        /// 302 to this Location. Errors the spec says to deliver to the
        /// client (denied, timeout) are redirects too.
        case redirect(String)
        /// 400 with this sentence; used when the client or redirect URI is
        /// not trustworthy enough to redirect to.
        case invalidRequest(String)
    }

    enum TokenOutcome: Equatable {
        case issued(Data)
        case rejected(status: Int, error: String, detail: String)
    }

    static let maximumClients = 16
    static let codeLifetime: TimeInterval = 60
    static let accessTokenLifetime: TimeInterval = 60 * 60
    static let refreshTokenLifetime: TimeInterval = 30 * 24 * 60 * 60

    private struct IssuedCode {
        let clientID: String
        let redirectURI: String
        let codeChallenge: String
        let expiresAt: Date
        /// Digests of tokens minted from this code, so a replayed code can
        /// revoke them (RFC 6749 §4.1.2 guidance).
        var grantedAccessDigests: [String] = []
    }

    private struct PendingConsent {
        let request: MCPOAuthConsentRequest
        let continuation: CheckedContinuation<Bool, Never>
        let timeout: Task<Void, Never>
    }

    private let store: MCPOAuthStateStore
    private let consentTimeout: TimeInterval
    private var state: MCPOAuthPersistentState
    /// Keyed by the SHA-256 digest of the code, so the plaintext code lives
    /// only in the redirect that carried it.
    private var codes: [String: IssuedCode] = [:]
    private var pending: [String: PendingConsent] = [:]
    private var pendingChanged: (@Sendable ([MCPOAuthConsentRequest]) -> Void)?

    init(store: MCPOAuthStateStore,
         consentTimeout: TimeInterval = 300) {
        self.store = store
        self.consentTimeout = consentTimeout
        state = store.load()
    }

    /// The MCP page's consent model registers here; it receives the full
    /// pending list on every change so a timeout clears its row too.
    func setConsentObserver(
        _ observer: @escaping @Sendable ([MCPOAuthConsentRequest]) -> Void) {
        pendingChanged = observer
        observer(pending.values.map(\.request).sorted { $0.id < $1.id })
    }

    // MARK: Metadata

    static func protectedResourceMetadata(host: String) -> Data {
        json([
            "resource": "http://\(host)/mcp",
            "authorization_servers": ["http://\(host)"],
            "bearer_methods_supported": ["header"],
        ])
    }

    static func authorizationServerMetadata(host: String) -> Data {
        json([
            "issuer": "http://\(host)",
            "authorization_endpoint": "http://\(host)/oauth/authorize",
            "token_endpoint": "http://\(host)/oauth/token",
            "registration_endpoint": "http://\(host)/oauth/register",
            "response_types_supported": ["code"],
            "grant_types_supported": ["authorization_code", "refresh_token"],
            "code_challenge_methods_supported": ["S256"],
            "token_endpoint_auth_methods_supported": ["none"],
            "scopes_supported": ["mcp"],
        ])
    }

    // MARK: Registration (RFC 7591)

    func register(body: Data, now: Date) -> TokenOutcome {
        guard let object = try? JSONSerialization.jsonObject(with: body)
                as? [String: Any],
              let redirectURIs = object["redirect_uris"] as? [String],
              !redirectURIs.isEmpty else {
            return .rejected(status: 400, error: "invalid_client_metadata",
                             detail: "redirect_uris is required.")
        }
        guard redirectURIs.allSatisfy(Self.isLoopbackRedirectURI) else {
            return .rejected(status: 400, error: "invalid_redirect_uri",
                             detail: "Redirect URIs must be loopback HTTP.")
        }
        let name = Self.boundedName(object["client_name"] as? String)
        let registration = MCPOAuthClientRegistration(
            clientID: Self.randomHex(16),
            clientName: name,
            redirectURIs: redirectURIs,
            registeredAt: now,
            lastUsed: now)
        state.clients.append(registration)
        if state.clients.count > Self.maximumClients {
            /* Registration is unauthenticated (loopback-only), so the roster
               is bounded: evict the least recently used client and every
               grant it held. */
            let evicted = state.clients.min { $0.lastUsed < $1.lastUsed }!
            state.clients.removeAll { $0.clientID == evicted.clientID }
            state.grants.removeAll { $0.clientID == evicted.clientID }
        }
        persist()
        return .issued(Self.json([
            "client_id": registration.clientID,
            "client_name": registration.clientName,
            "redirect_uris": registration.redirectURIs,
            "token_endpoint_auth_method": "none",
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
        ]))
    }

    // MARK: Authorization (code + PKCE, human consent)

    func authorize(query: [String: String], now: Date) async
        -> AuthorizeOutcome {
        guard let clientID = query["client_id"],
              let clientIndex = state.clients.firstIndex(
                where: { $0.clientID == clientID }) else {
            return .invalidRequest("Unknown client.")
        }
        let client = state.clients[clientIndex]
        guard let redirectURI = query["redirect_uri"],
              client.redirectURIs.contains(redirectURI) else {
            return .invalidRequest("The redirect URI is not registered.")
        }
        /* From here on errors go to the redirect URI: it is registered, so
           the client is entitled to hear why. */
        let stateParam = query["state"]
        guard query["response_type"] == "code" else {
            return errorRedirect(redirectURI, "unsupported_response_type",
                                 state: stateParam)
        }
        guard let challenge = query["code_challenge"],
              query["code_challenge_method"] == "S256",
              !challenge.isEmpty else {
            return errorRedirect(redirectURI, "invalid_request",
                                 state: stateParam)
        }
        if let resource = query["resource"],
           !resource.hasSuffix("/mcp") {
            return errorRedirect(redirectURI, "invalid_target",
                                 state: stateParam)
        }

        state.clients[clientIndex].lastUsed = now
        persist()

        let approved = await awaitConsent(
            .init(id: Self.randomHex(8), clientID: clientID,
                  clientName: client.clientName))
        guard approved else {
            return errorRedirect(redirectURI, "access_denied",
                                 state: stateParam)
        }

        let code = Self.randomHex(32)
        codes[Self.digest(code)] = IssuedCode(
            clientID: clientID, redirectURI: redirectURI,
            codeChallenge: challenge,
            expiresAt: now.addingTimeInterval(Self.codeLifetime))
        var location = "\(redirectURI)?code=\(code)"
        if let stateParam {
            location += "&state=\(Self.queryEscape(stateParam))"
        }
        return .redirect(location)
    }

    func resolveConsent(id: String, approved: Bool) {
        guard let consent = pending.removeValue(forKey: id) else { return }
        consent.timeout.cancel()
        consent.continuation.resume(returning: approved)
        notifyPendingChanged()
    }

    private func awaitConsent(_ request: MCPOAuthConsentRequest) async
        -> Bool {
        await withCheckedContinuation { continuation in
            let timeout = Task { [consentTimeout] in
                try? await Task.sleep(
                    nanoseconds: UInt64(consentTimeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self.resolveConsent(id: request.id, approved: false)
            }
            pending[request.id] = PendingConsent(
                request: request, continuation: continuation,
                timeout: timeout)
            notifyPendingChanged()
        }
    }

    private func notifyPendingChanged() {
        pendingChanged?(pending.values.map(\.request)
            .sorted { $0.id < $1.id })
    }

    // MARK: Token endpoint

    func token(form: [String: String], now: Date) -> TokenOutcome {
        pruneExpired(at: now)
        switch form["grant_type"] {
        case "authorization_code":
            return codeGrant(form: form, now: now)
        case "refresh_token":
            return refreshGrant(form: form, now: now)
        default:
            return .rejected(status: 400, error: "unsupported_grant_type",
                             detail: "Use authorization_code or refresh_token.")
        }
    }

    private func codeGrant(form: [String: String], now: Date) -> TokenOutcome {
        guard let code = form["code"], let clientID = form["client_id"],
              let redirectURI = form["redirect_uri"],
              let verifier = form["code_verifier"] else {
            return .rejected(status: 400, error: "invalid_request",
                             detail: "code, client_id, redirect_uri and "
                                 + "code_verifier are required.")
        }
        let digest = Self.digest(code)
        guard let issued = codes[digest] else {
            return .rejected(status: 400, error: "invalid_grant",
                             detail: "The code is unknown or already used.")
        }
        if !issued.grantedAccessDigests.isEmpty {
            /* Replay of a redeemed code: revoke what the first redemption
               minted and refuse (RFC 6749 §4.1.2). */
            codes[digest] = nil
            state.grants.removeAll {
                issued.grantedAccessDigests.contains($0.accessTokenDigest)
            }
            persist()
            return .rejected(status: 400, error: "invalid_grant",
                             detail: "The code was already used; its tokens "
                                 + "are revoked.")
        }
        guard issued.expiresAt >= now,
              issued.clientID == clientID,
              issued.redirectURI == redirectURI,
              Self.pkceChallenge(for: verifier) == issued.codeChallenge else {
            codes[digest] = nil
            return .rejected(status: 400, error: "invalid_grant",
                             detail: "The code did not match this request.")
        }
        let outcome = mint(clientID: clientID, now: now)
        if case .issued = outcome,
           let minted = state.grants.last?.accessTokenDigest {
            /* The redeemed code stays, marked, until its expiry sweep — that
               is what lets a replay find and revoke the tokens it minted. */
            var redeemed = issued
            redeemed.grantedAccessDigests.append(minted)
            codes[digest] = redeemed
        } else {
            codes[digest] = nil
        }
        return outcome
    }

    private func refreshGrant(form: [String: String], now: Date)
        -> TokenOutcome {
        guard let refresh = form["refresh_token"],
              let clientID = form["client_id"] else {
            return .rejected(status: 400, error: "invalid_request",
                             detail: "refresh_token and client_id are "
                                 + "required.")
        }
        let digest = Self.digest(refresh)
        guard let index = state.grants.firstIndex(
                where: { $0.refreshTokenDigest == digest }),
              state.grants[index].clientID == clientID,
              state.grants[index].refreshExpiresAt >= now else {
            return .rejected(status: 400, error: "invalid_grant",
                             detail: "The refresh token is not valid.")
        }
        state.grants.remove(at: index)
        return mint(clientID: clientID, now: now)
    }

    private func mint(clientID: String, now: Date) -> TokenOutcome {
        let access = Self.randomHex(32)
        let refresh = Self.randomHex(32)
        state.grants.append(.init(
            accessTokenDigest: Self.digest(access),
            refreshTokenDigest: Self.digest(refresh),
            clientID: clientID,
            accessExpiresAt: now.addingTimeInterval(
                Self.accessTokenLifetime),
            refreshExpiresAt: now.addingTimeInterval(
                Self.refreshTokenLifetime)))
        persist()
        return .issued(Self.json([
            "access_token": access,
            "token_type": "Bearer",
            "expires_in": Int(Self.accessTokenLifetime),
            "refresh_token": refresh,
            "scope": "mcp",
        ]))
    }

    // MARK: Resource-server validation

    func validateAccessToken(_ token: String, now: Date) -> Bool {
        pruneExpired(at: now)
        let digest = Self.digest(token)
        return state.grants.contains {
            $0.accessTokenDigest == digest && $0.accessExpiresAt >= now
        }
    }

    func revokeEverything() {
        state = MCPOAuthPersistentState()
        codes = [:]
        persist()
        for id in pending.keys { resolveConsent(id: id, approved: false) }
    }

    // MARK: Helpers

    private func pruneExpired(at now: Date) {
        codes = codes.filter {
            /* A redeemed code outlives its own expiry as a replay marker,
               but only while the access token it minted could still live —
               otherwise the marker set would grow without bound. */
            let replayHorizon = $0.value.grantedAccessDigests.isEmpty
                ? 0 : Self.accessTokenLifetime
            return $0.value.expiresAt.addingTimeInterval(replayHorizon) >= now
        }
        let before = state.grants.count
        state.grants.removeAll { $0.refreshExpiresAt < now }
        if state.grants.count != before { persist() }
    }

    private func persist() {
        do {
            try store.save(state)
        } catch {
            let detail = "OAuth state could not be saved: \(error)"
            Task { @MainActor in
                HostLog.shared.write(.warn, "mcp", detail)
            }
        }
    }

    private func errorRedirect(_ redirectURI: String, _ error: String,
                               state: String?) -> AuthorizeOutcome {
        var location = "\(redirectURI)?error=\(error)"
        if let state { location += "&state=\(Self.queryEscape(state))" }
        return .redirect(location)
    }

    static func isLoopbackRedirectURI(_ uri: String) -> Bool {
        guard let components = URLComponents(string: uri),
              components.scheme?.lowercased() == "http" else { return false }
        let host = components.host?.lowercased()
        return host == "127.0.0.1" || host == "localhost"
    }

    static func pkceChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func randomHex(_ bytes: Int) -> String {
        var raw = [UInt8](repeating: 0, count: bytes)
        guard SecRandomCopyBytes(kSecRandomDefault, raw.count, &raw)
                == errSecSuccess else {
            /* SecRandomCopyBytes failing is a broken machine; a UUID pair
               keeps the flow alive rather than crashing the listener. */
            return (UUID().uuidString + UUID().uuidString)
                .replacingOccurrences(of: "-", with: "").lowercased()
        }
        return raw.map { String(format: "%02x", $0) }.joined()
    }

    private static func queryEscape(_ value: String) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics) ?? ""
    }

    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// application/x-www-form-urlencoded, the token endpoint's body format.
    static func parseForm(_ body: Data) -> [String: String] {
        guard let text = String(data: body, encoding: .utf8) else {
            return [:]
        }
        var form: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1,
                                   omittingEmptySubsequences: false)
            guard let name = Self.formDecode(String(parts[0])),
                  !name.isEmpty else { continue }
            let value = parts.count == 2
                ? Self.formDecode(String(parts[1])) : ""
            guard let value, form[name] == nil else { continue }
            form[name] = value
        }
        return form
    }

    private static func formDecode(_ value: String) -> String? {
        value.replacingOccurrences(of: "+", with: " ")
            .removingPercentEncoding
    }

    private static func boundedName(_ raw: String?) -> String {
        let fallback = "Unnamed MCP client"
        guard let raw else { return fallback }
        let cleaned = raw.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
        let name = String(String.UnicodeScalarView(cleaned))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return fallback }
        return String(name.prefix(80))
    }
}
