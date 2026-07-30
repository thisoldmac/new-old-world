import XCTest
@testable import Host
import NOWAgentIntegration

/// The PowerPC guest's shape: all eight fields filled.
///
/// File scope rather than a static on the test case, because it is a default
/// argument of the listing builder below and `Self` cannot be referenced from
/// one.
private let softwareInventoryFullEntry = SoftwareEntry(
    name: "SimpleText",
    path: "Macintosh HD:Applications:SimpleText",
    type: "APPL", creator: "ttxt", sizeK: 384, off: false,
    running: true, version: "1.4")

/// NOW-68K's shape: six fields, and the two costly ones ABSENT.
private let softwareInventorySparseEntry = SoftwareEntry(
    name: "TeachText",
    path: "Macintosh HD:TeachText",
    type: "APPL", creator: "ttxt", sizeK: 48, off: false,
    running: nil, version: nil)

/// The software listing's own coverage, aimed at the two things that are
/// genuinely this capability's: **absence is an answer**, and **a guest that
/// declares its own bound must have that sentence reach the caller.**
///
/// NOW-68K omits `version` and `running` deliberately — one resource-fork open
/// per entry, and a Process Manager walk per page — so this side is held to
/// carrying `nil` as `nil`. A `""` version would claim the file has an empty
/// version string, and a `false` running flag would claim the machine looked
/// and found the application idle; both are indistinguishable from the truth on
/// the guest that DOES look, which is precisely why the schema can never be
/// allowed to default them.
///
/// The wire is real: the listings below cross a socket through the codec and the
/// listener, so nothing here is a model parsing what it just built.
@MainActor
final class AgentIntegrationSoftwareInventoryTests: XCTestCase {
    // MARK: - Harness

    /// Answers each `software.list` with one scripted listing, echoing the
    /// request's id, and records the domains and cursors the host sent.
    @MainActor
    private final class Script {
        var pages: [SoftwareListing] = []
        private(set) var domains: [String] = []
        private(set) var cursors: [Int?] = []
        private var served = 0
        /// When set, the guest answers with an `error` carrying the request's
        /// id instead of a listing — how a guest says it does not implement
        /// the family at all.
        var refuseFamily: (code: String, message: String)?

        func install(on guest: FakeGuest) {
            guest.onMessage = { [weak self, weak guest] message in
                guard let self, let guest,
                      case .softwareList(let request) = message else {
                    return
                }
                domains.append(request.domain)
                cursors.append(request.cursor)
                if let refusal = refuseFamily {
                    try? guest.send(.error(ErrorMessage(
                        id: request.id, code: refusal.code,
                        message: refusal.message)))
                    return
                }
                let index = served
                served += 1
                guard index < pages.count else { return }
                var listing = pages[index]
                listing.id = request.id
                try? guest.send(.softwareListing(listing))
            }
        }
    }

    private func listing(
        domain: String = "apps",
        entries: [SoftwareEntry] = [softwareInventoryFullEntry],
        more: Bool = false,
        cursor: Int? = nil,
        note: String? = nil
    ) -> SoftwareListing {
        SoftwareListing(id: 0, domain: domain, entries: entries, more: more,
                        cursor: cursor, note: note)
    }

    private func page(
        domain: AgentIntegrationSoftwareDomain = .apps,
        cursor: Int? = nil,
        script: Script
    ) async throws -> AgentIntegrationSoftwareInventoryResult {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        script.install(on: guest)
        /* One stable id for the whole call: the adapter only compares the
           session before and after the wire, so what matters is that it does
           not change under it. */
        let session = UUID()
        let inventory = AgentIntegrationSoftwareInventory(
            listener: listener,
            currentSessionID: { session },
            clock: { Self.moment })
        return await inventory.page(domain: domain, cursor: cursor)
    }

    private static let moment = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Absence is an answer

