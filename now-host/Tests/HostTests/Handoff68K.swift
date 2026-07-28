import Foundation
@testable import Host

/// Naming the process on the other end of a connection, and retiring it.
///
/// THE DEFECT THIS REPLACES. The handoff used to build the outgoing
/// build's name out of the version it read from that build's `hello`:
/// `"NOW-68K " + guestVersion`. That is a guess about a FILE NAME made
/// from a COMPILED CONSTANT, and the two agree only by convention. On
/// 2026-07-25 the convention had lapsed — a build deployed as
/// `NOW-68K 0.18` reported `0.16` — so the retire step sent
/// `quit NOW-68K 0.16`, the guest answered honestly that nothing of that
/// name was running, the old build kept running, and a 4 MB machine was
/// left with two NOW-68Ks. Nothing was wrong with the guest, the wire, or
/// the command; the identifier was invented on this side.
///
/// A PSN cannot go wrong that way. It names exactly one live process, and
/// `process.listing` marks the responder's own row with `isSelf`, so the
/// identity comes from the machine that has it rather than from a string
/// this side assembled. The name that comes back with it is for the
/// human reading the log, and is never the thing acted on.
///
/// Shared by the metal handoff and by the loopback test that reproduces
/// the version/name disagreement (`HandoffIdentityTests`) — the second is
/// the one that can be run without a PowerBook, and it is the reason this
/// lives in a file of its own rather than inside the metal test.
@MainActor
enum Handoff68K {
    /// A process named the way a machine should name one. `name` is
    /// carried for the log only: two builds can share it, and the whole
    /// point here is that nothing downstream depends on it.
    struct Retiree: Equatable, CustomStringConvertible {
        var name: String
        var psnHigh: Int
        var psnLow: Int

        var description: String { "\(name) [PSN \(psnHigh).\(psnLow)]" }
    }

    enum Failure: Error, CustomStringConvertible {
        case listing(String)
        case noSelfRow
        case noPSN(String)
        case refused(String)

        var description: String {
            switch self {
            case .listing(let why):
                return "could not read the guest's process list: \(why)"
            case .noSelfRow:
                return """
                    the guest listed its processes but marked none of them \
                    isSelf. Either it predates the field (contract: \
                    ProcessListing.isSelf) or it could not read its own \
                    PSN — and without it there is no honest way to name \
                    the process on the other end of this connection. \
                    Deriving a name from the version in `hello` is what \
                    this exists to stop doing.
                    """
            case .noPSN(let name):
                return "\(name) is marked isSelf but carries no PSN, so "
                    + "nothing can drive it"
            case .refused(let why):
                return "the guest refused the quit: \(why)"
            }
        }
    }

    /// Every process the guest reports, paged to the end. A page is a
    /// snapshot; the whole list is a snapshot of snapshots, which is what
    /// the contract's cursor gives and is honest enough for "is this PSN
    /// still there".
    static func processes(of listener: GuestListener) async throws
        -> [ProcessEntry] {
        var all: [ProcessEntry] = []
        var cursor: Int?
        // Bounded: a guest that answers `more:true` forever would
        // otherwise hang the run rather than fail it.
        for _ in 0..<32 {
            let listing = try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<ProcessListing, Error>) in
                listener.listProcesses(cursor: cursor) { result in
                    switch result {
                    case .success(let listing): cont.resume(returning: listing)
                    case .failure(let f):
                        cont.resume(throwing: Failure.listing(f.message))
                    }
                }
            }
            all += listing.processes
            guard listing.more, let next = listing.cursor else { return all }
            cursor = next
        }
        throw Failure.listing("the listing never stopped paging")
    }

    /// Who is on the other end of THIS connection, as that machine names
    /// it. The one identity in the handoff that is not a guess.
    static func identifySelf(of listener: GuestListener) async throws
        -> Retiree {
        let rows = try await processes(of: listener)
        guard let me = rows.first(where: { $0.isSelf == true }) else {
            throw Failure.noSelfRow
        }
        guard let high = me.psnHigh, let low = me.psnLow else {
            throw Failure.noPSN(me.name)
        }
        return Retiree(name: me.name, psnHigh: high, psnLow: low)
    }

    /// Ask a DIFFERENT connection to quit that process. `ok` means the
    /// Apple Event was delivered, never that the process has gone — the
    /// contract is explicit, and `hasGone` is the check that follows.
    static func retire(_ who: Retiree, using listener: GuestListener)
        async throws {
        let result = try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<ProcessResult, Error>) in
            listener.driveProcess(psnHigh: who.psnHigh, psnLow: who.psnLow,
                                  verb: .quit) { result in
                switch result {
                case .success(let r): cont.resume(returning: r)
                case .failure(let f):
                    cont.resume(throwing: Failure.refused(f.message))
                }
            }
        }
        guard result.ok else {
            throw Failure.refused(result.reason ?? "no reason given")
        }
    }

    /// Whether that PSN still names a live process, asked of whichever
    /// connection can still answer. This is the independent half: the
    /// quit was served by one subsystem and this is read from another.
    static func hasGone(_ who: Retiree, accordingTo listener: GuestListener)
        async throws -> Bool {
        let rows = try await processes(of: listener)
        return !rows.contains { $0.psnHigh == who.psnHigh
                                && $0.psnLow == who.psnLow }
    }
}
