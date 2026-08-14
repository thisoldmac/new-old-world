import XCTest
import Network
@testable import Host

/// The dossier model driven over the real wire: a scripted `FakeGuest`
/// answers `census.request` with `census.report` pages, and these check that
/// the model threads the cursor back, accumulates rows across pages, carries
/// each outcome/note faithfully, and sweeps every probe. The one path the
/// guest and host share (request out, report in) is exercised end to end,
/// codec and listener included - not a model talking to itself.
@MainActor
final class CensusModuleModelTests: XCTestCase {
    private var listener: GuestListener!
    private var model: CensusModuleModel!

    override func setUp() async throws {
        listener = GuestListener(identity: .init(version: "t", name: "Host"),
                                 timing: .init(idleTimeout: 60))
        listener.start(port: 0)
        try await waitUntil("listening") {
            if case .listening = self.listener.state { return true }
            return false
        }
        model = CensusModuleModel(listener: listener)
    }

    override func tearDown() async throws {
        listener.stop()
        listener = nil
        model = nil
    }

    // MARK: harness

    private func waitUntil(_ what: String, timeout: TimeInterval = 5,
                           _ cond: @escaping () -> Bool) async throws {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout {
                return XCTFail("timed out waiting for \(what)")
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func connectGuest() async throws -> FakeGuest {
        let guest = FakeGuest(port: listener.boundPort!)
        guest.start()
        try guest.send(.hello(Hello(contract: Contract.revision, side: "guest",
            version: "0.1", name: "PB 1400", os: "9.1", chunk: 8192)))
        try await waitUntil("host hello") { !guest.received.isEmpty }
        try await waitUntil("host connected") {
            if case .connected = self.listener.state { return true }
            return false
        }
        model.connection = .connected(named: "PB 1400")
        return guest
    }

    /// Answers each `census.request` with the next scripted report for that
    /// probe, echoing the request id. Records the cursor every request
    /// carried, so the test can prove the host threaded it back.
    @MainActor
    private final class Script {
        var pages: [String: [CensusReport]] = [:]
        private(set) var cursors: [String: [Int?]] = [:]
        private var served: [String: Int] = [:]

        func install(on guest: FakeGuest) {
            guest.onMessage = { [weak self, weak guest] msg in
                guard let self, let guest,
                      case .censusRequest(let req) = msg else { return }
                self.cursors[req.probe, default: []].append(req.cursor)
                let i = self.served[req.probe, default: 0]
                self.served[req.probe] = i + 1
                let list = self.pages[req.probe] ?? []
                var report = i < list.count ? list[i] : CensusReport(
                    id: 0, probe: req.probe, outcome: "absent", rows: [],
                    more: false, cursor: nil, total: nil, note: "unscripted")
                report.id = req.id
                try? guest.send(.censusReport(report))
            }
        }
    }

    private func report(_ probe: String, _ rows: [[String]],
                        outcome: String = "present", more: Bool = false,
                        cursor: Int? = nil, total: Int? = nil,
                        note: String? = nil) -> CensusReport {
        CensusReport(id: 0, probe: probe, outcome: outcome, rows: rows,
                     more: more, cursor: cursor, total: total, note: note)
    }

    private func rows(_ n: Int, _ tag: String) -> [[String]] {
        (0..<n).map { ["\(tag)\($0)", "$\($0)", "meaning \($0)"] }
    }

    // MARK: tests

    func testAMultiPageProbeAccumulatesAndThreadsTheCursor() async throws {
        let guest = try await connectGuest()
        let script = Script()
        script.pages["selectors"] = [
            report("selectors", rows(16, "s"), more: true, cursor: 16, total: 20),
            report("selectors", rows(4, "t"), more: false, total: 20),
        ]
        script.install(on: guest)

        model.run(probeID: "selectors")
        try await waitUntil("selectors done") {
            self.model.state(id: "selectors")?.isRunning == false
                && self.model.state(id: "selectors")?.hasRun == true
        }

        let state = try XCTUnwrap(model.state(id: "selectors"))
        XCTAssertEqual(state.outcome, "present")
        XCTAssertEqual(state.rows.count, 20, "both pages accumulated")
        XCTAssertEqual(state.total, 20)
        XCTAssertEqual(state.rows.first, ["s0", "$0", "meaning 0"])
        XCTAssertEqual(state.rows.last, ["t3", "$3", "meaning 3"])
        XCTAssertEqual(script.cursors["selectors"], [nil, 16],
            "page 1 asked from the start, page 2 from the report's cursor")
    }

    func testAbsentOutcomeAndNoteSurvive() async throws {
        let guest = try await connectGuest()
        let script = Script()
        script.pages["scsi"] = [
            report("scsi", [], outcome: "absent", note: "no SCSI bus on this Mac"),
        ]
        script.install(on: guest)

        model.run(probeID: "scsi")
        try await waitUntil("scsi done") {
            self.model.state(id: "scsi")?.hasRun == true
        }
        let state = try XCTUnwrap(model.state(id: "scsi"))
        XCTAssertEqual(state.outcome, "absent")
        XCTAssertEqual(state.rows.count, 0)
        XCTAssertEqual(state.note, "no SCSI bus on this Mac",
                       "the machine's own words reach the dossier")
    }

    func testRunAllSweepsEveryProbe() async throws {
        let guest = try await connectGuest()
        let script = Script()
        for probe in CensusProbes.all {
            script.pages[probe.id] = [report(probe.id, rows(1, probe.id))]
        }
        script.install(on: guest)

        model.runAll()
        try await waitUntil("sweep complete") {
            self.model.isSweeping == false
                && self.model.probes.allSatisfy { $0.hasRun }
        }
        XCTAssertTrue(model.probes.allSatisfy { $0.outcome == "present" },
                      "every probe ran and reported")
        XCTAssertEqual(script.cursors.count, CensusProbes.all.count,
                       "one probe requested for each probe in the registry")
    }

    func testRunWhileDisconnectedDoesNothing() async throws {
        // No guest, no connection.
        model.connection = .disconnected
        model.run(probeID: "ata")
        try await Task.sleep(nanoseconds: 50_000_000)
        let state = try XCTUnwrap(model.state(id: "ata"))
        XCTAssertNil(state.outcome, "a probe not run leaves no outcome")
        XCTAssertFalse(state.isRunning)
    }

    func testROMDumpUsesCommandThenOrdinaryFileStream() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-rom-dump-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        model = CensusModuleModel(listener: listener,
                                  romDumpDirectory: directory)
        let guest = try await connectGuest()
        let payload = Data([0x4E, 0xFA, 0x00, 0x74])
        guest.onMessage = { [weak guest] message in
            guard let guest else { return }
            switch message {
            case .commandRequest(let request) where request.name == "romdump":
                try? guest.send(.commandResult(.init(
                    id: request.id, ok: true,
                    output: ["romdump": [["Guest file",
                                           "New Old World ROM.bin"]]])))
            case .fileGet(let request):
                try? guest.send(.fileBegin(.init(
                    id: request.id, transfer: 91,
                    name: "New Old World ROM.bin", container: "data",
                    bytes: payload.count, dataBytes: payload.count,
                    rsrcBytes: 0, fileType: "BINA", creator: "NOWo",
                    modified: nil)))
                guest.sendRaw(try! FrameCodec.encode(
                    channel: .bulk, flags: [.end], transfer: 91,
                    payload: payload))
                try? guest.send(.fileEnd(.init(
                    id: request.id, transfer: 91, ok: true, sendMs: 1)))
            default:
                break
            }
        }

        model.dumpROM()
        try await waitUntil("ROM saved") {
            if case .saved = self.model.romDumpState { return true }
            return false
        }
        guard case .saved(let url) = model.romDumpState else {
            return XCTFail("ROM dump did not settle as saved")
        }
        XCTAssertEqual(try Data(contentsOf: url), payload)
        XCTAssertTrue(guest.received.contains {
            if case .fileGet(let get) = $0 {
                return get.path == "New Old World ROM.bin"
                    && get.container == "data"
            }
            return false
        }, "the ROM bytes use file.get rather than a second transfer family")
    }

    func testRerunReplacesRowsRatherThanAppending() async throws {
        let guest = try await connectGuest()
        let script = Script()
        script.pages["video"] = [
            report("video", rows(2, "a")),   // first run
            report("video", rows(3, "b")),   // the rerun
        ]
        script.install(on: guest)

        model.run(probeID: "video")
        try await waitUntil("first run") {
            self.model.state(id: "video")?.rows.count == 2
        }
        model.run(probeID: "video")
        try await waitUntil("rerun") {
            self.model.state(id: "video")?.rows.first == ["b0", "$0", "meaning 0"]
        }
        let state = try XCTUnwrap(model.state(id: "video"))
        XCTAssertEqual(state.rows.count, 3, "rerun replaced, did not append")
    }
}
