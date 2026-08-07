import AppKit
import Combine
import Foundation
import CoreGraphics
import NOWAgentIntegration

enum CaptureDepth: Int, CaseIterable, Identifiable, Sendable {
    case mono = 1
    case gray4 = 2
    case indexed16 = 4
    case indexed = 8
    case thousands = 16
    case millions = 32

    var id: Int { rawValue }
    var title: String { "\(rawValue)-bit" }
}

enum GuestConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    /// Connected, and to WHICH machine. The key is here rather than
    /// alongside because a model that has to consult two published
    /// properties to know whose rows it is holding will one day read them
    /// a frame apart — and the whole failure this carries exists to
    /// prevent is showing one Mac's state under another's name.
    case connected(name: String, key: GuestKey)

    /// Tests and previews only. A key CANNOT be derived from a name any
    /// more — identity is per connection, and two Macs may share a name —
    /// so the live path takes the listener's key and this mints a
    /// synthetic one that is merely distinct per label.
    static func connected(named name: String) -> GuestConnectionState {
        .connected(name: name, key: .synthetic(name))
    }

    var canCapture: Bool {
        if case .connected = self { return true }
        return false
    }

    /// Which machine, when there is one. Nil is "nobody is being driven",
    /// never "some machine we cannot name".
    var key: GuestKey? {
        if case .connected(_, let key) = self { return key }
        return nil
    }

    /// What to call the machine on the other end, for anything a human
    /// reads. It is the name that machine sent in its hello; before a
    /// connection there is no name to use, so it degrades to a plain
    /// description. Never "the guest" — guest and host are words for
    /// the code, not for the person using it. And never "the Mac":
    /// both of them are Macs.
    var peerLabel: String {
        if case .connected(let name, _) = self, !name.isEmpty { return name }
        return "the classic Mac"
    }
}

/// Rolling numbers for the live stream — the tuning surface: watch fps
/// respond as depth, chunk, pacing, and compression change.
struct StreamStats: Equatable {
    var frames: Int
    var fps: Double
    var kbPerSecond: Double
    var lastFrameMs: Int
}

/// One received screen capture, with the numbers behind it.
struct ScreenshotRecord: Identifiable, Equatable {
    let id = UUID()
    let capturedAt: Date
    let image: CGImage
    let format: CaptureFormat
    let transferMs: Int
    let wireBytes: Int
    /// Which machine this is a picture of. Carried on the record rather
    /// than inferred from the list it is in, because a push arrives from
    /// whichever guest felt like sending one.
    var guest: String = Session.unnamedGuest

    var width: Int { format.width }
    var height: Int { format.height }

    /// Raw pixel volume before compression, for the ratio readout.
    var rawBytes: Int { format.rowBytes * format.height }

    var compressionRatio: Double {
        wireBytes > 0 ? Double(rawBytes) / Double(wireBytes) : 0
    }

    static func == (lhs: ScreenshotRecord, rhs: ScreenshotRecord) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
final class ScreenshotModuleModel: ObservableObject, GuestScopedModel {
    /// One machine's captures, parked while another is driven.
    ///
    /// The history is CACHED, and the reasoning here ran the other way to
    /// begin with: a screenshot cache looks like the cheapest thing in the
    /// app to throw away. It is not, because it is the only cache here that
    /// cannot be refilled — a capture is a picture of a moment on a machine
    /// that has moved on, and auto-save is off by default, so discarding it
    /// on a switch would destroy something. Cheap to re-fetch is the test,
    /// and this is the one that fails it.
    ///
    /// The STREAM is the opposite and is discarded: the frame, the stats
    /// and the recorder all belong to a bracket that only the driven guest
    /// can hold, and the listener has already closed it by the time this
    /// runs.
    struct Snapshot {
        var history: [ScreenshotRecord] = []
    }

    private let cache = GuestStateCache<Snapshot>()

