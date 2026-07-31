import XCTest
@testable import Host
import NOWAgentIntegration

/// The companion must work against whichever guest dialled in, and must
/// decide what it can do from what that guest ANSWERS — never from who it
/// says it is.
///
/// The fake guests below are deliberately anonymous. Nothing here sets a
/// hello name, and nothing in the code under test may read one: the guest
/// that serves `process.list` but refuses `file.list`, `software.list` and
/// `process.quit` is not "the 68K guest" to this code, it is a guest with
/// those capabilities. If a future change starts branching on identity,
/// these tests keep passing while the product silently goes stale — which
/// is exactly what happened to MetalQuitTests — so `testNoSourceFile...`
/// below reads the sources and fails instead.
@MainActor
final class AgentIntegrationCapabilityTests: XCTestCase {
    /// A guest that implements a stated subset of the contract and answers
    /// everything else the way both real guests do: `error not-implemented`
    /// for an unknown message family, `unknown-command` for an unknown
    /// command.
    private func installPartialGuest(
        on guest: FakeGuest,
        commands: [String],
        serves: Set<String>
    ) {
        guest.onMessage = { message in
            switch message {
            case .commandRequest(let request):
                guard request.name == "help" else { return }
                guard commands.isEmpty == false else {
                    try? guest.send(.error(.init(
                        id: request.id, code: "unknown-command",
                        message: "no such command")))
                    return
                }
                try? guest.send(.commandResult(.init(
                    id: request.id, ok: true,
                    output: ["help": commands.map { [$0, "a verb"] }],
                    error: nil)))
            case .processList(let request):
                guard serves.contains("process.list") else {
                    try? guest.send(.error(.init(
                        id: request.id, code: "not-implemented",
                        message: "unsupported message type")))
                    return
                }
                try? guest.send(.processListing(.init(
                    id: request.id,
                    processes: [.init(
                        name: "Finder", kind: "finder", code: "FNDR",
                        creator: "MACS", sizeKB: 4096, front: true,
                        psnHigh: 0, psnLow: 2)],
                    more: false, cursor: nil)))
            case .fileList(let request):
                guard serves.contains("file.list") else {
                    try? guest.send(.error(.init(
                        id: request.id, code: "not-implemented",
                        message: "unsupported message type")))
                    return
                }
                try? guest.send(.fileListing(.init(
                    id: request.id, path: request.path, entries: [],
                    more: false, cursor: nil, root: "Macintosh HD:")))
            case .softwareList(let request):
                guard serves.contains("software.list") else {
                    try? guest.send(.error(.init(
                        id: request.id, code: "not-implemented",
                        message: "unsupported message type")))
                    return
                }
                try? guest.send(.softwareListing(.init(
                    id: request.id, domain: request.domain, entries: [],
                    more: false, cursor: nil)))
            default:
                return
            }
        }
    }

    private func capabilities(
        _ report: AgentIntegrationSessionCapabilitiesResult
    ) throws -> AgentIntegrationSessionCapabilities {
        guard case .available(let value) = report else {
            throw XCTSkip("expected an available capability report")
        }
        return value
    }

    private func state(
        _ report: AgentIntegrationSessionCapabilities,
        tool: String
    ) -> AgentIntegrationCapabilityState? {
        report.tools.first { $0.tool == tool }?.state
    }

    private func state(
        _ report: AgentIntegrationSessionCapabilities,
        family: String
    ) -> AgentIntegrationCapabilityState? {
        report.families.first { $0.family == family }?.state
    }

    // MARK: - The partial guest

    /// The case the whole arc exists for: a guest implementing a small part
    /// of the contract gets a report that is right about every tool, with
    /// no code anywhere asking which guest it is.
    func testAPartialGuestGetsPerToolAvailabilityFromWhatItAnswers()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        installPartialGuest(
            on: guest,
            commands: ["launch", "quit", "help", "ps", "vprobe"],
            serves: ["process.list"])
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        let report = try capabilities(await adapter.sessionCapabilities())

        XCTAssertEqual(report.commandTable,
                       ["help", "launch", "ps", "quit", "vprobe"])
        XCTAssertEqual(state(report, family: "process.list"), .available)
        XCTAssertEqual(state(report, family: "file.list"), .unavailable)

