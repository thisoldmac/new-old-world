import Foundation
import XCTest
@testable import Host

/// The host-side twin of `MetalMachineGuard`: a gate must check that the
/// MACHINE is free before it believes anything it measured.
///
/// **Why this exists.** The metal side has had that rule since 2026-07-25
/// (docs/68k-metal-runbook.md). The host gate never did, and it cost three
/// days: `scripts/test-all` was red here from 2026-08-02, five loopback
/// cases timing out at 5 s and passing in 0.1 s alone, and the enquiry went
/// looking for a defect in the code under test. The machine was busy the
/// whole time — another worktree's session had an `xctest` holding 5250 —
/// and nothing said so, because the check being made was `ps | grep` for
/// `New Old World`, `swift build`, `swift test` and `xcodebuild`. A SwiftPM
/// suite runs as a bare `xctest` and matches none of those. **Check the
/// PORT, not the process name.**
///
/// **Why it is a test and not a line in `scripts/test-host`.** The person
/// who reproduced this ran `cd now-host && swift test`, which no shell
/// script wraps. A guard that only fires through the gate script is absent
/// exactly when somebody is narrowing a failure by hand, which is when it
/// is worth most. The gate script runs `swift test` too, so this covers
/// both and the rule is stated once.
///
/// The `lsof` reading itself is not repeated here — `MetalMachineGuard`
/// already does it, and correctly (its `holdsLocally` filter is what keeps
/// a guest DIALLING a port from reading as a second listener ON it). What
/// is metal about that type is its policy, not its plumbing.
@MainActor
final class HostMachineGuardTests: XCTestCase {

    /// The port the product listens on, from the product — not a constant
    /// repeated here. `NOW_WIRE_PORT` overrides it, the same name
    /// `scripts/spin-up-ppc` uses for the same idea.
    private var wirePort: UInt16 {
        ProcessInfo.processInfo.environment["NOW_WIRE_PORT"]
            .flatMap(UInt16.init) ?? SettingsModel.defaultPort
    }

    private var overridden: Bool {
        ProcessInfo.processInfo.environment["NOW_ALLOW_BUSY_MACHINE"] != nil
    }

    /// Nothing else on this Mac may be holding the wire port.
    ///
    /// A held 5250 is not a hypothetical: the app holds it whenever it is
    /// running, and — until the defect settled on 2026-08-05 — so did this
    /// suite, because five tests built a `HostAppState` on a bare defaults
    /// suite and `listenAtLaunch` is true when absent. That is fixed
    /// (`UserDefaults.offTheWire()`), which is what makes this guard
    /// meaningful rather than self-tripping.
    func testNothingElseOnThisMacHoldsTheWirePort() throws {
        let port = wirePort
        guard let held = MetalMachineGuard.holders(ofPort: port) else {
            return XCTFail("""
                /usr/sbin/lsof would not run, so nothing established that \
                port \(port) is free. That is a failure and not a shrug: a \
                run nobody can attribute is worse than no run. Set \
                NOW_ALLOW_BUSY_MACHINE=1 to proceed anyway and label the \
                result accordingly.
                """)
        }
        guard !held.isEmpty else { return }
        let who = held.map(\.description).joined(separator: "\n  ")
        let whose = LanePorts.attribution(ofPort: port,
                                          mine: LanePorts.mine(),
                                          lanes: LanePorts.all())
        guard !overridden else {
            return print("""
                === host machine guard: port \(port) is held, and \
                NOW_ALLOW_BUSY_MACHINE says proceed anyway:
                  \(who)
                \(whose)
                Anything red in this run is unattributable. Say so.
                """)
        }
        XCTFail("""
            Port \(port) is already held on this Mac, so this run is \
            measuring a machine somebody else is using:
              \(who)
            \(whose)
            Usually the NOW app (it lives on \(port)), or another \
            worktree's `swift test`, which runs as a bare `xctest` and so \
            matches no `ps | grep` you are likely to try. Quit it and \
            re-run — a red host gate on a busy Mac names nothing, which is \
            how this one went misread from 2026-08-02 to 2026-08-05 \
            (docs/open-issues.md). To proceed regardless and label the \
            result unattributable, set NOW_ALLOW_BUSY_MACHINE=1.
            """)
    }

