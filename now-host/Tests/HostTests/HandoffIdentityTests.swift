import XCTest
@testable import Host

/// The handoff's identity step, over loopback, with the defect
/// reintroduced on purpose.
///
/// THE MUTATION THIS FILE IS. The retire step used to build the outgoing
/// build's name as `"NOW-68K " + <version from its hello>`. That passes
/// forever on a machine where a build's file name and its compiled
/// `NOW68K_APP_VERSION` agree — which is every machine until one day it
/// is not, and on 2026-07-25 it was not. So the scripted guests here are
/// deliberately mismatched: the outgoing one is deployed as
/// `NOW-68K 0.18` and reports `0.16`. Anything that names it from the
/// version names nothing; anything that names it from the PSN on the
/// `isSelf` row of its own listing names it exactly.
///
/// A scripted guest proves nothing about the 68K guest's Toolbox code —
/// what it proves is that THIS side never invents an identifier, which is
/// where the defect was. The guest half is proved by
/// `now-guest-68k/tests/test_proclist.c` (isSelf lands on the right row) and,
/// on metal, by `Metal68KHandoffTests`.
@MainActor
final class HandoffIdentityTests: XCTestCase {
    private var oldHost: GuestListener!
    private var newHost: GuestListener!
    private var oldGuest: FakeGuest!
    private var newGuest: FakeGuest!

    /// The PSNs of the two builds. Both are called the same thing on the
    /// machine here and only the number tells them apart, which is the
    /// case a name provably cannot serve.
    private let oldPSN = (high: 0, low: 16519)
    private let newPSN = (high: 0, low: 24601)

    /// The lie. `NOW-68K 0.18` is what is on the disk; `0.16` is what the
    /// binary says.
    private let deployedName = "NOW-68K 0.18"
    private let reportedVersion = "0.16"

    /// What the old guest was asked to quit, by name, if anything was.
    private var quitByName: [String] = []
    /// The PSNs the new guest was asked to quit.
    private var quitByPSN: [(Int, Int)] = []
    /// Whether the old build is still "running" in the scripted machine.
    private var oldStillRunning = true

    override func setUp() async throws {
        oldHost = GuestListener(identity: .init(version: "0.1-test",
                                                name: "Handoff (old)"))
        newHost = GuestListener(identity: .init(version: "0.1-test",
                                                name: "Handoff (new)"))
        oldHost.start(port: 0)
        newHost.start(port: 0)
        // `.listening`, not merely a bound port: NWListener hands over a
        // port number before it is ready to accept, and a guest that
        // dials into that gap never connects.
        try await waitUntil("both listening") {
            if case .listening = self.oldHost.state,
               case .listening = self.newHost.state { return true }
            return false
        }

        oldGuest = FakeGuest(port: oldHost.boundPort!)
        newGuest = FakeGuest(port: newHost.boundPort!)
        script(oldGuest, isNewBuild: false)
        script(newGuest, isNewBuild: true)
        oldGuest.start()
        newGuest.start()
        try oldGuest.send(hello(version: reportedVersion))
        try newGuest.send(hello(version: "0.19"))
        try await waitUntil("both connected") {
            if case .connected = self.oldHost.state,
               case .connected = self.newHost.state { return true }
            return false
        }
    }

    override func tearDown() async throws {
        oldHost?.stop(); oldHost = nil
        newHost?.stop(); newHost = nil
        oldGuest = nil; newGuest = nil
    }

