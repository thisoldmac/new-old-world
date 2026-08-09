import Foundation
import Combine

/// **Whether the Mirror is running, owned apart from where it is shown.**
///
/// The poll used to be a property of the window: `show()` started it and
/// `windowWillClose` stopped it, which was defensible while a window was
/// the only way to look at a mirror. It stopped being defensible the
/// moment the Mirror gained a second container and a headless face.
/// `now_semantic_ui_act`, `now_semantic_ui_status` and the whole fidelity sweep
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
    /// What the person asked for during this host process. It deliberately
    /// survives a guest reconnect but not an application relaunch: starting a
    /// new host must never begin probing a classic Mac merely because the last
    /// process happened to be mirroring when it quit.
    @Published private(set) var wantsRunning = false

    /// Whether the poll is actually going. Republished from the source so
    /// a view observing this object alone still sees it change.
    @Published private(set) var running = false

    private var retry: Task<Void, Never>?
    private var runningMirror: AnyCancellable?

    init(source: NOWMirrorSource, defaults: UserDefaults = ProductIdentity.defaults) {
        self.source = source
        /* Retire the old persisted bit as well as ignoring it. A downgrade may
           still understand the key, but this build's launch contract is off. */
        defaults.removeObject(forKey: "mirrorWantsRunning")
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

    /// Runs while the outgoing guest is still the listener's command target,
    /// so guest-owned claims can be withdrawn before focus moves.
    func activeGuestWillChange() {
        source.activeGuestWillChange()
    }

    /// Called from the same listener event path that re-points every other
    /// guest-scoped model. Ending the old source first makes a direct switch
    /// and a disconnect/reconnect pair share one session boundary.
    func activeGuestDidChange() {
        source.activeGuestDidChange()
        resumeIfWanted()
    }

    /// Called on every connection change. Only an intent established during
    /// this process is eligible to resume.
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
