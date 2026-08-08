import XCTest
@testable import Host

final class MirrorPlaneDomainTests: XCTestCase {
    @MainActor
    private final class LifecycleProbe: MirrorGuestProbing {
        var facts: MirrorWireFacts
        var activeGuest: ConnectedGuest?
        init(facts: MirrorWireFacts, activeGuest: ConnectedGuest? = nil) {
            self.facts = facts
            self.activeGuest = activeGuest
        }
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
        XCTAssertEqual(MirrorPlaneReducer.resolve(
            plane: plane(.semantics), lifecycle: .active,
            connected: true, policyEnabled: true, guestEnabled: false),
            .guestDisabled,
            "the Mac's safety gate is distinct from host preference")
    }

    func testGuestPolicyDomainsStayIndependent() {
        let policy = MirrorGuestPolicy(
            structure: true, finderComplements: false,
            content: false, foregroundCycle: true)
        XCTAssertTrue(policy.allows(.structure))
        XCTAssertTrue(policy.allows(.semantics))
        XCTAssertTrue(policy.allows(.interaction))
        XCTAssertFalse(policy.allows(.content))
        XCTAssertFalse(policy.finderComplements)
        XCTAssertTrue(policy.foregroundCycle)
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

    @MainActor
    func testPolicyToggleImmediatelyNotifiesTheProjectionOwner() {
        let resident = MirrorWireExtension(
            selector: "NWex", lifecycle: .active, expectedMajor: 1,
            residentMajor: 1, residentMinor: 0, tableLength: 10,
            capabilities: 15, requested: 15, active: 15, heartbeat: 1,
            sourceManifest: nil, buildFingerprint: nil, reason: nil)
        let planes = MirrorPlaneID.allCases.map {
            plane($0)
        }
        let key = GuestKey.synthetic("projection-owner")
        let guest = ConnectedGuest(
            key: key, id: key.machine, idIsAutoAssigned: false,
            idIsAnchored: true, name: "Test Mac",
            address: GuestAddress(text: "127.0.0.1"), version: nil,
            operatingSystem: "9.1", connectedAt: Date(), isActive: true)
        var notifications = 0
        let model = MirrorControlModel(
            guestProbe: LifecycleProbe(
                facts: .init(schema: 1, resident: resident, planes: planes),
                activeGuest: guest),
            defaults: UserDefaults(suiteName: "MirrorImmediate-\(UUID())")!,
            policyDidChange: { notifications += 1 })

        model.setPolicy(false, for: .content)

        XCTAssertEqual(notifications, 1)
        XCTAssertFalse(model.policyEnabled(.content))
        XCTAssertTrue(model.policyEnabled(.semantics),
                      "one live toggle cannot disturb another plane")
    }

    @MainActor
    func testOtherGuestToggleCannotReprojectPinnedMirrorPolicy() throws {
        let resident = MirrorWireExtension(
            selector: "NWex", lifecycle: .active, expectedMajor: 1,
            residentMajor: 1, residentMinor: 0, tableLength: 10,
            capabilities: 15, requested: 15, active: 15, heartbeat: 1,
            sourceManifest: nil, buildFingerprint: nil, reason: nil)
        let facts = MirrorWireFacts(
            schema: 1, resident: resident,
            planes: MirrorPlaneID.allCases.map { plane($0) })
        let keyA = GuestKey.synthetic("pinned-a")
        let keyB = GuestKey.synthetic("selected-b")
        func guest(_ key: GuestKey, active: Bool) -> ConnectedGuest {
            ConnectedGuest(
                key: key, id: key.machine, idIsAutoAssigned: false,
                idIsAnchored: false, name: key.machine.slug,
                address: GuestAddress(text: "127.0.0.1"), version: nil,
                operatingSystem: "9.1", connectedAt: Date(),
                isActive: active)
        }
        let guestA = guest(keyA, active: true)
        let guestB = guest(keyB, active: true)
        let probe = LifecycleProbe(facts: facts, activeGuest: guestA)
        let model = MirrorControlModel(
            guestProbe: probe,
            defaults: UserDefaults(suiteName: "MirrorPinned-\(UUID())")!)
        model.connection = .connected(name: guestA.name, key: keyA)

        let fixture = try XCTUnwrap(
            Bundle.module.url(forResource: "now-scene-ir-v1",
                              withExtension: "json",
                              subdirectory: "Fixtures"))
        let scene = try NOWMirrorSceneDecoder.decode(
            irVersion: 1, document: Data(contentsOf: fixture))
        let registry = MirrorStateEngineRegistry()
        let engineA = registry.engine(for: keyA)
        _ = engineA.accept(scene)
        let before = try XCTUnwrap(engineA.snapshot)

        let listener = GuestListener(
            identity: .init(version: "test", name: "Test Host"))
        var heldScene: ((Result<GuestListener.SceneDelivery,
                                GuestListener.SceneFailure>) -> Void)?
        let io = NOWMirrorCycleIO(
            activeKey: { keyA }, isGuestConnected: { _ in true },
            isGuestAnswering: { _ in true },
            isScenePending: { heldScene != nil },
            requestScene: { _, _, _, completion in heldScene = completion },
            guestChanged: {},
            disableContent: { $0(nil) },
            joinContent: { scene, completion in
                completion(.init(scene: scene, sentence: "test"))
            })
        let source = NOWMirrorSource(
            listener: listener, engineRegistry: registry,
            act: AgentIntegrationActControl(
                listener: listener, currentSessionID: { nil }),
            interval: 3_600,
            planePolicy: { model.requestedPlaneIDs(for: $0) },
            cycleIO: io)
        model.bindPolicyProjection { source.planePolicyDidChange() }
        source.start()

        probe.activeGuest = guestB
        model.connection = .connected(name: guestB.name, key: keyB)
        model.setPolicy(false, for: .content)

        XCTAssertTrue(engineA.isPlaneEnabled(.content))
        XCTAssertEqual(engineA.snapshot?.id, before.id,
                       "guest B policy cannot republish pinned guest A")
        XCTAssertFalse(model.requestedPlaneIDs(for: keyB).contains(.content))
        XCTAssertTrue(model.requestedPlaneIDs(for: keyA).contains(.content))
    }

    func testAGuestPredatingAPlaneIsNotRefusedItsWholeReport() throws {
        /* Seen on 2026-08-05: the Mirror page read "The Mac's mirror
           facts do not match schema 1 … must carry every plane, in
           order" against a guest reporting its four planes perfectly
           correctly. The newer host was reinterpreting an older peer's
           right answer as a fault, which is the inverse of this
           project's compatibility rule. */
        let fourRows = #"{"schema":1,"extension":{"selector":"NWex","lifecycle":"active","expectedMajor":1,"residentMajor":1,"residentMinor":7,"tableLength":4096,"capabilities":15,"requested":15,"active":15,"heartbeat":99,"sourceManifest":"0000000100000002000000030000000400000005","buildFingerprint":"0000001000000011000000120000001300000014"},"planes":[{"id":"structure","purpose":"Window structure","capability":1,"supported":true,"format":3,"requested":true,"active":true,"freshness":"current","state":"active-current","generation":8},{"id":"semantics","purpose":"Meaning","capability":2,"supported":true,"format":2,"requested":true,"active":true,"freshness":"current","state":"active-current","generation":9},{"id":"content","purpose":"Content","capability":8,"supported":true,"format":2,"requested":true,"active":true,"freshness":"current","state":"active-current","generation":9},{"id":"interaction","purpose":"Input","capability":4,"supported":true,"format":2,"requested":true,"active":true,"freshness":"current","state":"active-current","generation":10}]}"#

        let facts = try JSONDecoder().decode(
            MirrorWireFacts.self, from: Data(fourRows.utf8))

        XCTAssertEqual(facts.planes.map(\.id), MirrorPlaneID.allCases,
                       "the roster is completed, not refused")
        let filled = try XCTUnwrap(facts.planes.last)
        XCTAssertEqual(filled.id, .transitions)
        /* Present and unsupported, never absent: an unsupported plane and
           an unasked one must not collapse into each other. */
        XCTAssertFalse(filled.supported)
        XCTAssertEqual(filled.state, .unsupported)
        XCTAssertNotNil(filled.reason)
        XCTAssertTrue(facts.planes[0].supported,
                      "the rows the guest did send are untouched")
        XCTAssertEqual(facts.policy, .legacyAllowed,
                       "an older guest keeps its established behavior")
    }

    func testCurrentGuestPolicyDecodesWithoutChangingSchema() throws {
        let json = #"{"schema":1,"extension":{"selector":"NWex","lifecycle":"active","expectedMajor":1},"policy":{"structure":true,"finderComplements":false,"content":false,"foregroundCycle":false},"planes":[{"id":"structure","purpose":"Window structure","capability":1,"supported":true,"format":3,"requested":false,"active":false,"freshness":"unavailable","state":"inactive","generation":0}]}"#
        let facts = try JSONDecoder().decode(
            MirrorWireFacts.self, from: Data(json.utf8))

        XCTAssertTrue(facts.policy.structure)
        XCTAssertFalse(facts.policy.finderComplements)
        XCTAssertFalse(facts.policy.content)
        XCTAssertFalse(facts.policy.foregroundCycle)
    }

    func testAScrambledPlaneOrderIsStillRefused() throws {
        /* Accepting a prefix must not become accepting anything: the rows
           are positional, and a reordering would silently relabel every
           plane after the first difference. */
        let scrambled = #"{"schema":1,"extension":{"selector":"NWex","lifecycle":"active","expectedMajor":1,"residentMajor":1,"residentMinor":7,"tableLength":4096,"capabilities":15,"requested":15,"active":15,"heartbeat":99,"sourceManifest":"0000000100000002000000030000000400000005","buildFingerprint":"0000001000000011000000120000001300000014"},"planes":[{"id":"semantics","purpose":"Meaning","capability":2,"supported":true,"format":2,"requested":true,"active":true,"freshness":"current","state":"active-current","generation":9},{"id":"structure","purpose":"Window structure","capability":1,"supported":true,"format":3,"requested":true,"active":true,"freshness":"current","state":"active-current","generation":8}]}"#

        XCTAssertThrowsError(try JSONDecoder().decode(
            MirrorWireFacts.self, from: Data(scrambled.utf8)))
    }

    func testUnifiedWireFactsDecodeWithoutLegacyInventory() throws {
        let json = #"{"schema":1,"extension":{"selector":"NWex","lifecycle":"active","expectedMajor":1,"residentMajor":1,"residentMinor":7,"tableLength":4096,"capabilities":15,"requested":15,"active":15,"heartbeat":99,"sourceManifest":"0000000100000002000000030000000400000005","buildFingerprint":"0000001000000011000000120000001300000014"},"planes":[{"id":"structure","purpose":"Window structure","capability":1,"supported":true,"format":3,"requested":true,"active":true,"freshness":"current","state":"active-current","generation":8},{"id":"semantics","purpose":"Meaning","capability":2,"supported":false,"format":0,"requested":false,"active":false,"freshness":"unavailable","state":"unsupported","generation":0},{"id":"content","purpose":"Content","capability":8,"supported":true,"format":2,"requested":true,"active":true,"freshness":"current","state":"active-current","generation":9},{"id":"interaction","purpose":"Input","capability":4,"supported":true,"format":2,"requested":true,"active":true,"freshness":"current","state":"active-current","generation":10},{"id":"transitions","purpose":"Transitions a poll is too slow to see","capability":16,"supported":true,"format":1,"requested":true,"active":true,"freshness":"current","state":"active-current","generation":11}]}"#
        let facts = try JSONDecoder().decode(MirrorWireFacts.self,
                                              from: Data(json.utf8))
        XCTAssertEqual(facts.schema, 1)
        XCTAssertEqual(facts.resident.lifecycle, .active)
        XCTAssertEqual(facts.resident.buildFingerprint,
                       "0000001000000011000000120000001300000014")
        XCTAssertEqual(facts.planes.map(\.id),
                       [.structure, .semantics, .content, .interaction,
                        .transitions])
        XCTAssertFalse(facts.planes[1].supported)
    }

    func testActiveMirrorSurfaceCannotRegressToLegacyRuntime() throws {
        let active = try GateSource.hostSwift(
            "now-host/Sources/Host/MirrorControlView.swift")
        let model = try GateSource.hostSwift(
            "now-host/Sources/Host/MirrorControlModel.swift")
        let sources = active + model
        for forbidden in ["AXPeek", "QDPeek", "Portal", "mirror-agent",
                          "forwardedAgentPort", "qmpSocketPath",
                          "buildFromSource", "MirrorProcessSpawner",
                          "MirrorTCPProbe", "Launch Mirror"] {
            XCTAssertFalse(sources.contains(forbidden),
                           "active Mirror path contains legacy runtime term \(forbidden)")
        }
        /* **Two controls now, because the Mirror has two axes.** The old
           pair was `Open Mirror` / `Close Mirror`, one button meaning
           both "run the poll" and "put a window on screen". Splitting
           them is the point of the 019 change; asserting all four here
           keeps the page from quietly collapsing back to one. */
        XCTAssertTrue(active.contains("\"Stop\" : \"Start\""),
                      "the running axis has a control of its own")
        XCTAssertTrue(active.contains("\"Attach\" : \"Detach\""),
                      "and so does the where-it-is-shown axis")
    }

    func testCloseReleasesContentAndInteractionOffRefusesBeforeDispatch() throws {
        let source = try GateSource.hostSwift(
            "now-host/Sources/Host/NOWMirrorSource.swift")
        let stop = try XCTUnwrap(source.range(of: "func stop()"))
        let poll = try XCTUnwrap(source.range(of: "private func poll()",
                                              range: stop.upperBound..<source.endIndex))
        let stopBody = source[stop.lowerBound..<poll.lowerBound]
        XCTAssertTrue(stopBody.contains("cycleIO.disableContent"))
        XCTAssertTrue(stopBody.contains("Content claim release refused"),
                      "close must not call a refused P3 release clean")

        let direct = try XCTUnwrap(source.range(
            of: "func perform(_ interaction: Interaction)"))
        let legacy = try XCTUnwrap(source.range(
            of: "func perform(_ actions: [MirrorAction]",
            range: direct.upperBound..<source.endIndex))
        let directBody = source[direct.lowerBound..<legacy.lowerBound]
        let policy = try XCTUnwrap(directBody.range(
            of: "guard currentPlanePolicy.contains(.interaction)"))
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
            defaults: UserDefaults(suiteName: "MirrorDisconnect-\(UUID())")!)
        model.connection = .connected(named: "Mac")
        model.refreshLifecycle()
        XCTAssertEqual(model.wireFacts?.resident.lifecycle, .active)
        model.connection = .disconnected
        XCTAssertEqual(model.wireFacts?.planes.count,
                       MirrorPlaneID.allCases.count,
                       "disconnect pins the last facts instead of blanking")
        XCTAssertEqual(model.presentation(for: try XCTUnwrap(model.planeFacts.first)),
                       .disconnected)
    }
}