    @Published var connection: GuestConnectionState = .disconnected {
        didSet { connectionChanged(from: oldValue) }
    }
    @Published var selectedDepth: CaptureDepth = .indexed
    /// The host's tuning knobs, sent with every request and stream so the
    /// initiator's settings win; the guest's panel remains the fallback
    /// for guest-initiated work. All persisted.
    @Published var chunkKB: Int {
        didSet { defaults.set(chunkKB, forKey: Keys.chunkKB) }
    }
    @Published var paceMs: Int {
        didSet { defaults.set(paceMs, forKey: Keys.paceMs) }
    }
    @Published var compress: Bool {
        didSet { defaults.set(compress, forKey: Keys.compress) }
    }
    @Published var predictive: Bool {
        didSet { defaults.set(predictive, forKey: Keys.predictive) }
    }
    @Published var interlace: Bool {
        didSet { defaults.set(interlace, forKey: Keys.interlace) }
    }
    /// The stream's frame-rate ceiling, sent as `minIntervalMs`. Capture on
    /// this hardware tops out near 7 fps, so this is a guard rail rather
    /// than a target: it exists because frames that carry no pixels (a
    /// static screen under predictive capture) cost the guest nothing to
    /// produce, and an unpaced loop over them floods the wire.
    @Published var maxFps: Int {
        didSet { defaults.set(maxFps, forKey: Keys.maxFps) }
    }

    /// What `stream.start` carries: the minimum interval between frames.
    var minIntervalMs: Int { maxFps > 0 ? 1000 / maxFps : 0 }

    /// Whether the tuning row is disclosed; plumbing most sessions never
    /// touch stays folded away.
    @Published var showSettings: Bool {
        didSet { defaults.set(showSettings, forKey: Keys.showSettings) }
    }

    var tuning: GuestListener.CaptureTuning {
        .init(chunkKb: chunkKB, paceMs: paceMs, pack: compress,
              predictive: predictive, interlace: interlace)
    }
    @Published private(set) var history: [ScreenshotRecord] = []
    @Published private(set) var isCapturing = false
    @Published private(set) var lastError: String?
    /// Bytes in over bytes promised, while a transfer is in flight.
    @Published private(set) var progress: GuestListener.CaptureProgress?

    /// Live-stream state: the latest frame replaces the preview while the
    /// bracket is open; frames never touch history, disk, or clipboard.
    @Published private(set) var isStreaming = false
    @Published private(set) var liveFrame: ScreenshotRecord?
    @Published private(set) var streamStats: StreamStats?

    /// The finished movie of the last stream, encoded live as it played
    /// and offered once the bracket closes. Discarded when a new stream
    /// starts, or explicitly.
    @Published private(set) var recording: StreamRecorder.Recording?

    /// The landing pad: guest-initiated screenshots always save here;
    /// host-initiated ones only when autoSave says so (they already have a
    /// home — the panel).
    @Published var autoSave: Bool {
        didSet { defaults.set(autoSave, forKey: Keys.autoSave) }
    }
    /// Put each capture on the pasteboard as it lands, so a screenshot can
    /// go straight into a message without a round trip through the disk.
    @Published var autoCopy: Bool {
        didSet { defaults.set(autoCopy, forKey: Keys.autoCopy) }
    }
    @Published var saveDirectory: URL {
        didSet { defaults.set(saveDirectory.path, forKey: Keys.saveDirectory) }
    }

    var canCapture: Bool {
        connection.canCapture && !isCapturing && !isStreaming
    }

    /// **Whether the machine on the wire can be streamed from at all**, and
    /// the sentence to show when it cannot.
    ///
    /// Derived, never asserted: the requirements are
    /// `StreamScreenProjection`'s own — `stream.start`, `stream.stop`,
    /// `stream.refresh` as a conjunction, since a bracket you can open and
    /// cannot close is not a capability — and the answer is whatever the
    /// connected Mac has said about them. Nothing here asks which guest it is.
    /// A machine nobody has asked leaves this `unsettled`, which is ENABLED:
    /// the click is what settles it, and the refusal that comes back is what
    /// turns the button dark, in that machine's own words.
    var streamGate: GuestCapabilityGate.Decision {
        GuestCapabilityGate.decide(
            StreamScreenProjection.self,
            in: capabilities.evidence(for: connection, listener: listener))
    }

