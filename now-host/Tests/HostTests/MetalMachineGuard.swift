import Foundation
import XCTest
@testable import Host

/// Refuses to start a metal run against a machine somebody else is
/// already using.
///
/// ---- Why this is not covered by `requireTheBuildUnderTest()` ---------
///
/// That guard asks whether the guest on the wire is the right GUEST, and
/// it earns its place: several QEMU guests run on this Mac at once and
/// every one of them sees the host as 10.0.2.2, so any session's VM can
/// answer any session's listener.
///
/// It has nothing to say about the case that actually cost an evening.
/// On 2026-07-25 two host sessions used one PowerBook: one held port
/// 5252 for the better part of an hour while the other deployed a build
/// into the same folder over FTP, mid-ladder. A 1 MB push stalled at
/// 606208 bytes and every rung after it timed out at `0 of N`. The right
/// guest answered the whole time. Contention is the likely cause and
/// nothing proves it, which is the worst outcome a gate can produce —
/// worse than a red, because a red at least names something.
///
/// So: the other guard asks *who answered*, this one asks *whether the
/// machine was free to answer at all*, and both run before a byte moves.
///
/// ---- What it can see, and what it cannot ------------------------------
///
/// Everything here is observed from THIS Mac, because that is where the
/// contention originates — a second harness, an FTP deploy, the human's
/// own NOW app. `lsof` answers all of it in about a second.
///
/// It cannot ask the guest. NOW-68K knows perfectly well whether it is
/// mid-transfer in either direction — `xfer` renders exactly that — but
/// `xfer` is console-only by a recorded decision (`CommandParityTests ::
/// consoleOnly`) and NOW-68K serves no `putstat`, so there is no message
/// a host can send to ask. That gap is in the ledger rather than papered
/// over here: a guard that guessed would be the same class of mistake as
/// the run it exists to prevent.
enum MetalMachineGuard {

    /// One socket held by one process, as `lsof` reports it.
    struct Holder: Equatable, CustomStringConvertible {
        var pid: Int32
        var command: String
        /// `*:5252`, or `192.0.2.15:63194->192.0.2.180:21` for a
        /// conversation.
        var endpoint: String
        /// `LISTEN`, `ESTABLISHED`, or empty when lsof reported none.
        var state: String

        var description: String {
            let where_ = state.isEmpty ? endpoint : "\(endpoint) (\(state))"
            return "\(command) [pid \(pid)] \(where_)"
        }

        /// Whether this socket holds `port` on ITS OWN side — listening on
        /// it, or answering on it.
        ///
        /// THE GUEST'S OWN DIAL IS THE REASON THIS EXISTS. Under QEMU the
        /// emulator process connects out to the harness port, so
        /// `qemu-system-m68k … 127.0.0.1:50095->127.0.0.1:5252` is in
        /// every answer while a run is working perfectly, and counting it
        /// as contention would fail the second test in every suite. The
        /// port is on the FAR side of that socket: it is the guest
        /// reaching a listener, not a second listener.
        ///
        /// The colon anchors it — an ephemeral local port of 15252 does
        /// not end in ":5252".
        func holdsLocally(_ port: UInt16) -> Bool {
            let local = endpoint.components(separatedBy: "->").first ?? endpoint
            return local.hasSuffix(":\(port)")
        }

        /// Whether this socket is a CONVERSATION with `address` — the
        /// address on the far side of an arrow.
        ///
        /// `lsof -iTCP@<addr>` also returns sockets merely BOUND to that
        /// address, and a listener is not talking to anybody. It does not
        /// arise for the 180c, whose address this Mac cannot bind, but it
        /// does the moment somebody points `NOW_METAL_MACHINE` at
        /// 127.0.0.1 for a forwarded emulator — where the answer is a
        /// page of unrelated local daemons and the guard reads as noise.
        /// A guard whose failures are noise is a guard people route
        /// around.
        func talksTo(_ address: String) -> Bool {
            let halves = endpoint.components(separatedBy: "->")
            guard halves.count == 2 else { return false }
            return halves[1].hasPrefix("\(address):")
                || halves[1].hasPrefix("[\(address)]:")
        }
    }

