import Foundation
import NOWAgentIntegration

/// Serves one page of one software domain to an agent face.
///
/// Thin by construction, like the census: the listing needs no composition, so
/// this layer addresses, bounds, forwards and renders, and decides nothing
/// about the machine (rule 2, docs/agent-integration.md). It is the counterpart
/// of `AgentIntegrationSoftwareLaunch`, which consumes the same family and
/// hands back none of it.
///
/// **Three things it will not do**, each for a reason the caller would
/// otherwise have to guess at:
///
/// - **It does not loop the cursor.** `SoftwareModel` does, because a person
///   wants an inventory rather than a scroll that fetches; an agent gets one
///   page and the guest's own cursor, so a caller keeps the ability to stop.
///   `SoftwareInventoryProjection` carries the argument in full.
/// - **It does not interpret `note`.** The guest declares its own bounds there
///   — an `apps` inventory stopped at 48 items, or a `PBCatSearch` that was
///   unusable so only the volume root was walked — and turning either sentence
///   into a typed host field would go stale the first time a guest reworded a
///   note, and would be this side answering a question about somebody's
///   Macintosh out of its own state.
/// - **It does not guard against a second call.** The catalog-search
///   measurement does, because two sweeps in flight make each other's TIMINGS
///   meaningless. A listing makes no timing claim: a second one is slower and
///   still correct, the listener bounds each with its own 30 s watchdog, and
///   refusing a caller's second page would be a host decision about somebody
///   else's machine time.
@MainActor
final class AgentIntegrationSoftwareInventory {
    private let listener: GuestListener
    private let currentSessionID: @MainActor () -> UUID?
    private let clock: @MainActor () -> Date

    init(listener: GuestListener,
         currentSessionID: @escaping @MainActor () -> UUID?,
         clock: @escaping @MainActor () -> Date = { Date() }) {
        self.listener = listener
        self.currentSessionID = currentSessionID
        self.clock = clock
    }

    func page(domain: AgentIntegrationSoftwareDomain, cursor: Int?) async
        -> AgentIntegrationSoftwareInventoryResult {
        let floor = AgentIntegrationSoftwareInventoryBounds.minimumCursor
        if let cursor, cursor < floor {
            /* The projection refuses this before a request is composed and the
               local codec refuses it again on arrival; this is the third
               reading, for a caller that reached the adapter directly. */
            return refused(
                "now-software-cursor-invalid",
                "A software inventory cursor is \(floor) or more; \(floor) "
                    + "rebuilds the guest's inventory")
        }
        guard let sessionID = currentSessionID() else {
            return .unavailable(.guest)
        }

        let outcome = await request(domain: domain, cursor: cursor)
        guard currentSessionID() == sessionID else {
            /* Unavailable rather than refused: the machine that was asked is
               no longer the machine on the other end, so nothing here can say
               what is installed on either of them. */
            return .unavailable(.init(
                code: "now-software-outcome-unknown",
                message: "The paired guest changed while the software "
                    + "inventory page was in progress"))
        }
        switch outcome {
        case .failure(let failure):
            /* The guest's own words, forwarded. A `timeout` is the listener's
               watchdog rather than the guest's answer, and it says so — an
               unanswered page proves nothing about what the machine has
               installed, which is why it is a refused CALL and never an empty
               listing. */
            return refused(
                failure.code == "timeout"
                    ? "now-software-outcome-unknown" : "now-software-refused",
                failure.message)
        case .success(let listing):
            return render(listing, asked: domain)
        }
    }

    // MARK: - The wire

    /// No watchdog of its own: `GuestListener.listSoftware` arms a 30 s one,
    /// which outlives the `apps` sweep (~4 s measured) with room for a slow
    /// disk and is shorter than the local surface's window for this operation
    /// — so a caller reads this capability's typed refusal rather than a
    /// transport error, which would teach it nothing.
    private func request(domain: AgentIntegrationSoftwareDomain,
                         cursor: Int?) async
        -> Result<SoftwareListing, GuestListener.FileFailure> {
        await withCheckedContinuation { continuation in
            listener.listSoftware(domain: domain.rawValue, cursor: cursor) {
                continuation.resume(returning: $0)
            }
        }
    }