    /// Stop is always reachable while a bracket is open — the person always
    /// wins, whoever opened it — so the gate only governs OPENING one.
    var canStream: Bool {
        connection.canCapture && !isCapturing
            && (isStreaming || streamGate.isEnabled)
    }

    /// The reason to show beside a Start Streaming button that will not
    /// respond. Nil while the control works, and nil for the merely unproven
    /// case: an enabled control does not get to nag, and its sentence lives
    /// in the tooltip (`streamGateTooltip`).
    var streamUnavailableNote: String? {
        guard !isStreaming, streamGate.deservesAVisibleReason else {
            return nil
        }
        return streamGate.explanation
    }

    /// The hover text for the stream button, in every state that has
    /// something to say.
    var streamGateTooltip: String? {
        isStreaming ? nil : streamGate.explanation
    }

    /// **Who opened the stream that is running**, nil when none is or when
    /// this person opened it themselves.
    ///
    /// The one thing the page could not say. The bracket is host-wide, so an
    /// agent opening one turns this page's live view on and greys out its
    /// Capture button — and until this existed, a person who had clicked
    /// nothing saw a screen they did not ask for and a control that had
    /// stopped working, which is what a broken app looks like.
    ///
    /// **The person always wins, and the honest way to give them that is one
    /// explicit click rather than a hidden side effect.** Stop Streaming is
    /// already enabled while any stream runs, whoever opened it, and it ends
    /// an agent's exactly as it ends their own. What was missing was knowing
    /// there was something to stop. Making Capture *itself* end an agent's
    /// stream was the alternative and is rejected: a button that says Capture
    /// and also silently ends somebody else's work is a button that does two
    /// things, and the person cannot see the second one in its label.
    @Published private(set) var streamOwner: AgentIntegrationStreamOrigin?

    var streamOwnerNote: String? {
        switch streamOwner {
        case .agent:
            return "An agent is streaming this Mac's screen. Capture is "
                + "unavailable while it runs — the machine has one transfer "
                + "lane. Stop Streaming ends it."
        case .guest:
            return "\(connection.peerLabel) asked for this stream. Capture "
                + "is unavailable while it runs; Stop Streaming ends it."
        case .person, nil:
            return nil
        }
    }

    var streamButtonTitle: String {
        isStreaming ? "Stop Streaming" : "Start Streaming"
    }

    /// The Screenshots page's one stream affordance.
    ///
    /// A method rather than the two calls spelled out at the button, so the
    /// projection row's app-UI proof can name a symbol this file uses exactly
    /// once — `HostFaceReach.reached` records the failure where a row names a
    /// symbol its view contains three times and deleting the affordance
    /// changes nothing.
    func toggleStream() {
        isStreaming ? stopStream() : startStream()
    }
    var latest: ScreenshotRecord? { history.first }

    private enum Keys {
        static let showSettings = "screenshots.showSettings"
        static let chunkKB = "screenshots.chunkKB"
        static let paceMs = "screenshots.paceMs"
        static let compress = "screenshots.compress"
        static let predictive = "screenshots.predictive"
        static let interlace = "screenshots.interlace"
        static let maxFps = "screenshots.maxFps"
        static let autoSave = "screenshots.autoSave"
        static let autoCopy = "screenshots.autoCopy"
        static let saveDirectory = "screenshots.saveDirectory"
    }

    /// Called when a guest-initiated screenshot lands; the app wires the
    /// system-notification toaster here. Kept as a closure so tests and
    /// headless runs stay silent.
    var announce: ((_ guest: String, _ format: CaptureFormat,
                    _ fileURL: URL?) -> Void)?

