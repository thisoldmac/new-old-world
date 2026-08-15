import AppKit
import Foundation
import NOWAgentIntegration

/// The two wire calls this page makes, behind one seam.
///
/// Both of them go straight to the listener in the app; naming them here
/// lets a test answer a listing or a capture without a Mac, which is the
/// only way the selection and preview rules below can be exercised at all —
/// a listener with no session refuses every call before the model sees a
/// row. It is a seam, not an abstraction: `.live` is the whole production
/// implementation and there is no second one outside the tests.
struct ProcessWire {
    var list: (Int?,
               @escaping (Result<ProcessListing,
                                 GuestListener.FileFailure>) -> Void) -> Void
    /// psnHigh, psnLow, verb.
    var drive: (Int, Int, GuestListener.ProcessVerb,
                @escaping (Result<ProcessResult,
                                  GuestListener.FileFailure>) -> Void) -> Void
    /// psnHigh, psnLow, depth.
    var shoot: (Int, Int, Int,
                @escaping (Result<GuestListener.CaptureDelivery,
                                  GuestListener.CaptureFailure>) -> Void) -> Void

    @MainActor
    static func live(_ listener: GuestListener) -> ProcessWire {
        ProcessWire(
            list: { cursor, done in
                listener.listProcesses(cursor: cursor, completion: done)
            },
            drive: { high, low, verb, done in
                listener.driveProcess(psnHigh: high, psnLow: low, verb: verb,
                                      completion: done)
            },
            shoot: { high, low, depth, done in
                /* The same request `ScreenshotModuleModel.captureProcess`
                   makes — the reuse is at this seam rather than through that
                   model, because a capture taken here has to come BACK here
                   to be previewed, and that model's entry point delivers
                   into its own history and nowhere else. */
                listener.requestProcessShot(psnHigh: high, psnLow: low,
                                            depth: depth, completion: done)
            })
    }
}

