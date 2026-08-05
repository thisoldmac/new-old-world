import Foundation
import MirrorKit

struct MirrorMutationAttempt {
    var complaint: String?
    var effectMayHaveLanded: Bool
}

/// One direct-input FIFO for one pinned guest session.
///
/// Dispatch is serialized with settlement: a second gesture may be queued and
/// highlighted locally, but it cannot reach the guest until the prior typed
/// postcondition confirms or times out. That makes a later matching scene
/// attributable to exactly one operation rather than whichever click last
/// overwrote a shared correlation slot.
@MainActor
final class MirrorMutationBroker {
    typealias Execute = @MainActor () async -> MirrorMutationAttempt
    typealias Report = @MainActor (MirrorOperation, String?) -> Void

    typealias Clocks = @MainActor (MirrorActClocks) -> Void

    private struct Work {
        var operation: MirrorOperation
        var execute: Execute
        var report: Report
        var label: String
        var queueDepthAtEntry: Int
        var dispatchStartedAt: Date?
        var dispatchReturnedAt: Date?
        var releasedAt: Date?
    }

    let journal: MirrorOperationJournal
    private var queue: [Work] = []
    private var active: Work?
    private var awaitingLateEvidence: [Work] = []
    private var timeoutTask: Task<Void, Never>?
    private let timeout: TimeInterval
    private let now: () -> Date
    private let clocks: Clocks?

    /// Acts waiting for the lane, plus the one holding it. Read by the
    /// Mirror's own queue display, and recorded on every act that enters:
    /// a person looking at a slow gesture needs to know whether anything
    /// was in front of it before they can read the number at all.
    var depth: Int { queue.count + (active == nil ? 0 : 1) }

    init(journal: MirrorOperationJournal? = nil,
         timeout: TimeInterval = 15,
         now: @escaping () -> Date = Date.init,
         clocks: Clocks? = nil) {
        self.journal = journal ?? MirrorOperationJournal()
        self.timeout = timeout
        self.now = now
        self.clocks = clocks
    }

    @discardableResult
    func enqueue(_ operation: MirrorOperation,
                 label: String = "",
                 execute: @escaping Execute,
                 report: @escaping Report) -> Bool {
        guard journal.append(operation) else { return false }
        queue.append(.init(operation: operation, execute: execute,
                           report: report, label: label,
                           queueDepthAtEntry: depth))
        drain()
        return true
    }

    func observe(_ evidence: [MirrorSettlementEvidence]) {
        let currentPostcondition = active?.operation.postcondition
        if var work = active {
            for item in evidence {
                work.operation = MirrorOperationReducer.reduce(
                    work.operation, event: .observation(item))
            }
            active = work
            journal.replace(work.operation)
            if work.operation.outcome.isTerminal {
                finish(work, complaint: nil)
            }
        }

        /* A timeout frees the FIFO but does not rewrite history into a
           refusal. Keep listening for its exact postcondition unless a newer
           operation is currently trying to establish the same condition; in
           that case attribution would be ambiguous, so the older timeout
           remains honestly unresolved. */
        var remaining: [Work] = []
        for var work in awaitingLateEvidence {
            guard work.operation.postcondition != currentPostcondition else {
                remaining.append(work)
                continue
            }
            for item in evidence {
                work.operation = MirrorOperationReducer.reduce(
                    work.operation, event: .observation(item))
            }
            journal.replace(work.operation)
            if work.operation.outcome == .confirmedAfterTimeout {
                record(work, kind: .late)
                work.report(work.operation, nil)
            } else {
                remaining.append(work)
            }
        }
        awaitingLateEvidence = remaining
    }

