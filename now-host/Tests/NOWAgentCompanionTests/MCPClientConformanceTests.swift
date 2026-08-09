import Foundation
import XCTest

/// **Every advertised tool, called by a real client, classified.**
///
/// The gate the transport defect of 2026-08-07 needed and did not have.
/// `StdioTransportLivenessTests` next door proves the loop answers *one*
/// message with stdio open; this proves the whole surface does, and says
/// what each tool answered.
///
/// ## What it does and does not prove
///
/// With no host running — the CI shape, and the default — every row's
/// honest answer is a refusal naming the absent host. That is still worth
/// gating, and it is precisely the gate that was missing: it exercises the
/// transport, the handshake, the dispatch and every tool's argument
/// validation against a client that holds the pipe open. **A tool that only
/// works when a driver closes stdin fails here immediately.**
///
/// With `NOW_MCP_CONFORMANCE_LIVE=1` and a host running, the same run means
/// something stronger: `now-host-unavailable` becomes a failure, because a
/// healthy host answering "there is no host" is the defect class this plan
/// is named for.
///
/// ## Why the list is not in this file
///
/// The tools come from `tools/list` — the surface's own answer — and the
/// recipe book is checked against it **in both directions**. A capability
/// added without a recipe fails naming itself; a recipe for a capability
/// that no longer exists fails too. Nothing here enumerates the surface, so
/// nothing here can rot into agreeing with an older one.
final class MCPClientConformanceTests: XCTestCase {

    private static var live: Bool {
        ProcessInfo.processInfo.environment["NOW_MCP_CONFORMANCE_LIVE"] == "1"
    }

    /// Per-call bound. Generous: with no host every call is local and
    /// answers in milliseconds, and with one it may reach a 1400c.
    private static let callTimeout: TimeInterval = 45

    // MARK: The gate

    func testEveryAdvertisedToolAnswersARealClient() throws {
        let client = try MCPClient(executable: Self.companionExecutable(),
                                   environment: Self.environment())
        defer { client.shutDown() }

        let initialize = try client.handshake()
        XCTAssertNotNil(initialize["result"],
                        "initialize did not succeed: \(initialize)")

        let tools = try client.advertisedTools()
        let advertised = tools.compactMap { $0["name"] as? String }
        XCTAssertFalse(advertised.isEmpty,
                       "The surface advertised no tools at all")

        try assertRecipesCoverExactly(advertised)

        try requireTheBuildUnderTest(client)

        let rows = try run(advertised, through: client)
        print(Self.table(rows, live: Self.live))

        let failed = rows.filter { $0.verdict == .failed }
        XCTAssertTrue(failed.isEmpty, """
            \(failed.count) of \(rows.count) advertised tools did not answer \
            a real MCP client acceptably.

            \(failed.map { "  \($0.tool): \($0.detail)" }
                .joined(separator: "\n"))

            A refusal that names a reason is a PASS here — with no host \
            running, that is what every row should be. A timeout, an \
            unparseable reply, an "Unknown tool" for a name the surface \
            itself advertises, or an invalid-arguments rejection of this \
            driver's own recipe is not.
            """)

        if Self.live {
            let mustSucceed = Set([
                "now_guest_files_mutate",
                "now_guest_files_upload_begin",
                "now_guest_files_upload_append",
                "now_guest_files_upload_commit",
            ])
            let notServed = rows.filter {
                mustSucceed.contains($0.tool) && $0.verdict != .served
            }
            XCTAssertTrue(notServed.isEmpty, """
                The live create-and-upload chain must succeed, not merely \
                return an explained refusal. Non-served rows: \
                \(notServed.map { "\($0.tool): \($0.detail)" }
                    .joined(separator: ", "))
                """)
        }

        /* Not an assertion, and deliberately: an uncovered row is a finding
           to be READ, and failing on it would push the next person to
           invent an argument rather than name the gap. It is printed in the
           table and repeated here so it survives a truncated log. */
        let uncovered = rows.filter { $0.verdict == .uncovered }
        if !uncovered.isEmpty {
            print("""

                UNCOVERED — advertised, and this surface can construct no \
                legal argument for it:
                \(uncovered.map { "  \($0.tool): \($0.detail)" }
                    .joined(separator: "\n"))
                """)
        }
    }

