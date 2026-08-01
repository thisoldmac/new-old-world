import XCTest
@testable import Host

/// The Mirror module is a launcher, so what there is to test is the part
/// that runs before anything is launched: where Mirror was found, what
/// command would be run, and — the half that matters most — whether a
/// missing prerequisite is NAMED rather than discovered as a wall of shell
/// output after the click.
///
/// Nothing here spawns a process. That is the point of the split: the model
/// keeps Process and SwiftUI, `MirrorInstallation` keeps the decisions.
final class MirrorLauncherTests: XCTestCase {

    private var root: URL!

    /// A repository shaped like this one: a lab checkout with a `mirror/`
    /// inside it, and `spin-up.sh`'s borrowed instruments as siblings of
    /// mirror rather than inside it — which is exactly the geometry the
    /// script assumes and the one a vendored Mirror breaks.
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mirror-launcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private func write(_ relative: String, executable: Bool = false) {
        let url = root.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: url.path, contents: Data("x\n".utf8),
            attributes: executable ? [.posixPermissions: 0o755] : nil)
    }

    /// The minimum that makes a directory Mirror at all.
    private func makeMirror() -> URL {
        write("mirror/host/MirrorKit/Package.swift")
        return root.appendingPathComponent("mirror")
    }

    /// Everything `spin-up.sh` needs, so a test can remove exactly one thing
    /// and see it named.
    private func makeCompleteGuestRig() {
        write("mirror/tools/spin-up.sh", executable: true)
        write("mirror/guest/extensions/axpeek/build/AXPeek.bin")
        write("mirror/guest/extensions/qdpeek/build/QDPeek.bin")
        write("mirror/guest/extensions/portal/build/Portal.bin")
        write("mirror/guest/app/build/mirror-agent.bin")
        write("tools/lib.sh", executable: true)
        write("tools/qmp", executable: true)
        write("mcp-classic/marker")
        write("qemu/build/qemu-system-ppc", executable: true)
        write("os91-runner.qcow2")
    }

    private var completeEnvironment: [String: String] {
        ["MIRROR_BASE": root.appendingPathComponent("os91-runner.qcow2").path]
    }

    // MARK: - Locating

    func testLocateWalksUpToTheRepositoryHoldingMirror() {
        let mirror = makeMirror()
        /* Where `swift run` leaves the binary: several levels below the
           repository root, which is the only reason the walk exists. */
        let executable = root.appendingPathComponent("now-host/.build/debug/Host")
        XCTAssertEqual(
            MirrorInstallation.locate(override: nil, startingAt: executable)?.root
                .standardizedFileURL,
            mirror.standardizedFileURL)
    }

    func testLocateFindsNothingWithoutTheMarkerFile() {
        /* A directory NAMED mirror is not Mirror. The marker is a file
           inside it, so an empty or half-copied tree reads as absent rather
           than as an installation that then fails obscurely. */
        try? FileManager.default.createDirectory(
            at: root.appendingPathComponent("mirror"),
            withIntermediateDirectories: true)
        XCTAssertNil(MirrorInstallation.locate(
            override: nil, startingAt: root.appendingPathComponent("now-host")))
    }

    func testOverrideNamesMirrorDirectly() {
        let mirror = makeMirror()
        let elsewhere = URL(fileURLWithPath: "/")
        XCTAssertEqual(
            MirrorInstallation.locate(override: mirror.path,
                                      startingAt: elsewhere)?.root
                .standardizedFileURL,
            mirror.standardizedFileURL)
        XCTAssertNil(MirrorInstallation.locate(
            override: root.appendingPathComponent("nowhere").path,
            startingAt: elsewhere))
    }

    // MARK: - The host app

    func testHostAppIsBlockedWithoutARunningGuestSession() {
        let installation = MirrorInstallation(root: makeMirror())
        let plan = installation.plan(.hostApp, environment: [:])
        XCTAssertNil(plan.invocation)
        XCTAssertEqual(plan.blockers.map(\.what),
                       ["A running Mirror guest session"])
        /* The reason has to say WHERE it looked, because the fix is to run
           the other button and the file is the evidence it worked. */
        XCTAssertTrue(plan.blockers[0].why.contains("run/ports"),
                      plan.blockers[0].why)
    }

    func testHostAppTakesThePortSpinUpChose() {
        let mirror = makeMirror()
        write("mirror/run/ports")
        try? "1704 1724\n".write(
            to: mirror.appendingPathComponent("run/ports"),
            atomically: true, encoding: .utf8)
        write("mirror/run/qmp.sock")

        let plan = MirrorInstallation(root: mirror).plan(.hostApp,
                                                         environment: [:])
        let arguments = try? XCTUnwrap(plan.invocation).arguments
        /* The AGENT port, not the anchor. spin-up.sh writes both and the
           first one is the deploy channel — MirrorApp pointed at it would
           talk to the wrong server on the same machine. */
        XCTAssertEqual(arguments?.firstIndex(of: "--port")
            .map { arguments![$0 + 1] }, "1724")
        XCTAssertTrue(arguments?.contains("--window") == true)
        /* `--scope front` walks only the front application, so every other
           app's windows are missing from the scene — which reads as a
           rendering fault and was mistaken for one once. */
        XCTAssertEqual(arguments?.firstIndex(of: "--scope")
            .map { arguments![$0 + 1] }, "all")
        XCTAssertTrue(arguments?.contains("--qmp") == true)
    }

    func testHostAppOmitsQMPWhenTheSocketIsGone() {
        let mirror = makeMirror()
        write("mirror/run/ports")
        try? "1700 1720\n".write(
            to: mirror.appendingPathComponent("run/ports"),
            atomically: true, encoding: .utf8)

        let plan = MirrorInstallation(root: mirror).plan(.hostApp,
                                                         environment: [:])
        XCTAssertFalse(try XCTUnwrap(plan.invocation).arguments.contains("--qmp"))
    }

    // MARK: - The guest session

    func testGuestSessionIsReadyWhenEverythingIsPresent() throws {
        _ = makeMirror()
        makeCompleteGuestRig()
        let installation = MirrorInstallation(
            root: root.appendingPathComponent("mirror"))
        let plan = installation.plan(.guestSession,
                                     environment: completeEnvironment)
        let invocation = try XCTUnwrap(plan.invocation)
        XCTAssertEqual(invocation.executable.path, "/bin/bash")
        XCTAssertEqual(invocation.arguments, [installation.spinUp.path])
        /* The cocoa window beside the mirror: the comparison IS the test
           drive, so the launcher asks for it rather than leaving a person
           with a mirror of a screen they cannot see. */
        XCTAssertEqual(invocation.extraEnvironment["MIRROR_DISPLAY"], "1")
    }

    func testMissingLabInstrumentsAreNamed() throws {
        _ = makeMirror()
        makeCompleteGuestRig()
        /* The blocker a Mirror vendored inside NOW actually hits:
           spin-up.sh resolves the lab as its own parent, which here is a
           repository that has none of the emulator plumbing. Without this
           check the click produces bash errors about a file the reader has
           no reason to have heard of. */
        try FileManager.default.removeItem(at: root.appendingPathComponent("tools/lib.sh"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("mcp-classic"))

        let plan = MirrorInstallation(root: root.appendingPathComponent("mirror"))
            .plan(.guestSession, environment: completeEnvironment)
        XCTAssertNil(plan.invocation)
        let why = try XCTUnwrap(plan.blockers.first {
            $0.what.contains("lab instruments")
        }).why
        XCTAssertTrue(why.contains("tools/lib.sh"), why)
        XCTAssertTrue(why.contains("mcp-classic"), why)
        XCTAssertFalse(why.contains("tools/qmp"), "present, so not a blocker")
    }

    func testMissingGuestArtifactsAreNamedAsBuildsRatherThanAsErrors() throws {
        _ = makeMirror()
        makeCompleteGuestRig()
        /* A fresh checkout has none of these: Mirror's .gitignore keeps
           build output out of the tree, so "not built yet" is the ordinary
           state and must not read as breakage. */
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("mirror/guest/app/build/mirror-agent.bin"))

        let plan = MirrorInstallation(root: root.appendingPathComponent("mirror"))
            .plan(.guestSession, environment: completeEnvironment)
        let why = try XCTUnwrap(plan.blockers.first {
            $0.what.contains("guest pieces")
        }).why
        XCTAssertTrue(why.contains("mirror-agent.bin"), why)
        XCTAssertTrue(why.contains("Retro68"), why)
    }

    func testEveryMissingPrerequisiteIsReportedAtOnce() {
        _ = makeMirror()
        /* Nothing staged at all. A launcher that reports the first missing
           thing makes a person discover the list one click at a time. */
        let plan = MirrorInstallation(root: root.appendingPathComponent("mirror"))
            .plan(.guestSession, environment: ["MIRROR_BASE": "/nonexistent"])
        XCTAssertNil(plan.invocation)
        XCTAssertEqual(plan.blockers.count, 5, plan.blockers.map(\.what).description)
    }

    func testQemuAndBaseImageHonourTheScriptsOwnOverrides() throws {
        _ = makeMirror()
        makeCompleteGuestRig()
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("qemu/build/qemu-system-ppc"))
        write("elsewhere/qemu-system-ppc", executable: true)

        var environment = completeEnvironment
        environment["TIMBOTTU_QEMU"] =
            root.appendingPathComponent("elsewhere/qemu-system-ppc").path
        let plan = MirrorInstallation(root: root.appendingPathComponent("mirror"))
            .plan(.guestSession, environment: environment)
        XCTAssertNotNil(plan.invocation, plan.blockers.map(\.what).description)
    }

    // MARK: - Outcomes

    func testANonZeroExitPointsAtTheOutputRatherThanGuessing() {
        let summary = MirrorLauncherModel.summary(.guestSession, status: 1)
        XCTAssertTrue(summary.contains("spin-up.sh"), summary)
        XCTAssertTrue(summary.contains("exited 1"), summary)
        /* The process said what went wrong; paraphrasing it here is how a
           reason gets lost. */
        XCTAssertTrue(summary.contains("its own"), summary)
    }

    func testTheDisplayedCommandIsTheOneThatWouldRun() {
        let invocation = MirrorInvocation(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: ["/m/tools/spin-up.sh"],
            workingDirectory: URL(fileURLWithPath: "/m"),
            extraEnvironment: ["MIRROR_DISPLAY": "1"])
        XCTAssertEqual(invocation.displayCommand,
                       "MIRROR_DISPLAY=1 /bin/bash /m/tools/spin-up.sh")
    }
}
