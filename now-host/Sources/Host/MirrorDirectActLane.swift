import Foundation

/// **One act on the wire at a time, for the acts that never queue.**
///
/// `MirrorMutationBroker` serializes the handful of plans that carry a typed
/// postcondition. Everything else — move, resize, select, **control clicks**,
/// keystrokes, most menu commands — dispatched straight from
/// `NOWMirrorSource.perform`, each in its own `Task`, with nothing between
/// them and the socket. Those are the commonest gestures a person makes, and
/// they were the only ones with no lane at all.
///
/// The guest cannot take them that way. `contract/peek_table.h` gives the act
/// plane **one** request cell (`NowPeekActCell act;` — one struct member, not
/// an array), and since 2026-08-06 the guest services the wire from inside
/// its own act wait, so a second act command now *arrives* mid-flight instead
/// of sitting in the socket until the first finished. `now_act_cell()` refuses
/// it before it can overwrite the armed request's identity:
///
/// > another act is already in flight — this Mac's act plane has one request
/// > cell and it is taken. Nothing was written.
///
/// Michelle hit that **nine times in ninety seconds** working a scroll bar on
/// 2026-08-07. A scroll arrow is a control click, so every one of those clicks
/// took the unbrokered path and raced the one before it.
///
/// ## Why the fix is here and not in the guest
///
/// `now_act_inflight.h` argues the refusal is correct rather than poor — "a
/// caller told *busy* can decide, whereas a caller made to wait cannot" — and
/// it is right. The defect is that **this side never did the deciding.** The
/// guest's contract asks the caller to serialize; the brokered path honours
/// that and the direct path did not. So this is the missing half of an
/// existing agreement, not a new policy, and it changes no contract, no
/// `ext/` code and no `peek_table.h` layout — it owes no bake.
///
/// ## Order, and why the lane is not a settlement queue
///
/// A direct act releases the lane when the **guest has answered**, not when
/// some later scene confirms the effect. That is the honest boundary for
/// these plans: they carry no postcondition, so nothing will ever settle
/// them, and holding the lane for a confirmation that cannot arrive would
/// wedge it. Arrival order is preserved — a person clicking a scroll arrow
/// four times means four scrolls, in that order.
///
/// ## The cap, and what it admits
///
/// The lane is bounded. Past `capacity` a submission is refused **here**,
/// instantly and with a reason, rather than queued behind acts whose targets
/// may no longer exist by the time they dispatch. This is deliberately the
/// same shape as `MirrorMutationBroker.shedQueue`: the guest is serial, so an
/// unbounded backlog is a person's stale clicks arriving minutes later at
/// whatever happens to be under them by then.
///
/// **What this does NOT fix**, stated because a guard whose limits are not
/// written down gets read as a guarantee: it serializes *this host app's*
/// direct acts. It says nothing about the brokered lane running alongside it
/// (the two are separate lanes into one cell, and an act from each can still
/// collide), and nothing about a second application linking the same plane —
/// the shared table does not authenticate its writer.
@MainActor
final class MirrorDirectActLane {
    typealias Work = @MainActor () async -> Void

    /// The most recently submitted act. Each new submission awaits it, which
    /// is what makes the lane a lane; a completed task returns from `value`
    /// immediately, so a drained lane costs nothing.
    private var tail: Task<Void, Never>?

    /// Acts running or waiting. Read by the queue display for the same reason
    /// the broker's `depth` is: a person looking at a slow gesture needs to
    /// know whether anything was in front of it.
    private(set) var depth: Int = 0

    /// Bumped by ``reset``. A completion from a previous generation must not
    /// decrement the new generation's `depth`, or a reconnection would leave
    /// the lane reading emptier than it is and admit acts past `capacity`.
    private var generation = 0

    let capacity: Int

    init(capacity: Int = 8) {
        self.capacity = capacity
    }

    /// Run `work` after every act already in the lane, and not before.
    ///
    /// Returns `false` when the lane is full, in which case `work` is **never
    /// run** — the caller owes the person a refusal saying so.
    @discardableResult
    func submit(_ work: @escaping Work) -> Bool {
        guard depth < capacity else { return false }
        depth += 1
        let ahead = tail
        let mine = generation
        let task = Task { @MainActor [weak self] in
            /* THE WHOLE LANE IS THIS LINE. Without it every act runs
               concurrently and the guest refuses all but one of them. */
            _ = await ahead?.value
            await work()
            guard let self, self.generation == mine else { return }
            self.depth -= 1
        }
        tail = task
        return true
    }

    /// Abandon the wait. The acts already dispatched are not recalled — they
    /// may be running on the guest — but nothing further chains behind them,
    /// and their completions no longer count against the new generation.
    func reset() {
        generation += 1
        tail = nil
        depth = 0
    }
}
