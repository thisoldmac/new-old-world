import XCTest
@testable import Host
@testable import NOWAgentIntegration

/// The HTTP transport's three auth modes, and the built-in authorization
/// server behind the oauth one. Every request here goes through
/// `MCPHTTPService.respond`, the same choke point the listener drives, so a
/// passing flow is the wire behaviour minus TCP.
final class MCPOAuthTests: XCTestCase {
    private static let port: UInt16 = 5254
    private static let host = "127.0.0.1:5254"

    // MARK: Modes

    func testUnauthenticatedModeSkipsAuthorizationButKeepsLoopbackChecks()
        async throws {
        let service = Self.service(mode: .unauthenticated)
        let initialize = try Self.initializeBody(id: 1)

        let accepted = await service.respond(to: Self.post(initialize))
        XCTAssertEqual(accepted.status, 200)

        let badHost = await service.respond(to: Self.post(
            initialize, headers: ["host": "example.test:5254"]))
        XCTAssertEqual(badHost.status, 400)
        let badOrigin = await service.respond(to: Self.post(
            initialize, headers: ["origin": "https://attacker.example"]))
        XCTAssertEqual(badOrigin.status, 403)
    }

    func testBearerModeIgnoresOAuthRoutes() async throws {
        let service = Self.service(mode: .bearer,
                                   bearerToken: String(repeating: "t",
                                                       count: 32))
        for target in ["/.well-known/oauth-protected-resource",
                       "/.well-known/oauth-authorization-server",
                       "/oauth/authorize?client_id=x"] {
            let reply = await service.respond(to: .init(
                method: "GET", target: target,
                headers: ["host": Self.host], body: Data()))
            XCTAssertEqual(reply.status, 404, target)
        }
    }

    func testOAuthModeRejectsMissingTokenWithDiscoveryChallenge()
        async throws {
        let (service, _) = try Self.oauthService()
        let reply = await service.respond(to: Self.post(
            try Self.initializeBody(id: 1)))
        XCTAssertEqual(reply.status, 401)
        XCTAssertEqual(
            reply.headers["WWW-Authenticate"],
            "Bearer resource_metadata=\"http://\(Self.host)"
                + "/.well-known/oauth-protected-resource/mcp\"")
    }

    // MARK: Metadata

    func testOAuthMetadataDescribesThisListener() async throws {
        let (service, _) = try Self.oauthService()
        let resource = await service.respond(to: .init(
            method: "GET",
            target: "/.well-known/oauth-protected-resource/mcp",
            headers: ["host": "localhost:5254"], body: Data()))
        XCTAssertEqual(resource.status, 200)
        let resourceObject = try Self.object(resource.body)
        XCTAssertEqual(resourceObject["resource"] as? String,
                       "http://localhost:5254/mcp")
        XCTAssertEqual(resourceObject["authorization_servers"] as? [String],
                       ["http://localhost:5254"])

        let server = await service.respond(to: .init(
            method: "GET",
            target: "/.well-known/oauth-authorization-server",
            headers: ["host": Self.host], body: Data()))
        XCTAssertEqual(server.status, 200)
        let serverObject = try Self.object(server.body)
        XCTAssertEqual(serverObject["issuer"] as? String,
                       "http://\(Self.host)")
        XCTAssertEqual(serverObject["authorization_endpoint"] as? String,
                       "http://\(Self.host)/oauth/authorize")
        XCTAssertEqual(serverObject["token_endpoint"] as? String,
                       "http://\(Self.host)/oauth/token")
        XCTAssertEqual(serverObject["registration_endpoint"] as? String,
                       "http://\(Self.host)/oauth/register")
        XCTAssertEqual(serverObject["code_challenge_methods_supported"]
                        as? [String], ["S256"])
        XCTAssertEqual(serverObject["grant_types_supported"] as? [String],
                       ["authorization_code", "refresh_token"])
    }

    // MARK: The full flow