    /// **The distinction rule 4 lives in.** The smaller guest sends six of the
    /// eight fields, and the two it omits must arrive absent — not defaulted.
    /// A `false` here would be a claim the machine never made.
    func testTheOmittedFieldsArriveAbsentAndNotDefaulted() async throws {
        let script = Script()
        script.pages = [listing(entries: [softwareInventorySparseEntry])]

        let result = try await page(script: script)

        guard case .completed(let page) = result else {
            return XCTFail("a guest that answered has completed: \(result)")
        }
        let entry = try XCTUnwrap(page.entries.first)
        XCTAssertNil(
            entry.version,
            "a guest that did not open the resource fork said nothing about "
                + "the version; \"\" would claim an empty version string")
        XCTAssertNil(
            entry.running,
            "a guest that did not walk the Process Manager said nothing "
                + "about running; false would claim it looked and found it "
                + "idle")
        /* The six it DID send survive, which is what makes the two above an
           omission rather than a dropped page. */
        XCTAssertEqual(entry.name, "TeachText")
        XCTAssertEqual(entry.path, "Macintosh HD:TeachText")
        XCTAssertEqual(entry.fileType, "APPL")
        XCTAssertEqual(entry.creator, "ttxt")
        XCTAssertEqual(entry.sizeK, 48)
        XCTAssertEqual(entry.disabled, false)
    }

    /// And the encoded answer omits the KEYS, rather than sending nulls a
    /// caller has to read as absence-by-another-spelling. A JSON `"version"`
    /// that is present at all is the thing the schema promised would not be.
    func testTheOmittedFieldsAreAbsentKeysInTheEncodedAnswer() async throws {
        let script = Script()
        script.pages = [listing(entries: [softwareInventorySparseEntry])]

        let result = try await page(script: script)
        let json = String(
            decoding: try JSONEncoder().encode(result), as: UTF8.self)

        XCTAssertFalse(json.contains("\"version\""),
                       "the version key is absent, not null: \(json)")
        XCTAssertFalse(json.contains("\"running\""),
                       "the running key is absent, not null: \(json)")
        XCTAssertTrue(json.contains("\"sizeK\":48"))
    }

    /// The other direction, which is what makes the test above a distinction
    /// rather than a blanket rule: the guest that DOES fill all eight has all
    /// eight carried.
    func testTheLargerGuestsEightFieldsAllSurvive() async throws {
        let script = Script()
        script.pages = [listing()]

        let result = try await page(script: script)

        guard case .completed(let page) = result else {
            return XCTFail("expected a completed listing: \(result)")
        }
        let entry = try XCTUnwrap(page.entries.first)
        XCTAssertEqual(entry.version, "1.4")
        XCTAssertEqual(entry.running, true)
    }

    /// `-1` is the guest saying it looked and could not read the forks. That
    /// is a different fact from absence, so it is carried rather than mapped.
    func testAnUnreadableSizeIsCarriedRatherThanMadeAbsent() async throws {
        let script = Script()
        var unreadable = softwareInventoryFullEntry
        unreadable.sizeK = -1
        script.pages = [listing(entries: [unreadable])]

        let result = try await page(script: script)

        guard case .completed(let page) = result else {
            return XCTFail("expected a completed listing: \(result)")
        }
        XCTAssertEqual(
            page.entries.first?.sizeK, -1,
            "\"we looked and could not read it\" is not \"we did not look\"")
    }

    /// An empty path is the guest saying it could not name the parent chain
    /// honestly. The item is still installed, so it is listed — empty and not
    /// dropped, and never filled in with a guess.
    func testAnUnnameablePathIsListedEmptyRatherThanDropped() async throws {
        let script = Script()
        var deep = softwareInventoryFullEntry
        deep.path = ""
        script.pages = [listing(entries: [deep])]

        let result = try await page(script: script)

        guard case .completed(let page) = result else {
            return XCTFail("expected a completed listing: \(result)")
        }
        XCTAssertEqual(page.entries.count, 1)
        XCTAssertEqual(page.entries.first?.path, "")
        XCTAssertEqual(page.entries.first?.name, "SimpleText")
    }

    // MARK: - A guest's own bound reaches the caller

