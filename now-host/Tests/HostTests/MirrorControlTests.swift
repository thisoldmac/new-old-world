import Foundation
import XCTest
@testable import Host

/// The Mirror page's decisions, exercised without a Mac, a socket or a
/// child process.
///
/// The page it replaced was tested the same way and still shipped broken,
/// so the split here is deliberate: everything a person acts on — which
/// address Mirror would dial, why Launch is dark, which binary it would
/// run — is a pure function or a model transition, and none of it needs
/// anything spawned to be watched failing.
@MainActor
final class MirrorControlTests: XCTestCase {

    // MARK: - Fakes

    private final class FakeGuestProbe: MirrorGuestProbing {
        var extensions: Result<[SoftwareEntry], MirrorProbeFailure> =
            .success([])
        var processNames: Result<[String], MirrorProbeFailure> = .success([])
        var activeGuest: ConnectedGuest?

        func listExtensions(
            completion: @escaping (Result<[SoftwareEntry],
                                          MirrorProbeFailure>) -> Void) {
            completion(extensions)
        }

        func listProcesses(
            completion: @escaping (Result<[String],
                                          MirrorProbeFailure>) -> Void) {
            completion(processNames)
        }
    }

    private final class FakeEndpointProbe: MirrorEndpointProbing {
        var answer: Result<Void, MirrorProbeFailure> = .success(())
        var asked: [(host: String, port: Int)] = []

        func probe(host: String, port: Int, timeout: TimeInterval,
                   completion: @escaping (Result<Void,
                                                 MirrorProbeFailure>) -> Void) {
            asked.append((host, port))
            completion(answer)
        }
    }

    private final class FakeSpawner: MirrorSpawning {
        var invocations: [MirrorInvocation] = []
        /// Answers in order; the last one repeats, so a test that only
        /// cares about the launch does not have to describe the build.
        var results: [Result<Int32, MirrorProbeFailure>] = [.success(4242)]
        var exits: [(Int32) -> Void] = []
        var outputs: [(String) -> Void] = []
        var terminated: [(pid: Int32, grace: TimeInterval)] = []

        func spawn(_ invocation: MirrorInvocation,
                   onOutput: @escaping (String) -> Void,
                   onExit: @escaping (Int32) -> Void)
            -> Result<Int32, MirrorProbeFailure> {
            invocations.append(invocation)
            outputs.append(onOutput)
            exits.append(onExit)
            let index = min(invocations.count - 1, results.count - 1)
            return results[index]
        }

        func terminate(pid: Int32, escalateAfter: TimeInterval) {
            terminated.append((pid, escalateAfter))
        }

        /// Ends the n-th child (0-based), the way the real one does.
        func finish(_ index: Int, status: Int32) {
            exits[index](status)
        }
    }

    // MARK: - Builders

    private func guest(address: String,
                       slug: String = "pb1400c") -> ConnectedGuest {
        ConnectedGuest(
            key: .synthetic(address), id: GuestID(slug)!,
            idIsAutoAssigned: false, idIsAnchored: true,
            name: "New Old World", address: GuestAddress(text: address),
            version: "0.7", operatingSystem: "Mac OS 9.1",
            connectedAt: Date(), isActive: true)
    }