    private let listener: GuestListener
    /// What the machines on the wire have said they can do. Shared, because
    /// every page that gates a control wants the same answers about the same
    /// Macs; injectable, so a test gets its own.
    let capabilities: GuestCapabilityRecord
    private let defaults: UserDefaults
    /// Everything the wire tells this page, on one subscription.
    ///
    /// **Deliberately NOT guest-scoped.** Four of the five things it hears
    /// are about the Mac being driven, but a pushed capture is not: a
    /// background Mac may take a screenshot unasked, and this page files it
    /// under the machine that sent it (`receivePushed`) rather than showing
    /// it as the focused Mac's. Scoping the subscription would drop those on
    /// the floor, which is the bug MultiGuestFocusTests names.
    private var busWatch: HostEventSubscription?
    private var capabilityWatch: AnyCancellable?
    /// The id of a bracket this page opened and has not seen a frame from.
    /// It is what lets a guest's `error` be attributed to `stream.start`
    /// rather than to nothing.
    private var unansweredStreamStart: Int?
    private var frameClock: [Date] = []
    private var recorder: StreamRecorder?
    private static let historyLimit = 20
    private static let fpsWindow = 10
    static let fpsChoices = [4, 7, 10, 15, 30]
    static let defaultMaxFps = 15

    init(listener: GuestListener,
         defaults: UserDefaults = .standard,
         capabilities: GuestCapabilityRecord = .shared) {
        self.listener = listener
        self.capabilities = capabilities
        self.defaults = defaults
        self.autoSave = defaults.bool(forKey: Keys.autoSave)
        self.autoCopy = defaults.bool(forKey: Keys.autoCopy)
        let chunk = defaults.integer(forKey: Keys.chunkKB)
        self.chunkKB = (1...32).contains(chunk) ? chunk : 32
        let pace = defaults.integer(forKey: Keys.paceMs)
        self.paceMs = (0...100).contains(pace) ? pace : 0
        self.compress = defaults.object(forKey: Keys.compress) as? Bool ?? true
        self.predictive = defaults.bool(forKey: Keys.predictive)
        self.interlace = defaults.bool(forKey: Keys.interlace)
        let fps = defaults.integer(forKey: Keys.maxFps)
        self.maxFps = ScreenshotModuleModel.fpsChoices.contains(fps)
            ? fps : ScreenshotModuleModel.defaultMaxFps
        self.showSettings = defaults.bool(forKey: Keys.showSettings)
        let stored = defaults.string(forKey: Keys.saveDirectory)
        self.saveDirectory = stored.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .picturesDirectory,
                                        in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        busWatch = listener.events.subscribe { [weak self] event in
            guard let self else { return }
            switch event {
            case .transferProgressed(_, let received, let expected):
                self.progress = .init(received: received, expected: expected)
            case .transferEnded:
                self.progress = nil
            case .captureArrived(_, let delivery):
                self.receivePushed(delivery)
            case .streamFrame(_, let delivery):
                self.receiveStreamFrame(delivery)
            case .streamStateChanged(_, let id):
                self.streamStateChanged(id)
            /* The one place a stream refusal can be heard. `stream.start`
               takes an id no pending map holds, so a guest that does not
               implement the bracket answers `error` and nothing else on this
               side is waiting on it. Without this the button would offer the
               same dead click every time, forever. */
            case .guestReportedError(_, let problem):
                self.guestReportedError(problem)
            default:
                break
            }
        }
        // The gate is computed, so a recorded refusal has to nudge the view.
        capabilityWatch = capabilities.$revision
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    private func connectionChanged(from old: GuestConnectionState) {
        guard connection != old,
              case .switched(let restored) =
                cache.focus(connection.key, parking: Snapshot(history: history))
        else { return }
        history = restored?.history ?? []
        liveFrame = nil
        streamStats = nil
        progress = nil
        isCapturing = false
        lastError = nil
        discardRecording()
    }

    /// A machine leaving the roster takes its capability answers with it —
    /// they were claims about that Mac, and the next one to dial in under the
    /// same name may be a different build.
    func guestLeft(_ key: GuestKey) {
        capabilities.forget(key)
    }

    func startStream() {
        guard canStream else { return }
        lastError = nil
        unansweredStreamStart = listener.startStream(
            depth: selectedDepth.rawValue, minIntervalMs: minIntervalMs,
            tuning: tuning, origin: .person)
    }

    /// A guest error, read for the one thing this page can attribute: the
    /// bracket it just asked for.
    ///
    /// **A refusal by name is a capability answer and is written down.**
    /// Anything else — a busy lane, a Toolbox failure, silence — is not:
    /// `GuestCapabilityRecord` would happily store it and the gate would
    /// still leave the control enabled, but a machine that was merely busy
    /// must not be recorded as one that cannot, so the filter is here too.
    private func guestReportedError(_ problem: ErrorMessage) {
        guard let id = unansweredStreamStart, problem.id == id else { return }
        unansweredStreamStart = nil
        guard AgentIntegrationCapabilityNames.isRefusal(problem.code) else {
            lastError = problem.message
            return
        }
        capabilities.noteRefusal(
            AgentIntegrationCapabilityNames.streamStart,
            by: connection.key, code: problem.code, message: problem.message)
        lastError = "\(connection.peerLabel) does not serve live streaming: "
            + problem.message
        /* Closing the bracket is NOT this page's job and no longer happens
           here. It used to: the refusal reached `lastGuestError` and nothing
           else, so the page asked for a stop the same guest would also refuse
           and let the listener's five-second fallback do the clearing —
           a wedge cleared late, by a timer, under a reason ("no answer to
           stop") that described neither what happened nor what the machine
           said. The listener now recognises its own bracket id and has closed
           it before this line runs, with the guest's own reason, for every
           opener rather than only for the one page that could correlate. */
    }

    func stopStream() {
        listener.stopStream()
    }

    /// Manual keyframe: the next frame arrives whole.
    func refreshStream() {
        listener.refreshStream()
    }

    private func streamStateChanged(_ id: Int?) {
        let streaming = id != nil
        /* Read on every change rather than only on a transition: the guard
           below returns early when the flag has not moved, and the owner is
           the field that must be right the first time the page draws. */
        streamOwner = streaming ? listener.streamOrigin : nil
        guard streaming != isStreaming else { return }
        isStreaming = streaming
        /* A bracket the guest itself closed by answering `stream.stopped` is
           that guest serving stream.stop — the listener's own self-heal sets
           a different reason, and recording THAT as service would be writing
           down a silence as an answer. */
        if !streaming, let reason = listener.streamEndReason,
           reason != AgentIntegrationStreamFailure.unacknowledgedStop {
            capabilities.noteServed(
                AgentIntegrationCapabilityNames.streamStop,
                by: connection.key)
        }
        if streaming {
            frameClock = []
            streamStats = nil
            liveFrame = nil
            discardRecording()
            recorder = StreamRecorder()
        } else {
            if let reason = listener.streamEndReason {
                lastError = "Stream ended: \(reason)"
            }
            let finishing = recorder
            recorder = nil
            finishing?.finish { [weak self] recording in
                self?.recording = recording
            }
        }
    }

    /// Moves the finished movie to `directory` under a stamped name.
    /// Returns nil on success, else a human-readable reason.
    @discardableResult
    func saveRecording(to directory: URL) -> String? {
        guard let recording else { return "No recording to save" }
        let stamp = Self.stampFormatter.string(from: Date())
        var url = directory.appendingPathComponent(
            "Screen Recording \(stamp).mov")
        var bump = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent(
                "Screen Recording \(stamp) (\(bump)).mov")
            bump += 1
        }
        do {
            try FileManager.default.moveItem(at: recording.url, to: url)
            self.recording = nil
            return nil
        } catch {
            return "Could not save the recording: "
                + error.localizedDescription
        }
    }

