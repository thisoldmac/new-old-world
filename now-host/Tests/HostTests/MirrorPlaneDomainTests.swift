import XCTest
@testable import Host

final class MirrorPlaneDomainTests: XCTestCase {
    @MainActor
    private final class LifecycleProbe: MirrorGuestProbing {
        let facts: MirrorWireFacts
        init(facts: MirrorWireFacts) { self.facts = facts }
        var activeGuest: ConnectedGuest? { nil }
        func listExtensions(completion: @escaping (Result<[SoftwareEntry], MirrorProbeFailure>) -> Void) {}
        func listProcesses(completion: @escaping (Result<[String], MirrorProbeFailure>) -> Void) {}
        func readMirrorFacts(completion: @escaping (Result<MirrorWireFacts, MirrorProbeFailure>) -> Void) {
            completion(.success(facts))
        }
    }
    private func plane(_ id: MirrorPlaneID,
                       supported: Bool = true,
                       requested: Bool = true,
                       active: Bool = true,
                       freshness: MirrorPlaneFreshness = .current,
                       state: MirrorGuestPlaneState = .activeCurrent,
                       reason: String? = nil) -> MirrorWirePlane {
        MirrorWirePlane(id: id, purpose: "purpose", capability: 1,
                        supported: supported, format: supported ? 1 : 0,
                        requested: requested, active: active,
                        freshness: freshness, state: state,
                        generation: 12, reason: reason)
    }

    func testPrecedenceKeepsUnsupportedAheadOfRememberedPolicy() {
        let state = MirrorPlaneReducer.resolve(
            plane: plane(.content, supported: false, requested: false,
                         active: false, freshness: .unavailable,
                         state: .unsupported),
            lifecycle: .active, connected: true, policyEnabled: true)
        XCTAssertEqual(state, .unsupported)
    }

    func testPrecedenceKeepsUnsupportedAheadOfDisconnect() {
        let state = MirrorPlaneReducer.resolve(
            plane: plane(.content, supported: false, requested: false,
                         active: false, freshness: .unavailable,
                         state: .unsupported),
            lifecycle: .active, connected: false, policyEnabled: true)
        XCTAssertEqual(state, .unsupported)
    }

    func testPrecedenceDistinguishesEveryOperationalState() {
        XCTAssertEqual(MirrorPlaneReducer.resolve(
            plane: plane(.semantics), lifecycle: .active,
            connected: false, policyEnabled: true), .disconnected)
        XCTAssertEqual(MirrorPlaneReducer.resolve(
            plane: plane(.semantics), lifecycle: .active,
            connected: true, policyEnabled: false), .userDisabled)
        XCTAssertEqual(MirrorPlaneReducer.resolve(
            plane: plane(.semantics, requested: false, active: false,
                         freshness: .unavailable, state: .inactive),
            lifecycle: .active, connected: true, policyEnabled: true,
            pendingTimedOut: true),
            .enabledInactive,
            "host policy is not proof that a closed Mirror made a claim")
        XCTAssertEqual(MirrorPlaneReducer.resolve(
            plane: plane(.semantics, requested: true, active: false,
                         freshness: .pending, state: .refused,
                         reason: "resident refused"),
            lifecycle: .degraded, connected: true, policyEnabled: true),
            .refused("resident refused"))
        XCTAssertEqual(MirrorPlaneReducer.resolve(
            plane: plane(.semantics, requested: true, active: false,
                         freshness: .pending, state: .requested),
            lifecycle: .active, connected: true, policyEnabled: true),
            .requested)
        XCTAssertEqual(MirrorPlaneReducer.resolve(
            plane: plane(.semantics, requested: true, active: false,
                         freshness: .pending, state: .requested),
            lifecycle: .active, connected: true, policyEnabled: true,
            pendingTimedOut: true),
            .degraded("The resident did not activate this plane within 5 seconds."))
        XCTAssertEqual(MirrorPlaneReducer.resolve(
            plane: plane(.semantics, freshness: .stale,
                         state: .activeStale),
            lifecycle: .degraded, connected: true, policyEnabled: true),
            .activeStale)
        XCTAssertEqual(MirrorPlaneReducer.resolve(
            plane: plane(.semantics), lifecycle: .active,
            connected: true, policyEnabled: true), .activeCurrent)
    }

