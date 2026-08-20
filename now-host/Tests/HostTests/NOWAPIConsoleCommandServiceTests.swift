import XCTest
@testable import Host
@testable import NOWAgentIntegration

@MainActor
final class NOWAPIConsoleCommandServiceTests: XCTestCase {
    func testExpectedSessionIsRecheckedAtDriverOwnedDispatchSeam() async {
        let driver = CommandDriverFixture()
        let service = NOWAPIConsoleCommandService(driver: driver)
        let result = await withCheckedContinuation { continuation in
            service.execute(
                guestID: "pb1400c", expectedSessionID: "pb1400c-old-session",
                request: .init(command: "help", arguments: nil,
                               argumentLine: nil)) {
                    continuation.resume(returning: $0)
                }
        }
        XCTAssertEqual(result.disposition, .disconnected)
        XCTAssertEqual(result.error?.code, "session_changed")
        XCTAssertTrue(driver.calls.isEmpty)
    }
    func testAdvertisedCommandUsesTypedArgumentsAndExistingScheduledLane() async {
        let driver = CommandDriverFixture()
        driver.responses = [
            .init(id: 1, ok: true,
                  output: ["help": [["winact", "act on a window"]]]),
            .init(id: 2, ok: true,
                  output: ["winact": [["status", "dispatched"]]]),
        ]
        let service = NOWAPIConsoleCommandService(driver: driver)
        let result = await execute(service, request: .init(
            command: "winact", arguments: ["part": .number(21)],
            argumentLine: nil))

        XCTAssertEqual(result.disposition, .completed)
        XCTAssertEqual(result.sessionID, driver.guest?.sessionID)
        XCTAssertEqual(driver.calls.map(\.name), ["help", "winact"])
        XCTAssertEqual(driver.calls.last?.arguments, ["part": .number(21)])
        XCTAssertEqual(driver.calls.last?.workClass, .foreground)
    }

    func testHyphenatedAdvertisedCommandUsesTheSameIdentifierGrammarAsHTTP() async {
        let driver = CommandDriverFixture()
        driver.responses = [
            .init(id: 1, ok: true,
                  output: ["help": [["development-build", "build a project"]]]),
            .init(id: 2, ok: true,
                  output: ["development-build": [["status", "idle"]]]),
        ]
        let service = NOWAPIConsoleCommandService(driver: driver)
        let result = await execute(service, request: .init(
            command: "development-build", arguments: nil,
            argumentLine: "status"))

        XCTAssertEqual(result.disposition, .completed)
        XCTAssertEqual(driver.calls.map(\.name), ["help", "development-build"])
    }

    func testConnectedButInactiveGuestIsNeverReaddressedToTheDrivenGuest() async {
        let driver = CommandDriverFixture()
        driver.guest = .init(id: "pb1400c", sessionID: "pb1400c-old",
                             isActive: false, agentAccess: .fullAccess)
        let service = NOWAPIConsoleCommandService(driver: driver)
        let result = await execute(service, request: .init(
            command: "help", arguments: nil, argumentLine: ""))

        XCTAssertEqual(result.disposition, .refused)
        XCTAssertEqual(result.error?.code, "guest_not_addressed")
        XCTAssertTrue(driver.calls.isEmpty,
                      "a wrong-guest request must not reach the active command lane")
    }

    func testDisconnectedGuestReturnsBeforeLoadingACommandTable() async {
        let driver = CommandDriverFixture()
        driver.guest = nil
        let result = await execute(
            NOWAPIConsoleCommandService(driver: driver),
            request: .init(command: "help", arguments: nil,
                           argumentLine: ""))

        XCTAssertEqual(result.disposition, .disconnected)
        XCTAssertEqual(result.error?.code, "guest_disconnected")
        XCTAssertTrue(driver.calls.isEmpty)
    }

    func testCommandMustAppearInThatSessionsAdvertisedTable() async {
        let driver = CommandDriverFixture()
        driver.responses = [.init(
            id: 1, ok: true,
            output: ["help": [["help", "list commands"]]])]
        let service = NOWAPIConsoleCommandService(driver: driver)
        let result = await execute(service, request: .init(
            command: "winact", arguments: nil, argumentLine: "target=front"))

        XCTAssertEqual(result.disposition, .unadvertised)
        XCTAssertEqual(result.error?.code, "command_unadvertised")
        XCTAssertEqual(driver.calls.map(\.name), ["help"])
    }

