import Foundation

/// The half of the feedback pair that works without a code signature.
/// System notifications silently do nothing under the ad-hoc signature
/// `scripts/build-host-app` produces — no banner, no prompt, no error — so
/// the status item itself says what happened for a couple of seconds and
/// then goes back to its name. Signed builds get both; nobody gets neither.
@MainActor
final class StatusItemFlash {
    private let restingTitle: String
    private let duration: TimeInterval
    private let apply: (String) -> Void
    /// Bumped per flash so an earlier flash's restore timer cannot cut a
    /// later flash short.
    private var generation = 0

    init(restingTitle: String, duration: TimeInterval = 2.2,
         apply: @escaping (String) -> Void) {
        self.restingTitle = restingTitle
        self.duration = duration
        self.apply = apply
    }

    func flash(_ text: String) {
        generation += 1
        let mine = generation
        apply(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            [weak self] in
            guard let self, self.generation == mine else { return }
            self.apply(self.restingTitle)
        }
    }

    /// Restores the resting title now, cancelling any pending restore.
    func settle() {
        generation += 1
        apply(restingTitle)
    }
}