    func testLifecycleFailureMakesSupportedPlaneUnavailable() {
        XCTAssertEqual(MirrorPlaneReducer.resolve(
            plane: plane(.interaction), lifecycle: .needsRestart,
            connected: true, policyEnabled: true),
            .unavailable(.needsRestart))
        XCTAssertEqual(MirrorPlaneReducer.resolve(
            plane: plane(.interaction), lifecycle: .wrongVersion,
            connected: true, policyEnabled: false),
            .unavailable(.wrongVersion),
            "stored policy cannot make an incompatible lifecycle actionable")
        XCTAssertEqual(MirrorPlaneReducer.resolve(
            plane: plane(.interaction, supported: false), lifecycle: .absent,
            connected: true, policyEnabled: true), .unsupported,
            "unsupported is the primary plane label; the lifecycle card names absence")
    }

    func testAnchoredPolicyPersistsButUnanchoredPolicyIsSessionOnly() {
        let suite = "MirrorPlaneDomainTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = MirrorPlanePolicyStore(defaults: defaults)
        first.set(false, plane: .interaction, machineID: "q950",
                  identityAnchored: true, sessionID: "s1")
        let relaunched = MirrorPlanePolicyStore(defaults: defaults)
        XCTAssertFalse(relaunched.isEnabled(.interaction, machineID: "q950",
                                            identityAnchored: true,
                                            sessionID: "s2"))

        first.set(false, plane: .interaction, machineID: "emulator",
                  identityAnchored: false, sessionID: "vm-a")
        XCTAssertFalse(first.isEnabled(.interaction, machineID: "emulator",
                                       identityAnchored: false,
                                       sessionID: "vm-a"))
        XCTAssertTrue(first.isEnabled(.interaction, machineID: "emulator",
                                      identityAnchored: false,
                                      sessionID: "vm-b"),
                      "a different VM cannot inherit Interaction")
        XCTAssertTrue(relaunched.isEnabled(.interaction, machineID: "emulator",
                                           identityAnchored: false,
                                           sessionID: "vm-a"),
                      "session-only policy cannot survive a host relaunch")
    }

    func testTogglesAreIsolatedAndStructureIsNotUserPolicy() {
        let defaults = UserDefaults(suiteName: "MirrorToggle-\(UUID())")!
        let store = MirrorPlanePolicyStore(defaults: defaults)
        store.set(false, plane: .content, machineID: "pb1400c",
                  identityAnchored: true, sessionID: "s")
        XCTAssertFalse(store.isEnabled(.content, machineID: "pb1400c",
                                       identityAnchored: true, sessionID: "s"))
        XCTAssertTrue(store.isEnabled(.semantics, machineID: "pb1400c",
                                      identityAnchored: true, sessionID: "s"))
        XCTAssertTrue(store.isEnabled(.interaction, machineID: "pb1400c",
                                      identityAnchored: true, sessionID: "s"))
        XCTAssertTrue(store.isEnabled(.structure, machineID: "pb1400c",
                                      identityAnchored: true, sessionID: "s"))
    }

    func testUnifiedWireFactsDecodeWithoutLegacyInventory() throws {
        let json = #"{"schema":1,"extension":{"selector":"NWex","lifecycle":"active","expectedMajor":1,"residentMajor":1,"residentMinor":7,"tableLength":4096,"capabilities":15,"requested":15,"active":15,"heartbeat":99,"sourceManifest":"0000000100000002000000030000000400000005","buildFingerprint":"0000001000000011000000120000001300000014"},"planes":[{"id":"structure","purpose":"Window structure","capability":1,"supported":true,"format":3,"requested":true,"active":true,"freshness":"current","state":"active-current","generation":8},{"id":"semantics","purpose":"Meaning","capability":2,"supported":false,"format":0,"requested":false,"active":false,"freshness":"unavailable","state":"unsupported","generation":0},{"id":"content","purpose":"Content","capability":8,"supported":true,"format":2,"requested":true,"active":true,"freshness":"current","state":"active-current","generation":9},{"id":"interaction","purpose":"Input","capability":4,"supported":true,"format":2,"requested":true,"active":true,"freshness":"current","state":"active-current","generation":10}]}"#
        let facts = try JSONDecoder().decode(MirrorWireFacts.self,
                                              from: Data(json.utf8))
        XCTAssertEqual(facts.schema, 1)
        XCTAssertEqual(facts.resident.lifecycle, .active)
        XCTAssertEqual(facts.resident.buildFingerprint,
                       "0000001000000011000000120000001300000014")
        XCTAssertEqual(facts.planes.map(\.id),
                       [.structure, .semantics, .content, .interaction])
        XCTAssertFalse(facts.planes[1].supported)
    }