    func testOAuthFullFlowRegisterConsentTokenCallAndRefresh() async throws {
        let (service, authority) = try Self.oauthService()
        await Self.approveEveryConsent(authority)
        let now = Date(timeIntervalSince1970: 1_000)

        let registered = await service.respond(to: Self.registration(),
                                               now: now)
        XCTAssertEqual(registered.status, 201)
        let registration = try Self.object(registered.body)
        let clientID = try XCTUnwrap(registration["client_id"] as? String)

        let verifier = "the-flow-tests-verifier-0123456789"
        let authorized = await service.respond(
            to: Self.authorizeRequest(clientID: clientID,
                                      verifier: verifier,
                                      state: "opaque-state"),
            now: now)
        XCTAssertEqual(authorized.status, 302)
        let location = try XCTUnwrap(authorized.headers["Location"])
        XCTAssertTrue(location.hasPrefix("\(Self.redirectURI)?"),
                      location)
        let query = Self.query(of: location)
        let code = try XCTUnwrap(query["code"])
        XCTAssertEqual(query["state"], "opaque-state")

        let issued = await service.respond(to: Self.tokenRequest([
            "grant_type": "authorization_code", "code": code,
            "client_id": clientID, "redirect_uri": Self.redirectURI,
            "code_verifier": verifier,
        ]), now: now)
        XCTAssertEqual(issued.status, 200)
        let grant = try Self.object(issued.body)
        let access = try XCTUnwrap(grant["access_token"] as? String)
        let refresh = try XCTUnwrap(grant["refresh_token"] as? String)
        XCTAssertEqual(grant["token_type"] as? String, "Bearer")

        let initialized = await service.respond(to: Self.post(
            try Self.initializeBody(id: 1),
            authorization: "Bearer \(access)"), now: now)
        XCTAssertEqual(initialized.status, 200)
        let session = try XCTUnwrap(initialized.headers["Mcp-Session-Id"])
        let listed = await service.respond(to: Self.post(
            try Self.request(id: 2, method: "tools/list", params: [:]),
            session: session, protocolVersion: "2025-11-25",
            authorization: "Bearer \(access)"), now: now)
        XCTAssertEqual(listed.status, 200)

        /* Refresh rotates: the new pair works, the old refresh token and
           the old access token are both dead. */
        let later = now.addingTimeInterval(10)
        let refreshed = await service.respond(to: Self.tokenRequest([
            "grant_type": "refresh_token", "refresh_token": refresh,
            "client_id": clientID,
        ]), now: later)
        XCTAssertEqual(refreshed.status, 200)
        let second = try Self.object(refreshed.body)
        let secondAccess = try XCTUnwrap(second["access_token"] as? String)
        XCTAssertNotEqual(secondAccess, access)

        let reusedRefresh = await service.respond(to: Self.tokenRequest([
            "grant_type": "refresh_token", "refresh_token": refresh,
            "client_id": clientID,
        ]), now: later)
        XCTAssertEqual(reusedRefresh.status, 400)
        let oldAccess = await service.respond(to: Self.post(
            try Self.initializeBody(id: 3),
            authorization: "Bearer \(access)"), now: later)
        XCTAssertEqual(oldAccess.status, 401)
        let newAccess = await service.respond(to: Self.post(
            try Self.initializeBody(id: 4),
            authorization: "Bearer \(secondAccess)"), now: later)
        XCTAssertEqual(newAccess.status, 200)
    }

    func testAccessTokenExpiresAfterItsLifetime() async throws {
        let (service, authority) = try Self.oauthService()
        await Self.approveEveryConsent(authority)
        let now = Date(timeIntervalSince1970: 1_000)
        let access = try await Self.mintAccessToken(service, now: now)

        let expired = await service.respond(to: Self.post(
            try Self.initializeBody(id: 1),
            authorization: "Bearer \(access)"),
            now: now.addingTimeInterval(
                MCPOAuthAuthority.accessTokenLifetime + 1))
        XCTAssertEqual(expired.status, 401)
        XCTAssertNotNil(expired.headers["WWW-Authenticate"])
    }

    // MARK: Negatives

