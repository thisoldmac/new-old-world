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

    private struct Work {
        var operation: MirrorOperation
        var execute: Execute
        var report: Report
    }

    let journal: MirrorOperationJournal
    private var queue: [Work] = []
    private var active: Work?
    private var awaitingLateEvidence: [Work] = []
    private var timeoutTask: Task<Void, Never>?
    private let timeout: TimeInterval

    init(journal: MirrorOperationJournal? = nil,
         timeout: TimeInterval = 15) {
        self.journal = journal ?? MirrorOperationJournal()
        self.timeout = timeout
    }

    @discardableResult
    func enqueue(_ operation: MirrorOperation,
                 execute: @escaping Execute,
                 report: @escaping Report) -> Bool {
        guard journal.append(operation) else { return false }
        queue.append(.init(operation: operation, execute: execute,
                           report: report))
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
                work.report(work.operation, nil)
            } else {
                remaining.append(work)
            }
        }
        awaitingLateEvidence = remaining
    }

    func sessionChanged(at date: Date = Date()) {
        timeoutTask?.cancel()
        if var work = active {
            work.operation = MirrorOperationReducer.reduce(
                work.operation, event: .sessionChanged(at: date))
            journal.replace(work.operation)
            work.report(work.operation, nil)
        }
        for var work in queue {
            work.operation = MirrorOperationReducer.reduce(
                work.operation, event: .sessionChanged(at: date))
            journal.replace(work.operation)
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
        active = work
        Task { @MainActor [weak self] in
            guard let self else { return }
            let attempt = await work.execute()
            guard self.active?.operation.id == work.operation.id else { return }
            if let complaint = attempt.complaint {
                work.operation = MirrorOperationReducer.reduce(
                    work.operation,
                    event: .refused(reason: complaint, at: Date(),
                                    effectMayHaveLanded:
                                        attempt.effectMayHaveLanded))
            } else {
                work.operation = MirrorOperationReducer.reduce(
                    work.operation, event: .dispatched(at: Date()))
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
                work.operation, event: .timedOut(at: Date()))
            self.active = work
            self.journal.replace(work.operation)
            self.finish(work, complaint: nil)
        }
    }

    private func finish(_ work: Work, complaint: String?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        work.report(work.operation, complaint)
        if work.operation.outcome == .timedOut {
            awaitingLateEvidence.append(work)
        }
        active = nil
        drain()
    }
}
