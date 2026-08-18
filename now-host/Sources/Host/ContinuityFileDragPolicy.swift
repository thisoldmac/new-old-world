import Foundation

/// Whether a guest→host file drag fetches its bytes eagerly, during the
/// crossing, or leaves them to a Finder-only promise. Stated once, here,
/// beside the other Continuity policies — not duplicated between the
/// decision site and the log line that explains it.
///
/// **The problem this answers.** The drag pasteboard used to carry only an
/// `NSFilePromiseProvider`. Finder consumes promises natively; most other
/// applications register only for a concrete `public.file-url` and never
/// adopted `NSFilePromiseReceiver`, so a promise-only pasteboard reads as
/// nothing-droppable to them (metal, 2026-08-15: only Finder/Desktop
/// accepted the drop). The host knows the item's size BEFORE the drag
/// starts — the guest selection stub publishes `dataSize` and
/// `resourceSize` — so a small file can be fetched during the crossing and
/// handed over as a real file, which every application accepts.
///
/// **The cap.** The wire measures at roughly 100 KB/s
/// (`assumedThroughputBytesPerSecond`, deliberately conservative). 256 KB
/// is about 2.6 seconds at that rate — comfortably inside the time a
/// person spends physically dragging the pointer back across the shared
/// edge, over a destination window, and releasing: the gesture an eager
/// fetch has to outrun, not an arbitrary round number. Above the cap, an
/// eager fetch would either visibly stall the drag or lose the race to the
/// drop more often than not, so those stay promise-only — an honest
/// limitation for large files (Finder-fluent, not every app) rather than a
/// drag that silently hangs.
///
/// **The pasteboard cannot be mutated after `NSDraggingSession` starts**,
/// so which mode a drag uses is a decision made once, at session start —
/// see `ContinuityGrabTransfer.EagerFetch` for where that decision is
/// actually pinned.
enum ContinuityFileDragPolicy {
    /// Total bytes (`dataSize` + `resourceSize`) at or under this size are
    /// eager-eligible.
    static let eagerFetchCapBytes = 256 * 1024

    /// Conservative assumed wire throughput, used only to size the bounded
    /// wait a drag may still owe an in-flight fetch when it starts before
    /// the fetch finishes. It is cheaper to wait a touch too long on a
    /// small file than to abandon a fetch seconds from completing.
    static let assumedThroughputBytesPerSecond = 100 * 1024

    /// A floor under the computed budget, so a near-zero-byte stub is not
    /// given a near-zero window to even begin.
    static let minimumBudgetSeconds: TimeInterval = 0.5

    static func totalBytes(dataSize: Int?, resourceSize: Int?) -> Int {
        (dataSize ?? 0) + (resourceSize ?? 0)
    }

    static func eligibleForEagerFetch(dataSize: Int?, resourceSize: Int?)
        -> Bool {
        totalBytes(dataSize: dataSize, resourceSize: resourceSize)
            <= eagerFetchCapBytes
    }

    /// How long a fetch of `bytes` may run before a drag starting from it
    /// gives up and falls back to the promise.
    static func budget(forBytes bytes: Int) -> TimeInterval {
        max(minimumBudgetSeconds,
            Double(bytes) / Double(assumedThroughputBytesPerSecond))
    }

    /// The single sentence both the decision site and the eventual
    /// resolution log against, so the two cannot describe the same drag
    /// differently. `elapsedMs` is nil for the initial "which mode did this
    /// drag choose" line and set for the later "here is what actually
    /// happened" one.
    static func summary(bytes: Int, eager: Bool, elapsedMs: Int? = nil)
        -> String {
        if eager {
            let elapsed = elapsedMs.map { " fetched in \($0) ms" } ?? ""
            return "eager (\(bytes) bytes\(elapsed))"
        }
        return "promise (\(bytes) bytes over cap \(eagerFetchCapBytes))"
    }
}