    /// The file was moved by the caller (save panel); just stop offering.
    func discardRecordingReference() {
        recording = nil
    }

    func discardRecording() {
        if let recording {
            try? FileManager.default.removeItem(at: recording.url)
            self.recording = nil
        }
    }

    private func receiveStreamFrame(_ delivery: GuestListener.CaptureDelivery) {
        /* A frame is the machine serving stream.start, which is a better
           answer than any probe could have bought: the bracket is open and
           pixels are crossing. */
        if unansweredStreamStart != nil {
            unansweredStreamStart = nil
            capabilities.noteServed(
                AgentIntegrationCapabilityNames.streamStart,
                by: connection.key)
        }
        let record = ScreenshotRecord(
            capturedAt: Date(), image: delivery.image,
            format: delivery.format, transferMs: delivery.transferMs,
            wireBytes: delivery.wireBytes, guest: delivery.guestName)
        liveFrame = record
        recorder?.append(delivery.image, at: record.capturedAt)
        frameClock.append(record.capturedAt)
        if frameClock.count > Self.fpsWindow {
            frameClock.removeFirst(frameClock.count - Self.fpsWindow)
        }
        var stats = streamStats
            ?? StreamStats(frames: 0, fps: 0, kbPerSecond: 0, lastFrameMs: 0)
        stats.frames += 1
        stats.lastFrameMs = delivery.transferMs
        if frameClock.count >= 2,
           let first = frameClock.first, let last = frameClock.last {
            let span = last.timeIntervalSince(first)
            if span > 0 {
                stats.fps = Double(frameClock.count - 1) / span
            }
        }
        if delivery.transferMs > 0 {
            stats.kbPerSecond = Double(delivery.wireBytes) / 1024.0
                / (Double(delivery.transferMs) / 1000.0)
        }
        streamStats = stats
    }

