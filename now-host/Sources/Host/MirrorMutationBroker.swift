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
        record(work, kind: .released)
        work.report(work.operation, complaint)
        if work.operation.outcome == .timedOut {
            awaitingLateEvidence.append(work)
        }
        active = nil
        drain()
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