    func testActiveMirrorSurfaceCannotRegressToLegacyRuntime() throws {
        let active = try GateSource.hostSwift(
            "now-host/Sources/Host/MirrorControlView.swift")
        for forbidden in ["AXPeek", "QDPeek", "Portal", "mirror-agent",
                          "forwardedAgentPort", "qmpSocketPath",
                          "buildFromSource", "Launch Mirror"] {
            XCTAssertFalse(active.contains(forbidden),
                           "active Mirror UI contains legacy runtime term \(forbidden)")
        }
        XCTAssertTrue(active.contains("Open Mirror"))
        XCTAssertTrue(active.contains("Close Mirror"))
    }

    func testCloseReleasesContentAndInteractionOffRefusesBeforeDispatch() throws {
        let source = try GateSource.hostSwift(
            "now-host/Sources/Host/NOWMirrorSource.swift")
        let stop = try XCTUnwrap(source.range(of: "func stop()"))
        let poll = try XCTUnwrap(source.range(of: "private func poll()",
                                              range: stop.upperBound..<source.endIndex))
        let stopBody = source[stop.lowerBound..<poll.lowerBound]
        XCTAssertTrue(stopBody.contains("content.disable"))
        XCTAssertTrue(stopBody.contains("Content claim release refused"),
                      "close must not call a refused P3 release clean")

        let direct = try XCTUnwrap(source.range(
            of: "func perform(_ interaction: Interaction)"))
        let legacy = try XCTUnwrap(source.range(
            of: "func perform(_ actions: [MirrorAction]",
            range: direct.upperBound..<source.endIndex))
        let directBody = source[direct.lowerBound..<legacy.lowerBound]
        let policy = try XCTUnwrap(directBody.range(
            of: "guard planePolicy().contains(.interaction)"))
        let dispatch = try XCTUnwrap(directBody.range(of: "Task {"))
        XCTAssertLessThan(policy.lowerBound, dispatch.lowerBound,
                          "P4 policy must refuse before asynchronous dispatch")
        XCTAssertTrue(directBody.contains("NOT DISPATCHED"))
    }

    @MainActor
    func testDisconnectPinsLastFactsAsDisconnected() throws {
        let resident = MirrorWireExtension(
            selector: "NWex", lifecycle: .active, expectedMajor: 1,
            residentMajor: 1, residentMinor: 0, tableLength: 10,
            capabilities: 15, requested: 15, active: 15, heartbeat: 1,
            sourceManifest: nil, buildFingerprint: nil, reason: nil)
        let planes = MirrorPlaneID.allCases.map {
            MirrorWirePlane(id: $0, purpose: "purpose", capability: 1,
                            supported: true, format: 1, requested: true,
                            active: true, freshness: .current,
                            state: .activeCurrent, generation: 1, reason: nil)
        }
        let model = MirrorControlModel(
            guestProbe: LifecycleProbe(facts: .init(
                schema: 1, resident: resident, planes: planes)),
            checkout: nil,
            defaults: UserDefaults(suiteName: "MirrorDisconnect-\(UUID())")!)
        model.connection = .connected(named: "Mac")
        model.refreshLifecycle()
        XCTAssertEqual(model.wireFacts?.resident.lifecycle, .active)
        model.connection = .disconnected
        XCTAssertEqual(model.wireFacts?.planes.count, 4,
                       "disconnect pins the last facts instead of blanking")
        XCTAssertEqual(model.presentation(for: try XCTUnwrap(model.planeFacts.first)),
                       .disconnected)
    }
}
