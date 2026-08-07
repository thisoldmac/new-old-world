import Combine
import Foundation

/// What the menu bar says about the guest. Derived rather than stored, so
/// the glyph, the menu's status line, and the Screenshot Guest grey-out all
/// read from one description of the connection instead of three.
enum GuestStatus: Equatable {
    case notListening
    case waiting(port: UInt16)
    /// Connected, with how long the wire has been silent. The host never
    /// pings (the guest drives the heartbeat), so silence is the only
    /// health signal there is.
    case connected(name: String, quietFor: TimeInterval)
    case failed(String)

    /// Matches `GuestListener.silenceReason`: past this the Mac is probably
    /// sitting in a modal dialog rather than merely idle. Well short of the
    /// 75s idle timeout, so "quiet" shows up before "gone" does.
    static let quietAfter: TimeInterval = 20

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isQuiet: Bool {
        if case .connected(_, let quiet) = self {
            return quiet > Self.quietAfter
        }
        return false
    }

    /// A single leading character, because that is all a menu-bar title can
    /// spend before it starts crowding everyone else's.
    var glyph: String {
        switch self {
        case .notListening: return "○"
        case .waiting: return "◌"
        case .connected: return isQuiet ? "◐" : "●"
        case .failed: return "⚠"
        }
    }

    /// The menu-bar glyph for this state: a template image of the compact
    /// Mac whose *screen* carries what `glyph` puts in a character — empty,
    /// a dot, half filled, filled, or filled behind a bang. Kept in step with
    /// `glyph` deliberately; both describe the same five states, and the text
    /// one is still the fallback when the asset cannot be loaded.
    var statusImageName: String {
        switch self {
        case .notListening: return "StatusNotListening"
        case .waiting: return "StatusWaiting"
        case .connected: return isQuiet ? "StatusQuiet" : "StatusConnected"
        case .failed: return "StatusFailed"
        }
    }

    /// The disabled header line at the top of the menu — where the grey-out
    /// of Screenshot Guest gets explained rather than left a mystery.
    var menuLine: String {
        switch self {
        case .notListening:
            return "Not listening"
        case .waiting(let port):
            /* Read from the menu bar of the Mac that is listening, so "no
               Mac connected" had two readings and the wrong one is the
               alarming one. */
            return "Listening on \(String(port)) — no "
                + "\(MachineNaming.commonNoun) connected"
        case .connected(let name, let quiet):
            guard quiet > Self.quietAfter else { return "Connected: \(name)" }
            return "\(name) — quiet for \(Int(quiet))s"
        case .failed(let reason):
            return reason
        }
    }

    /// The same connection in the width a sidebar caption has — one short
    /// line under "Connection". Connected, that is the name the other
    /// machine sent, the way `peerLabel` answers it elsewhere; otherwise a
    /// plain description of what this side is doing, since there is no name
    /// to use yet.
    var sidebarLine: String {
        switch self {
        case .notListening:
            return "Not listening"
        case .waiting(let port):
            return "Listening on \(String(port))"
        case .connected(let name, let quiet):
            guard quiet > Self.quietAfter else { return name }
            return "\(name) — quiet"
        case .failed(let reason):
            return reason
        }
    }

    static func evaluate(state: GuestListener.State,
                         health: GuestListener.SessionHealth?,
                         now: Date = Date()) -> GuestStatus {
        switch state {
        case .idle:
            return .notListening
        case .listening(let port):
            return .waiting(port: port)
        case .failed(let reason):
            return .failed(reason)
        case .connected(let name):
            // No health record yet means the hello just landed — treat that
            // as fresh, not as silence since the epoch.
            let quiet = health.map { now.timeIntervalSince($0.lastTraffic) } ?? 0
            return .connected(name: name, quietFor: max(0, quiet))
        }
    }
}

/// Publishes `GuestStatus` for the menu bar. Connection changes arrive as
/// events, but going quiet is the absence of one — so while a guest is
/// connected this also ticks, and stops ticking the moment it isn't.
@MainActor
final class GuestStatusMonitor: ObservableObject {
    @Published private(set) var status: GuestStatus = .notListening

    private let listener: GuestListener
    private var watch: AnyCancellable?
    private var tick: Timer?
    private let interval: TimeInterval

    init(listener: GuestListener, interval: TimeInterval = 5) {
        self.listener = listener
        self.interval = interval
        watch = listener.$state.combineLatest(listener.$health)
            .sink { [weak self] _, _ in
                // The publishers fire in `willSet`, so read the settled
                // values a turn later rather than the outgoing ones.
                DispatchQueue.main.async { self?.refresh() }
            }
    }

    deinit {
        tick?.invalidate()
    }

    /// Recomputes now. Also called when the menu is about to open, so the
    /// line a person reads is never up to `interval` stale.
    func refresh() {
        let next = GuestStatus.evaluate(state: listener.state,
                                        health: listener.health)
        if next != status { status = next }
        setTicking(next.isConnected)
    }

    private func setTicking(_ wanted: Bool) {
        guard wanted != (tick != nil) else { return }
        if wanted {
            let timer = Timer.scheduledTimer(withTimeInterval: interval,
                                             repeats: true) { _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
            tick = timer
        } else {
            tick?.invalidate()
            tick = nil
        }
    }
}