    /// A guest-initiated screenshot: same record as a requested one, but it
    /// always writes to the landing pad — unlike a panel capture it has no
    /// other home — and it announces itself.
    ///
    /// It files under the machine that SENT it, which is not necessarily
    /// the one being driven. A push is the one capture path that arrives
    /// unasked, so a Mac nobody is looking at can produce one at any
    /// moment; attributing it to whoever was active — which is what this
    /// did, by reading `connection` for a name — put one machine's screen
    /// in another machine's list and told the notification the wrong Mac's
    /// name. The picture still lands on disk and still announces itself
    /// either way: a push nobody sees is worse than one filed away.
    func receivePushed(_ delivery: GuestListener.CaptureDelivery) {
        let record = ScreenshotRecord(
            capturedAt: Date(), image: delivery.image,
            format: delivery.format, transferMs: delivery.transferMs,
            wireBytes: delivery.wireBytes, guest: delivery.guestName)
        let fromBackground = delivery.guestKey.map { key in
            cache.updateParked(key, startingFrom: Snapshot()) { parked in
                parked.history.insert(record, at: 0)
                if parked.history.count > Self.historyLimit {
                    parked.history.removeLast(
                        parked.history.count - Self.historyLimit)
                }
            }
        } ?? false
        if !fromBackground {
            receive(record)
            if autoCopy {
                // The clipboard is a place a person is about to PASTE from,
                // so only the machine they are looking at may take it.
                copyToPasteboard(record)
            }
        }
        var savedTo: URL?
        if let failure = write(record, to: saveDirectory, savedTo: &savedTo) {
            // A background machine's failure is still this app's failure to
            // report; it is shown wherever the human is.
            lastError = failure
        }
        announce?(record.guest, record.format, savedTo)
    }

    func capture() {
        capture(forcingClipboard: false, completion: nil)
    }

    /// The menu command's path. Copying is the whole point of "Screenshot
    /// Guest" — there is no panel to land in — so the clipboard happens
    /// whether or not auto-copy is on. Auto-save is still merely honoured:
    /// someone who asked for every capture to be archived meant every
    /// capture, and someone who didn't should not start collecting files
    /// because they used a different button.
    func captureToClipboard(completion: @escaping (QuickCaptureOutcome) -> Void) {
        capture(forcingClipboard: true, completion: completion)
    }