    func testAuthorizeRefusesUnknownClientAndForeignRedirect() async throws {
        let (service, authority) = try Self.oauthService()
        await Self.approveEveryConsent(authority)

        let unknown = await service.respond(to: Self.authorizeRequest(
            clientID: "not-registered", verifier: "v"))
        XCTAssertEqual(unknown.status, 400)

        let registered = await service.respond(to: Self.registration())
        let clientID = try XCTUnwrap(
            try Self.object(registered.body)["client_id"] as? String)
        let foreign = await service.respond(to: .init(
            method: "GET",
            target: "/oauth/authorize?client_id=\(clientID)"
                + "&redirect_uri=http%3A%2F%2F127.0.0.1%3A7777%2Felsewhere"
                + "&response_type=code&code_challenge=x"
                + "&code_challenge_method=S256",
            headers: ["host": Self.host], body: Data()))
        XCTAssertEqual(foreign.status, 400)

        let plain = await service.respond(to: .init(
            method: "GET",
            target: "/oauth/authorize?client_id=\(clientID)"
                + "&redirect_uri=\(Self.escapedRedirectURI)"
                + "&response_type=code&code_challenge=x"
                + "&code_challenge_method=plain",
            headers: ["host": Self.host], body: Data()))
        XCTAssertEqual(plain.status, 302)
        XCTAssertEqual(Self.query(
            of: try XCTUnwrap(plain.headers["Location"]))["error"],
            "invalid_request")
    }

    func testTokenEndpointRefusesWrongVerifierExpiredAndReplayedCodes()
        async throws {
        let (service, authority) = try Self.oauthService()
        await Self.approveEveryConsent(authority)
        let now = Date(timeIntervalSince1970: 1_000)
        let registered = await service.respond(to: Self.registration(),
                                               now: now)
        let clientID = try XCTUnwrap(
            try Self.object(registered.body)["client_id"] as? String)

        func freshCode(verifier: String) async throws -> String {
            let authorized = await service.respond(
                to: Self.authorizeRequest(clientID: clientID,
                                          verifier: verifier), now: now)
            return try XCTUnwrap(Self.query(
                of: try XCTUnwrap(authorized.headers["Location"]))["code"])
        }

        let wrongVerifier = await service.respond(to: Self.tokenRequest([
            "grant_type": "authorization_code",
            "code": try await freshCode(verifier: "right-verifier-000000"),
            "client_id": clientID, "redirect_uri": Self.redirectURI,
            "code_verifier": "wrong-verifier-0000000",
        ]), now: now)
        XCTAssertEqual(wrongVerifier.status, 400)

        let expired = await service.respond(to: Self.tokenRequest([
            "grant_type": "authorization_code",
            "code": try await freshCode(verifier: "expiring-verifier-0000"),
            "client_id": clientID, "redirect_uri": Self.redirectURI,
            "code_verifier": "expiring-verifier-0000",
        ]), now: now.addingTimeInterval(MCPOAuthAuthority.codeLifetime + 1))
        XCTAssertEqual(expired.status, 400)

        /* Replay: the second redemption fails AND kills the first's access
           token. */
        let verifier = "replayed-verifier-000000"
        let code = try await freshCode(verifier: verifier)
        let form: [String: String] = [
            "grant_type": "authorization_code", "code": code,
            "client_id": clientID, "redirect_uri": Self.redirectURI,
            "code_verifier": verifier,
        ]
        let first = await service.respond(to: Self.tokenRequest(form),
                                          now: now)
        XCTAssertEqual(first.status, 200)
        let access = try XCTUnwrap(
            try Self.object(first.body)["access_token"] as? String)
        let replayed = await service.respond(to: Self.tokenRequest(form),
                                             now: now)
        XCTAssertEqual(replayed.status, 400)
        let revoked = await service.respond(to: Self.post(
            try Self.initializeBody(id: 9),
            authorization: "Bearer \(access)"), now: now)
        XCTAssertEqual(revoked.status, 401)
    }

    // MARK: Consent

    func testDeniedAndTimedOutConsentsRedirectWithAccessDenied()
        async throws {
        let (service, authority) = try Self.oauthService(consentTimeout: 600)
        await authority.setConsentObserver { requests in
            guard let request = requests.first else { return }
            Task { await authority.resolveConsent(id: request.id,
                                                  approved: false) }
        }
        let registered = await service.respond(to: Self.registration())
        let clientID = try XCTUnwrap(
            try Self.object(registered.body)["client_id"] as? String)
        let denied = await service.respond(to: Self.authorizeRequest(
            clientID: clientID, verifier: "denied-verifier-000000"))
        XCTAssertEqual(denied.status, 302)
        XCTAssertEqual(Self.query(
            of: try XCTUnwrap(denied.headers["Location"]))["error"],
            "access_denied")

        let (quick, _) = try Self.oauthService(consentTimeout: 0.05)
        let quickRegistered = await quick.respond(to: Self.registration())
        let quickClient = try XCTUnwrap(
            try Self.object(quickRegistered.body)["client_id"] as? String)
        let timedOut = await quick.respond(to: Self.authorizeRequest(
            clientID: quickClient, verifier: "timeout-verifier-00000"))
        XCTAssertEqual(timedOut.status, 302)
        XCTAssertEqual(Self.query(
            of: try XCTUnwrap(timedOut.headers["Location"]))["error"],
            "access_denied")
    }