    private func hello(version: String) -> ControlMessage {
        .hello(Hello(contract: Contract.revision, side: "guest",
                     version: version, name: "PowerBook 180c", os: "7.1",
                     chunk: 4096))
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5,
                           _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting for \(what)")
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// One process row, written the way the guest writes it: `isSelf` is
    /// present only where it is true.
    private func row(_ name: String, psn: (high: Int, low: Int),
                     isSelf: Bool) -> ProcessEntry {
        ProcessEntry(name: name, kind: "application", code: "APPL",
                     creator: "NW68", sizeKB: 384, front: isSelf,
                     psnHigh: psn.high, psnLow: psn.low,
                     isSelf: isSelf ? true : nil)
    }

    /// A guest that serves process.list from a shared scripted machine
    /// and answers process.quit against it. Both builds are on that
    /// machine and both are called the same thing, so nothing but the PSN
    /// distinguishes them.
    private func script(_ guest: FakeGuest, isNewBuild: Bool) {
        guest.onMessage = { [weak self, weak guest] message in
            guard let self, let guest else { return }
            switch message {
            case .processList(let request):
                var rows: [ProcessEntry] = [
                    self.row("Finder", psn: (0, 8386), isSelf: false)
                ]
                if self.oldStillRunning {
                    rows.append(self.row(self.deployedName, psn: self.oldPSN,
                                         isSelf: !isNewBuild))
                }
                rows.append(self.row(self.deployedName, psn: self.newPSN,
                                     isSelf: isNewBuild))
                try? guest.send(.processListing(
                    ProcessListing(id: request.id, processes: rows,
                                   more: false, cursor: rows.count + 1)))
            case .processQuit(let request):
                self.quitByPSN.append((request.psnHigh, request.psnLow))
                let live = (self.oldStillRunning
                            && request.psnHigh == self.oldPSN.high
                            && request.psnLow == self.oldPSN.low)
                    || (request.psnHigh == self.newPSN.high
                        && request.psnLow == self.newPSN.low)
                if live && !isNewBuild {
                    // The self-quit refusal, mirrored from proc68.c.
                    try? guest.send(.processResult(ProcessResult(
                        id: request.id, ok: false,
                        reason: "quit: NOW will not ask itself to quit")))
                    return
                }
                if live {
                    self.oldStillRunning = false
                    try? guest.send(.processResult(
                        ProcessResult(id: request.id, ok: true, reason: nil)))
                } else {
                    try? guest.send(.processResult(ProcessResult(
                        id: request.id, ok: false,
                        reason: "quit: that process is no longer running")))
                }
            case .commandRequest(let request):
                // The name-shaped route, answered exactly as the guest
                // answers it: honestly, and uselessly, when the name was
                // never on the machine.
                let target = request.args?["target"]?.stringValue ?? ""
                self.quitByName.append(target)
                let found = target == self.deployedName
                try? guest.send(.commandResult(CommandResult(
                    id: request.id, ok: found,
                    output: found ? ["quit": [["Outcome", "gone"]]] : nil,
                    error: found ? nil
                        : .init(code: "not-running",
                                message: "quit: nothing named \(target) "
                                    + "is running"))))
            default:
                break
            }
        }
    }

    /// The whole point. The old build's file name and its reported
    /// version disagree; the retire step still finds and quits it.
    func testTheOutgoingBuildIsRetiredEvenWhenItsNameAndVersionDisagree()
        async throws {
        let retiree = try await Handoff68K.identifySelf(of: oldHost)
        XCTAssertEqual(retiree.psnLow, oldPSN.low, """
            identifySelf picked the wrong row. Both builds are called \
            \(deployedName) here, so a name cannot choose between them — \
            only isSelf can, and it is on the connection's own process.
            """)

        // The identity must NOT be reconstructible from the hello: this
        // is the assertion that fails if anyone reintroduces the old
        // derivation, because the string it would build names nothing.
        let derived = "NOW-68K \(oldHost.health?.guestVersion ?? "?")"
        XCTAssertNotEqual(derived, retiree.name, """
            this test is not testing anything: the build's file name and \
            the version in its hello agree, which is the case the old \
            code passed in. Keep them apart.
            """)

        try await Handoff68K.retire(retiree, using: newHost)
        XCTAssertEqual(quitByPSN.map(\.1), [oldPSN.low],
                       "the new build was told which PROCESS, once")
        XCTAssertTrue(quitByName.isEmpty,
                      "nothing went out as a name — a name is what got "
                      + "this wrong")

        let gone = try await Handoff68K.hasGone(retiree, accordingTo: newHost)
        XCTAssertTrue(gone, "the surviving build no longer lists that PSN")
    }

    /// The old derivation, run against the same scripted machine, so the
    /// defect is watched failing rather than described. `quit` with a name
    /// built from the version reaches the guest, is understood, and
    /// refuses — which is exactly what made it so hard to see: nothing
    /// errored, and the old build simply kept running.
    func testNamingTheBuildFromItsHelloVersionQuitsNothing() async throws {
        let derived = "NOW-68K \(oldHost.health?.guestVersion ?? "?")"
        XCTAssertEqual(derived, "NOW-68K \(reportedVersion)")

        let result = await withCheckedContinuation {
            (cont: CheckedContinuation<CommandResult, Never>) in
            newHost.runCommand("quit", args: ["target": derived]) {
                cont.resume(returning: $0)
            }
        }
        XCTAssertFalse(result.ok, """
            the scripted guest accepted \(derived), which means this test \
            no longer reproduces the defect.
            """)
        XCTAssertEqual(result.error?.code, "not-running")
        XCTAssertTrue(oldStillRunning, """
            the old build is still up, and the failure is a REFUSAL rather \
            than an error — which is why nothing noticed for a day.
            """)
    }
}
