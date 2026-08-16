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

enum ROMDumpState: Equatable {
    case idle
    case writing
    case transferring
    case saved(URL)
    case failed(String)

    var isRunning: Bool {
        self == .writing || self == .transferring
    }
}

/// Drives the Hardware dossier: asks the guest to run each probe and follows
/// the `more`/`cursor` pagination to accumulate a probe's rows, one page per
/// request. It never serves a census - the guest is the machine with
/// hardware worth asking about - it only requests and displays.
@MainActor
final class CensusModuleModel: ObservableObject, GuestScopedModel {
    /// One machine's dossier, parked while another is driven.
    ///
    /// Cached rather than discarded because a hardware census is the most
    /// nearly PERMANENT thing either guest can tell us: a Mac's CPU, RAM,
    /// slots and monitors do not change between two glances at the other
    /// machine, and on a 68K guest each probe is slow enough that a person
    /// runs the sweep once and reads it for the rest of the session. It
    /// survives a disconnect for the same reason it survives a switch, and
    /// that was already true before there were two guests.
    struct Snapshot {
        var probes: [CensusProbeState]
        var selection: String?
    }

    private let cache = GuestStateCache<Snapshot>()

    @Published var connection: GuestConnectionState = .disconnected {
        didSet { connectionChanged(from: oldValue) }
    }

    private func connectionChanged(from old: GuestConnectionState) {
        guard connection != old else { return }
        if case .switched(let restored) = cache.focus(connection.key,
                                                      parking: snapshot()) {
            // A sweep in flight belongs to the machine we left; the
            // listener has already failed whatever request was outstanding.
            isSweeping = false
            sweepQueue = []
            generation = [:]
            let fresh = restored
                ?? Snapshot(
                    probes: CensusProbes.all.map { CensusProbeState(probe: $0) },
                    selection: CensusProbes.all.first?.id)
            probes = fresh.probes.map { state in
                var state = state
                state.isRunning = false
                return state
            }
            selection = fresh.selection
            return
        }
        if case .connected = connection { return }
        // The link dropped: nothing is still running, and a sweep that
        // was in flight is over. Results already gathered stay on screen.
        isSweeping = false
        sweepQueue = []
        for i in probes.indices where probes[i].isRunning {
            probes[i].isRunning = false
        }
    }

    private func snapshot() -> Snapshot {
        Snapshot(probes: probes, selection: selection)
    }
    @Published private(set) var probes: [CensusProbeState]
    @Published var selection: String?
    /// True while `runAll` is walking the probe list.
    @Published private(set) var isSweeping = false
    @Published private(set) var romDumpState: ROMDumpState = .idle
    /// Bytes in over bytes promised, while the ROM transfer is in flight.
    /// `.writing` (the guest's own File Manager read) has no wire signal
    /// and stays represented by an indeterminate spinner in the view.
    @Published private(set) var romDumpProgress: GuestListener.CaptureProgress?
    /// The folder the save panel opens to next time — the panel always
    /// asks for a name and place, this only saves the person from having
    /// to navigate back to the same folder on the following dump.
    @Published var romDumpDirectory: URL {
        didSet { defaults.set(romDumpDirectory.path, forKey: Keys.romDumpDirectory) }
    }

    private let listener: GuestListener
    private let defaults: UserDefaults
    private var busWatch: HostEventSubscription?
    /// Per-probe run generation; a page from a superseded run is discarded,
    /// so a rerun (or a sweep restarting a probe) never interleaves rows.
    private var generation: [String: Int] = [:]
    private var sweepQueue: [String] = []

    private enum Keys {
        static let romDumpDirectory = "census.romDumpDirectory"
    }

    init(listener: GuestListener, defaults: UserDefaults = ProductIdentity.defaults,
         romDumpDirectory: URL? = nil) {
        self.listener = listener
        self.defaults = defaults
        let stored = defaults.string(forKey: Keys.romDumpDirectory)
        self.romDumpDirectory = romDumpDirectory
            ?? stored.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .downloadsDirectory,
                                        in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        probes = CensusProbes.all.map { CensusProbeState(probe: $0) }
        selection = CensusProbes.all.first?.id
        busWatch = listener.events.subscribe { [weak self] event in
            guard let self, self.romDumpState == .transferring else { return }
            switch event {
            case .transferProgressed(_, let received, let expected):
                self.romDumpProgress = .init(received: received, expected: expected)
            case .transferEnded:
                self.romDumpProgress = nil
            default:
                break
            }
        }
    }