    /// **Ends the in-flight act and everything queued behind it, on
    /// request.** This is the difference between a bad act and a lost
    /// session: before it existed, a person watching a 70-second wait had
    /// no way to abandon it, and neither did an agent — seven stacked
    /// timeouts were measured at 87.5 s on 2026-08-05, with nothing to do
    /// but watch.
    ///
    /// A cancel is a statement about the WAIT, not about the machine. The
    /// active act may already be running on the guest, so its record says
    /// the effect may still land rather than pretending it was refused;
    /// acts still queued were provably never sent and say that instead.
    /// Late evidence for previously timed-out acts keeps accruing — those
    /// already gave the lane up, and their history is not this cancel's
    /// to rewrite.
    @discardableResult
    func cancelAll(at date: Date = Date()) -> Int {
        var ended = 0
        timeoutTask?.cancel()
        timeoutTask = nil
        if var work = active {
            work.operation = MirrorOperationReducer.reduce(
                work.operation, event: .cancelled(at: date))
            work.releasedAt = date
            /* The lane frees BEFORE the reports go out, for the same
               reason `finish` does: the queue display reads `depth` from
               inside the notification. */
            active = nil
            journal.replace(work.operation)
            record(work, kind: .released)
            work.report(work.operation, nil)
            ended += 1
        }
        let waiting = queue
        queue.removeAll()
        for var work in waiting {
            work.operation = MirrorOperationReducer.reduce(
                work.operation, event: .cancelled(at: date))
            work.releasedAt = date
            journal.replace(work.operation)
            record(work, kind: .released)
            work.report(work.operation, nil)
            ended += 1
        }
        return ended
    }

    func sessionChanged(at date: Date = Date()) {
        timeoutTask?.cancel()
        /* A session change ends these acts without settling them, and
           that time was still spent. Recording it keeps a reconnection
           from reading as a run with no slow acts in it. */
        if var work = active {
            work.operation = MirrorOperationReducer.reduce(
                work.operation, event: .sessionChanged(at: date))
            work.releasedAt = date
            journal.replace(work.operation)
            record(work, kind: .released)
            work.report(work.operation, nil)
        }
        for var work in queue {
            work.operation = MirrorOperationReducer.reduce(
                work.operation, event: .sessionChanged(at: date))
            work.releasedAt = date
            journal.replace(work.operation)
            record(work, kind: .released)
            work.report(work.operation, nil)
        }
        for var work in awaitingLateEvidence {
            work.operation = MirrorOperationReducer.reduce(
                work.operation, event: .sessionChanged(at: date))
            journal.replace(work.operation)
            work.report(work.operation, nil)
        }
        active = nil
        queue.removeAll()
        awaitingLateEvidence.removeAll()
    }

    private func drain() {
        guard active == nil, !queue.isEmpty else { return }
        var work = queue.removeFirst()
        work.dispatchStartedAt = now()
        active = work
        Task { @MainActor [weak self] in
            guard let self else { return }
            let attempt = await work.execute()
            work.dispatchReturnedAt = self.now()
            guard self.active?.operation.id == work.operation.id else { return }
            if let complaint = attempt.complaint {
                work.operation = MirrorOperationReducer.reduce(
                    work.operation,
                    event: .refused(reason: complaint, at: self.now(),
                                    effectMayHaveLanded:
                                        attempt.effectMayHaveLanded))
            } else {
                work.operation = MirrorOperationReducer.reduce(
                    work.operation, event: .dispatched(at: self.now()))
            }
            self.active = work
            self.journal.replace(work.operation)
            if work.operation.outcome.isTerminal {
                self.finish(work, complaint: attempt.complaint)
            } else {
                work.report(work.operation, attempt.complaint)
                self.armTimeout(for: work.operation.id)
            }
        }
    }