    /// Thrown after the `XCTFail`, so the caller stops rather than going
    /// on to produce numbers nobody can attribute.
    struct Busy: Error, CustomDebugStringConvertible {
        var debugDescription: String { "the machine is busy — see above" }
    }

    /// The ports this project's harnesses dial on. `deploy-68k` alternates
    /// 5252/5253 across a handoff, the NOW app itself lives on 5250, and
    /// 5251 is the large-transfer suite's. A second harness on any of them
    /// is a second harness on the same PowerBook.
    static let conventionalPorts: [UInt16] = [5250, 5251, 5252, 5253]

    // MARK: - reading lsof

    /// `lsof` field mode (`-F`), not its table.
    ///
    /// The table's COMMAND column is truncated and can contain spaces
    /// ("Google Chrome H"), so splitting a row on whitespace puts the PID
    /// in a different place depending on which process holds the port —
    /// a parser that works until the day it matters. Field mode emits one
    /// tagged value per line and is meant to be read by a program.
    ///
    /// Pure, so the shapes below can be pinned without a socket.
    static func parse(_ text: String, excluding ownPID: Int32) -> [Holder] {
        var out: [Holder] = []
        var pid: Int32 = 0
        var command = ""
        var endpoint: String?
        var state = ""

        /// A file descriptor's fields arrive before the next `f`, so the
        /// one in hand is only complete when something else starts.
        func flush() {
            defer { endpoint = nil; state = "" }
            guard let endpoint, pid != ownPID else { return }
            out.append(Holder(pid: pid, command: command,
                              endpoint: endpoint, state: state))
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let body = String(line.dropFirst())
            switch line.first {
            case "p":
                flush()
                pid = Int32(body) ?? 0
                command = ""
            case "c":
                command = body
            case "f":
                flush()
            case "n":
                endpoint = body
            case "T":
                // `TST=LISTEN`; the other T records are queue depths.
                if body.hasPrefix("ST=") { state = String(body.dropFirst(3)) }
            default:
                break
            }
        }
        flush()
        return out
    }

