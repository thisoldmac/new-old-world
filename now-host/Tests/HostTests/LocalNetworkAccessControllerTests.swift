import Network
import XCTest
@testable import Host

final class FakeLocalNetworkDirectAccessConnection:
    LocalNetworkDirectAccessConnection {
    var stateUpdateHandler: ((NWConnection.State) -> Void)?
    var pathDescription = "unsatisfied, interface: en7, ipv4"
    private(set) var started = false
    private(set) var cancelled = false
    private(set) var verifications: [Data] = []
    private(set) var calls: [String] = []

    func start(queue: DispatchQueue) {
        started = true
        calls.append("start")
    }
    func sendVerification(_ content: Data,
                          completion: @escaping (NWError?) -> Void) {
        verifications.append(content)
        calls.append("send")
    }
    func cancel() {
        cancelled = true
        calls.append("cancel")
    }
    func emit(_ state: NWConnection.State) { stateUpdateHandler?(state) }
}

final class FakeLocalNetworkPermissionPrompt: LocalNetworkPermissionPrompt {
    var eventHandler: ((String) -> Void)?
    private(set) var started = false
    private(set) var cancelled = false

    func start(queue: DispatchQueue) { started = true }
    func cancel() { cancelled = true }
    func emit(_ event: String) { eventHandler?(event) }
}

@MainActor
final class LocalNetworkAccessControllerTests: XCTestCase {
    func testProductionSolicitationKeepsPromptSeparateFromDirectProof()
        throws {
        let source = try GateSource.hostSwift(
            "now-host/Sources/Host/LocalNetworkAccessController.swift")

        XCTAssertTrue(source.contains("func request()"))
        XCTAssertTrue(source.contains(
            "func verifyDirectAccess(to host: String)"))
        XCTAssertTrue(source.contains("using: .udp"))
        XCTAssertTrue(source.contains("connection.send(content: content"))
        XCTAssertTrue(source.contains("NWBrowser"))
        XCTAssertTrue(source.contains("NWListener"))
        XCTAssertFalse(source.contains("requiredInterface"))
        XCTAssertFalse(source.contains("requiredInterfaceType"))

        let app = try GateSource.hostSwift(
            "now-host/Sources/Host/App.swift")
        let continuity = try GateSource.hostSwift(
            "now-host/Sources/Host/MirrorContinuityController.swift")
        XCTAssertTrue(app.contains("state.localNetworkAccess.request()"))
        XCTAssertTrue(continuity.contains(
            "localNetworkAccess?.verifyDirectAccess(to: host)"))
        XCTAssertFalse(continuity.contains(
            "localNetworkAccess?.request("))
    }

    func testAppRequestNeedsNoGuestAndStartsThePromptOnly() {
        let prompt = FakeLocalNetworkPermissionPrompt()
        var madeConnection = false
        let controller = LocalNetworkAccessController(
            audit: { _, _ in },
            makeConnection: { _, _ in
                madeConnection = true
                return FakeLocalNetworkDirectAccessConnection()
            },
            makePrompt: { prompt })

        controller.request()

        XCTAssertTrue(prompt.started)
        XCTAssertFalse(madeConnection)
        XCTAssertEqual(controller.directEvidence, .notChecked)
    }

    func testDirectVerificationTargetsGuestWithoutOwningPrompt() {
        let connection = FakeLocalNetworkDirectAccessConnection()
        let prompt = FakeLocalNetworkPermissionPrompt()
        var target: (host: String, port: UInt16)?
        let controller = LocalNetworkAccessController(
            audit: { _, _ in },
            makeConnection: { host, port in
                target = (host, port)
                return connection
            },
            makePrompt: { prompt })

        controller.verifyDirectAccess(to: "10.91.5.47")

        XCTAssertEqual(target?.host, "10.91.5.47")
        XCTAssertEqual(target?.port,
                       LocalNetworkAccessController.verificationPort)
        XCTAssertTrue(connection.started)
        XCTAssertEqual(connection.verifications,
                       [LocalNetworkAccessController.verificationPayload])
        XCTAssertEqual(connection.calls, ["start", "send"])
        XCTAssertFalse(prompt.started)
        XCTAssertEqual(controller.directEvidence, .requesting)
        XCTAssertFalse(controller.directAccessReady)
    }

    func testWaitingPathStaysAliveForTheSystemPrompt() async {
        let connection = FakeLocalNetworkDirectAccessConnection()
        let prompt = FakeLocalNetworkPermissionPrompt()
        let controller = LocalNetworkAccessController(
            audit: { _, _ in },
            makeConnection: { _, _ in connection },
            makePrompt: { prompt })
        controller.request()
        controller.verifyDirectAccess(to: "10.91.5.47")

        connection.emit(.waiting(.posix(.ENETDOWN)))
        try? await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertEqual(controller.directEvidence, .waiting)
        XCTAssertFalse(controller.directAccessReady)
        XCTAssertFalse(connection.cancelled,
                       "a waiting Network.framework operation must survive "
                       + "long enough for the person to answer macOS")
        XCTAssertTrue(controller.status.contains("Waiting for macOS"))
        XCTAssertFalse(controller.status.contains("blocked this build"))
    }