    // MARK: State persistence

    func testStateFileIsPrivateAndSurvivesANewAuthority() async throws {
        let url = Self.temporaryStateURL()
        defer {
            try? FileManager.default.removeItem(
                at: url.deletingLastPathComponent())
        }
        let store = try MCPOAuthStateStore(url: url)
        let authority = MCPOAuthAuthority(store: store)
        let now = Date(timeIntervalSince1970: 1_000)
        let registered = await authority.register(
            body: try JSONSerialization.data(withJSONObject: [
                "client_name": "persisted client",
                "redirect_uris": [Self.redirectURI],
            ]), now: now)
        guard case .issued(let body) = registered else {
            return XCTFail("registration failed: \(registered)")
        }
        let clientID = try XCTUnwrap(
            try Self.object(body)["client_id"] as? String)

        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue,
                       0o600)

        let reloaded = MCPOAuthAuthority(store: try MCPOAuthStateStore(
            url: url))
        await Self.approveEveryConsent(reloaded)
        let verifier = "persisted-verifier-000000"
        let outcome = await reloaded.authorize(query: [
            "client_id": clientID, "redirect_uri": Self.redirectURI,
            "response_type": "code",
            "code_challenge": MCPOAuthAuthority.pkceChallenge(for: verifier),
            "code_challenge_method": "S256",
        ], now: now)
        guard case .redirect(let location) = outcome else {
            return XCTFail("authorize failed: \(outcome)")
        }
        XCTAssertNotNil(Self.query(of: location)["code"])
    }

    func testCorruptStateFileMeansEmptyStateNotAFailure() throws {
        let url = Self.temporaryStateURL()
        defer {
            try? FileManager.default.removeItem(
                at: url.deletingLastPathComponent())
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let store = try MCPOAuthStateStore(url: url)
        XCTAssertEqual(store.load(), MCPOAuthPersistentState())
    }

    func testOAuthAcceptsOnlyTheExactEmbeddedLaneCredential() async throws {
        let (_, authority) = try Self.oauthService()
        let service = Self.service(
            mode: .oauth, oauth: authority,
            embeddedAccessToken: "embedded-only")

        let accepted = await service.respond(to: Self.post(
            try Self.initializeBody(id: 1),
            authorization: "Bearer embedded-only"))
        XCTAssertEqual(accepted.status, 200)

        let rejected = await service.respond(to: Self.post(
            try Self.initializeBody(id: 2),
            authorization: "Bearer another-local-token"))
        XCTAssertEqual(rejected.status, 401)
    }

    // MARK: Harness

    private static func service(
        mode: MCPHTTPAuthMode, bearerToken: String? = nil,
        oauth: MCPOAuthAuthority? = nil,
        embeddedAccessToken: String? = nil) -> MCPHTTPService {
        MCPHTTPService(
            configuration: .init(port: port, authMode: mode,
                                 bearerToken: bearerToken,
                                 embeddedAccessToken: embeddedAccessToken),
            serverFactory: {
                (NOWMCPServer(client: SocketAgentIntegrationClient(),
                              audit: LocalMCPAuditSink()),
                 NOWMCPClientIdentity())
            },
            oauth: oauth)
    }

    private static func oauthService(consentTimeout: TimeInterval = 600)
        throws -> (MCPHTTPService, MCPOAuthAuthority) {
        /* The parent directory is unique per call; the OS reaps the
           temporary tree, so no teardown block is registered. */
        let url = temporaryStateURL()
        let authority = MCPOAuthAuthority(
            store: try MCPOAuthStateStore(url: url),
            consentTimeout: consentTimeout)
        return (service(mode: .oauth, oauth: authority), authority)
    }

    /// The tests cannot click Approve; this observer is that person.
    private static func approveEveryConsent(
        _ authority: MCPOAuthAuthority) async {
        await authority.setConsentObserver { requests in
            guard let request = requests.first else { return }
            Task { await authority.resolveConsent(id: request.id,
                                                  approved: true) }
        }
    }

    private static func mintAccessToken(
        _ service: MCPHTTPService, now: Date) async throws -> String {
        let registered = await service.respond(to: registration(), now: now)
        let clientID = try XCTUnwrap(
            try object(registered.body)["client_id"] as? String)
        let verifier = "minting-verifier-000000"
        let authorized = await service.respond(
            to: authorizeRequest(clientID: clientID, verifier: verifier),
            now: now)
        let code = try XCTUnwrap(query(
            of: try XCTUnwrap(authorized.headers["Location"]))["code"])
        let issued = await service.respond(to: tokenRequest([
            "grant_type": "authorization_code", "code": code,
            "client_id": clientID, "redirect_uri": redirectURI,
            "code_verifier": verifier,
        ]), now: now)
        return try XCTUnwrap(
            try object(issued.body)["access_token"] as? String)
    }

    private static let redirectURI = "http://127.0.0.1:33418/callback"
    private static var escapedRedirectURI: String {
        redirectURI.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics)!
    }

    private static func registration() -> MCPHTTPRequest {
        .init(method: "POST", target: "/oauth/register",
              headers: ["host": host, "content-type": "application/json"],
              body: try! JSONSerialization.data(withJSONObject: [
                "client_name": "oauth tests",
                "redirect_uris": [redirectURI],
              ]))
    }

    private static func authorizeRequest(
        clientID: String, verifier: String, state: String? = nil)
        -> MCPHTTPRequest {
        var target = "/oauth/authorize?client_id=\(clientID)"
            + "&redirect_uri=\(escapedRedirectURI)"
            + "&response_type=code"
            + "&code_challenge=\(MCPOAuthAuthority.pkceChallenge(for: verifier))"
            + "&code_challenge_method=S256"
        if let state { target += "&state=\(state)" }
        return .init(method: "GET", target: target,
                     headers: ["host": host], body: Data())
    }

    private static func tokenRequest(_ form: [String: String])
        -> MCPHTTPRequest {
        let body = form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)"
        }.joined(separator: "&")
        return .init(method: "POST", target: "/oauth/token",
                     headers: ["host": host,
                               "content-type":
                                "application/x-www-form-urlencoded"],
                     body: Data(body.utf8))
    }

    private static func query(of location: String) -> [String: String] {
        guard let divider = location.firstIndex(of: "?") else { return [:] }
        let raw = String(location[location.index(after: divider)...])
        return MCPOAuthAuthority.parseForm(Data(raw.utf8))
    }

    private static func temporaryStateURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("now-mcp-oauth-\(UUID().uuidString)")
            .appendingPathComponent("state.json")
    }

    private static func post(_ body: Data, session: String? = nil,
                             protocolVersion: String? = nil,
                             authorization: String? = nil,
                             headers: [String: String] = [:])
        -> MCPHTTPRequest {
        var all: [String: String] = [
            "host": host,
            "content-type": "application/json",
            "accept": "application/json, text/event-stream",
        ]
        all["authorization"] = authorization
        for (key, value) in headers { all[key] = value }
        all["mcp-session-id"] = session
        all["mcp-protocol-version"] = protocolVersion
        return .init(method: "POST", target: "/mcp", headers: all,
                     body: body)
    }

    private static func initializeBody(id: Int) throws -> Data {
        try request(id: id, method: "initialize", params: [
            "protocolVersion": "2025-11-25",
            "capabilities": [:],
            "clientInfo": ["name": "oauth-tests", "version": "1"],
        ])
    }

    private static func request(id: Int, method: String,
                                params: [String: Any]? = nil) throws
        -> Data {
        var object: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": method,
        ]
        object["params"] = params
        return try JSONSerialization.data(withJSONObject: object,
                                          options: [.sortedKeys])
    }

    private static func object(_ data: Data) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data)
            as? NSDictionary)
    }
}