    // MARK: - Rendering

    /// One `software.listing` as a projected page.
    ///
    /// Everything it can refuse, it refuses rather than repairing: a listing
    /// this side had to patch up is a listing nobody can quote.
    private func render(_ listing: SoftwareListing,
                        asked domain: AgentIntegrationSoftwareDomain)
        -> AgentIntegrationSoftwareInventoryResult {
        guard listing.domain == domain.rawValue else {
            /* Refused, not relabelled. A page carrying one domain's entries
               under another's name is worse than no page — and the guests echo
               the request's own domain verbatim, so this cannot happen without
               something having gone wrong that a caller must be told about. */
            return refused(
                "now-software-listing-invalid",
                "The paired guest answered a "
                    + bounded(listing.domain, scalars: 32)
                    + " listing to a \(domain.rawValue) request")
        }
        let cap = AgentIntegrationSoftwareInventoryBounds
            .maximumEntriesPerPage
        guard listing.entries.count <= cap else {
            /* Refused, not trimmed. Trimming would hand a caller ten entries
               out of eleven under a `hasMore` that says the page is complete,
               which is the one failure a paginated answer must not be able to
               have. The bound is the contract's own `maxItems` and both
               guests' page buffer, so a complete answer can never hit it. */
            return refused(
                "now-software-listing-invalid",
                "The paired guest sent more than \(cap) entries in one "
                    + "software listing")
        }
        return .completed(.init(
            domain: domain,
            entries: listing.entries.map(Self.item),
            hasMore: listing.more,
            /* Carried as the guest sent it, including a `more` with no cursor.
               Inventing one would send the caller back to a page the guest
               never offered. */
            nextCursor: listing.cursor,
            /* The guest's sentence about the edges of its own answer, bounded
               and never rewritten. */
            note: listing.note.map {
                bounded($0, scalars: AgentIntegrationSoftwareInventoryBounds
                    .maximumNoteScalars)
            },
            observedAt: clock()))
    }

    /// One entry, bounded.
    ///
    /// **Every optional field stays optional through here**, and that is the
    /// whole of rule 4 on this row: NOW-68K omits `version` and `running`
    /// deliberately, so `nil` is carried as `nil`. A `""` version or a `false`
    /// running flag would be this side making a claim the machine never made —
    /// and the second would be indistinguishable from the truth on the guest
    /// that does look.
    ///
    /// `sizeK` of `-1` is likewise carried rather than mapped to absent: "we
    /// looked and could not read it" is a different fact from "we did not
    /// look", and absence here means the second.
    private static func item(_ entry: SoftwareEntry)
        -> AgentIntegrationSoftwareItem {
        let bounds = AgentIntegrationSoftwareInventoryBounds.self
        return .init(
            name: bounded(entry.name, scalars: bounds.maximumNameScalars),
            /* Empty is a real answer — the guest could not name the parent
               chain honestly — and is passed through as empty rather than
               dropped, because the item is still installed. */
            path: bounded(entry.path, scalars: bounds.maximumPathScalars),
            fileType: AgentIntegrationBoundedText.fourCC(entry.type),
            creator: AgentIntegrationBoundedText.fourCC(entry.creator),
            sizeK: entry.sizeK,
            disabled: entry.off,
            running: entry.running,
            version: entry.version.map {
                bounded($0, scalars: bounds.maximumVersionScalars)
            })
    }

    private func refused(_ code: String, _ message: String)
        -> AgentIntegrationSoftwareInventoryResult {
        .refused(.init(
            code: code,
            message: bounded(
                message,
                scalars: AgentIntegrationSoftwareInventoryBounds
                    .maximumRefusalScalars)))
    }

    private func bounded(_ value: String, scalars: Int) -> String {
        AgentIntegrationBoundedText.prefix(value, scalars: scalars)
    }

    private static func bounded(_ value: String, scalars: Int) -> String {
        AgentIntegrationBoundedText.prefix(value, scalars: scalars)
    }
}
