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
        model.engine = .playwright
        model.profile = .macweb
        model.lens = .reader
        model.handlersEnabled = false
        model.allowPrivateDestinations = true
        model.aiPlannerExecutable = "/tmp/layout-plan"

        let data = try JSONEncoder().encode(model.configuration)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["host"] as? String, "127.0.0.1")
        XCTAssertEqual(object["port"] as? Int, 0)
        XCTAssertEqual(object["engine"] as? String, "playwright")
        XCTAssertEqual(object["allowed_clients"] as? [String],
                       ["127.0.0.1", "::1"])
        XCTAssertEqual(object["ai_plan_command"] as? [String],
                       ["/tmp/layout-plan"])
        XCTAssertEqual(object["allow_private_destinations"] as? Bool, true)
        XCTAssertEqual(object["default_profile"] as? String, "macweb")
        XCTAssertEqual(object["default_lens"] as? String, "reader")
        XCTAssertEqual(object["handlers_enabled"] as? Bool, false)
    }

    func testStartsAutomaticallyDefaultsOffAndRoundTripsThroughDefaults() {
        // H1b: unlike MCP stdio (default on), the web relay is a heavier
        // bundled process, so an unset preference must read false — and the
        // key App.swift's launch hook reads directly must be the same one
        // this model persists to.
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }

        XCTAssertFalse(WebBridgeModel(defaults: defaults, environment: [:])
            .startsAutomatically)

        let model = WebBridgeModel(defaults: defaults, environment: [:])
        model.startsAutomatically = true
        XCTAssertTrue(defaults.bool(
            forKey: WebBridgeModel.startsAutomaticallyDefaultsKey))

        let reloaded = WebBridgeModel(defaults: defaults, environment: [:])
        XCTAssertTrue(reloaded.startsAutomatically)
    }

    func testRendererIsInternalAndUsesReadinessEndpoint() {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let model = WebBridgeModel(defaults: defaults, environment: [:])
        model.acceptOutput("NOW_WEB_READY now-web-bridge/1 127.0.0.1:53144\n")
        XCTAssertEqual(model.rendererEndpoint?.absoluteString,
                       "http://127.0.0.1:53144")
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

    func testWireAbsoluteTargetRoutesThroughInternalRenderer() throws {
        let request = WebRequest(
            id: 1, method: "GET", target: "https://example.com/a?q=1")
        let url = try XCTUnwrap(WebWireService.rendererURL(
            for: request, endpoint: URL(string: "http://127.0.0.1:53144")!,
            profile: .macweb, lens: .reader, handlersEnabled: false))
        let parts = try XCTUnwrap(URLComponents(url: url,
                                                resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.path, "/go")
        XCTAssertEqual(parts.queryItems?.first { $0.name == "u" }?.value,
                       request.target)
        XCTAssertEqual(parts.queryItems?.first { $0.name == "profile" }?.value,
                       "macweb")
        XCTAssertEqual(parts.queryItems?.first { $0.name == "lens" }?.value,
                       "reader")
        XCTAssertEqual(parts.queryItems?.first { $0.name == "handlers" }?.value,
                       "off")
    }
}
