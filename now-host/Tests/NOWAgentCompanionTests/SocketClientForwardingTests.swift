import Foundation
import XCTest

/// **The gate for a capability that is advertised and cannot reach the
/// machine.**
///
/// `SocketAgentIntegrationClient` is the one client every MCP call travels
/// through. `AgentIntegrationClient` gives most of its requirements a
/// default — deliberately, and the rule at the head of that file argues for
/// it: seven stub conformers across the test tree implement only their own
/// lanes, and a requirement without a default is seven compile errors in
/// seven files named for other capabilities.
///
/// The cost of that rule is this defect class. A default is invisible at the
/// call site: a projection writes `await client.observeElements(…)`, the
/// compiler is satisfied, and the socket client — which has a live host, a
/// live socket and a Macintosh on the end of it — silently answers
/// *"this client cannot observe"*. Nothing was broken, nothing was red, and
/// the tool was listed in the MCP catalog the whole time.
///
/// That happened. On 2026-08-07 a surface audit found `observeElements`,
/// `mirrorDrive` and `tailGuestLog` all landing on their protocol defaults,
/// so `now_observe_elements`, `now_mirror_drive` and `now_guest_log_tail`
/// answered "no lane" from a healthy host — and because
/// `ObserveElementsProjection` is the ONLY producer of the `now-element-…`
/// references the act rows take, `now_window_act`, `now_control_act`,
/// `now_text_get` and `now_text_set` were unreachable for want of a legal
/// argument. Seven of forty-one tools. Every one of them worked from
/// `tools/now-agent`, which is what made it survive: the developer road was
/// fine and only the product's road was broken.
///
/// ## Why this is derived and not a list
///
/// A list of "methods the socket client must implement" would be a
/// hand-maintained enumeration, and AGENTS.md is explicit about how those
/// rot: the same day this defect was found, three separate enumerations in
/// this repository were wrong, none of them by carelessness. So both halves
/// below are **derived from the source at test time**, from the two places
/// the facts already live:
///
/// - what the projections ask a client for — every `client.<name>(` in
///   `Sources/NOWAgentIntegration/Projection/`;
/// - what the protocol requires — every `func` in the `AgentIntegrationClient`
///   protocol body.
///
/// Both are checked against the `func` names `SocketAgentIntegrationClient`
/// declares. Nothing here is maintained; a projection that starts asking for
/// a new lane, or a requirement that lands with only its default, fails this
/// on the same commit that introduces it.
///
/// ## Why it reads source rather than calling the methods
///
/// Swift has no reflection over a type's methods, so "did this conformer
/// override the default?" cannot be asked at runtime. It could be asked
/// indirectly — call every catalog row through a socket client with no host
/// and assert the answer is a transport failure rather than a lane-absent
/// code — but that needs one set of valid arguments per row, which is
/// exactly the hand-maintained enumeration this file refuses to keep.
/// Reading the declarations is the derivation with no list in it, and
/// `MCPCoverageTests` and `GuestWireConformanceTests` already read source
/// for the same reason.
///
/// What it therefore does NOT prove: that a forwarder forwards to the right
/// operation, or that the lane works. Both are the drive's job, not a
/// suite's.
final class SocketClientForwardingTests: XCTestCase {

    private static let socketClientPath =
        "now-host/Sources/NOWAgentCompanion/SocketAgentIntegrationClient.swift"
    private static let protocolPath =
        "now-host/Sources/NOWAgentIntegration/Projection/"
        + "AgentIntegrationClient.swift"
    private static let projectionDirectory =
        "now-host/Sources/NOWAgentIntegration/Projection"