    func testOnlyAReadyDirectPathConfirmsAccess() async {
        let connection = FakeLocalNetworkDirectAccessConnection()
        let prompt = FakeLocalNetworkPermissionPrompt()
        connection.pathDescription =
            "satisfied, interface: en7, ipv4, wired"
        let controller = LocalNetworkAccessController(
            audit: { _, _ in },
            makeConnection: { _, _ in connection },
            makePrompt: { prompt })
        let ready = expectation(description: "direct path ready")
        controller.onDirectAccessReady = { ready.fulfill() }
        controller.request()
        controller.verifyDirectAccess(to: "10.91.5.47")

        connection.emit(.ready)
        await fulfillment(of: [ready], timeout: 1)

        XCTAssertEqual(controller.directEvidence, .directReady)
        XCTAssertTrue(controller.directAccessReady)
        XCTAssertEqual(controller.status,
                       "Local Network access confirmed to 10.91.5.47")
        XCTAssertTrue(connection.cancelled,
                      "the route probe has no payload or lifetime after ready")
        XCTAssertTrue(prompt.cancelled)
    }

    func testASecondTargetCancelsTheOldPath() {
        let first = FakeLocalNetworkDirectAccessConnection()
        let second = FakeLocalNetworkDirectAccessConnection()
        let firstPrompt = FakeLocalNetworkPermissionPrompt()
        var connections = [first, second]
        var targets: [String] = []
        let controller = LocalNetworkAccessController(
            audit: { _, _ in },
            makeConnection: { host, _ in
                targets.append(host)
                return connections.removeFirst()
            },
            makePrompt: { firstPrompt })

        controller.verifyDirectAccess(to: "10.91.5.47")
        controller.verifyDirectAccess(to: "192.168.1.40")

        XCTAssertTrue(first.cancelled)
        XCTAssertFalse(firstPrompt.started)
        XCTAssertFalse(firstPrompt.cancelled)
        XCTAssertTrue(second.started)
        XCTAssertEqual(targets, ["10.91.5.47", "192.168.1.40"])
    }

    func testNoGuestDoesNotManufactureAPermissionRequest() {
        var madeConnection = false
        var madePrompt = false
        let controller = LocalNetworkAccessController(
            audit: { _, _ in },
            makeConnection: { _, _ in
                madeConnection = true
                return FakeLocalNetworkDirectAccessConnection()
            },
            makePrompt: {
                madePrompt = true
                return FakeLocalNetworkPermissionPrompt()
            })

        controller.verifyDirectAccess(to: "")

        XCTAssertFalse(madeConnection)
        XCTAssertFalse(madePrompt)
        XCTAssertEqual(controller.directEvidence, .failed)
        XCTAssertTrue(controller.status.contains("Connect a Mac"))
    }

    func testPromptEventsCannotConfirmDirectAccess() async {
        let connection = FakeLocalNetworkDirectAccessConnection()
        let prompt = FakeLocalNetworkPermissionPrompt()
        let controller = LocalNetworkAccessController(
            audit: { _, _ in },
            makeConnection: { _, _ in connection },
            makePrompt: { prompt })

        controller.request()
        prompt.emit("browser ready")
        prompt.emit("listener ready")
        try? await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertFalse(controller.directAccessReady)
        XCTAssertEqual(controller.directEvidence, .notChecked)
    }

    func testRepeatingAppRequestDoesNotEraseProvenDirectAccess() async {
        let connection = FakeLocalNetworkDirectAccessConnection()
        let prompt = FakeLocalNetworkPermissionPrompt()
        let controller = LocalNetworkAccessController(
            audit: { _, _ in },
            makeConnection: { _, _ in connection },
            makePrompt: { prompt })

        controller.verifyDirectAccess(to: "10.91.5.47")
        connection.emit(.ready)
        try? await Task.sleep(nanoseconds: 10_000_000)
        controller.request()

        XCTAssertTrue(prompt.started)
        XCTAssertTrue(controller.directAccessReady)
        XCTAssertEqual(controller.directEvidence, .directReady)
        XCTAssertEqual(controller.status,
                       "Local Network access confirmed to 10.91.5.47")
    }

    func testAppLaunchRequestsBeforeStartingNetworkServices() throws {
        let app = try GateSource.hostSwift("now-host/Sources/Host/App.swift")
        let request = try XCTUnwrap(
            app.range(of: "state.localNetworkAccess.request()"))
        let services = try XCTUnwrap(app.range(
            of: "startAgentIntegrationServer()",
            range: request.upperBound..<app.endIndex))

        XCTAssertLessThan(request.lowerBound, services.lowerBound)
    }
}