    private func armTimeout(for id: String) {
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds:
                UInt64(self.timeout * 1_000_000_000))
            guard !Task.isCancelled, var work = self.active,
                  work.operation.id == id else { return }
            work.operation = MirrorOperationReducer.reduce(
                work.operation, event: .timedOut(at: self.now()))
            self.active = work
            self.journal.replace(work.operation)
            self.finish(work, complaint: nil)
        }
    }

    private func finish(_ work: Work, complaint: String?) {
        var work = work
        timeoutTask?.cancel()
        timeoutTask = nil
        work.releasedAt = now()
        /* The lane is free BEFORE the measurement is published, because
           the queue display reads `depth` from inside that notification.
           Leaving `active` set until afterwards made every record report
           one more act in flight than there was, so a lane that had just
           emptied still read as busy. */
        active = nil
        record(work, kind: .released)
        work.report(work.operation, complaint)
        if work.operation.outcome == .timedOut {
            awaitingLateEvidence.append(work)
            shedQueue(behind: work)
        }
        drain()
    }

    /// **A timeout ends the acts queued behind it, not just its own.**
    ///
    /// This is what bounds the QUEUE: the 15 s timeout bounds one act, and
    /// seven of them stacked to 87.5 s on 2026-08-05 because each queued
    /// act waited its turn to spend its own deadline against the same
    /// wedged guest. The guest is serial — one blocked callee deafens all
    /// of it — so an act queued behind a timeout was overwhelmingly going
    /// to time out too, and dispatching it anyway costs a person fifteen
    /// silent seconds per gesture they stacked.
    ///
    /// (That serial fact is also why the bound is a shed and not a second
    /// lane: 009 asked whether the FIFO should be one lane per target, and
    /// parallel lanes into a machine that can only answer one at a time
    /// would buy attribution ambiguity and no throughput.)
    ///
    /// A shed act was provably never sent, so `refused` is its honest
    /// outcome — but the refusal must say it GAVE UP, or the record reads
    /// as the machine declining rather than this side declining to wait.
    /// A fresh act enqueued after the shed dispatches immediately and
    /// earns its own answer.
    private func shedQueue(behind timedOut: Work) {
        guard !queue.isEmpty else { return }
        let ahead = timedOut.label.isEmpty
            ? "the act ahead of it" : "\"\(timedOut.label)\""
        let waiting = queue
        queue.removeAll()
        for var work in waiting {
            work.operation = MirrorOperationReducer.reduce(
                work.operation,
                event: .refused(
                    reason: "not sent: \(ahead) timed out and the guest "
                        + "may be wedged; re-send this if it is still "
                        + "wanted",
                    at: now(), effectMayHaveLanded: false))
            work.releasedAt = now()
            journal.replace(work.operation)
            record(work, kind: .released)
            work.report(work.operation, nil)
        }
    }

    /// One measurement per lane release, and one more if a late
    /// observation settles an act that had already given the lane up. The
    /// first is never rewritten: the fifteen seconds a timeout held the
    /// FIFO were really spent, whatever arrived afterwards.
    private func record(_ work: Work, kind: MirrorActClocks.Kind) {
        guard let clocks else { return }
        /* `MirrorOperation.settledAt` means "came to rest", which a
           timeout and a session change also do. The settle CLOCK means
           "an observation confirmed the effect", so it is read only from
           the outcomes that make that claim. Taking the field at face
           value gave a timed-out act a settle time, which is the exact
           false-green this instrument exists to make impossible. */
        let confirmed: Set<MirrorOperationOutcome> = [
            .confirmed, .confirmedAfterTimeout, .confirmedAfterRefusal,
        ]
        let settledAt = confirmed.contains(work.operation.outcome)
            ? work.operation.settledAt : nil
        clocks(.init(kind: kind,
                     operationID: work.operation.id,
                     label: work.label,
                     outcome: work.operation.outcome,
                     queueDepthAtEntry: work.queueDepthAtEntry,
                     enqueuedAt: work.operation.enqueuedAt,
                     dispatchStartedAt: work.dispatchStartedAt,
                     dispatchReturnedAt: work.dispatchReturnedAt,
                     settledAt: settledAt,
                     releasedAt: work.releasedAt ?? now()))
    }
}