        // Health never touches the guest, so it survives any guest.
        XCTAssertEqual(state(report, tool: "now_session_health"),
                       .available)
        // Newly possible: this guest serves process.list.
        XCTAssertEqual(state(report, tool: "now_list_processes"),
                       .available)
        // Not possible, and NOT because of who the guest is: it refused
        // file.list, so every Files read tool is out.
        XCTAssertEqual(state(report, tool: "now_guest_files_list"),
                       .unavailable)
        XCTAssertEqual(state(report, tool: "now_guest_files_stat"),
                       .unavailable)
        XCTAssertEqual(state(report, tool: "now_guest_files_capabilities"),
                       .unavailable)
        // A `quit` COMMAND is in this guest's table and must not be
        // mistaken for the process.quit family the tool's revalidation
        // model stands on.
        XCTAssertEqual(state(report, tool: "now_request_quit"), .unproven)
        XCTAssertEqual(
            report.tools.first { $0.tool == "now_request_quit" }?.missing,
            ["process.quit"],
            "process.list is served, so only the quit family is missing")
    }

    /// The same code, a complete guest, a different answer — which is what
    /// makes the derivation a derivation rather than a hardcoded table.
    func testACompleteGuestGetsTheOppositeAnswerFromTheSameCode()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        installPartialGuest(
            on: guest,
            commands: ["launch", "quit", "help", "gestalt"],
            serves: ["process.list", "file.list", "software.list"])
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        let report = try capabilities(
            await adapter.sessionCapabilities(probeCostly: true))

        XCTAssertEqual(state(report, family: "file.list"), .available)
        XCTAssertEqual(state(report, family: "software.list"), .available)
        XCTAssertEqual(state(report, tool: "now_guest_files_list"),
                       .available)
        XCTAssertEqual(state(report, tool: "now_launch_software"),
                       .available)
        XCTAssertTrue(report.probedCostly)
    }

    /// `unproven` is a third state and must not collapse into "no". A
    /// costly family nobody asked about is unknown, not absent — reporting
    /// it as absent would make the companion understate a guest that can
    /// in fact do the thing.
    func testAnUnprobedCostlyFamilyIsUnprovenRatherThanUnavailable()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        installPartialGuest(
            on: guest, commands: ["launch", "help"],
            serves: ["process.list", "file.list", "software.list"])
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        let report = try capabilities(await adapter.sessionCapabilities())

        XCTAssertEqual(state(report, family: "software.list"), .unproven)
        XCTAssertEqual(
            report.families.first { $0.family == "software.list" }?.evidence,
            .notProbedCostly)
        XCTAssertEqual(state(report, tool: "now_launch_software"),
                       .unproven,
                       "this guest may well be able to launch; nobody asked")
        XCTAssertFalse(report.probedCostly)
    }

    /// A mutating family is never probed. The report must not have quit
    /// anything to find out whether it can quit things.
    func testMutatingFamiliesAreNeverProbed() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        var quitRequests = 0
        installPartialGuest(
            on: guest, commands: ["help"], serves: ["process.list"])
        let inner = guest.onMessage
        guest.onMessage = { message in
            if case .processQuit = message { quitRequests += 1 }
            inner?(message)
        }
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        let report = try capabilities(
            await adapter.sessionCapabilities(probeCostly: true))

        XCTAssertEqual(quitRequests, 0)
        XCTAssertEqual(state(report, family: "process.quit"), .unproven)
        XCTAssertEqual(
            report.families.first { $0.family == "process.quit" }?.evidence,
            .notProbedMutating)
    }

    /// Ordinary use is the other capability source, and it must be able to
    /// settle a family the report is not allowed to probe.
    func testOrdinaryUseSettlesAFamilyTheReportWillNotProbe()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        installPartialGuest(
            on: guest, commands: ["help", "quit"],
            serves: ["process.list"])
        let inner = guest.onMessage
        guest.onMessage = { message in
            if case .processQuit(let request) = message {
                try? guest.send(.error(.init(
                    id: request.id, code: "not-implemented",
                    message: "unsupported message type")))
                return
            }
            inner?(message)
        }
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        guard case .available(let snapshot) = await adapter.processList(),
              let reference = snapshot.processes.first?.reference else {
            return XCTFail("expected a reference to attempt quit with")
        }
        _ = await adapter.requestQuit(reference: reference)

        let report = try capabilities(await adapter.sessionCapabilities())
        XCTAssertEqual(state(report, family: "process.quit"), .unavailable)
        XCTAssertEqual(
            report.families.first { $0.family == "process.quit" }?.evidence,
            .refusedInUse)
        XCTAssertEqual(state(report, tool: "now_request_quit"),
                       .unavailable)
    }

    /// Silence, or a plain failure, is not a refusal. Only the contract's
    /// typed "I do not implement that" settles a family; anything else —
    /// a Toolbox error, a wedged MacTCP stack going quiet — says nothing
    /// about what the guest implements, and writing it down as a missing
    /// feature would make one bad afternoon look permanent.
    func testANonRefusalFailureLeavesTheFamilyUnproven() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        installPartialGuest(
            on: guest, commands: ["help"], serves: ["process.list"])
        let inner = guest.onMessage
        guest.onMessage = { message in
            if case .fileList(let request) = message {
                try? guest.send(.error(.init(
                    id: request.id, code: "io-error",
                    message: "the volume went away")))
                return
            }
            inner?(message)
        }
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        let report = try capabilities(await adapter.sessionCapabilities())
        let fileList = report.families.first { $0.family == "file.list" }

        XCTAssertEqual(fileList?.state, .unproven,
                       "a failure that is not a refusal proves nothing")
        XCTAssertEqual(fileList?.refusalCode, "io-error",
                       "the guest's own words are still reported")
        XCTAssertEqual(state(report, tool: "now_guest_files_list"),
                       .unproven)
    }

    // MARK: - Refusals must arrive as refusals

    /// What makes a companion usable against an incomplete guest at all.
    ///
    /// An `error` frame carries the id of whatever request it answers, and
    /// the ids come from ONE sequence, so whichever waiter holds that id is
    /// owed the refusal now. Routing only some of the waiter kinds is not a
    /// smaller version of this: it is the same 15- or 30-second timeout
    /// carrying no reason, for exactly the requests a partial guest refuses
    /// most. Every family here settles promptly and with the guest's own
    /// code, or this test hangs until its watchdog and fails on the code.
    func testEveryFamilyWaiterGetsTheGuestsRefusalNotATimeout()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        guest.onMessage = { message in
            let id: Int
            switch message {
            case .fileList(let request): id = request.id
            case .processList(let request): id = request.id
            case .softwareList(let request): id = request.id
            case .processQuit(let request): id = request.id
            case .fileMkdir(let request): id = request.id
            default: return
            }
            try? guest.send(.error(.init(
                id: id, code: "not-implemented",
                message: "unsupported message type")))
        }

        func settle(
            _ name: String,
            _ request: (@escaping (String) -> Void) -> Void
        ) async throws -> String {
            let start = Date()
            let code: String = await withCheckedContinuation { c in
                request { c.resume(returning: $0) }
            }
            XCTAssertLessThan(
                Date().timeIntervalSince(start), 5,
                "\(name) waited on a watchdog for an answer the guest had "
                    + "already sent")
            return code
        }

        let file = try await settle("file.list") { done in
            listener.listFiles(path: "") { result in
                done(Self.failureCode(result))
            }
        }
        let processes = try await settle("process.list") { done in
            listener.listProcesses { result in
                done(Self.failureCode(result))
            }
        }
        let software = try await settle("software.list") { done in
            listener.listSoftware(domain: "apps") { result in
                done(Self.failureCode(result))
            }
        }
        let quit = try await settle("process.quit") { done in
            listener.driveProcess(psnHigh: 0, psnLow: 2, verb: .quit) {
                result in
                done(Self.failureCode(result))
            }
        }

        XCTAssertEqual(file, "not-implemented")
        XCTAssertEqual(processes, "not-implemented")
        XCTAssertEqual(software, "not-implemented")
        XCTAssertEqual(quit, "not-implemented")
    }

    private static func failureCode<Value>(
        _ result: Result<Value, GuestListener.FileFailure>
    ) -> String {
        switch result {
        case .success: return "unexpected-success"
        case .failure(let failure): return failure.code
        }
    }

    // MARK: - The rule itself

    /// The one rule this arc is a chip rather than a patch for. Prose goes
    /// stale; this fails.
    ///
    /// **Read through `GateSource.hostSwift`, which drops comment lines.**
    /// Scanning the raw text made this gate fire on doc comments four times
    /// in one week, once per agent, an amend each — and every one of them
    /// was prose *explaining* the rule, in a file that obeys it.
    ///
    /// Does stripping weaken it? No, and the reasoning is worth writing
    /// down, because the instinct is that a guest name in a comment beside
    /// a decision is evidence the author was reasoning from identity. It
    /// is — but it is evidence about an author, not about the code, and
    /// this gate's claim is about code: a comment cannot branch. What the
    /// raw scan bought was a weak proxy with a high false-positive rate;
    /// what it cost was more than that, because a surface this narrow was
    /// the price of keeping the noise tolerable.
    ///
    /// So the strip pays for the surface. Both trees are now walked whole
    /// and RECURSIVELY, rather than one non-recursive directory plus five
    /// hand-named files. The audit of 2026-07-31 found that the hand-named
    /// list covered 5 of the 26 files in `Host/Automation` and none of the
    /// 22 in `NOWAgentIntegration` outside `Projection/` — `if guestName ==
    /// "now-68k"` in any of the other forty-three was invisible. That hole
    /// was larger than the one the comments were making noise about.
    func testNoCompanionCodeBranchesOnGuestIdentity() throws {
        let root = GateSource.repoRoot
        // Every file of the companion surface, health included: naming
        // either guest is out everywhere, because there is no legitimate
        // reason for this code to know which one is on the wire.
        //
        // ENUMERATED, never listed. A hand-written list is how this guard
        // quietly stops covering the surface it names: the whole point of
        // the registry is that a capability arrives as a new file, and a
        // new file nobody added here is the one place identity creeps back
        // in. That is not hypothetical — it is what the list this replaced
        // had already become.
        var surface: [String] = []
        for tree in ["now-host/Sources/Host/Automation",
                     "now-host/Sources/NOWAgentIntegration",
                     "now-host/Sources/NOWAgentCompanion"] {
            let base = root.appendingPathComponent(tree)
            let walk = FileManager.default.enumerator(
                at: base, includingPropertiesForKeys: nil)
            while let url = walk?.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                surface.append(
                    tree + "/" + url.path.replacingOccurrences(
                        of: base.path + "/", with: ""))
            }
        }
        surface.sort()
        XCTAssertGreaterThanOrEqual(
            surface.count, 60,
            "This guard walks three source trees whole; a short read means "
                + "a path moved and the rule is being enforced over almost "
                + "nothing.")
        // The ones that DECIDE something. `guestName` / `guestOS` /
        // `guestVersion` are the hello's fields — the only identity the
        // host has — and reading them in a file that chooses what a tool
        // may do is the whole failure mode. Health is absent from this
        // second list on purpose: it REPORTS those fields to its caller,
        // which is a projection, not a decision.
        let deciders = surface.filter {
            !$0.hasSuffix("AgentIntegrationSessionHealth.swift")
        }
        let explanation = """
            Availability in the agent companion is decided by CAPABILITY, \
            never by guest identity — see docs/command-parity.md, "The MCP \
            is a client, not a face". A table keyed on which guest dialled \
            in goes stale the afternoon that guest grows a verb, and \
            nothing fails when it does: it just quietly understates the \
            machine, which is what happened to MetalQuitTests.
            """

        for file in surface {
            let text = try GateSource.hostSwift(file)
            for needle in ["now-68k", "NOW-68K"] {
                XCTAssertFalse(
                    text.contains(needle),
                    "\(file) names a specific guest (\"\(needle)\"). "
                        + explanation)
            }
        }
        for file in deciders {
            let text = try GateSource.hostSwift(file)
            for needle in ["guestName", "guestOS", "guestVersion"] {
                XCTAssertFalse(
                    text.contains(needle),
                    "\(file) reads the hello field \"\(needle)\", and that "
                        + "file decides what a tool may do. " + explanation)
            }
        }
    }
}