    /// **The 48-application ceiling, in the guest's own words.** NOW-68K holds
    /// 48 FSSpecs and stops, and says so in `note`. An inventory that hides
    /// its own bound is worse than a short one, so the sentence is carried
    /// verbatim rather than parsed into a host field.
    func testTheGuestsTruncationSentenceReachesTheCallerVerbatim()
        async throws {
        /* The guest's literal, from now-guest-68k/src/software/n68_swlist.c
           :: n68_swlist_note_truncated. Quoted rather than paraphrased: if
           the guest rewords it, this test still passes and the CALLER still
           gets whatever it now says — which is the property being asserted. */
        let sentence = "the inventory stopped at this Mac's bound of 48 items"
        let script = Script()
        script.pages = [listing(note: sentence)]

        let result = try await page(script: script)

        guard case .completed(let page) = result else {
            return XCTFail("expected a completed listing: \(result)")
        }
        XCTAssertEqual(page.note, sentence)
    }

    /// **The `PBCatSearch` fallback, which makes an answer NARROWER rather
    /// than shorter.** A root-only walk cannot see an application in a folder,
    /// so this is the one note a caller most needs, and it is the same
    /// mechanism: the guest's sentence, untouched.
    func testTheRootOnlyFallbackSentenceReachesTheCallerVerbatim()
        async throws {
        let sentence = "PBCatSearch was unusable; only the volume root"
        let script = Script()
        script.pages = [listing(entries: [softwareInventorySparseEntry], note: sentence)]

        let result = try await page(script: script)

        guard case .completed(let page) = result else {
            return XCTFail("expected a completed listing: \(result)")
        }
        XCTAssertEqual(
            page.note, sentence,
            "a narrower answer must say it is narrower, in the guest's words")
    }

    /// The host's note bound is sized over both guests' note buffers, so it
    /// cannot be the thing that shortens a guest's declaration of its own
    /// bound. Both sentences above are well inside it; this pins the property
    /// rather than the two literals.
    func testTheNoteBoundCannotShortenEitherGuestsBoundSentence() {
        let cap = AgentIntegrationSoftwareInventoryBounds.maximumNoteScalars
        for sentence in [
            "the inventory stopped at this Mac's bound of 48 items",
            "PBCatSearch was unusable; only the volume root",
            "no such domain on this Mac",
            "inventory truncated at cache",
        ] {
            XCTAssertLessThanOrEqual(
                sentence.unicodeScalars.count, cap,
                "the host bound would clip a guest's own bound sentence")
        }
    }

    /// A note the guest did not send is an ABSENT key, not `""`. An empty
    /// string reads as "the guest had something to say about its edges and it
    /// was nothing", which is not a thing a machine can mean.
    func testNoNoteIsAbsentRatherThanEmpty() async throws {
        let script = Script()
        script.pages = [listing()]

        let result = try await page(script: script)

        guard case .completed(let page) = result else {
            return XCTFail("expected a completed listing: \(result)")
        }
        XCTAssertNil(page.note)
    }

    /// A domain a guest does not have is a COMPLETED call whose note says so —
    /// the machine answered. Refusing the call would tell a caller nothing
    /// reached the Macintosh, which is false.
    func testAnUnknownDomainIsACompletedCallCarryingTheGuestsNote()
        async throws {
        let script = Script()
        script.pages = [listing(domain: "startup", entries: [],
                                note: "no such domain on this Mac")]

        let result = try await page(domain: .startup, script: script)

        guard case .completed(let page) = result else {
            return XCTFail(
                "a guest that answered has completed the call: \(result)")
        }
        XCTAssertTrue(page.entries.isEmpty)
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(page.note, "no such domain on this Mac")
    }

    // MARK: - Paging