    func testUploadRecipesShareOneFreshBoundedScratchDestination() {
        let first = MCPConformanceRecipes.Context()
        let second = MCPConformanceRecipes.Context()

        XCTAssertNotEqual(first.scratchFolder, second.scratchFolder)
        XCTAssertLessThanOrEqual(first.scratchFolder.count, 31)
        XCTAssertFalse(first.scratchFolder.contains(":"))

        guard case .send(let mutate, .real) =
                MCPConformanceRecipes.all["now_guest_files_mutate"]?
                    .build(first),
              case .send(let begin, .real) =
                MCPConformanceRecipes.all["now_guest_files_upload_begin"]?
                    .build(first) else {
            return XCTFail("expected real mkdir and upload recipes")
        }
        XCTAssertEqual(mutate["path"] as? String, first.scratchFolder)
        XCTAssertEqual(begin["destinationPath"] as? String,
                       first.scratchFolder + ":probe.txt")
    }

    // MARK: Whose machine answered

    /// **Which guest is on the other end, asserted before anything it says
    /// is believed.**
    ///
    /// Every QEMU guest on this Mac sees the host as `10.0.2.2`, several
    /// sessions run at once, and the agent endpoint was per-uid until
    /// `NOW_AGENT_SOCKET_SUFFIX` — so a live run can be answered in full,
    /// promptly and wrongly by another branch's Macintosh. AGENTS.md's
    /// metal rule in its host-side form.
    ///
    /// `NOW_MCP_CONFORMANCE_BUILD` is the build prefix the run expects.
    /// Absent, the run says out loud whose machine it reached rather than
    /// silently accepting whichever one did, because a table nobody can
    /// attribute to a build is not a measurement.
    private func requireTheBuildUnderTest(_ client: MCPClient) throws {
        guard Self.live else { return }
        let reply = try client.request(
            "tools/call",
            params: ["name": "now_list_machines", "arguments": [:]],
            timeout: Self.callTimeout)
        let structured = (reply["result"] as? [String: Any])?[
            "structuredContent"] as? [String: Any]
        let health = structured?["health"] as? [String: Any]
        let guest = health?["guest"] as? [String: Any]
        let build = (guest?["build"] as? String) ?? ""
        let name = (guest?["name"] as? String) ?? "<no guest>"
        print("=== conformance is driving: \(name), build \(build)")

        guard let expected = ProcessInfo.processInfo
            .environment["NOW_MCP_CONFORMANCE_BUILD"], !expected.isEmpty
        else { return }
        XCTAssertTrue(build.hasPrefix(expected), """
            A live conformance run reached a guest whose build is \
            \(build.isEmpty ? "<unreported>" : build), and this run expects \
            \(expected). Any VM on this Mac can answer a host, and several \
            sessions run here at once — a full table from the wrong \
            Macintosh reads exactly like a passing one.
            """)
    }

    // MARK: Totality

    /// The recipe book against the live surface, **both ways**.
    private func assertRecipesCoverExactly(_ advertised: [String]) throws {
        let advertisedSet = Set(advertised)
        let recipes = Set(MCPConformanceRecipes.all.keys)
        let missing = advertisedSet.subtracting(recipes).sorted()
        let stale = recipes.subtracting(advertisedSet).sorted()
        XCTAssertTrue(missing.isEmpty, """
            The surface advertises \(missing.count) tool(s) this conformance \
            run has no argument for: \(missing.joined(separator: ", ")).

            Sampling is how a dead surface stayed green, so this fails rather \
            than skipping. Add a recipe in MCPConformanceRecipes — and if no \
            legal argument exists on this surface, say so with \
            `.uncovered(reason)`, which is a named finding rather than a gap.
            """)
        XCTAssertTrue(stale.isEmpty, """
            \(stale.count) recipe(s) name a tool the surface no longer \
            advertises: \(stale.joined(separator: ", ")). A recipe book that \
            outlives its capability is the hand-kept list this gate exists \
            to avoid.
            """)
    }

