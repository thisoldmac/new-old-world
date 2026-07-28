import XCTest
@testable import Host
import NOWAgentIntegration

@MainActor
final class AgentIntegrationQuitTests: XCTestCase {
    private final class Counter {
        var value = 0
    }

    private final class Box<Value> {
        var value: Value

        init(_ value: Value) {
            self.value = value
        }
    }

    private func process(
        name: String = "SimpleText",
        high: Int = 0,
        low: Int = 42
    ) -> ProcessEntry {
        .init(name: name, kind: "application", code: "APPL",
              creator: "ttxt", sizeKB: 1024, front: false,
              psnHigh: high, psnLow: low)
    }

    private func installResponder(
        on guest: FakeGuest,
        entries: @escaping () -> [ProcessEntry],
        listCount: Counter = Counter(),
        quitCount: Counter = Counter(),
        pendingQuit: Box<ProcessQuit?> = Box(nil),
        result: ProcessResult? = nil
    ) {
        guest.onMessage = { message in
            switch message {
            case .processList(let request):
                listCount.value += 1
                try? guest.send(.processListing(.init(
                    id: request.id,
                    processes: entries(),
                    more: false,
                    cursor: nil)))
            case .processQuit(let request):
                quitCount.value += 1
                pendingQuit.value = request
                let reply = result.map {
                    ProcessResult(id: request.id, ok: $0.ok,
                                  reason: $0.reason)
                } ?? .init(id: request.id, ok: true, reason: nil)
                try? guest.send(.processResult(reply))
            default:
                break
            }
        }
    }

    private func currentReference(
        from adapter: AgentIntegrationHostAdapter
    ) async throws -> String {
        guard case .available(let snapshot) = await adapter.processList(),
              let reference = snapshot.processes.first?.reference else {
            throw XCTSkip("expected a current process reference")
        }
        return reference
    }

    func testCurrentReferenceIsRelistedAndRequestsOnlyCooperativeQuit()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let lists = Counter()
        let quits = Counter()
        let pending = Box<ProcessQuit?>(nil)
        installResponder(on: guest, entries: { [self] in [process()] },
                         listCount: lists, quitCount: quits,
                         pendingQuit: pending)
        let adapter = AgentIntegrationHostAdapter(listener: listener)
        let reference = try await currentReference(from: adapter)

        let result = await adapter.requestQuit(reference: reference)