    private func entry(_ name: String, off: Bool? = nil,
                       version: String? = nil) -> SoftwareEntry {
        SoftwareEntry(name: name,
                      path: "Macintosh HD:System Folder:Extensions:\(name)",
                      type: "INIT", creator: "TBmr", sizeK: 12,
                      off: off, running: nil, version: version)
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "now.mirror.tests.\(UUID().uuidString)")!
    }

    /// Always with an explicit checkout: the default walks up from the
    /// running binary, and the test binary lives INSIDE this repository —
    /// so a test that let it default would quietly assert against the real
    /// `mirror/` and pass or fail on whether somebody had built it.
    private func model(probe: FakeGuestProbe? = nil,
                       endpoint: FakeEndpointProbe? = nil,
                       spawner: FakeSpawner? = nil,
                       checkout: MirrorCheckout? = nil) -> MirrorControlModel {
        MirrorControlModel(guestProbe: probe ?? FakeGuestProbe(),
                           endpointProbe: endpoint ?? FakeEndpointProbe(),
                           spawner: spawner ?? FakeSpawner(),
                           checkout: checkout, defaults: defaults())
    }

    /// A connected model whose machine is ready in every way, so a test
    /// about ONE refusal changes ONE thing.
    private func ready(probe maybeProbe: FakeGuestProbe? = nil,
                       endpoint: FakeEndpointProbe? = nil,
                       spawner: FakeSpawner? = nil,
                       product: URL) -> MirrorControlModel {
        let probe = maybeProbe ?? FakeGuestProbe()
        probe.activeGuest = guest(address: "10.0.1.7")
        if case .success(let existing) = probe.extensions, existing.isEmpty {
            probe.extensions = .success(MirrorInit.allCases.map {
                entry($0.fileName)
            })
        }
        probe.processNames = .success(["Finder",
                                       MirrorControlModel.agentProcessName])
        let model = self.model(probe: probe, endpoint: endpoint,
                               spawner: spawner)
        model.namedAppPath = product.path
        model.connection = .connected(named: "New Old World")
        model.check()
        return model
    }

    // MARK: - Detection

    func testAnInstalledExtensionReadsAsInstalledWithItsVersion() {
        let rows = MirrorInitReport.rows(from: [
            entry("AXPeek", version: "1.2"),
        ])
        XCTAssertEqual(rows.first { $0.component == .axPeek }?.state,
                       .installed(version: "1.2"))
    }

    func testAnExtensionInTheDisabledFolderIsNotInstalled() {
        let rows = MirrorInitReport.rows(from: [entry("QDPeek", off: true)])
        XCTAssertEqual(rows.first { $0.component == .qdPeek }?.state,
                       .disabled,
                       "Extensions Manager off is not the same as absent, "
                           + "and both differ from loaded")
    }

    func testAnExtensionInNeitherFolderIsMissing() {
        let rows = MirrorInitReport.rows(from: [entry("Something Else")])
        XCTAssertEqual(rows.first { $0.component == .portal }?.state, .missing)
    }

    func testTheEnabledCopyWinsOverAStaleDisabledOne() {
        let rows = MirrorInitReport.rows(from: [
            entry("Portal", off: true),
            entry("Portal", off: false, version: "2.0"),
        ])
        XCTAssertEqual(rows.first { $0.component == .portal }?.state,
                       .installed(version: "2.0"),
                       "what loads at the next boot is the enabled copy")
    }

    func testTheNamesAreMatchedCaseInsensitively() {
        let rows = MirrorInitReport.rows(from: [entry("axpeek")])
        XCTAssertEqual(rows.first { $0.component == .axPeek }?.state,
                       .installed(version: nil))
    }

    func testAMachineThatCouldNotBeAskedIsUnknownRatherThanMissing() {
        let probe = FakeGuestProbe()
        probe.activeGuest = guest(address: "10.0.1.7")
        probe.extensions = .failure(MirrorProbeFailure("timeout"))
        let model = model(probe: probe)
        model.connection = .connected(named: "New Old World")
        model.check()

        XCTAssertEqual(model.initRows.map(\.state),
                       Array(repeating: .unknown("timeout"), count: 3))
        XCTAssertTrue(model.absentInits.isEmpty,
                      "a check that could not run must not read as a "
                          + "failed check, or it blocks a launch that "
                          + "would have worked")
    }

    func testTheAgentIsFoundByNameInTheProcessList() {
        let probe = FakeGuestProbe()
        probe.activeGuest = guest(address: "10.0.1.7")
        probe.processNames = .success(["Finder", "mirror-agent"])
        let model = model(probe: probe)
        model.connection = .connected(named: "New Old World")
        model.check()
        XCTAssertEqual(model.agent, .running)

        probe.processNames = .success(["Finder"])
        model.check()
        XCTAssertEqual(model.agent, .notRunning)
    }

    // MARK: - Endpoint derivation

    func testAMachineOnTheNetworkIsDialledDirectlyAtTheAgentsOwnPort() {
        XCTAssertEqual(
            MirrorEndpoint.derive(peer: GuestAddress(text: "10.0.1.7"),
                                  forwardedPort: 1730),
            .direct(host: "10.0.1.7", port: 1420))
    }

    func testAMachineOnTheNetworkIgnoresTheForwardSetting() {
        let endpoint = MirrorEndpoint.derive(
            peer: GuestAddress(text: "192.168.0.44"), forwardedPort: 9999)
        XCTAssertEqual(endpoint.addressText, "192.168.0.44:1420",
                       "the forward is a fact about an emulator rig and "
                           + "must not touch a real machine's address")
    }

    func testALoopbackPeerIsEmulatedAndGoesThroughTheHostSideForward() {
        XCTAssertEqual(
            MirrorEndpoint.derive(peer: GuestAddress(text: "127.0.0.1"),
                                  forwardedPort: 1730),
            .forwarded(host: "127.0.0.1", port: 1730, guestPort: 1420),
            "user-mode NAT means nothing can dial into the guest; the "
                + "only way in is the forward the emulator was started with")
    }

    func testTheForwardSettingIsTheOneThatIsUsed() {
        let endpoint = MirrorEndpoint.derive(
            peer: GuestAddress(text: "127.0.0.1"), forwardedPort: 1899)
        XCTAssertEqual(endpoint.addressText, "127.0.0.1:1899")
    }

    func testNoMachineMeansNoAddressRatherThanAGuess() {
        let endpoint = MirrorEndpoint.derive(peer: nil, forwardedPort: 1730)
        XCTAssertNil(endpoint.target)
        XCTAssertTrue(endpoint.route.contains("No Mac is connected"),
                      endpoint.route)
    }

    func testAnImpossibleForwardPortIsRefusedWithTheNumberInIt() {
        let endpoint = MirrorEndpoint.derive(
            peer: GuestAddress(text: "127.0.0.1"), forwardedPort: 0)
        XCTAssertNil(endpoint.target)
        XCTAssertTrue(endpoint.route.contains("0 is not a port"),
                      endpoint.route)
    }

    func testTheModelDialsTheDerivedAddressAndNotTheGuestsOwn() {
        let probe = FakeGuestProbe()
        let endpoint = FakeEndpointProbe()
        probe.activeGuest = guest(address: "127.0.0.1")
        let model = model(probe: probe, endpoint: endpoint)
        model.forwardedAgentPort = 1724
        model.connection = .connected(named: "New Old World")
        model.check()

        XCTAssertEqual(endpoint.asked.map(\.port), [1724],
                       "dialling 1420 on loopback would reach this Mac, "
                           + "not the emulated one")
        XCTAssertEqual(model.reachability, .reachable)
    }

    // MARK: - Launch preconditions

    private func product() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MirrorApp-\(UUID().uuidString)")
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testNoConnectedMacRefusesWithItsOwnReason() throws {
        let model = model()
        model.namedAppPath = try product().path
        XCTAssertEqual(model.refusal, .noGuest)
        XCTAssertFalse(model.canLaunch)
    }

    func testAnUnreachableAgentRefusesWithTheAddressAndTheReason() throws {
        let endpoint = FakeEndpointProbe()
        endpoint.answer = .failure(
            MirrorProbeFailure("the connection was refused"))
        let model = try ready(endpoint: endpoint, product: product())

        XCTAssertEqual(model.refusal,
                       .unreachable(address: "10.0.1.7:1420",
                                    reason: "the connection was refused"))
        XCTAssertTrue(model.refusal!.message.contains("10.0.1.7:1420"))
    }

    func testAMissingExtensionRefusesAndNamesIt() throws {
        let probe = FakeGuestProbe()
        probe.extensions = .success([entry("AXPeek"), entry("QDPeek")])
        let model = try ready(probe: probe, product: product())

        XCTAssertEqual(model.refusal, .initsAbsent([.portal]))
        XCTAssertTrue(model.refusal!.message.contains("Portal"),
                      model.refusal!.message)
        XCTAssertTrue(model.refusal!.message.contains("loads at boot"),
                      "the fix is a restart, and nothing else says so")
    }

    func testADisabledExtensionRefusesJustAsAMissingOneDoes() throws {
        let probe = FakeGuestProbe()
        probe.extensions = .success([
            entry("AXPeek"), entry("QDPeek"), entry("Portal", off: true),
        ])
        let model = try ready(probe: probe, product: product())
        XCTAssertEqual(model.refusal, .initsAbsent([.portal]))
    }

    func testNoBuiltMirrorRefusesAndPointsAtTheDevToggle() throws {
        let probe = FakeGuestProbe()
        probe.activeGuest = guest(address: "10.0.1.7")
        probe.extensions = .success(MirrorInit.allCases.map {
            entry($0.fileName)
        })
        let model = model(probe: probe)
        model.connection = .connected(named: "New Old World")
        model.check()

        guard case .noProduct(let reason) = model.refusal else {
            return XCTFail("expected a product refusal, got "
                           + String(describing: model.refusal))
        }
        XCTAssertTrue(reason.contains("Build from source"), reason)
    }

    func testBuildFromSourceWithoutACheckoutRefusesForThatReason() throws {
        let model = try ready(product: product())
        model.buildFromSource = true
        XCTAssertEqual(model.refusal, .noCheckout)
    }

    func testAReadyMachineRefusesNothing() throws {
        let model = try ready(product: product())
        XCTAssertNil(model.refusal)
        XCTAssertTrue(model.canLaunch)
    }

    // MARK: - Binary resolution

    func testTheNamedPathWinsOverTheCheckoutBuild() throws {
        let named = try product()
        let checkout = try builtCheckout()
        let resolution = MirrorProduct.resolve(named: named.path,
                                               checkout: checkout)
        XCTAssertEqual(resolution.product?.executable.path, named.path)
        XCTAssertEqual(resolution.product?.origin, .named)
    }

    func testWithoutANamedPathTheCheckoutsReleaseBuildIsUsed() throws {
        let checkout = try builtCheckout()
        let resolution = MirrorProduct.resolve(named: nil, checkout: checkout)
        XCTAssertEqual(resolution.product?.executable.path,
                       checkout.releaseProduct.path)
        XCTAssertEqual(resolution.product?.origin, .checkout)
    }

    func testANamedPathWithNothingRunnableAtItDoesNotFallThrough() throws {
        let checkout = try builtCheckout()
        let resolution = MirrorProduct.resolve(
            named: "/nowhere/MirrorApp", checkout: checkout)
        XCTAssertNil(resolution.product,
                     "an explicit answer that is wrong must say so rather "
                         + "than launch a different Mirror than the one asked "
                         + "for")
    }

    func testAnAppBundleResolvesToTheBinaryInside() throws {
        let bundle = try folder("bundle")
            .appendingPathComponent("Mirror.app")
        let macOS = bundle.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(
            at: macOS, withIntermediateDirectories: true)
        let binary = macOS.appendingPathComponent("MirrorApp")
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let resolution = MirrorProduct.resolve(named: bundle.path,
                                               checkout: nil)
        XCTAssertEqual(resolution.product?.executable.path, binary.path)
    }

    func testAFolderIsNotARunnableMirror() throws {
        let plain = try folder("not-a-binary")
        XCTAssertNil(MirrorProduct.resolve(named: plain.path,
                                           checkout: nil).product,
                     "a directory's execute bit means searchable, and "
                         + "accepting one buys a launch failure that never "
                             + "mentions the path that was typed")
    }

    func testAnUnbuiltCheckoutSaysSoRatherThanReportingNoMirror() throws {
        let checkout = try emptyCheckout()
        guard case .missing(let reason) = MirrorProduct.resolve(
            named: nil, checkout: checkout) else {
            return XCTFail("expected a missing product")
        }
        XCTAssertTrue(reason.contains(checkout.root.path), reason)
        XCTAssertTrue(reason.contains("Build from source"), reason)
    }

    func testTheCheckoutIsFoundByAMarkerInsideItRatherThanByName() throws {
        let root = try folder("repo")
        let mirror = root.appendingPathComponent("now/mirror")
        try FileManager.default.createDirectory(
            at: mirror.appendingPathComponent("host/MirrorKit"),
            withIntermediateDirectories: true)
        try Data().write(to: mirror
            .appendingPathComponent("host/MirrorKit/Package.swift"))

        let deep = root.appendingPathComponent(
            "now/now-host/.build/release/Host")
        XCTAssertEqual(MirrorCheckout.locate(startingAt: deep, defaults: nil)?.root.path,
                       mirror.standardizedFileURL.path)

        let decoy = try folder("decoy")
        try FileManager.default.createDirectory(
            at: decoy.appendingPathComponent("mirror"),
            withIntermediateDirectories: true)
        XCTAssertNil(MirrorCheckout.locate(startingAt: decoy, defaults: nil),
                     "a directory named mirror is not Mirror")
    }

    // MARK: - Lifecycle

    func testLaunchRunsTheLiveWindowAgainstTheDerivedEndpoint() throws {
        let spawner = FakeSpawner()
        let model = try ready(spawner: spawner, product: product())
        model.launch()

        XCTAssertEqual(spawner.invocations.count, 1)
        XCTAssertEqual(spawner.invocations[0].arguments,
                       ["--host", "10.0.1.7", "--port", "1420",
                        "--machine", "pb1400c", "--scope", "all",
                        "--window", "--display", "--islands",
                        "--interval", "0.7"])
        XCTAssertEqual(model.run, .running(pid: 4242))
    }

    func testWhileRunningTheReachabilityCheckStandsDownAndSaysWhy() throws {
        let spawner = FakeSpawner()
        let model = try ready(spawner: spawner, product: product())
        model.launch()
        model.check()

        guard case .paused(let reason) = model.reachability else {
            return XCTFail("expected a paused probe, got "
                           + String(describing: model.reachability))
        }
        XCTAssertTrue(reason.contains("one client"), reason)
    }

    func testAnExitCarriesTheStatusAndWhatMirrorSaid() throws {
        let spawner = FakeSpawner()
        let model = try ready(spawner: spawner, product: product())
        model.launch()
        spawner.outputs[0]("could not open the display\n")
        spawner.finish(0, status: 3)

        XCTAssertEqual(model.run,
                       .exited(status: 3,
                               tail: ["could not open the display"]))
        XCTAssertEqual(model.reachability, .untried,
                       "the agent's one slot is free again, so the paused "
                           + "answer is no longer the true one")
    }

    func testQuitAsksBeforeItForces() throws {
        let spawner = FakeSpawner()
        let model = try ready(spawner: spawner, product: product())
        model.launch()
        model.quit()

        XCTAssertEqual(spawner.terminated.count, 1)
        XCTAssertEqual(spawner.terminated[0].pid, 4242)
        XCTAssertGreaterThan(spawner.terminated[0].grace, 0,
                             "a killed Mirror leaves the agent's single "
                                 + "slot held until the guest times out")
    }

    func testASecondLaunchIsRefusedWhileOneIsRunning() throws {
        let spawner = FakeSpawner()
        let model = try ready(spawner: spawner, product: product())
        model.launch()
        XCTAssertEqual(model.refusal, .alreadyRunning)
        model.launch()
        XCTAssertEqual(spawner.invocations.count, 1)
    }

    func testAChildThatNeverStartsIsReportedRatherThanLeftPending() throws {
        let spawner = FakeSpawner()
        spawner.results = [.failure(MirrorProbeFailure("No such file"))]
        let model = try ready(spawner: spawner, product: product())
        model.launch()

        XCTAssertEqual(model.run, .failed("Mirror did not start — "
                                          + "No such file"))
    }

    // MARK: - The dev toggle

    func testBuildFromSourceBuildsFirstAndThenLaunchesTheProduct() throws {
        let checkout = try builtCheckout()
        let probe = FakeGuestProbe()
        let spawner = FakeSpawner()
        probe.activeGuest = guest(address: "10.0.1.7")
        probe.extensions = .success(MirrorInit.allCases.map {
            entry($0.fileName)
        })
        let model = MirrorControlModel(
            guestProbe: probe, endpointProbe: FakeEndpointProbe(),
            spawner: spawner, checkout: checkout, defaults: defaults())
        model.buildFromSource = true
        model.connection = .connected(named: "New Old World")
        model.check()

        model.launch()
        XCTAssertEqual(model.run, .building)
        XCTAssertEqual(spawner.invocations[0].executable.path,
                       "/usr/bin/swift")
        XCTAssertEqual(spawner.invocations[0].arguments,
                       ["build", "-c", "release",
                        "--package-path", checkout.package.path])

        spawner.finish(0, status: 0)
        XCTAssertEqual(spawner.invocations.count, 2)
        XCTAssertEqual(spawner.invocations[1].executable.path,
                       checkout.releaseProduct.path)
        XCTAssertEqual(model.run, .running(pid: 4242))
    }

    func testAFailedBuildStopsAndDoesNotLaunchAnOlderBinary() throws {
        let checkout = try builtCheckout()
        let probe = FakeGuestProbe()
        let spawner = FakeSpawner()
        probe.activeGuest = guest(address: "10.0.1.7")
        probe.extensions = .success(MirrorInit.allCases.map {
            entry($0.fileName)
        })
        let model = MirrorControlModel(
            guestProbe: probe, endpointProbe: FakeEndpointProbe(),
            spawner: spawner, checkout: checkout, defaults: defaults())
        model.buildFromSource = true
        model.connection = .connected(named: "New Old World")
        model.check()

        model.launch()
        spawner.finish(0, status: 1)

        XCTAssertEqual(spawner.invocations.count, 1,
                       "a build that produced nothing must not launch the "
                           + "binary from before it ran")
        guard case .failed(let reason) = model.run else {
            return XCTFail("expected a failure, got \(model.run)")
        }
        XCTAssertTrue(reason.contains("exit 1"), reason)
    }

    // MARK: - Focus

    func testSwitchingMachinesDropsEveryClaimAboutTheOldOne() throws {
        let probe = FakeGuestProbe()
        let model = try ready(probe: probe, product: product())
        XCTAssertEqual(model.agent, .running)

        model.connection = .connected(named: "Another Mac")
        XCTAssertEqual(model.agent, .untried)
        XCTAssertEqual(model.reachability, .untried)
        XCTAssertTrue(model.absentInits.isEmpty)
        XCTAssertEqual(model.initRows.map(\.state),
                       Array(repeating: .unknown("Not checked yet."),
                             count: 3),
                       "one Mac's readiness under another's name is the "
                           + "defect every guest-scoped model here exists "
                           + "to avoid")
    }

    // MARK: - Scratch

    private var scratch: [URL] = []

    override func tearDown() async throws {
        for url in scratch { try? FileManager.default.removeItem(at: url) }
        scratch = []
    }

    private func folder(_ tag: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("now-mirror-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        scratch.append(url)
        return url
    }

    private func emptyCheckout() throws -> MirrorCheckout {
        let root = try folder("checkout")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("host/MirrorKit"),
            withIntermediateDirectories: true)
        try Data().write(to: root
            .appendingPathComponent("host/MirrorKit/Package.swift"))
        return MirrorCheckout(root: root)
    }

    private func builtCheckout() throws -> MirrorCheckout {
        let checkout = try emptyCheckout()
        let product = checkout.releaseProduct
        try FileManager.default.createDirectory(
            at: product.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: product)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: product.path)
        return checkout
    }

    /// A shipped app never sits inside the checkout, so the walk finds
    /// nothing and the remembered path is the only thing that can answer.
    /// This is what a person hits the moment the app is on a Desktop.
    func testARememberedCheckoutAnswersForACopiedApp() throws {
        let root = try folder("remembered-repo")
        let mirror = root.appendingPathComponent("mirror")
        try FileManager.default.createDirectory(
            at: mirror.appendingPathComponent("host/MirrorKit"),
            withIntermediateDirectories: true)
        try Data().write(to: mirror
            .appendingPathComponent("host/MirrorKit/Package.swift"))
        let defaults = UserDefaults(suiteName: "MirrorControlTests.remembered")!
        defaults.removePersistentDomain(forName: "MirrorControlTests.remembered")
        defaults.set(mirror.path, forKey: MirrorCheckout.rememberedRepoKey)
        let desktop = URL(fileURLWithPath: "/Users/someone/Desktop")
        XCTAssertEqual(
            MirrorCheckout.locate(startingAt: desktop, defaults: defaults)?
                .root.path,
            mirror.standardizedFileURL.path,
            "a copied app must still find the checkout it was built from")

        defaults.set("/nowhere/at/all", forKey: MirrorCheckout.rememberedRepoKey)
        XCTAssertNil(MirrorCheckout.locate(startingAt: desktop, defaults: defaults),
                     "a remembered path that moved degrades to nil, not to a bad launch")
        defaults.removePersistentDomain(forName: "MirrorControlTests.remembered")
    }

    /// Without `--qmp` Mirror's own availability rule refuses every drag,
    /// widget-track and positional click — "needs the emulator QMP input
    /// plane" — so the window draws and answers almost nothing. A pane that
    /// omits it ships a mirror you cannot use, which is what happened.
    func testTheLiveWindowCarriesTheQMPSocketWhenThereIsOne() {
        let product = MirrorProduct(executable: URL(fileURLWithPath: "/bin/m"),
                                    origin: .named)
        let withQMP = MirrorInvocation.liveWindow(
            product, host: "127.0.0.1", port: 1730, machine: "guest-2",
            qmpSocket: URL(fileURLWithPath: "/tmp/qmp.sock"))
        XCTAssertTrue(withQMP.arguments.contains("--qmp"),
                      "an emulated target must get its input plane")
        XCTAssertTrue(withQMP.arguments.contains("/tmp/qmp.sock"))

        let metal = MirrorInvocation.liveWindow(
            product, host: "10.0.1.7", port: 1420, machine: "pb1400c")
        XCTAssertFalse(metal.arguments.contains("--qmp"),
                       "a real Mac has no QMP; the flag would name nothing")
        XCTAssertTrue(metal.arguments.contains("--window"))
    }
}