    // MARK: The run

    /// Producers first, then the surface's own order.
    private func run(_ advertised: [String],
                     through client: MCPClient) throws
        -> [MCPConformance.Row] {
        var order = MCPConformanceRecipes.producersFirst
            .filter(advertised.contains)
        order += advertised.filter { !order.contains($0) }

        var context = MCPConformanceRecipes.Context()
        var rows: [MCPConformance.Row] = []
        for tool in order {
            guard let recipe = MCPConformanceRecipes.all[tool] else {
                continue  // assertRecipesCoverExactly already failed.
            }
            switch recipe.build(context) {
            case .humanGated(let reason):
                rows.append(.init(tool: tool, verdict: .humanGated,
                                  argumentKind: .none, detail: reason,
                                  elapsed: 0))
            case .uncovered(let reason):
                rows.append(.init(tool: tool, verdict: .uncovered,
                                  argumentKind: .none, detail: reason,
                                  elapsed: 0))
            case .send(let arguments, let kind):
                let started = Date()
                let reply: [String: Any]
                do {
                    reply = try client.request(
                        "tools/call",
                        params: ["name": tool, "arguments": arguments],
                        timeout: Self.callTimeout)
                } catch {
                    rows.append(.init(
                        tool: tool, verdict: .failed, argumentKind: kind,
                        detail: "\(error)",
                        elapsed: Date().timeIntervalSince(started)))
                    continue
                }
                let (verdict, detail) = MCPConformance.classify(
                    reply, live: Self.live)
                rows.append(.init(
                    tool: tool, verdict: verdict, argumentKind: kind,
                    detail: detail,
                    elapsed: Date().timeIntervalSince(started)))
                harvest(reply, into: &context)
            }
        }
        return rows
    }

    // MARK: Harvesting

    /// Pull every reference this reply minted into the context.
    ///
    /// It scans the reply's own JSON for the reference *shapes* rather than
    /// walking a model, and that is on purpose: a driver that decoded
    /// `AgentIntegrationElementObservation` would agree with the host's
    /// idea of the tree by construction, and a reshaping defect there would
    /// be invisible to it. The one shape it does read structurally is the
    /// text element, because `windows[].text.ref` is the only reference on
    /// the surface that `now_text_get` accepts and `now_control_act`
    /// refuses — they are not distinguishable by their spelling.
    private func harvest(_ reply: [String: Any],
                         into context: inout MCPConformanceRecipes.Context) {
        guard let result = reply["result"] as? [String: Any],
              let structured = result["structuredContent"] as? [String: Any]
        else { return }

        var found = Harvest()
        Self.scan(structured, into: &found)

        context.windowReference =
            context.windowReference ?? found.windows.first
        context.elementReference =
            context.elementReference ?? found.elements.first
        context.textElementReference =
            context.textElementReference ?? found.textElements.first
        context.processReference =
            context.processReference ?? found.processes.first
        context.softwareReference =
            context.softwareReference ?? found.software.first
        context.uploadID = context.uploadID ?? found.uploadID
        context.mirrorSnapshotID =
            context.mirrorSnapshotID ?? found.snapshotID
        context.guestFilePath = context.guestFilePath ?? found.filePath
    }

    private struct Harvest {
        var windows: [String] = []
        var elements: [String] = []
        var textElements: [String] = []
        var processes: [String] = []
        var software: [String] = []
        var uploadID: String?
        var snapshotID: Int?
        var filePath: String?
    }