    /// One call is one page, and the guest's cursor reaches the caller — never
    /// a loop this side hides.
    func testOneCallIsOnePageAndTheCursorReachesTheCaller() async throws {
        let script = Script()
        script.pages = [
            listing(more: true, cursor: 11),
            listing(entries: [softwareInventorySparseEntry]),
        ]

        let result = try await page(script: script)

        guard case .completed(let page) = result else {
            return XCTFail("expected a completed listing: \(result)")
        }
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.nextCursor, 11)
        XCTAssertEqual(page.entries.count, 1,
                       "the adapter must not have fetched the second page")
        XCTAssertEqual(script.cursors, [nil])
    }

    /// The caller's cursor reaches the guest as sent, and an absent one stays
    /// absent — absent means "rebuild", which is a thing a caller may mean.
    func testTheCallersCursorReachesTheGuestUnchanged() async throws {
        let script = Script()
        script.pages = [listing(domain: "extensions")]

        _ = try await page(domain: .extensions, cursor: 21, script: script)

        XCTAssertEqual(script.domains, ["extensions"])
        XCTAssertEqual(script.cursors, [21])
    }

    /// `more` with no cursor is reported as the guest sent it. Inventing one
    /// would send the caller back to a page the guest never offered.
    func testMoreWithoutACursorIsReportedRatherThanRepaired() async throws {
        let script = Script()
        script.pages = [listing(more: true, cursor: nil)]

        let result = try await page(script: script)

        guard case .completed(let page) = result else {
            return XCTFail("expected a completed listing: \(result)")
        }
        XCTAssertTrue(page.hasMore)
        XCTAssertNil(page.nextCursor)
    }

    /// A page over the contract's own `maxItems` is REFUSED, not trimmed. Ten
    /// entries out of eleven under a `hasMore` that says the page is complete
    /// is the one failure a paginated answer must not be able to have.
    func testAnOversizedPageIsRefusedRatherThanTrimmed() async throws {
        let cap = AgentIntegrationSoftwareInventoryBounds
            .maximumEntriesPerPage
        let script = Script()
        script.pages = [listing(
            entries: (0...cap).map { index in
                var entry = softwareInventoryFullEntry
                entry.name = "App \(index)"
                entry.path = "Macintosh HD:App \(index)"
                return entry
            })]

        let result = try await page(script: script)

        guard case .refused(let failure) = result else {
            return XCTFail("an oversized page must be refused: \(result)")
        }
        XCTAssertEqual(failure.code, "now-software-listing-invalid")
        XCTAssertTrue(failure.message.contains("\(cap)"))
    }

    /// A listing labelled with a domain nobody asked for is refused rather
    /// than relabelled: a page of one domain's entries under another's name is
    /// worse than no page.
    func testAListingForAnotherDomainIsRefusedRatherThanRelabelled()
        async throws {
        let script = Script()
        script.pages = [listing(domain: "cdevs")]

        let result = try await page(domain: .apps, script: script)

        guard case .refused(let failure) = result else {
            return XCTFail("a mislabelled page must be refused: \(result)")
        }
        XCTAssertEqual(failure.code, "now-software-listing-invalid")
    }

    // MARK: - Nothing answered

    /// A guest that does not serve the family refuses the CALL, in its own
    /// words — and never as an empty listing, which would read as "nothing is
    /// installed on that Mac".
    func testAGuestThatDoesNotServeTheFamilyRefusesTheCall() async throws {
        let script = Script()
        script.refuseFamily = (code: "not-implemented",
                               message: "unsupported message type")

        let result = try await page(script: script)

        guard case .refused(let failure) = result else {
            return XCTFail("expected a refused call: \(result)")
        }
        XCTAssertEqual(failure.code, "now-software-refused")
        XCTAssertEqual(failure.message, "unsupported message type")
    }

    /// No paired guest is `unavailable` rather than `refused`: nothing was
    /// asked, so nothing about any machine can be reported.
    func testADisconnectedGuestIsUnavailableRatherThanRefused() async {
        let listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"),
            timing: .init(idleTimeout: 60))
        let inventory = AgentIntegrationSoftwareInventory(
            listener: listener, currentSessionID: { nil })

        let result = await inventory.page(domain: .apps, cursor: nil)

        guard case .unavailable = result else {
            return XCTFail("expected unavailable: \(result)")
        }
    }

    /// The cursor floor is read at the adapter too, for a caller that reached
    /// it directly — and it is 1, not 0.
    func testTheAdapterRefusesACursorBelowItsFloor() async throws {
        let script = Script()
        script.pages = [listing()]

        let result = try await page(cursor: 0, script: script)

        guard case .refused(let failure) = result else {
            return XCTFail("expected a refused call: \(result)")
        }
        XCTAssertEqual(failure.code, "now-software-cursor-invalid")
        XCTAssertTrue(script.domains.isEmpty,
                      "a refused cursor must not reach the machine")
    }

    // MARK: - The projection's own bound

    /// The domain is required, is one of the contract's five, and the cursor —
    /// unlike the census's — has a floor of 1 rather than 0.
    func testTheProjectionRequiresAKnownDomainAndAWholeCursor() async {
        let refused: [Any?] = [
            nil,
            [String: Any](),
            ["cursor": 1],
            ["domain": ""],
            ["domain": "APPS"],
            ["domain": "fonts"],
            ["domain": "apps", "extra": 1],
            ["domain": "apps", "cursor": 0],
            ["domain": "apps", "cursor": -1],
            ["domain": "apps", "cursor": "2"],
            ["domain": "apps", "cursor": true],
        ]
        for raw in refused {
            let outcome = await SoftwareInventoryProjection.invoke(
                .init(raw: raw), through: SoftwareInventoryStubHost())
            guard case .invalidArguments(let message) = outcome else {
                return XCTFail(
                    "accepted \(String(describing: raw)) as an inventory ask")
            }
            XCTAssertEqual(
                message, SoftwareInventoryProjection.argumentRefusal)
        }
    }

    /// Every declared domain is accepted, so the closed enum in the schema is
    /// the same set the projection will actually take.
    func testEveryDeclaredDomainIsAccepted() async {
        for domain in AgentIntegrationSoftwareDomain.allCases {
            let host = SoftwareInventoryStubHost()
            let outcome = await SoftwareInventoryProjection.invoke(
                .init(raw: ["domain": domain.rawValue]), through: host)
            guard case .value = outcome else {
                return XCTFail("\(domain.rawValue) should reach the host")
            }
            let asked = await host.asked
            XCTAssertEqual(asked.map(\.domain), [domain])
        }
    }

    /// The ask reaches the host verbatim and the answer is rendered rather
    /// than re-decided.
    func testTheAskReachesTheHostVerbatimAndTheAnswerSurvives() async throws {
        let host = SoftwareInventoryStubHost()
        let outcome = await SoftwareInventoryProjection.invoke(
            .init(raw: ["domain": "extensions", "cursor": 11]), through: host)

        guard case .value(let value) = outcome else {
            return XCTFail("a known domain should reach the host")
        }
        let asked = await host.asked
        XCTAssertEqual(asked.map(\.domain), [.extensions])
        XCTAssertEqual(asked.map(\.cursor), [11])
        let json = String(
            decoding: try value.encoded(using: JSONEncoder()), as: UTF8.self)
        XCTAssertTrue(json.contains("\"outcome\":\"completed\""))
        XCTAssertTrue(json.contains("\"domain\":\"extensions\""))
        XCTAssertNil(
            value.attachment,
            "This row answers in JSON; only capture attaches anything.")
    }

    /// An omitted cursor is omitted all the way down. It is not sent as 1: the
    /// two mean the same thing to the guest, and sending a number the caller
    /// did not choose is how a default becomes a claim.
    func testAnOmittedCursorReachesTheHostAsAbsent() async {
        let host = SoftwareInventoryStubHost()
        _ = await SoftwareInventoryProjection.invoke(
            .init(raw: ["domain": "apps"]), through: host)
        let asked = await host.asked
        XCTAssertEqual(asked.count, 1)
        XCTAssertNil(asked.first?.cursor)
    }

    // MARK: - What the row declares

    /// **The requirement is the FAMILY and never a domain name.** A domain is
    /// an argument, and the ledger can resolve neither a family nor a domain
    /// out of the guest's `help` table — so requiring "apps" would switch this
    /// tool off against every guest for the life of every connection.
    func testTheRowRequiresTheFamilyAndNotADomain() {
        XCTAssertEqual(
            SoftwareInventoryProjection.requires,
            [AgentIntegrationCapabilityNames.softwareList])
        XCTAssertEqual(
            SoftwareInventoryProjection.exposes,
            [AgentIntegrationCapabilityNames.softwareList],
            "this row is the one that closes the gap `exposes` found, so it "
                + "exposes what launch only consumes")
        for domain in AgentIntegrationSoftwareDomain.allCases {
            XCTAssertFalse(
                SoftwareInventoryProjection.requires.contains(domain.rawValue),
                "\(domain.rawValue) is an argument of this row, not a "
                    + "requirement of it")
        }
    }

    /// The ledger row the family owes, and its cost policy read as a policy
    /// rather than as an accident. `MCPCoverageTests` gates the row's
    /// existence; asserting the second column here is what makes the cost
    /// decision visible beside the capability that pays it.
    func testTheFamilyHasALedgerRowThatStillGatesTheCostlyProbe() {
        let row = AgentIntegrationCapabilityLedger.familyPolicy.first {
            $0.family == AgentIntegrationCapabilityNames.softwareList
        }
        let policy = try? XCTUnwrap(row)
        XCTAssertEqual(
            policy?.unobserved, .notProbedCostly,
            "the first apps page is a whole-volume sweep, so the LEDGER does "
                + "not spend it to answer a question nobody asked")
        XCTAssertEqual(
            policy?.probedOnRequest, true,
            "probeCostly is the opt-in, and it stays on the ledger rather "
                + "than becoming a flag on this tool: a caller of this tool "
                + "asked for the inventory, which is what the sweep is")
    }

    /// The app UI reaches this capability by an affordance that predates the
    /// row — the domain picker and Refresh — so rule 3 cost it no new button.
    /// `HostFaceParityTests` checks the file and the symbol; this pins the
    /// claim beside the capability.
    func testTheAppUIFaceIsTheInventoryTheSoftwarePageAlreadyPages() {
        guard case .reached(let file, let symbol)? =
            SoftwareInventoryProjection.faces[.appUI] else {
            return XCTFail("the Software page reaches this capability")
        }
        XCTAssertEqual(file, "SoftwareModuleView.swift")
        XCTAssertEqual(symbol, "model.refresh()")
    }
}