        guard case .requestSent(let receipt) = result else {
            return XCTFail("a current exact identity should request quit")
        }
        XCTAssertEqual(lists.value, 2)
        XCTAssertEqual(quits.value, 1)
        XCTAssertEqual(pending.value?.psnHigh, 0)
        XCTAssertEqual(pending.value?.psnLow, 42)
        XCTAssertEqual(receipt.process.reference, reference)
        XCTAssertEqual(receipt.process.name, "SimpleText")
        XCTAssertEqual(receipt.guestMessage,
                       "Cooperative quit request acknowledged by the paired guest")
        let encoded = try JSONEncoder().encode(result)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("psn"))
        XCTAssertFalse(text.contains("path"))
        XCTAssertFalse(text.contains("exited"))
    }

    func testChangedIdentityAtTheSamePSNIsStaleAndActsOnNothing()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        var entries = [process()]
        let quits = Counter()
        installResponder(on: guest, entries: { entries },
                         quitCount: quits)
        let adapter = AgentIntegrationHostAdapter(listener: listener)
        let reference = try await currentReference(from: adapter)
        entries = [process(name: "Another App")]

        let result = await adapter.requestQuit(reference: reference)

        guard case .stale(let failure) = result else {
            return XCTFail("a reused PSN with changed identity must be stale")
        }
        XCTAssertEqual(failure.code, "now-process-reference-stale")
        XCTAssertEqual(quits.value, 0)
    }

    func testMissingCurrentPSNReturnsNotFoundAndActsOnNothing()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        var entries = [process()]
        let quits = Counter()
        installResponder(on: guest, entries: { entries },
                         quitCount: quits)
        let adapter = AgentIntegrationHostAdapter(listener: listener)
        let reference = try await currentReference(from: adapter)
        entries = []

        let result = await adapter.requestQuit(reference: reference)

        guard case .notFound(let failure) = result else {
            return XCTFail("a vanished process must be not found")
        }
        XCTAssertEqual(failure.code, "now-process-not-found")
        XCTAssertEqual(quits.value, 0)
    }

    func testDisconnectedGuestAndOldObservationReturnTypedOutcomes()
        async throws {
        let disconnected = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"))
        let unavailable = await AgentIntegrationHostAdapter(
            listener: disconnected
        ).requestQuit(
            reference:
                "now-process-00000000-0000-0000-0000-000000000000")
        guard case .unavailable(let missingGuest) = unavailable else {
            return XCTFail("a disconnected guest must be unavailable")
        }
        XCTAssertEqual(missingGuest.code, "now-guest-unavailable")

        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        installResponder(on: guest, entries: { [self] in [process()] })
        let adapter = AgentIntegrationHostAdapter(listener: listener)
        guard case .available(let snapshot) = await adapter.processList(
            observedAt: Date(timeIntervalSince1970: 1_000)),
              let reference = snapshot.processes.first?.reference else {
            return XCTFail("expected a process observation")
        }

        let stale = await adapter.requestQuit(
            reference: reference,
            requestedAt: Date(timeIntervalSince1970: 1_031))

        guard case .stale(let failure) = stale else {
            return XCTFail("an old observation must be stale")
        }
        XCTAssertEqual(failure.code, "now-process-reference-stale")
    }

    func testGuestRefusalIsBoundedAndDoesNotClaimExit() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        installResponder(
            on: guest,
            entries: { [self] in [process()] },
            result: .init(
                id: 0, ok: false,
                reason: "Process declined quit at HD:Secret:Thing"))
        let adapter = AgentIntegrationHostAdapter(listener: listener)
        let reference = try await currentReference(from: adapter)

        let result = await adapter.requestQuit(reference: reference)

        guard case .refused(let failure) = result else {
            return XCTFail("guest refusal must remain a refusal")
        }
        XCTAssertEqual(failure.code, "now-quit-refused")
        XCTAssertEqual(failure.message,
                       "The paired guest refused cooperative quit")
        XCTAssertFalse(failure.message.contains("HD:"))
    }

    func testReconnectInvalidatesPriorProcessReference() async throws {
        let (listener, firstGuest) = try await connectedListener()
        installResponder(
            on: firstGuest, entries: { [self] in [process()] })
        let adapter = AgentIntegrationHostAdapter(listener: listener)
        let reference = try await currentReference(from: adapter)

        firstGuest.connection.cancel()
        try await waitUntil("first guest disconnect") {
            if case .listening = listener.state { return true }
            return false
        }
        let secondGuest = FakeGuest(port: try XCTUnwrap(listener.boundPort))
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
        try await waitUntil("second guest connect") {
            if case .connected = listener.state { return true }
            return false
        }

        let result = await adapter.requestQuit(reference: reference)

        guard case .stale(let failure) = result else {
            return XCTFail("a prior-session reference must be stale")
        }
        XCTAssertEqual(failure.code, "now-process-reference-stale")
    }

    func testConcurrentQuitIsRefusedBeforeASecondRevalidation()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let listCount = Counter()
        let pendingList = Box<ProcessList?>(nil)
        var firstList = true
        guest.onMessage = { message in
            switch message {
            case .processList(let request):
                listCount.value += 1
                if firstList {
                    firstList = false
                    try? guest.send(.processListing(.init(
                        id: request.id,
                        processes: [self.process()],
                        more: false,
                        cursor: nil)))
                } else {
                    pendingList.value = request
                }
            case .processQuit(let request):
                try? guest.send(.processResult(.init(
                    id: request.id, ok: true, reason: nil)))
            default:
                break
            }
        }
        let adapter = AgentIntegrationHostAdapter(listener: listener)
        let reference = try await currentReference(from: adapter)
        let first = Task { @MainActor in
            await adapter.requestQuit(reference: reference)
        }
        try await waitUntil("quit revalidation") {
            pendingList.value != nil
        }

        let second = await adapter.requestQuit(reference: reference)
        guard case .refused(let failure) = second else {
            return XCTFail("a concurrent quit must be refused")
        }
        XCTAssertEqual(failure.code, "now-quit-busy")
        XCTAssertEqual(listCount.value, 2)

        let request = try XCTUnwrap(pendingList.value)
        try guest.send(.processListing(.init(
            id: request.id,
            processes: [process()],
            more: false,
            cursor: nil)))
        guard case .requestSent = await first.value else {
            return XCTFail("the first quit should complete")
        }
    }
}