/// The connected Mac's running processes, pulled over the wire.
///
/// The consume half of the process.* family made visible: one `refresh`
/// asks `process.list` and pages the whole table in, because a process
/// list is small and a human wants all of it, not a scroll that fetches.
/// It shows what the guest serves and nothing it does not — the read is
/// honest about being a snapshot from the moment it was asked.
@MainActor
final class ProcessesModel: ObservableObject, GuestScopedModel {
    @Published var connection: GuestConnectionState = .disconnected {
        didSet { connectionChanged(from: oldValue) }
    }
    @Published private(set) var rows: [ProcessEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    /// When the shown list was fetched, so the header can say how fresh
    /// it is — a process list goes stale the instant it is read.
    @Published private(set) var fetchedAt: Date?
    @Published var selection: ProcessEntry.ID? {
        didSet {
            guard selection != oldValue else { return }
            rememberSelected()
            // A picture of the process you were reading is not a picture of
            // the one you just picked.
            if preview != nil { dismissPreview() }
        }
    }
    /// A drive verb (front / quit / screenshot) is waiting on the guest.
    /// Buttons disable while it is, so one click cannot stack another.
    @Published private(set) var actionInFlight = false

    /// The last row the selection actually resolved to.
    ///
    /// Kept because the list repaints underneath the reader: `.processListChanged`
    /// fires when an agent quits something anywhere, and the process a person
    /// is reading may simply not be in the next listing. Without this the
    /// details side would empty itself and give no account of why.
    @Published private(set) var lastKnownSelected: ProcessEntry?

    /// The capture depth this page asks for. Shares `CaptureDepth` with the
    /// Screen module — one notion of bit depth, chosen per page, because a
    /// window shot and a full-screen shot are wanted at different weights.
    @Published var captureDepth: CaptureDepth = .native

    /// The shot on screen, and which process it is of. Non-nil IS the
    /// preview state: the details side shows the picture instead of the
    /// process while it holds, and nothing navigates anywhere.
    @Published private(set) var preview: ScreenshotRecord?
    @Published private(set) var previewOf: String?
    @Published private(set) var isCapturing = false

    private let listener: GuestListener
    private let wire: ProcessWire
    /// The page's one push: the table changed, so re-read it.
    ///
    /// Scoped to the Mac being shown. Everything else here is still a
    /// pull — neither guest offers a process table it has not been asked
    /// for, so a list is only ever as fresh as the last question.
    private var busWatch: HostEventSubscription?
    /// What the machines on the wire have said they can do. Shared with every
    /// other page that gates a control, injectable so a test gets its own.
    let capabilities: GuestCapabilityRecord
    /// Guards against a slow page landing after the human hit Refresh:
    /// each refresh takes a token, and only the current token may append.
    private var loadToken = 0
    /// Pages land here and only reach `rows` when the whole table has
    /// arrived. A refresh that emptied `rows` first would blink the list —
    /// and, worse, blink the details side through "no longer running" — on
    /// every push from the bus.
    private var staging: [ProcessEntry] = []

    init(listener: GuestListener,
         capabilities: GuestCapabilityRecord = .shared,
         wire: ProcessWire? = nil) {
        self.listener = listener
        self.capabilities = capabilities
        self.wire = wire ?? .live(listener)
        busWatch = listener.events.subscribe(
            scopedTo: { [weak self] in self?.connection.key }
        ) { [weak self] event in
            guard let self, case .processListChanged = event else { return }
            /* Only with a table on screen. A page nobody has opened does
               not fetch one because an agent quit something. */
            guard !self.rows.isEmpty else { return }
            self.refresh()
        }
    }

    var canBrowse: Bool { connection.canCapture }

    /// The row a person has selected, if it is still in the list.
    var selectedEntry: ProcessEntry? {
        rows.first { $0.id == selection }
    }

    /// What the details side is about.
    ///
    /// `.gone` is the case worth naming: the list repaints from the bus, and
    /// a process a person was reading can vanish between one listing and the
    /// next. Emptying the pane would say the selection was lost; this says
    /// the PROCESS was, keeps the facts that were true when it was last
    /// seen, and lets the view dark every control that would drive it.
    enum Subject: Equatable {
        case nothing
        case running(ProcessEntry)
        case gone(ProcessEntry)
    }

    var subject: Subject {
        guard let selection else { return .nothing }
        if let live = rows.first(where: { $0.id == selection }) {
            return .running(live)
        }
        if let last = lastKnownSelected, last.id == selection,
           !rows.isEmpty {
            return .gone(last)
        }
        return .nothing
    }

    private func rememberSelected() {
        if let live = selectedEntry { lastKnownSelected = live }
        if selection == nil { lastKnownSelected = nil }
    }

    /// **Whether bringing this process forward means anything, on this Mac.**
    ///
    /// The kind is the guest's own classification, not a type code read on
    /// this side: a faceless process has no windows and no menu bar, so there
    /// is nothing to bring forward whichever Mac is attached. `isDrivable` is
    /// a third fact and stays where it is — it says this ROW arrived without a
    /// PSN, which is about the listing rather than the process or the wire,
    /// and is not restated here.
    func bringToFrontGate(_ entry: ProcessEntry)
        -> GuestCapabilityGate.Decision {
        GuestCapabilityGate.decide(
            BringToFrontProjection.self, performing: .bringToFront,
            on: entry.itemKind, named: entry.name,
            in: capabilities.evidence(for: connection, listener: listener))
    }

    /// The sentence a dark Bring to Front button owes the reader, and nil
    /// while it works — including for the merely unproven case, which stays
    /// enabled and does not get to nag. Nil with nothing selected: a control
    /// dark for want of a selection is explained by the empty selection.
    ///
    /// Takes the row rather than reading `selectedEntry` itself, so the answer
    /// is a function of what the page is showing and can be asked without a
    /// wire, a listing, or a Mac.
    func bringToFrontNote(for entry: ProcessEntry?) -> String? {
        guard let entry else { return nil }
        let decision = bringToFrontGate(entry)
        guard decision.deservesAVisibleReason else { return nil }
        return decision.explanation
    }

    /// Two buckets a person reads at a glance: what has a face, and what
    /// runs behind everything. The Finder sits with the applications —
    /// it is one, and hiding it under "background" would read as wrong to
    /// anyone who knows the machine.
    enum Group: Int, CaseIterable {
        case applications, background

        var title: String {
            switch self {
            case .applications: return "Applications"
            case .background: return "Background"
            }
        }
    }

    static func group(of entry: ProcessEntry) -> Group {
        entry.kind == "background" ? .background : .applications
    }

    /// Rows for one group, the front process first, then by name — the
    /// same order the guest's own Processes page settled on.
    func rows(in group: Group) -> [ProcessEntry] {
        rows.filter { Self.group(of: $0) == group }
            .sorted { lhs, rhs in
                if (lhs.front ?? false) != (rhs.front ?? false) {
                    return lhs.front ?? false
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                    == .orderedAscending
            }
    }

    /// The process table belongs to one connection. When the Mac goes
    /// away — most sharply on a redeploy, where a fresh guest reconnects
    /// with a new set of PSNs — the rows we still hold name processes that
    /// no longer exist, and driving one by its stale PSN fails closed. So
    /// drop the table the instant the connection does: a stale list never
    /// lingers into the next one, and because the rows are now empty the
    /// reconnect (or a reopened pane) reads afresh on its own, with no
    /// manual Refresh. This only clears — the re-read is driven from the
    /// view, past the state change the listener has yet to see.
    ///
    /// **The one model here that parks nothing.** Every other module caches
    /// something worth keeping per machine; a process table is worth
    /// keeping for about as long as it takes to read it. It goes stale on
    /// its own machine in seconds — that is why the header says when it was
    /// fetched — so parking it would buy a page of rows that are wrong in
    /// the same way the shared-across-guests version was wrong, only
    /// quieter. Switching guests therefore clears it exactly as
    /// disconnecting does, and the view re-reads.
    private func connectionChanged(from old: GuestConnectionState) {
        let switched = connection.key != nil && connection.key != old.key
        guard connection != old, !connection.canCapture || switched else {
            return
        }
        rows = []
        selection = nil
        fetchedAt = nil
        lastError = nil
        dismissPreview()
        // A page still in flight from the old connection must not append.
        loadToken += 1
        staging = []
        isLoading = false
        // And the re-read is HERE, not in the view. It used to be an
        // `.onChange(of: model.connection)` there as well as this clear, so
        // every guest switch fetched the table twice — once because the view
        // saw the state change and once because the pane it repainted had no
        // rows. One owner: the model hears the change first and reads.
        if canBrowse { refresh() }
    }

    func refresh() {
        guard canBrowse else { return }
        loadToken += 1
        staging = []
        // Neither the rows nor the selection are cleared here. The rows stay
        // until the whole new table has landed (see `staging`), and the
        // selection is kept by identity: a refresh after driving a process
        // leaves the same row picked if it is still running, and falls to
        // `.gone` by itself if it is not.
        lastError = nil
        load(cursor: nil, token: loadToken)
    }

    /// Bring the selected process to the front of the guest's screen.
    func bringToFront(_ entry: ProcessEntry) { drive(entry, .front) }

    /// Ask the selected process to quit — a request it may decline.
    func askToQuit(_ entry: ProcessEntry) { drive(entry, .quit) }

    /// Capture just this process's window. The whole sequence — front it,
    /// let it repaint, crop to its window, deliver — happens on the guest
    /// (process.shot); the picture lands HERE, beside the process it is of,
    /// rather than sending the reader to another page to find it. A capture
    /// is something you take while reading a process, not a reason to stop.
    func screenshotApp(_ entry: ProcessEntry) {
        guard let high = entry.psnHigh, let low = entry.psnLow,
              !isCapturing, canBrowse else { return }
        isCapturing = true
        lastError = nil
        let name = entry.name
        wire.shoot(high, low, captureDepth.rawValue) { [weak self] result in
            guard let self else { return }
            self.isCapturing = false
            switch result {
            case .success(let delivery):
                self.preview = ScreenshotRecord(
                    capturedAt: Date(), image: delivery.image,
                    format: delivery.format, transferMs: delivery.transferMs,
                    wireBytes: delivery.wireBytes, guest: delivery.guestName)
                self.previewOf = name
            case .failure(let failure):
                self.lastError = failure.message
            }
        }
    }

    /// Back to the process. The picture is dropped rather than parked: it
    /// was never filed anywhere, and saying otherwise by keeping it would
    /// invite a reader to come back for it.
    func dismissPreview() {
        preview = nil
        previewOf = nil
    }

    /// The shown capture on the pasteboard, as an image.
    ///
    /// The same six lines as `ScreenshotModuleModel.copyToPasteboard`, which
    /// is where this belongs — it is an instance method on a model this page
    /// cannot reach, and the smallest fix is to make that one `static` (or
    /// move it beside `CaptureDecoder`) and have both sides call it.
    func copyPreview() {
        guard let record = preview else { return }
        let rep = NSBitmapImageRep(cgImage: record.image)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    /// The shown capture as a PNG, encoded by the one encoder this app has.
    /// Nil on success, a sentence on failure — the shape every other write
    /// in this app answers in.
    @discardableResult
    func savePreview(to url: URL) -> String? {
        guard let record = preview else { return nil }
        guard let png = CaptureDecoder.pngData(record.image) else {
            return "Could not encode the capture as PNG"
        }
        do {
            try png.write(to: url)
            return nil
        } catch {
            return "Could not save: \(error.localizedDescription)"
        }
    }

    /// The name a save panel offers, matching the Screen module's stamp.
    var suggestedPreviewName: String {
        let stamp = Self.stamp.string(from: preview?.capturedAt ?? Date())
        let of = previewOf.map { " of \($0)" } ?? ""
        return "Screenshot\(of) \(stamp).png"
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    private func drive(_ entry: ProcessEntry,
                       _ verb: GuestListener.ProcessVerb) {
        guard let high = entry.psnHigh, let low = entry.psnLow,
              !actionInFlight else { return }
        actionInFlight = true
        lastError = nil
        wire.drive(high, low, verb) { [weak self] result in
            guard let self else { return }
            self.actionInFlight = false
            switch result {
            case .success(let r) where r.ok:
                /* The re-read used to be here. It is on the bus now
                   (`processListChanged`, published where the guest's answer
                   lands), because a `process.quit` served over the agent
                   surface changed the same table and this page never heard
                   about it. */
                break
            case .success(let r):
                self.lastError = r.reason
                    ?? "\(MachineNaming.title(self.connection)) declined"
            case .failure(let f):
                self.lastError = f.message
            }
        }
    }

    /// One page, chaining straight into the next while `more` holds, so a
    /// refresh settles on the whole table rather than a first page.
    private func load(cursor: Int?, token: Int) {
        isLoading = true
        wire.list(cursor) { [weak self] result in
            guard let self, token == self.loadToken else { return }
            switch result {
            case .success(let listing):
                self.staging += listing.processes
                if listing.more, let next = listing.cursor {
                    self.load(cursor: next, token: token)
                } else {
                    self.isLoading = false
                    self.rows = self.staging
                    self.staging = []
                    // The selected process may be in this table and may not.
                    // Either way the remembered row is refreshed from it
                    // while it is there, so `.gone` shows the last facts that
                    // were true rather than the facts from first selection.
                    self.rememberSelected()
                    self.fetchedAt = Date()
                }
            case .failure(let failure):
                self.isLoading = false
                self.staging = []
                self.lastError = failure.message
            }
        }
    }
}

extension ProcessEntry {
    /// A face-forward kind label. The wire word is honest but terse;
    /// this is what a person reads in the row.
    var kindLabel: String {
        switch kind {
        case "finder": return "Finder"
        case "background": return "Background"
        default: return "Application"
        }
    }

    /// The two 4CCs as one caption, when the server sent them. The host's
    /// own list (the mirror direction) has neither, so this is empty
    /// there rather than a pair of blanks.
    var signatureLabel: String? {
        let parts = [code, creator].compactMap { code -> String? in
            guard let code, !code.isEmpty else { return nil }
            return code
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    /// Partition size, in the unit that keeps the number legible.
    var sizeLabel: String? {
        guard let kb = sizeKB, kb > 0 else { return nil }
        if kb < 1024 { return "\(kb) KB" }
        return String(format: "%.1f MB", Double(kb) / 1024.0)
    }
}
