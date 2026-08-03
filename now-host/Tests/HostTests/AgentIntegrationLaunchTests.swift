import XCTest
@testable import Host
import NOWAgentIntegration

@MainActor
final class AgentIntegrationLaunchTests: XCTestCase {
    private func entry(_ name: String, path: String,
                       version: String? = nil) -> SoftwareEntry {
        .init(name: name, path: path, type: "APPL", creator: "ttxt",
              sizeK: 200, off: false, running: false, version: version)
    }

    private func installResponder(
        on guest: FakeGuest,
        entries: @escaping () -> [SoftwareEntry],
        commandCount: Counter,
        launchedTarget: Box<String?>,
        commandResult: CommandResult? = nil
    ) {
        guest.onMessage = { message in
            switch message {
            case .softwareList(let request):
                try? guest.send(.softwareListing(.init(
                    id: request.id,
                    domain: "apps",
                    entries: entries(),
                    more: false,
                    cursor: nil,
                    note: nil)))
            case .commandRequest(let request) where request.name == "launch":
                commandCount.value += 1
                launchedTarget.value = request.args?["target"]?.stringValue
                let reply = commandResult.map {
                    CommandResult(
                        id: request.id,
                        ok: $0.ok,
                        output: $0.output,
                        error: $0.error)
                } ?? .init(
                        id: request.id,
                        ok: true,
                        output: ["launch": [["Launch",
                                             "launched SimpleText"]]],
                        error: nil)
                try? guest.send(.commandResult(reply))
            default:
                break
            }
        }
    }

    func testDisconnectedGuestReturnsTypedUnavailable() async {
        let listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"))
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        let result = await adapter.launchSoftware(.name("SimpleText"))

        guard case .unavailable(let unavailable) = result else {
            return XCTFail("a disconnected guest must be unavailable")
        }
        XCTAssertEqual(unavailable.code, "now-guest-unavailable")
    }

    func testUniqueExactNameLaunchesCurrentListingPathWithoutExposingIt()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let count = Counter()
        let target = Box<String?>(nil)
        installResponder(
            on: guest,
            entries: { [self] in
                [entry("SimpleText", path: "HD:Apps:SimpleText",
                       version: "1.4")]
            },
            commandCount: count,
            launchedTarget: target)
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        let result = await adapter.launchSoftware(.name("simpletext"))