    /// Runs lsof and returns its field output, or "" when nothing matched.
    ///
    /// A non-zero exit is lsof's normal answer for "no such socket", so it
    /// is not an error here. lsof being absent altogether would be, and
    /// that surfaces as an empty result — which is why the callers below
    /// prove the tool answered at all before trusting a quiet one.
    private static func lsof(_ selector: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-nP", "-FpcnT", selector]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static var ownPID: Int32 { ProcessInfo.processInfo.processIdentifier }

    /// Everything on this Mac holding `port` on its own side, this
    /// process excluded. `nil` means lsof could not be run, which is not
    /// the same as a free port and must not be read as one.
    ///
    /// The local-side filter is what keeps a guest dialling in from
    /// reading as a second harness — see `Holder.holdsLocally`.
    static func holders(ofPort port: UInt16) -> [Holder]? {
        lsof("-iTCP:\(port)").map {
            parse($0, excluding: ownPID).filter { $0.holdsLocally(port) }
        }
    }

    /// Every TCP conversation this Mac has open with `address`, whatever
    /// the port. An FTP deploy shows up here, and so does another
    /// session's harness. Sockets merely BOUND to the address are not
    /// conversations — see `Holder.talksTo`.
    static func conversations(with address: String) -> [Holder]? {
        lsof("-iTCP@\(address)").map {
            parse($0, excluding: ownPID).filter { $0.talksTo(address) }
        }
    }

    // MARK: - the guards

    /// Nothing else may hold the port this run is about to listen on.
    ///
    /// Failing here rather than at `start()` matters because
    /// `NWListener` is created without endpoint reuse, so a taken port
    /// leaves the listener `.failed` and every suite that does not check
    /// for it then waits out its full 120 s and reports "no guest dialled
    /// in" — a message that points at the Macintosh for a fault entirely
    /// on this side.
    static func requireThePortIsFree(_ port: UInt16,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) throws {
        guard let held = holders(ofPort: port) else {
            XCTFail("""
                /usr/sbin/lsof would not run, so nothing established that \
                port \(port) is free. Under NOW_METAL that is a failure and \
                not a shrug: the whole point of this guard is that a run \
                nobody can attribute is worse than no run.
                """, file: file, line: line)
            throw Busy()
        }
        guard held.isEmpty else {
            XCTFail("""
                Port \(port) is already held on this Mac, so this run would \
                either fail to bind or measure somebody else's transfer:
                  \(held.map(\.description).joined(separator: "\n  "))
                \(LanePorts.attribution(ofPort: port, mine: LanePorts.mine(),
                                        lanes: LanePorts.all()))
                Another session's harness, a `deploy-68k --test` still \
                running, or the NOW app itself (it lives on 5250). Give \
                this run a port nothing else is dialling with \
                NOW_METAL_PORT — `tools/lane-ports --env` exports one \
                derived for this lane — or wait for the other one; do not \
                race it. See docs/68k-metal-runbook.md.
                """, file: file, line: line)
            throw Busy()
        }
    }

    /// Nothing else on this Mac may be talking to the machine under test.
    ///
    /// `NOW_METAL_MACHINE` names it (the 180c is 192.0.2.180). When it is
    /// unset the address check cannot run — there is no way to know from
    /// here whether the guest that will dial in is the PowerBook or a
    /// local emulator — so this says so out loud rather than passing
    /// quietly, and falls back to the weaker evidence.
    ///
    /// The weaker evidence is the other conventional harness ports, and
    /// it is graded rather than absolute, because the strength of "a
    /// neighbouring port is held" varies enormously:
    ///
    /// * **Held and ESTABLISHED** — something on this Mac has a guest
    ///   right now. Against a named machine that is enough to stop: two
    ///   harnesses aimed at one PowerBook do not queue, they interleave.
    /// * **Held but only LISTENING** — an idle listener has nobody. The
    ///   NOW app sits on 5250 all day and is not using the 180c; failing
    ///   the run for it would teach people to route around this guard,
    ///   which costs more than the case it catches. Warned about.
    /// * Either, with no machine named — a warning, because two
    ///   emulators on one Mac are two different machines.
    static func requireTheMachineIsQuiet(harnessPort: UInt16,
                                         file: StaticString = #filePath,
                                         line: UInt = #line) throws {
        let machine = ProcessInfo.processInfo.environment["NOW_METAL_MACHINE"]
            .flatMap { $0.isEmpty ? nil : $0 }

        if let machine {
            guard let talking = conversations(with: machine) else {
                XCTFail("""
                    /usr/sbin/lsof would not run, so nothing established \
                    that \(machine) is free.
                    """, file: file, line: line)
                throw Busy()
            }
            guard talking.isEmpty else {
                XCTFail("""
                    Something on this Mac is already talking to \(machine):
                      \(talking.map(\.description).joined(separator: "\n  "))
                    An `ftp`/`python` conversation is a deploy in flight — \
                    that is the exact shape of the 2026-07-25 run whose 1 MB \
                    push stalled at 606208 bytes and whose every later rung \
                    read `0 of N`. An `xctest` one is another session's \
                    metal suite. Either way this run's numbers would mean \
                    nothing. Wait for it, or ask whoever is holding it.
                    """, file: file, line: line)
                throw Busy()
            }
        } else {
            print("=== machine-busy guard: NOW_METAL_MACHINE unset, so only "
                  + "the port checks ran. Set it to the guest's address "
                  + "(the 180c is 192.0.2.180) for the full check.")
        }

        let neighbours = conventionalPorts
            .filter { $0 != harnessPort }
            .compactMap { port -> (UInt16, [Holder])? in
                guard let held = holders(ofPort: port), !held.isEmpty else {
                    return nil
                }
                return (port, held)
            }
        guard !neighbours.isEmpty else { return }

        let report = neighbours.map { port, held in
            "  \(port): " + held.map(\.description).joined(separator: ", ")
        }.joined(separator: "\n")

        let anyoneHasAGuest = neighbours
            .contains { $0.1.contains { $0.state == "ESTABLISHED" } }

        guard let machine, anyoneHasAGuest else {
            print("""
                === machine-busy guard: something else is on this Mac's \
                other metal ports —
                \(report)
                Not a failure: \(machine == nil
                    ? "without NOW_METAL_MACHINE there is no telling whether "
                    + "it is driving the same machine as this run"
                    : "none of them has a guest connected, so they are idle "
                    + "listeners and not a second session"). If that is \
                wrong, these numbers are contended.
                """)
            return
        }
        XCTFail("""
            This run is against \(machine), and another harness on this Mac \
            has a guest connected on a conventional metal port:
            \(report)
            NOW-68K dials one host and the host serves one guest, so two \
            harnesses aimed at one PowerBook do not queue — they interleave, \
            and neither one's result can be attributed afterwards. Stop the \
            other run, or wait for it.
            """, file: file, line: line)
        throw Busy()
    }

    /// The listener actually came up. Cheap, and it converts the single
    /// most misleading failure this harness produces — a 120 s wait
    /// blamed on the Macintosh — into the bind error it always was.
    static func requireItIsListening(_ state: GuestListener.State,
                                     port: UInt16,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) throws {
        guard case .failed(let why) = state else { return }
        XCTFail("""
            The harness could not listen on port \(port): \(why). Nothing \
            could have dialled in, so anything this run reports would be \
            about this Mac and not about the guest.
            """, file: file, line: line)
        throw Busy()
    }

    // MARK: - leftovers from somebody else's ladder

    /// Whether a file name is one this project's transfers leave behind.
    ///
    /// Three families, all of them named by code rather than guessed at:
    /// the host's inbound staging (`.now-<uuid>.part`, `InboundFileSink`),
    /// the guests' own (`NOW incoming <hex>`, `n68_putfile.c` and
    /// `fileshare.c`), and the ladder rungs themselves (`N68 <size>` from
    /// the push ladder, `RT<size>` from the round trip).
    ///
    /// Pure and name-only. Whether a given leftover means anything is a
    /// question about its age, which is the caller's to ask.
    static func looksLikeTransferLeftover(_ name: String) -> Bool {
        if name.hasPrefix(".now-"), name.hasSuffix(".part") { return true }
        if name.hasPrefix("NOW incoming ") { return true }
        if name.hasPrefix("N68 ") { return true }
        if name.hasPrefix("RT"), name.count > 2,
           name.dropFirst(2).allSatisfy(\.isNumber) { return true }
        return false
    }

    /// Leftovers in `directory` touched within `within` seconds of `now`.
    ///
    /// AGE IS THE WHOLE SIGNAL. A `N68 4194304` from last week says
    /// somebody ran the ladder once; one modified ninety seconds ago says
    /// somebody is running it right now, and that is the finding. Reported
    /// rather than thrown, because this is evidence and not proof — it
    /// could equally be this session's own previous run, and stopping a
    /// suite over a file is a worse trade than making a human read one
    /// line.
    static func recentLeftovers(in directory: URL,
                                within: TimeInterval = 600,
                                now: Date = Date()) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: directory.path)) ?? []
        return names.filter { name in
            guard looksLikeTransferLeftover(name) else { return false }
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: directory.appendingPathComponent(name).path)
            guard let modified = attributes?[.modificationDate] as? Date else {
                return false
            }
            return now.timeIntervalSince(modified) < within
        }.sorted()
    }

    /// Prints `recentLeftovers` when there are any. Deliberately not a
    /// failure — see above.
    static func reportRecentLeftovers(in directory: URL) {
        let found = recentLeftovers(in: directory)
        guard !found.isEmpty else { return }
        print("""
            === machine-busy guard: \(directory.lastPathComponent) has \
            transfer leftovers touched in the last ten minutes —
              \(found.joined(separator: "\n  "))
            Either this session's own previous run, or another one still \
            mid-ladder. If it is not yours, the numbers below are contended.
            """)
    }

    // MARK: - the whole preflight

    /// What every 68K metal suite runs before it binds anything.
    static func preflight(port: UInt16,
                          file: StaticString = #filePath,
                          line: UInt = #line) throws {
        try requireThePortIsFree(port, file: file, line: line)
        try requireTheMachineIsQuiet(harnessPort: port, file: file, line: line)
    }
}