    /// What this lane's own port block is doing — reported, never failed.
    ///
    /// Deliberately not an assertion. A lane's VM holding the lane's own
    /// anchor and wire is a *working* spin-up, and `swift test` does not
    /// bind either of them; failing for it would be a guard that stops
    /// honest work, which is the failure mode that gets guards routed
    /// around.
    ///
    /// It is worth printing because the 2026-08-06 hazard was never that
    /// a port was busy — it was that nobody could say whose it was. One
    /// line naming this lane's block turns "something holds 1840" into
    /// "your own orphaned VM, reclaim it".
    func testThisLanesOwnPortBlockIsReported() throws {
        guard let mine = LanePorts.mine() else {
            return print("""
                === host machine guard: tools/lane-ports did not answer, so \
                this run has no derived port block and is back to whatever \
                a coordinator handed it. Not a failure — the tool is \
                additive — but see docs/lane-ports.md.
                """)
        }
        let busy = mine.ports
            .sorted { $0.key < $1.key }
            .compactMap { role, port -> String? in
                guard let held = MetalMachineGuard.holders(ofPort: port),
                      !held.isEmpty else { return nil }
                return "\(role) \(port): "
                    + held.map(\.description).joined(separator: ", ")
            }
        guard !busy.isEmpty else {
            return print("=== lane ports: block \(mine.block) "
                         + "(\(mine.label)) — all free")
        }
        print("""
            === lane ports: block \(mine.block) (\(mine.label)) has \
            something running in it —
              \(busy.joined(separator: "\n  "))
            Yours by derivation, so this is your own VM. Not a failure: \
            `swift test` binds none of these. `tools/lane-ports reclaim` \
            stops it guest-clean through the recorded QMP socket path if \
            it is an orphan.
            """)
    }

    /// Another copy of THIS suite running beside us is reported, not
    /// failed.
    ///
    /// Deliberately weaker than the port check, because two suites at once
    /// is a thing people legitimately do here and the loopback work
    /// survives it: measured 2026-08-05, two genuinely concurrent runs
    /// completed with no port collision between them. Failing for it would
    /// be a guard that stops honest work.
    ///
    /// It is still worth saying, for two reasons. A second suite is ~400
    /// more loopback dials out of the one ephemeral range this Mac has,
    /// which is the best candidate for the collisions that could never be
    /// reproduced. And concurrency is what exposed the defects that ARE
    /// still open below — a shared log file and a shared temporary share
    /// directory — so a red run that was not alone should say so.
    ///
    /// Note that `swift test` twice over will NOT produce this: SwiftPM
    /// takes a lock on `.build` and the second invocation waits ("Another
    /// instance of SwiftPM is already running"). Two runs from two
    /// worktrees do, and so does invoking `xctest` on the built bundle
    /// directly. An earlier version of this comment claimed a concurrency
    /// result that had in fact run sequentially for exactly that reason.
    func testAConcurrentCopyOfThisSuiteIsReported() throws {
        let others = Self.otherHostTestProcesses()
        guard !others.isEmpty else { return }
        print("""
            === host machine guard: \(others.count) other copy/copies of \
            this suite are running on this Mac:
              \(others.joined(separator: "\n  "))
            Not a failure — two full runs at once were measured green. But \
            they share one ephemeral port range, so weigh any loopback \
            timeout in this run accordingly.
            """)
    }

    /// `ps` rather than `lsof`: this asks about processes, not sockets,
    /// and the two questions have different right answers.
    ///
    /// **The executable has to be `xctest` itself.** Matching any command
    /// line CONTAINING "HostTests.xctest" was measured reporting three
    /// copies when there was one: the shell that launched the run, and the
    /// `grep` reading its output, both carry the string in their own argv.
    /// A guard whose output is mostly itself is noise, and noise is how a
    /// guard gets ignored.
    private static func otherHostTestProcesses() -> [String] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-Ao", "pid=,command="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let mine = ProcessInfo.processInfo.processIdentifier

        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { row -> String? in
                let fields = row.split(separator: " ",
                                       omittingEmptySubsequences: true)
                guard let pid = fields.first.flatMap({ Int32($0) }),
                      pid != mine,
                      let executable = fields.dropFirst().first,
                      executable.hasSuffix("/xctest") || executable == "xctest"
                else { return nil }
                guard let bundle = fields.first(where: {
                    $0.hasSuffix("HostTests.xctest")
                }) else { return nil }
                return "xctest [pid \(pid)] \(bundle)"
            }
    }
}
