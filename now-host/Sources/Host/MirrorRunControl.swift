import Foundation
import Combine

/// **Whether the Mirror is running, owned apart from where it is shown.**
///
/// The poll used to be a property of the window: `show()` started it and
/// `windowWillClose` stopped it, which was defensible while a window was
/// the only way to look at a mirror. It stopped being defensible the
/// moment the Mirror gained a second container and a headless face.
/// `now_mirror_drive`, `now_mirror_status` and the whole fidelity sweep
/// read the source with no window involved and every one of them refuses
/// while `running` is false — so a container deciding the poll's fate
/// means an agent's drive starting to refuse because somebody switched
/// to the Console page, with nothing on either machine naming the cause.
///
/// So this owns start and stop, and only this. Closing the detached
/// window re-attaches; backgrounding the module does nothing at all.
///
/// It also owns the retry the window learned the hard way. `start()`
/// REFUSES when the listener has no active key — it has nothing to poll
/// — and at launch that is the ordinary order of events, because
/// `--open-mirror` fires on the first connection change before the key
/// exists. That bounded retry is a property of the running axis, not of
/// a window, and it moved here with it.
@MainActor
final class MirrorRunControl: ObservableObject {

    private let source: NOWMirrorSource
    private let defaults: UserDefaults
    private static let wantsRunningKey = "mirrorWantsRunning"

    /// What the person last asked for, which is not the same as whether
    /// it is running: a "yes" with no Mac connected is still a yes, and
    /// it is what makes the Mirror come back by itself on the next
    /// connection and across a relaunch.
    @Published private(set) var wantsRunning: Bool {
        didSet { defaults.set(wantsRunning, forKey: Self.wantsRunningKey) }
    }

    /// Whether the poll is actually going. Republished from the source so
    /// a view observing this object alone still sees it change.
    @Published private(set) var running = false

    /// The persisted answer, readable **without constructing anything**.
    /// `HostAppState` asks this on every connection change, and asking
    /// the run control itself would build `NOWMirrorSource` on every host
    /// with a Mac on the wire — the mistake the metrics reader is already
    /// guarded against.
    static func storedWantsRunning(_ defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: wantsRunningKey)
    }

    private var retry: Task<Void, Never>?
    private var runningMirror: AnyCancellable?

    init(source: NOWMirrorSource, defaults: UserDefaults = .standard) {
        self.source = source
        self.defaults = defaults
        wantsRunning = defaults.bool(forKey: Self.wantsRunningKey)
        running = source.running
        runningMirror = source.$running.sink { [weak self] value in
            self?.running = value
        }
    }

    /// Asked for by a person or by any of the Mirror's four faces.
    func start() {
        wantsRunning = true
        source.start()
        if !source.running { retryUntilAMacArrives() }
    }

    func stop() {
        wantsRunning = false
        retry?.cancel()
        retry = nil
        source.stop()
    }

    /// Called on every connection change. A Mirror that was running when
    /// the app last quit — or when the guest last dropped — comes back by
    /// itself, because "running" is a state of the product and not of the
    /// session that happened to be up.
    func resumeIfWanted() {
        guard wantsRunning, !source.running else { return }
        source.start()
        if !source.running { retryUntilAMacArrives() }
    }

    /// Bounded and cheap, exactly as `NOWMirrorWindow` had it: a poll that
    /// has already started returns immediately, and a launch with no Mac
    /// at all gives up after ten seconds rather than spinning forever.
    private func retryUntilAMacArrives() {
        retry?.cancel()
        retry = Task { @MainActor [weak self] in
            for _ in 0..<40 {                          // ~10s
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, !Task.isCancelled, self.wantsRunning else {
                    return
                }
                if self.source.running { return }
                self.source.start()
            }
        }
    }
}