/// Answers one software page and records what it was asked. Everything else
/// says "no host", which is what the protocol's defaults are for.
private actor SoftwareInventoryStubHost: AgentIntegrationClient {
    private(set) var asked:
        [(domain: AgentIntegrationSoftwareDomain, cursor: Int?)] = []

    func softwareInventory(
        domain: AgentIntegrationSoftwareDomain, cursor: Int?
    ) async -> AgentIntegrationSoftwareInventoryResult {
        asked.append((domain: domain, cursor: cursor))
        return .completed(.init(
            domain: domain,
            /* The smaller guest's shape, so the encode assertion above is
               over an answer with two absent fields rather than eight full
               ones. */
            entries: [.init(name: "TeachText",
                            path: "Macintosh HD:TeachText",
                            fileType: "APPL", creator: "ttxt",
                            sizeK: 48, disabled: false)],
            hasMore: false,
            nextCursor: nil,
            note: nil,
            observedAt: Self.moment))
    }

    /// Fixed so an encode round trip cannot drift on sub-second precision.
    private static let moment = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Everything else answers "no host"

    func sessionHealth() async -> AgentIntegrationSessionHealthResult {
        .unavailable(.host)
    }

    func sessionCapabilities(probeCostly: Bool) async
        -> AgentIntegrationSessionCapabilitiesResult {
        .unavailable(.host)
    }

    func listProcesses() async -> AgentIntegrationProcessListResult {
        .unavailable(.host)
    }

    func launchSoftware(_ selection: AgentIntegrationLaunchSelection) async
        -> AgentIntegrationLaunchSoftwareResult {
        .unavailable(.host)
    }

    func requestQuit(reference: String) async
        -> AgentIntegrationQuitResult {
        .unavailable(.host)
    }

    func transferApprovedArtifact(receipt: String) async
        -> AgentIntegrationArtifactTransferResult {
        .unavailable(.host)
    }

    func guestFilesCapabilities() async
        -> AgentIntegrationGuestFileCapabilitiesResult {
        .hostUnavailable(.host)
    }

    func listGuestFiles(path: String, cursor: Int?) async
        -> AgentIntegrationGuestFileListResult {
        .hostUnavailable(.host)
    }

    func statGuestFile(path: String) async
        -> AgentIntegrationGuestFileStatResult {
        .hostUnavailable(.host)
    }
}