    /// Half one: **nothing a projection asks for may land on a default.**
    ///
    /// This is the half that names the defect directly. A projection is a
    /// published MCP row; if the method it calls is not forwarded, that row
    /// is advertised and dead.
    func testEveryLaneAProjectionAsksForIsForwardedBySocketClient() throws {
        let forwarded = try Self.declaredMethods(in: Self.socketClientPath)
        XCTAssertFalse(
            forwarded.isEmpty,
            "Read no methods out of \(Self.socketClientPath). The regex, "
                + "not the client, is what broke.")

        var asked: [String: Set<String>] = [:]
        for file in try Self.projectionSources() {
            let source = try Self.read(file)
            for method in Self.matches(
                #"client\.([a-zA-Z][a-zA-Z0-9]*)\("#, in: source) {
                asked[method, default: []].insert(
                    (file as NSString).lastPathComponent)
            }
        }
        XCTAssertFalse(
            asked.isEmpty,
            "Read no client calls out of \(Self.projectionDirectory).")

        let dead = asked.filter { !forwarded.contains($0.key) }
        XCTAssertTrue(dead.isEmpty, """
            These lanes are ASKED FOR by a registered projection and NOT \
            forwarded by SocketAgentIntegrationClient, so every MCP tool \
            that reaches them answers the protocol default — a "no lane" \
            refusal from a host that is up:

            \(Self.describe(dead))

            A four-line forwarder in \(Self.socketClientPath) is the whole \
            fix; the lane below it already exists. Do NOT silence this by \
            deleting the call — a projection that asks for nothing serves \
            nothing.
            """)
    }

    /// Half two: **the whole protocol, not only what is projected today.**
    ///
    /// The first half catches a dead MCP row. This one catches the lane that
    /// is about to become one: a requirement that arrives with its default
    /// and no forwarder is dead the moment a projection is written for it,
    /// and the projection's author has no way to see that from the call
    /// site. Caught here, it is one commit earlier and in the file that
    /// caused it.
    func testEveryClientRequirementIsForwardedBySocketClient() throws {
        let forwarded = try Self.declaredMethods(in: Self.socketClientPath)
        let source = try Self.read(Self.protocolPath)
        guard
            let start = source.range(
                of: "public protocol AgentIntegrationClient"),
            let end = source.range(
                of: "\nextension AgentIntegrationClient",
                range: start.upperBound..<source.endIndex)
        else {
            return XCTFail(
                "\(Self.protocolPath) no longer has an "
                    + "`AgentIntegrationClient` protocol followed by its "
                    + "defaults extension. This test reads the requirements "
                    + "from between them.")
        }
        let body = String(source[start.upperBound..<end.lowerBound])
        let required = Set(
            Self.matches(#"(?m)^\s{4}func ([a-zA-Z][a-zA-Z0-9]*)\("#,
                         in: body))
        XCTAssertFalse(
            required.isEmpty,
            "Read no requirements out of the AgentIntegrationClient "
                + "protocol body.")

        let missing = required.subtracting(forwarded).sorted()
        XCTAssertTrue(missing.isEmpty, """
            AgentIntegrationClient requires these and \
            SocketAgentIntegrationClient does not forward them, so they \
            answer their protocol default over the MCP face — which reads \
            like a missing host lane and is a missing forwarder:

            \(missing.joined(separator: ", "))

            If a lane genuinely has no socket operation yet, the honest fix \
            is still a forwarder: add the operation, or say so here in a \
            way a reader can check. An unforwarded requirement is a \
            capability this product would advertise and not have.
            """)
    }

    // MARK: - Derivation

    private static func describe(_ dead: [String: Set<String>]) -> String {
        dead.sorted { $0.key < $1.key }
            .map { "  \($0.key) — asked by \($0.value.sorted().joined(separator: ", "))" }
            .joined(separator: "\n")
    }

    private static func declaredMethods(in path: String) throws -> Set<String> {
        Set(matches(#"(?m)^\s+(?:public |private |internal )?func "#
                    + #"([a-zA-Z][a-zA-Z0-9]*)\("#,
                    in: try read(path)))
    }

    private static func projectionSources() throws -> [String] {
        let directory = repoRoot.appendingPathComponent(projectionDirectory)
        return try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix("Projection.swift")
                || $0.hasSuffix("Projections.swift") }
            .map { projectionDirectory + "/" + $0 }
            .sorted()
    }

    private static func matches(_ pattern: String, in text: String)
        -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            guard let found = Range($0.range(at: 1), in: text) else {
                return nil
            }
            return String(text[found])
        }
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func read(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path),
                   encoding: .utf8)
    }
}