    /// Suggests where the next dump lands: the last-used folder (or
    /// Downloads, the first time) and the auto-incrementing name the guest
    /// itself writes under, so the panel opens with a sane default rather
    /// than empty.
    var suggestedROMDumpURL: URL {
        uniqueURL(startingFrom:
            romDumpDirectory.appendingPathComponent("New Old World ROM.bin"))
    }

    /// Creates the image on the guest first, then uses the ordinary reverse
    /// file stream to land it at `destination`. The ROM command owns only
    /// the classic File Manager read; transfer, progress and integrity keep
    /// the same contract as every other guest download. `destination` is
    /// whatever the person chose in the save panel; a name already taken by
    /// the time the bytes actually land (a second dump started in the
    /// meantime, say) still gets the auto-incrementing treatment rather
    /// than silently overwriting.
    func dumpROM(to destination: URL) {
        guard isConnected, !romDumpState.isRunning else { return }
        romDumpDirectory = destination.deletingLastPathComponent()
        romDumpState = .writing
        listener.runScheduledCommand(
            "romdump", typed: nil, purpose: .command("romdump"),
            workClass: .humanInteractive, watchdogSeconds: 60
        ) {
            [weak self] result in
            guard let self else { return }
            guard result.ok else {
                self.romDumpState = .failed(
                    result.error?.message ?? "The Mac could not create its ROM dump.")
                return
            }
            self.romDumpState = .transferring
            self.listener.getFile(
                path: "New Old World ROM.bin", container: "data",
                stagingDirectory: self.romDumpDirectory) { [weak self] delivery in
                    guard let self else { return }
                    switch delivery {
                    case .failure(let failure):
                        self.romDumpState = .failed(failure.message)
                    case .success(let file):
                        do {
                            let finalURL = self.uniqueURL(startingFrom: destination)
                            try FileConverter.materialize(
                                name: file.name, container: file.container,
                                fileType: file.fileType, staged: file.staged,
                                to: finalURL)
                            self.romDumpState = .saved(finalURL)
                        } catch {
                            self.romDumpState = .failed(
                                "Could not save the ROM dump: "
                                + error.localizedDescription)
                        }
                    }
                }
        }
    }

    /// `candidate`, or the first `name (2).ext`, `name (3).ext`, … not
    /// already on disk — the same collision-avoidance the auto-named path
    /// always had, now seeded from wherever the person chose to save.
    private func uniqueURL(startingFrom candidate: URL) -> URL {
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            return candidate
        }
        let ext = candidate.pathExtension
        let base = candidate.deletingPathExtension().lastPathComponent
        let folder = candidate.deletingLastPathComponent()
        var suffix = 2
        var next: URL
        repeat {
            next = folder.appendingPathComponent("\(base) (\(suffix))")
                .appendingPathExtension(ext)
            suffix += 1
        } while FileManager.default.fileExists(atPath: next.path)
        return next
    }

    /// Creates the image on the guest first, then uses the ordinary reverse
    /// file stream to land it in Downloads. The ROM command owns only the
    /// classic File Manager read; transfer, progress and integrity keep the
    /// same contract as every other guest download.
    func dumpROM() {
        guard isConnected, !romDumpState.isRunning else { return }
        romDumpState = .writing
        listener.runScheduledCommand(
            "romdump", typed: nil, purpose: .command("romdump"),
            workClass: .humanInteractive, watchdogSeconds: 60
        ) {
            [weak self] result in
            guard let self else { return }
            guard result.ok else {
                self.romDumpState = .failed(
                    result.error?.message ?? "The Mac could not create its ROM dump.")
                return
            }
            self.romDumpState = .transferring
            self.listener.getFile(
                path: "New Old World ROM.bin", container: "data",
                stagingDirectory: self.romDumpDirectory) { [weak self] delivery in
                    guard let self else { return }
                    switch delivery {
                    case .failure(let failure):
                        self.romDumpState = .failed(failure.message)
                    case .success(let file):
                        do {
                            let destination = self.uniqueROMDumpURL()
                            try FileConverter.materialize(
                                name: file.name, container: file.container,
                                fileType: file.fileType, staged: file.staged,
                                to: destination)
                            self.romDumpState = .saved(destination)
                        } catch {
                            self.romDumpState = .failed(
                                "Could not save the ROM dump: "
                                + error.localizedDescription)
                        }
                    }
                }
        }
    }

    private func uniqueROMDumpURL() -> URL {
        let base = "New Old World ROM"
        var candidate = romDumpDirectory.appendingPathComponent(base + ".bin")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = romDumpDirectory.appendingPathComponent(
                "\(base) (\(suffix)).bin")
            suffix += 1
        }
        return candidate
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
