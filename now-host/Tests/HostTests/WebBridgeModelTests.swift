import Foundation
import XCTest
@testable import Host

@MainActor
final class WebBridgeModelTests: XCTestCase {
    private func defaults() -> (UserDefaults, String) {
        let name = "WebBridgeModelTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!.offTheWire(), name)
    }

    func testConfigurationUsesHelperContractKeys() throws {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let model = WebBridgeModel(defaults: defaults, environment: [:])
        model.bindAddress = "192.168.1.20"
        model.port = 5188
        model.allowedClient = "192.168.1.44"
        model.engine = .playwright
        model.profile = .macweb
        model.lens = .reader
        model.handlersEnabled = false
        model.allowPrivateDestinations = true
        model.aiPlannerExecutable = "/tmp/layout-plan"

        let data = try JSONEncoder().encode(model.configuration)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["host"] as? String, "192.168.1.20")
        XCTAssertEqual(object["port"] as? Int, 5188)
        XCTAssertEqual(object["engine"] as? String, "playwright")
        XCTAssertEqual(object["allowed_clients"] as? [String],
                       ["192.168.1.44"])
        XCTAssertEqual(object["ai_plan_command"] as? [String],
                       ["/tmp/layout-plan"])
        XCTAssertEqual(object["allow_private_destinations"] as? Bool, true)
        XCTAssertEqual(object["default_profile"] as? String, "macweb")
        XCTAssertEqual(object["default_lens"] as? String, "reader")
        XCTAssertEqual(object["handlers_enabled"] as? Bool, false)
    }

    func testLoopbackIsNotPresentedAsClassicMacReachable() {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let model = WebBridgeModel(defaults: defaults, environment: [:])
        model.bindAddress = "127.0.0.1"

        XCTAssertTrue(model.proxyInstruction.contains("not reachable"))
        XCTAssertFalse(model.proxyInstruction.contains("Set the classic"))
    }

    func testLANListenerWithoutPeerRestrictionIsVisible() {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let model = WebBridgeModel(defaults: defaults, environment: [:])
        model.bindAddress = "192.168.1.20"
        model.allowedClient = ""

        XCTAssertTrue(model.exposesLANWithoutPeerRestriction)
        model.allowedClient = "192.168.1.44"
        XCTAssertFalse(model.exposesLANWithoutPeerRestriction)
    }

    func testReadinessRequiresExactProtocol() {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let model = WebBridgeModel(defaults: defaults, environment: [:])

        model.acceptOutput("NOW_WEB_READY old-web/1 127.0.0.1:5180\n")
        guard case .failed(let reason) = model.lifecycle else {
            return XCTFail("incompatible helper must fail readiness")
        }
        XCTAssertTrue(reason.contains("incompatible"))
    }

    func testExactReadinessPublishesAddressAndPort() {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let model = WebBridgeModel(defaults: defaults, environment: [:])

        model.acceptOutput("NOW_WEB_READY now-web-bridge/1 192.168.1.20:5180\n")

        XCTAssertEqual(model.lifecycle,
                       .ready(address: "192.168.1.20", port: 5180))
    }
}