        guard case .launched(let receipt) = result else {
            return XCTFail("one exact HFS-style name should launch")
        }
        XCTAssertEqual(count.value, 1)
        XCTAssertEqual(target.value, "HD:Apps:SimpleText")
        XCTAssertEqual(receipt.software.name, "SimpleText")
        XCTAssertEqual(receipt.software.version, "1.4")
        XCTAssertFalse(receipt.software.reference.contains("SimpleText"))
        let encoded = try JSONEncoder().encode(result)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self)
            .contains("HD:Apps"))
    }

    func testSubstringAndMissingNameReturnNotFoundWithoutLaunching()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let count = Counter()
        installResponder(
            on: guest,
            entries: { [self] in
                [entry("SimpleText", path: "HD:Apps:SimpleText")]
            },
            commandCount: count,
            launchedTarget: Box(nil))
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        let result = await adapter.launchSoftware(.name("Simple"))

        guard case .notFound(let notFound) = result else {
            return XCTFail("substring selection must not guess")
        }
        XCTAssertEqual(notFound.code, "now-software-not-found")
        XCTAssertEqual(count.value, 0)
    }

    func testAmbiguousNameReturnsOpaqueCandidatesAndLaunchesNothing()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let count = Counter()
        installResponder(
            on: guest,
            entries: { [self] in [
                entry("SimpleText", path: "HD:Apps:SimpleText",
                      version: "1.4"),
                entry("SimpleText", path: "HD:Old:SimpleText",
                      version: "1.3"),
            ] },
            commandCount: count,
            launchedTarget: Box(nil))
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        let result = await adapter.launchSoftware(.name("SimpleText"))

        guard case .ambiguous(let ambiguous) = result else {
            return XCTFail("duplicate exact names must refuse")
        }
        XCTAssertEqual(ambiguous.matchCount, 2)
        XCTAssertEqual(ambiguous.candidates.count, 2)
        XCTAssertEqual(Set(ambiguous.candidates.map(\.reference)).count, 2)
        XCTAssertEqual(count.value, 0)
        let encoded = try JSONEncoder().encode(result)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self)
            .contains("HD:"))
    }

    func testOpaqueCandidateIsRevalidatedAgainstAFreshListing()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        var entries = [
            entry("SimpleText", path: "HD:Apps:SimpleText", version: "1.4"),
            entry("SimpleText", path: "HD:Old:SimpleText", version: "1.3"),
        ]
        let count = Counter()
        let target = Box<String?>(nil)
        installResponder(on: guest, entries: { entries },
                         commandCount: count, launchedTarget: target)
        let adapter = AgentIntegrationHostAdapter(listener: listener)
        guard case .ambiguous(let ambiguous) =
                await adapter.launchSoftware(.name("SimpleText")),
              let selected = ambiguous.candidates.last else {
            return XCTFail("expected two current candidates")
        }

        let launched = await adapter.launchSoftware(
            .reference(selected.reference))
        guard case .launched = launched else {
            return XCTFail("a current opaque selection should launch")
        }
        XCTAssertEqual(target.value, "HD:Old:SimpleText")

        entries.removeLast()
        let stale = await adapter.launchSoftware(
            .reference(selected.reference))
        guard case .refused(let refusal) = stale else {
            return XCTFail("a missing current identity must be stale")
        }
        XCTAssertEqual(refusal.code, "now-software-reference-stale")
        XCTAssertEqual(count.value, 1)
    }

    func testReconnectInvalidatesAnOpaqueSoftwareReference()
        async throws {
        let (listener, firstGuest) = try await connectedListener()
        let count = Counter()
        installResponder(
            on: firstGuest,
            entries: { [self] in [
                entry("SimpleText", path: "HD:Apps:SimpleText"),
                entry("SimpleText", path: "HD:Old:SimpleText"),
            ] },
            commandCount: count,
            launchedTarget: Box(nil))
        let adapter = AgentIntegrationHostAdapter(listener: listener)
        guard case .ambiguous(let ambiguity) =
                await adapter.launchSoftware(.name("SimpleText")),
              let oldReference = ambiguity.candidates.first?.reference else {
            return XCTFail("expected an opaque reference")
        }

        firstGuest.connection.cancel()
        try await waitUntil("first guest disconnected") {
            if case .listening = listener.state { return true }
            return false
        }
        let secondGuest = FakeGuest(
            port: try XCTUnwrap(listener.boundPort))
        defer {
            secondGuest.connection.cancel()
            listener.stop()
        }
        secondGuest.start()
        try secondGuest.send(.hello(.init(
            contract: Contract.revision,
            side: "guest",
            version: "0.1.0",
            name: "PowerBook 1400",
            os: "9.1",
            chunk: 8192)))
        try await waitUntil("second guest connected") {
            if case .connected = listener.state { return true }
            return false
        }

        let result = await adapter.launchSoftware(
            .reference(oldReference))

        guard case .refused(let refusal) = result else {
            return XCTFail("a pre-reconnect reference must be stale")
        }
        XCTAssertEqual(refusal.code, "now-software-reference-stale")
        XCTAssertEqual(count.value, 0)
    }

    func testExactMatchOnLaterPageUsesThePagedCurrentCatalog()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let target = Box<String?>(nil)
        guest.onMessage = { [self] message in
            switch message {
            case .softwareList(let request):
                if request.cursor == nil {
                    try? guest.send(.softwareListing(.init(
                        id: request.id,
                        domain: "apps",
                        entries: [
                            entry("Finder", path: "HD:System:Finder"),
                        ],
                        more: true,
                        cursor: 2,
                        note: nil)))
                } else {
                    try? guest.send(.softwareListing(.init(
                        id: request.id,
                        domain: "apps",
                        entries: [
                            entry("SimpleText", path: "HD:Apps:SimpleText"),
                        ],
                        more: false,
                        cursor: nil,
                        note: nil)))
                }
            case .commandRequest(let request):
                target.value = request.args?["target"]?.stringValue
                try? guest.send(.commandResult(.init(
                    id: request.id,
                    ok: true,
                    output: ["launch": [["Launch", "launched SimpleText"]]],
                    error: nil)))
            default:
                break
            }
        }
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        guard case .launched =
                await adapter.launchSoftware(.name("SimpleText")) else {
            return XCTFail("the complete current catalog should resolve")
        }
        XCTAssertEqual(target.value, "HD:Apps:SimpleText")
    }

    func testEmptyPathAndGuestRefusalRemainTypedRefusals()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        var entries = [entry("SimpleText", path: "")]
        let count = Counter()
        let refused = CommandResult(
            id: 0,
            ok: false,
            output: nil,
            error: .init(code: "launch-refused",
                         message:
                            "no such file: HD:Apps:SimpleText"))
        installResponder(on: guest, entries: { entries },
                         commandCount: count, launchedTarget: Box(nil),
                         commandResult: refused)
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        guard case .refused(let missingPath) =
                await adapter.launchSoftware(.name("SimpleText")) else {
            return XCTFail("an unnamed path cannot launch")
        }
        XCTAssertEqual(missingPath.code, "now-software-not-launchable")
        XCTAssertEqual(count.value, 0)

        entries = [entry("SimpleText", path: "HD:Apps:SimpleText")]
        guard case .refused(let guestRefusal) =
                await adapter.launchSoftware(.name("SimpleText")) else {
            return XCTFail("guest refusal must remain a refusal")
        }
        XCTAssertEqual(guestRefusal.code, "now-launch-refused")
        XCTAssertEqual(
            guestRefusal.message, "The paired guest refused launch")
        XCTAssertFalse(guestRefusal.message.contains("HD:"))
        XCTAssertEqual(count.value, 1)
    }

    func testReferenceCapacityRolloverKeepsOneAmbiguityBatchCurrent()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        var entries: [SoftwareEntry] = []
        let count = Counter()
        let target = Box<String?>(nil)
        installResponder(
            on: guest,
            entries: { entries },
            commandCount: count,
            launchedTarget: target)
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        for group in 0..<7 {
            entries = (0..<8).map {
                entry("App\(group)", path: "HD:\(group):\($0)")
            }
            guard case .ambiguous =
                    await adapter.launchSoftware(.name("App\(group)")) else {
                return XCTFail("each setup group should be ambiguous")
            }
        }
        entries = (0..<7).map {
            entry("AlmostFull", path: "HD:Almost:\($0)")
        }
        guard case .ambiguous =
                await adapter.launchSoftware(.name("AlmostFull")) else {
            return XCTFail("the setup should register 63 references")
        }

        entries = (0..<8).map {
            entry("Target", path: "HD:Target:\($0)")
        }
        guard case .ambiguous(let ambiguity) =
                await adapter.launchSoftware(.name("Target")),
              let first = ambiguity.candidates.first else {
            return XCTFail("the rollover group should return candidates")
        }
        entries = [entry("Target", path: "HD:Target:0")]

        guard case .launched =
                await adapter.launchSoftware(.reference(first.reference))
        else {
            return XCTFail("a just-returned candidate must remain current")
        }
        XCTAssertEqual(target.value, "HD:Target:0")
    }

    func testCommandDeadlineReturnsOutcomeUnknownAndBlocksRetry()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let pending = Box<CommandRequest?>(nil)
        let replyToCommands = Box(false)
        guest.onMessage = { message in
            switch message {
            case .softwareList(let request):
                try? guest.send(.softwareListing(.init(
                    id: request.id,
                    domain: "apps",
                    entries: [
                        self.entry(
                            "SimpleText", path: "HD:Apps:SimpleText"),
                    ],
                    more: false,
                    cursor: nil,
                    note: nil)))
            case .commandRequest(let request):
                pending.value = request
                if replyToCommands.value {
                    try? guest.send(.commandResult(.init(
                        id: request.id,
                        ok: true,
                        output: nil,
                        error: nil)))
                }
            default:
                break
            }
        }
        let adapter = AgentIntegrationHostAdapter(
            listener: listener, launchCommandTimeout: 0.05)

        guard case .refused(let timeout) =
                await adapter.launchSoftware(.name("SimpleText")) else {
            return XCTFail("a missing command result must settle")
        }
        XCTAssertEqual(timeout.code, "now-launch-outcome-unknown")
        guard case .refused(let busy) =
                await adapter.launchSoftware(.name("SimpleText")) else {
            return XCTFail("retry must be blocked while outcome is unknown")
        }
        XCTAssertEqual(busy.code, "now-launch-busy")

        let firstRequest = try XCTUnwrap(pending.value)
        try guest.send(.commandResult(.init(
            id: firstRequest.id, ok: true, output: nil, error: nil)))
        replyToCommands.value = true
        try await Task.sleep(nanoseconds: 20_000_000)

        guard case .launched =
                await adapter.launchSoftware(.name("SimpleText")) else {
            return XCTFail("a late result should release the action gate")
        }
    }

    func testConcurrentLaunchIsRefusedBeforeASecondCatalogSweep()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let listRequests = Counter()
        let pending = Box<SoftwareList?>(nil)
        guest.onMessage = { message in
            switch message {
            case .softwareList(let request):
                listRequests.value += 1
                pending.value = request
            case .commandRequest(let request):
                try? guest.send(.commandResult(.init(
                    id: request.id, ok: true,
                    output: ["launch": [["Launch", "launched SimpleText"]]],
                    error: nil)))
            default:
                break
            }
        }
        let adapter = AgentIntegrationHostAdapter(listener: listener)
        let first = Task { @MainActor in
            await adapter.launchSoftware(.name("SimpleText"))
        }
        try await waitUntil("first catalog request") {
            pending.value != nil
        }

        let second = await adapter.launchSoftware(.name("SimpleText"))
        guard case .refused(let refusal) = second else {
            return XCTFail("concurrent mutation must be refused")
        }
        XCTAssertEqual(refusal.code, "now-launch-busy")
        XCTAssertEqual(listRequests.value, 1)

        let request = try XCTUnwrap(pending.value)
        try guest.send(.softwareListing(.init(
            id: request.id,
            domain: "apps",
            entries: [entry("SimpleText", path: "HD:Apps:SimpleText")],
            more: false,
            cursor: nil,
            note: nil)))
        guard case .launched = await first.value else {
            return XCTFail("the first launch should complete")
        }
    }
}

@MainActor
private final class Counter {
    var value = 0
}

@MainActor
private final class Box<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