    private static func scan(_ value: Any, into found: inout Harvest,
                             underTextKey: Bool = false) {
        if let object = value as? [String: Any] {
            if let ref = object["ref"] as? String,
               ref.hasPrefix("now-element-"), underTextKey {
                found.textElements.append(ref)
            }
            if let id = object["uploadID"] as? String, found.uploadID == nil {
                found.uploadID = id
            }
            if let id = (object["snapshotID"] as? NSNumber)?.intValue,
               found.snapshotID == nil {
                found.snapshotID = id
            }
            /* A file, never a folder: `stat` and `download` both take a
               path, and only one of them can answer about a directory. */
            if found.filePath == nil,
               let path = object["path"] as? String, !path.isEmpty,
               (object["kind"] as? String) == "file"
                   || (object["isDirectory"] as? Bool) == false {
                found.filePath = path
            }
            for (key, child) in object {
                Self.scan(child, into: &found, underTextKey: key == "text")
            }
            return
        }
        if let array = value as? [Any] {
            for child in array {
                Self.scan(child, into: &found, underTextKey: underTextKey)
            }
            return
        }
        guard let text = value as? String else { return }
        if text.hasPrefix("now-window-") { found.windows.append(text) }
        if text.hasPrefix("now-element-"), !underTextKey {
            found.elements.append(text)
        }
        if text.hasPrefix("now-process-") { found.processes.append(text) }
        if text.hasPrefix("now-software-") { found.software.append(text) }
    }

    // MARK: The table

    /// The run's own report, printed whether it passes or fails.
    ///
    /// It is the artefact, not a debugging aid: `docs/mcp-coverage.md`'s
    /// **exercised** column is filled by pasting this, and a table only
    /// printed on failure could not fill it.
    static func table(_ rows: [MCPConformance.Row], live: Bool) -> String {
        var out = """

            === MCP client conformance — \(rows.count) advertised tools, \
            \(live ? "LIVE (a host is running)" : "no host") ===

            | tool | verdict | argument | ms | detail |
            |---|---|---|---|---|

            """
        for row in rows {
            let detail = row.detail
                .replacingOccurrences(of: "|", with: "/")
                .replacingOccurrences(of: "\n", with: " ")
            out += "| `\(row.tool)` | \(row.verdict.rawValue) "
                + "| \(row.argumentKind.rawValue) "
                + "| \(Int(row.elapsed * 1000)) | \(detail) |\n"
        }
        var counts: [MCPConformance.Verdict: Int] = [:]
        for row in rows { counts[row.verdict, default: 0] += 1 }
        let summary = [MCPConformance.Verdict.served, .refused, .failed,
                       .humanGated, .uncovered]
            .map { "\($0.rawValue) \(counts[$0] ?? 0)" }
            .joined(separator: ", ")
        out += "\n\(summary)\n"
        return out
    }

    // MARK: The environment the companion runs in

    /// **The default run reaches NOTHING, on purpose.**
    ///
    /// Without this, running the gate on a developer's Mac silently
    /// reaches whichever host happens to hold the per-uid socket — which
    /// on this desk is routinely a different session's host, driving a
    /// different branch's Macintosh. Watched: the "no host" run came back
    /// with `now_list_machines` served, from a stack this run had never
    /// heard of.
    ///
    /// So the default points the companion at an endpoint nothing binds,
    /// which is what CI's shape actually is and what the gate is meant to
    /// assert: the transport, the handshake, the dispatch and every
    /// tool's argument validation, against a client holding the pipe
    /// open. Going live is a deliberate act — `NOW_MCP_CONFORMANCE_LIVE=1`
    /// — and then the caller's own `NOW_AGENT_SOCKET_SUFFIX` decides
    /// which host it means.
    private static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if !live {
            environment["NOW_AGENT_SOCKET_SUFFIX"] = "conformance"
        }
        return environment
    }

    // MARK: The binary

    /// The built companion, beside the test bundle. Fails rather than
    /// skips, for the reason `StdioTransportLivenessTests` states: it is a
    /// product of this same package, so its absence is a broken build.
    private static func companionExecutable() throws -> URL {
        let candidate = Bundle(for: MCPClientConformanceTests.self)
            .bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("NOWAgentCompanion")
        guard FileManager.default.isExecutableFile(atPath: candidate.path)
        else {
            XCTFail("""
                No NOWAgentCompanion executable beside the test bundle at \
                \(candidate.path). It is a product of this same package, so \
                this is a build that did not produce it rather than a \
                missing tool — and this gate does not skip.
                """)
            throw CocoaError(.fileNoSuchFile)
        }
        return candidate
    }
}