    func testSessionChangeDuringCommandTableLoadIsDisconnectedNotRetargeted() async {
        let driver = CommandDriverFixture()
        driver.responses = [.init(
            id: 1, ok: true,
            output: ["help": [["help", "list commands"]]])]
        driver.afterResponse = { fixture in
            fixture.guest = .init(id: "pb1400c", sessionID: "pb1400c-new",
                                  isActive: true, agentAccess: .fullAccess)
        }
        let service = NOWAPIConsoleCommandService(driver: driver)
        let result = await execute(service, request: .init(
            command: "help", arguments: nil, argumentLine: ""))

        XCTAssertEqual(result.disposition, .disconnected)
        XCTAssertEqual(result.error?.code, "session_changed")
        XCTAssertEqual(driver.calls.map(\.name), ["help"])
    }

    func testGuestTimeoutAndOversizedOutputHaveDistinctBoundedResults() async {
        let timeoutDriver = CommandDriverFixture()
        timeoutDriver.responses = [
            .init(id: 1, ok: true,
                  output: ["help": [["vprobe", "measure video"]]]),
            .init(id: 2, ok: false,
                  error: .init(code: "timeout", message: "watchdog")),
        ]
        let timeout = await execute(
            NOWAPIConsoleCommandService(driver: timeoutDriver),
            request: .init(command: "vprobe", arguments: nil,
                           argumentLine: ""))
        XCTAssertEqual(timeout.disposition, .timedOut)
        XCTAssertEqual(timeout.error?.code, "timeout")

        let outputDriver = CommandDriverFixture()
        outputDriver.responses = [
            .init(id: 1, ok: true,
                  output: ["help": [["help", "list commands"]]]),
            .init(id: 2, ok: true,
                  output: ["help": [[
                    "body", String(repeating: "x", count:
                        NOWAPIConsoleCommandService.maximumOutputBytes),
                  ]]]),
        ]
        let oversized = await execute(
            NOWAPIConsoleCommandService(driver: outputDriver),
            request: .init(command: "help", arguments: nil,
                           argumentLine: ""))
        XCTAssertEqual(oversized.disposition, .failed)
        XCTAssertEqual(oversized.error?.code, "command_output_too_large")
        XCTAssertNil(oversized.output)
    }

    func testGuestControlConsentIsEnforcedBeforeHelp() async {
        for access in [AgentIntegrationGuestAccess.disabled, .readOnly,
                       .unrecognized("future")] {
            let driver = CommandDriverFixture()
            driver.guest = .init(id: "pb1400c", sessionID: "pb1400c-session",
                                 isActive: true, agentAccess: access)
            let result = await execute(
                NOWAPIConsoleCommandService(driver: driver),
                request: .init(command: "help", arguments: nil,
                               argumentLine: ""))
            XCTAssertEqual(result.disposition, .refused)
            XCTAssertEqual(result.error?.code, "guest_access_refused")
            XCTAssertTrue(driver.calls.isEmpty)
        }
    }

    private func execute(
        _ service: NOWAPIConsoleCommandService,
        request: NOWAPIConsoleCommandRequest
    ) async -> NOWAPIConsoleCommandOutcome {
        await withCheckedContinuation { continuation in
            service.execute(guestID: "pb1400c", request: request) {
                continuation.resume(returning: $0)
            }
        }
    }
}

@MainActor
private final class CommandDriverFixture: NOWAPICommandDriving {
    struct Call: Equatable {
        let name: String
        let arguments: [String: CommandArg]?
        let argumentLine: String?
        let purpose: GuestWorkPurpose
        let workClass: GuestWorkClass
    }

    var guest: NOWAPICommandGuest? = .init(
        id: "pb1400c", sessionID: "pb1400c-session",
        isActive: true, agentAccess: .fullAccess)
    var responses: [CommandResult] = []
    var calls: [Call] = []
    var afterResponse: ((CommandDriverFixture) -> Void)?

    func apiCommandGuest(id: String) -> NOWAPICommandGuest? {
        guard guest?.id == id else { return nil }
        return guest
    }

    func apiRunScheduledCommand(
        _ name: String, arguments: [String: CommandArg]?,
        argumentLine: String?, purpose: GuestWorkPurpose,
        workClass: GuestWorkClass,
        completion: @escaping (CommandResult) -> Void
    ) {
        calls.append(.init(name: name, arguments: arguments,
                           argumentLine: argumentLine, purpose: purpose,
                           workClass: workClass))
        let response = responses.isEmpty
            ? CommandResult(id: 0, ok: false,
                            error: .init(code: "fixture-empty",
                                         message: "No response"))
            : responses.removeFirst()
        afterResponse?(self)
        afterResponse = nil
        completion(response)
    }
}