    private func capture(forcingClipboard: Bool,
                         completion: ((QuickCaptureOutcome) -> Void)?) {
        guard canCapture else {
            completion?(.failed("The connection is busy"))
            return
        }
        isCapturing = true
        lastError = nil
        listener.requestCapture(depth: selectedDepth.rawValue,
                                tuning: tuning) { [weak self] in
            self?.receiveDelivery($0, forcingClipboard: forcingClipboard,
                                  completion: completion)
        }
    }

    /// "Screenshot App" from the Processes page: the guest fronts the
    /// process and captures just its window, and it lands in this record
    /// list like any other capture. Reuses the same delivery handling —
    /// only the request differs.
    func captureProcess(psnHigh: Int, psnLow: Int) {
        guard canCapture else { return }
        isCapturing = true
        lastError = nil
        listener.requestProcessShot(psnHigh: psnHigh, psnLow: psnLow,
                                    depth: selectedDepth.rawValue) {
            [weak self] in
            self?.receiveDelivery($0, forcingClipboard: false,
                                  completion: nil)
        }
    }

    private func receiveDelivery(
        _ result: Result<GuestListener.CaptureDelivery,
                         GuestListener.CaptureFailure>,
        forcingClipboard: Bool,
        completion: ((QuickCaptureOutcome) -> Void)?) {
        isCapturing = false
        progress = nil
        switch result {
        case .success(let delivery):
            let record = ScreenshotRecord(
                capturedAt: Date(), image: delivery.image,
                format: delivery.format, transferMs: delivery.transferMs,
                wireBytes: delivery.wireBytes, guest: delivery.guestName)
            receive(record)
            if forcingClipboard || autoCopy {
                copyToPasteboard(record)
            }
            var savedTo: URL?
            if autoSave {
                lastError = write(record, to: saveDirectory, savedTo: &savedTo)
            }
            completion?(.copied(width: record.width, height: record.height,
                                depth: record.format.depth,
                                savedAs: savedTo?.lastPathComponent))
        case .failure(let failure):
            lastError = failure.message
            completion?(.failed(failure.message))
        }
    }

    /// Asks the guest to stop. The failed capture.end that follows is what
    /// clears `isCapturing`, so the button state always tracks the wire.
    func cancel() {
        guard isCapturing else { return }
        listener.cancelCapture()
    }

    /// Writes a PNG into `directory` under a non-colliding name. Returns a
    /// human-readable reason on failure, nil on success.
    @discardableResult
    func write(_ record: ScreenshotRecord, to directory: URL) -> String? {
        var ignored: URL?
        return write(record, to: directory, savedTo: &ignored)
    }

    func write(_ record: ScreenshotRecord, to directory: URL,
               savedTo: inout URL?) -> String? {
        savedTo = nil
        guard let png = CaptureDecoder.pngData(record.image) else {
            return "Could not encode the capture as PNG"
        }
        let stamp = Self.stampFormatter.string(from: record.capturedAt)
        var url = directory.appendingPathComponent("Screenshot \(stamp).png")
        var bump = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent(
                "Screenshot \(stamp) (\(bump)).png")
            bump += 1
        }
        do {
            try png.write(to: url)
            savedTo = url
            return nil
        } catch {
            return "Could not save to \(directory.lastPathComponent): "
                + error.localizedDescription
        }
    }

    /// Replaces the pasteboard with the capture as a TIFF-backed image.
    func copyToPasteboard(_ record: ScreenshotRecord) {
        let rep = NSBitmapImageRep(cgImage: record.image)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    /// Save-panel defaults, in the contemporary style.
    var suggestedScreenshotName: String {
        "Screenshot \(Self.stampFormatter.string(from: Date())).png"
    }
    var suggestedRecordingName: String {
        "Screen Recording \(Self.stampFormatter.string(from: Date())).mov"
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    func receive(_ record: ScreenshotRecord) {
        history.insert(record, at: 0)
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
    }
}
