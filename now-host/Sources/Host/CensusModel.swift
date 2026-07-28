import Combine
import Foundation

/// One probe's state as the dossier shows it: the probe, its outcome once
/// run, and the rows accumulated across however many pages the guest sent.
struct CensusProbeState: Identifiable, Equatable {
    let probe: CensusProbe
    /// nil until the probe has run; then one of the contract's outcome words.
    var outcome: String?
    /// Every page's rows, concatenated in arrival order.
    var rows: [[String]] = []
    /// The guest's human sentence for a non-present outcome, when it sent one.
    var note: String?
    /// Rows the probe will yield in total, when the guest knows it.
    var total: Int?
    var isRunning = false

    var id: String { probe.id }
    var hasRun: Bool { outcome != nil }
}

/// Drives the Hardware dossier: asks the guest to run each probe and follows
/// the `more`/`cursor` pagination to accumulate a probe's rows, one page per
/// request. It never serves a census - the guest is the machine with
/// hardware worth asking about - it only requests and displays.
@MainActor
final class CensusModuleModel: ObservableObject {
    @Published var connection: GuestConnectionState = .disconnected {
        didSet {
            if case .connected = connection { return }
            // The link dropped: nothing is still running, and a sweep that
            // was in flight is over. Results already gathered stay on screen.
            isSweeping = false
            sweepQueue = []
            for i in probes.indices where probes[i].isRunning {
                probes[i].isRunning = false
            }
        }
    }
    @Published private(set) var probes: [CensusProbeState]
    @Published var selection: String?
    /// True while `runAll` is walking the probe list.
    @Published private(set) var isSweeping = false

    private let listener: GuestListener
    /// Per-probe run generation; a page from a superseded run is discarded,
    /// so a rerun (or a sweep restarting a probe) never interleaves rows.
    private var generation: [String: Int] = [:]
    private var sweepQueue: [String] = []

    init(listener: GuestListener) {
        self.listener = listener
        probes = CensusProbes.all.map { CensusProbeState(probe: $0) }
        selection = CensusProbes.all.first?.id
    }

    var isConnected: Bool {
        if case .connected = connection { return true }
        return false
    }

    func state(id: String) -> CensusProbeState? {
        probes.first { $0.id == id }
    }

    /// Run one probe from its first page, replacing whatever it held.
    func run(probeID: String) {
        guard isConnected,
              let idx = probes.firstIndex(where: { $0.id == probeID })
        else { return }
        let gen = (generation[probeID] ?? 0) + 1
        generation[probeID] = gen
        probes[idx].rows = []
        probes[idx].outcome = nil
        probes[idx].note = nil
        probes[idx].total = nil
        probes[idx].isRunning = true
        requestPage(probeID: probeID, cursor: nil, gen: gen)
    }

    /// Run every probe in rail order, sequentially - one probe at a time,
    /// each fully paged before the next - so the cooperatively-scheduled
    /// guest is never asked to serve a second probe mid-page.
    func runAll() {
        guard isConnected else { return }
        sweepQueue = CensusProbes.all.map(\.id)
        isSweeping = true
        advanceSweep()
    }

    private func advanceSweep() {
        guard isSweeping else { return }
        guard isConnected, !sweepQueue.isEmpty else {
            isSweeping = false
            sweepQueue = []
            return
        }
        run(probeID: sweepQueue.removeFirst())
    }

    private func requestPage(probeID: String, cursor: Int?, gen: Int) {
        listener.requestCensus(probe: probeID, cursor: cursor) {
            [weak self] report in
            guard let self else { return }
            // A newer run for this probe supersedes this page.
            guard self.generation[probeID] == gen,
                  let idx = self.probes.firstIndex(where: { $0.id == probeID })
            else { return }

            self.probes[idx].rows.append(contentsOf: report.rows)
            self.probes[idx].outcome = report.outcome
            if let note = report.note { self.probes[idx].note = note }
            if let total = report.total { self.probes[idx].total = total }

            if report.more, let next = report.cursor {
                self.requestPage(probeID: probeID, cursor: next, gen: gen)
            } else {
                self.probes[idx].isRunning = false
                self.advanceSweep()
            }
        }
    }
}
