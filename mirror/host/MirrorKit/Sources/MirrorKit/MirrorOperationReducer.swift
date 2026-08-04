import Foundation

/// Operation state changes only from broker facts or later guest evidence.
/// Dispatch deliberately never confirms its own effect.
public enum MirrorOperationReducer {
    public static func reduce(_ current: MirrorOperation,
                              event: MirrorOperationEvent) -> MirrorOperation {
        if current.outcome.isTerminal { return current }
        var operation = current
        switch event {
        case .dispatched(let at):
            guard operation.outcome == .queued else { return current }
            operation.outcome = .dispatched
            operation.dispatchedAt = at
        case .refused(let reason, let at, let effectMayHaveLanded):
            operation.outcome = effectMayHaveLanded
                ? .awaitingEvidenceAfterRefusal : .refused
            operation.reason = reason
            operation.settledAt = effectMayHaveLanded ? nil : at
        case .timedOut(let at):
            guard operation.outcome == .dispatched
                    || operation.outcome == .awaitingEvidenceAfterRefusal else {
                return current
            }
            operation.outcome = .timedOut
            operation.settledAt = at
        case .sessionChanged(let at):
            operation.outcome = .sessionChanged
            operation.reason = "guest session changed"
            operation.settledAt = at
        case .observation(let evidence):
            guard operation.outcome == .dispatched
                    || operation.outcome == .timedOut
                    || operation.outcome == .awaitingEvidenceAfterRefusal,
                  evidence.session == operation.session,
                  evidence.sequence > operation.displayedSequence,
                  confirms(operation.postcondition, with: evidence) else {
                return current
            }
            switch operation.outcome {
            case .timedOut:
                operation.outcome = .confirmedAfterTimeout
            case .awaitingEvidenceAfterRefusal:
                operation.outcome = .confirmedAfterRefusal
            default:
                operation.outcome = .confirmed
            }
            operation.settledSequence = evidence.sequence
            operation.settledAt = evidence.receivedAt
                ?? operation.settledAt ?? operation.dispatchedAt
        }
        return operation
    }

    private static func confirms(
        _ postcondition: MirrorOperationPostcondition,
        with evidence: MirrorSettlementEvidence) -> Bool {
        guard evidence.coverage.status == .complete else { return false }
        switch postcondition {
        case .windowAbsent(let identity):
            return evidence.coverage.scope == "windows"
                && evidence.coverage.owner == identity.process.incarnation
                && !evidence.presentWindows.contains(identity)
        case .windowFront(let identity):
            return evidence.coverage.scope == "windows"
                && evidence.coverage.owner == identity.process.incarnation
                && evidence.frontWindow == identity
        case .windowNamedPresent(let owner, let title):
            return evidence.coverage.scope == "windows"
                && evidence.coverage.owner == owner.incarnation
                && evidence.windowTitles.contains {
                    $0.key.process == owner && $0.value == title
                }
        case .processAbsent(let identity):
            return evidence.coverage.scope == "processes"
                && !evidence.presentProcesses.contains(identity)
        case .processFront(let identity):
            return evidence.coverage.scope == "processes"
                && evidence.frontProcess == identity
        case .processNamedPresent(let name):
            return evidence.coverage.scope == "processes"
                && evidence.processNames.values.contains(name)
        case .processVisibility(let expected):
            return evidence.coverage.scope == "process-visibility"
                && !expected.isEmpty
                && expected.allSatisfy {
                    evidence.processVisibility[$0.key] == $0.value
                }
        }
    }
}
