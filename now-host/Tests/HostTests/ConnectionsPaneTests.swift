import AppKit
import XCTest
import NOWAgentIntegration
@testable import Host

/// **The link and who is on it are one page.**
///
/// They were two sidebar rows: "Connections" in the list (the roster of
/// machines) and "Connection" in the footer (the port and the state of the
/// link). Neither half stood up alone — the roster explained an empty page
/// by naming the port, and the link page explained the port by describing a
/// machine that would dial into it — and a person reading the sidebar had no
/// way to tell which of the two nearly-identically-named rows they wanted.
///
/// These guards are about the fold surviving: one row, in the footer, with
/// the link dot; one headline answering both halves in every state the link
/// can be in; and a saved selection of the retired id still landing on it.
@MainActor
final class ConnectionsPaneTests: XCTestCase {

    // MARK: - One row, not two

    /// The defect in one assertion: there is no longer a second module about
    /// connections. Restore the list descriptor and this fails naming it.
    func testTheSidebarHasOneConnectionsRow() {
        let registry = ModuleRegistry.standard
        XCTAssertNil(registry.module(id: "connections"),
                     "the roster pane folded into the link pane; a second "
                     + "descriptor here is the split coming back")

        let about = registry.modules.filter {
            $0.title.lowercased().hasPrefix("connection")
        }
        XCTAssertEqual(about.map(\.id), ["settings"],
                       "exactly one module is named for the connection")
    }

    /// The survivor is the footer one, and it keeps the live link dot: the
    /// footer exists for the state of the link, and the roster came down to
    /// it rather than the link going up into the list.
    func testTheSurvivorKeepsTheFooterPlacementAndTheLinkDot() throws {
        let module = try XCTUnwrap(ModuleRegistry.standard
            .module(id: "settings"))
        XCTAssertEqual(module.placement, .footer)
        XCTAssertTrue(module.showsLinkStatus)
        XCTAssertEqual(ModuleRegistry.standard.modules
            .filter(\.showsLinkStatus).count, 1,
            "one module IS the link; the rest show their summary")
    }

    /// The summary has to promise both halves, or the sidebar sends a person
    /// looking for the roster somewhere else.
    func testTheSummaryPromisesBothHalves() throws {
        let summary = try XCTUnwrap(ModuleRegistry.standard
            .module(id: "settings")?.summary)
        XCTAssertTrue(summary.contains("port"),
                      "this side of the link: \(summary)")
        XCTAssertTrue(summary.contains(MachineNaming.properNounPlural),
                      "who is on it: \(summary)")
    }

    /// Return and the visible button must share one action. Updating only
    /// the port is not submission: the requested keyboard path also starts
    /// the listener.
    func testSubmittingThePortStartsListeningThroughTheButtonAction()
        throws {
        let source = try GateSource.hostSwift(
            "now-host/Sources/Host/ConnectionLinkSection.swift")
        XCTAssertTrue(source.contains(".onSubmit(startListening)"))
        XCTAssertTrue(source.contains(
            "Button(\"Start Listening\", action: startListening)"))
    }

    func testPortSubmissionValidatesAndStartsExactlyOnce() throws {
        let suite = "ConnectionsPaneTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsModel(defaults: defaults)
        var starts = 0

        XCTAssertTrue(settings.submitListenPort("5400") { starts += 1 })
        XCTAssertEqual(settings.listenPort, 5400)
        XCTAssertEqual(starts, 1)

        for invalid in ["", "0", "70000", "not-a-port"] {
            XCTAssertFalse(settings.submitListenPort(invalid) { starts += 1 },
                           invalid)
        }
        XCTAssertEqual(settings.listenPort, 5400)
        XCTAssertEqual(starts, 1,
                       "invalid Return must not start on the old port")
    }

    func testConnectionRowsExposeNativeRenameAndContextActions() throws {
        let source = try GateSource.hostSwift(
            "now-host/Sources/Host/ConnectionsModuleView.swift")
        XCTAssertTrue(source.contains("Image(systemName: \"pencil\")"))
        XCTAssertTrue(source.contains(".contextMenu"))
        XCTAssertTrue(source.contains("Button(\"Rename…\""))
        XCTAssertTrue(source.contains("Button(\"Delete\""))
        XCTAssertTrue(source.contains("Button(\"Start Listening\""))
        XCTAssertTrue(source.contains("Button(\"Stop Listening\""))
    }

    /// The boundary moved into the link card with the port it is about; it
    /// is still the app's statement of what this listener is safe for, so
    /// it is checked where it now lives rather than dropped.
    func testTheListenerStatesItsTrustedLANBoundaryInTheApp() throws {
        let source = try GateSource.hostSwift(
            "now-host/Sources/Host/ConnectionLinkSection.swift")
        XCTAssertTrue(source.contains("Trusted LAN only"))
        XCTAssertTrue(source.contains("plaintext"))
        XCTAssertTrue(source.contains("no peer authentication"))
        XCTAssertTrue(source.contains("do not expose this port"))
    }

    func testLocalNetworkPermissionHasRequestAndSystemSettingsDoors()
        throws {
        let source = try GateSource.hostSwift(
            "now-host/Sources/Host/ConnectionsModuleView.swift")
        XCTAssertTrue(source.contains("Button(\"Request Access\")"))
        XCTAssertTrue(source.contains("controller.request()"))
        XCTAssertTrue(source.contains(
            "controller.verifyDirectAccess(to: targetHost)"))
        XCTAssertTrue(source.contains("Button(\"Open Settings…\""))
        XCTAssertTrue(source.contains("Privacy_LocalNetwork"))
        XCTAssertTrue(source.contains("app-owned macOS request"))
        XCTAssertTrue(source.contains("connected Mac directly"))
        XCTAssertTrue(source.contains("denied earlier"))
    }

    // MARK: - The roster is a collapsible right sidebar, shared with Files

    /// **One collapsible right sidebar in this app, with two consumers.**
    ///
    /// The roster moved from a left `HSplitView` column to the trailing
    /// side of the same AppKit component Files uses for This Mac. The
    /// failure this guards is not the move but the copy: a
    /// Connections-local reimplementation would look identical in a
    /// screenshot and behave differently at every edge (hover peek, the
    /// native divider's hit slop, the rail winning over hosted minimum
    /// widths). So both call sites are asserted, in one test — if either
    /// stops consuming the shared component, this names it.
    func testTheRosterUsesTheSharedRightSidebarAndSoDoesFiles() throws {
        let connections = try GateSource.hostSwift(
            "now-host/Sources/Host/ConnectionsModuleView.swift")
        let files = try GateSource.hostSwift(
            "now-host/Sources/Host/FilesWorkspaceShell.swift")

        XCTAssertTrue(Self.calls("RightSidebarSplitView", in: connections),
                      "the roster must sit in the shared split component")
        XCTAssertTrue(connections.contains("leading: detail"),
                      "the selected machine is the page")
        XCTAssertTrue(connections.contains("trailing: connectionList"),
                      "the roster is the collapsible trailing side")
        XCTAssertTrue(Self.calls("RightSidebarToggle", in: connections),
                      "the expanded page owns a control to put it away")
        XCTAssertTrue(Self.calls("RightSidebarSplitView", in: files),
                      "extraction is only worth it while Files still "
                      + "consumes the extracted component")
    }

    /// **The toggle lives in the sidebar it collapses, not beside it.**
    ///
    /// It used to sit in the leading `detail` pane's header, next to the
    /// "Connections" title — functional, but the roster it puts away had
    /// no control of its own, unlike Files' "This Mac" sidebar, which owns
    /// its `RightSidebarToggle` inside its own chrome
    /// (`FilesWorkspaceShell.swift`'s `titleAccessory`). This pins the
    /// toggle to `connectionList`'s own body, and pins it OUT of
    /// `header`'s — a placement regression reads as green on the previous
    /// test (which only checks the toggle exists somewhere) but fails
    /// here.
    func testTheRosterToggleLivesInTheRosterHeaderNotTheDetailHeader()
        throws {
        let connections = try GateSource.hostSwift(
            "now-host/Sources/Host/ConnectionsModuleView.swift")

        guard let listRange = connections.range(
            of: "private var connectionList: some View {"),
            let headerRange = connections.range(
                of: "private var header: some View {")
        else {
            XCTFail("expected both connectionList and header properties")
            return
        }

        // `connectionList` is declared before `header` in this file;
        // the toggle must fall within connectionList's body, i.e.
        // between the two declarations.
        let listBody = connections[listRange.upperBound..<headerRange
            .lowerBound]
        XCTAssertTrue(Self.calls("RightSidebarToggle", in: String(listBody)),
                      "the roster pane must own its own toggle")

        // header's body runs from its declaration to the next `private var`
        // (detailHeadline); the toggle must NOT be back in there.
        guard let afterHeader = connections.range(
            of: "private var detailHeadline",
            range: headerRange.upperBound..<connections.endIndex)
        else {
            XCTFail("expected detailHeadline to follow header")
            return
        }
        let headerBody = connections[headerRange.upperBound..<afterHeader
            .lowerBound]
        XCTAssertFalse(
            Self.calls("RightSidebarToggle", in: String(headerBody)),
            "the detail header must not duplicate the roster's toggle")
    }

    /// Whether this source calls that type, as opposed to merely containing
    /// its name.
    ///
    /// A plain `contains` was the first version and it passed the mutation
    /// it was written for: `FilesLocalRightSidebarSplitView(` — a forked
    /// alias, which is precisely the drift this guard exists to catch —
    /// contains `RightSidebarSplitView(` as a substring. The boundary is
    /// the whole assertion.
    private static func calls(_ type: String, in source: String) -> Bool {
        let token = type + "("
        var searched = source[...]
        while let found = searched.range(of: token) {
            let precededByName = found.lowerBound > source.startIndex
                && (source[source.index(before: found.lowerBound)]
                    .isLetter
                    || source[source.index(before: found.lowerBound)]
                        .isNumber
                    || source[source.index(before: found.lowerBound)] == "_")
            if !precededByName { return true }
            searched = source[found.upperBound...]
        }
        return false
    }

    /// The collapsed rail and both toggles must name the surface the
    /// consumer named, not the one the component was written for.
    func testTheRailAndToggleCarryTheConsumersOwnNoun() {
        let rail = RightSidebarRailView(
            frame: NSRect(x: 0, y: 0, width: 54, height: 400))
        rail.title = ConnectionsModuleView.rosterTitle

        XCTAssertEqual(rail.accessibilityLabel(), "Show Machines")
        XCTAssertEqual(rail.toolTip, "Show Machines")
        XCTAssertNotEqual(rail.toolTip, "Show This Mac",
                          "a second consumer must not inherit Files' noun")

        let controller = RightSidebarSplitController()
        _ = controller.install(leading: NSViewController(),
                               trailing: NSViewController(),
                               trailingCollapsed: true,
                               trailingTitle: "Machines")
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        controller.view.layoutSubtreeIfNeeded()
        let installed = controller.splitViewItems[1].viewController.view
            .subviews.compactMap { $0 as? RightSidebarRailView }.first
        XCTAssertEqual(installed?.toolTip, "Show Machines",
                       "install must hand the rail the consumer's noun")
    }

    /// **Collapsed stays collapsed across launches — and only that.**
    ///
    /// Files persists the collapse and leaves the divider position to the
    /// session; this follows it rather than inventing a second policy. A
    /// second model reading the same defaults is the launch.
    func testCollapsingTheRosterSurvivesRelaunchAndDefaultsToShown() throws {
        let suite = "ConnectionsPaneTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"))

        let first = ConnectionsModel(listener: listener, resolve: { _ in nil },
                                     defaults: defaults)
        XCTAssertFalse(first.rosterCollapsed,
                       "a page nobody has put away shows its roster")
        first.rosterCollapsed = true

        let relaunched = ConnectionsModel(listener: listener,
                                          resolve: { _ in nil },
                                          defaults: defaults)
        XCTAssertTrue(relaunched.rosterCollapsed,
                      "a person who put the roster away meant it")
        XCTAssertNil(defaults.object(forKey: "connections.leadingFraction"),
                     "the divider position is a session, not a decision")
    }

    /// The listener log was written twice on this page — once filtered to
    /// the selected machine's sessions and once unfiltered — in two
    /// branches of the same `if`. One call site with a nil-able filter is
    /// the same behaviour and one place to be wrong.
    func testTheListenerLogHasExactlyOneCallSite() throws {
        let source = try GateSource.hostSwift(
            "now-host/Sources/Host/ConnectionsModuleView.swift")
        let sites = source.components(
            separatedBy: "ConnectionListenerLog(").count - 1
        XCTAssertEqual(sites, 1,
                       "two copies of the log are one edit from drifting")
    }

    // MARK: - The retired id still resolves

    /// **A saved selection of the retired id lands on the merged page.**
    ///
    /// The selection is persisted by id. Somebody last looking at
    /// "connections" has that word in their preferences, and without a
    /// forwarding entry it resolves to nothing and the next launch drops
    /// them on the first module — which reads as the app forgetting them
    /// rather than as two pages becoming one.
    func testASavedSelectionOfTheRetiredIDLandsOnTheMergedPage() {
        XCTAssertEqual(ModuleRegistry.standard
            .resolvingRenames(id: "connections")?.id, "settings")
        XCTAssertEqual(ModuleRegistry.standard
            .resolvingRenames(id: "connections")?.title, "Connections")
    }

    /// The forwarding table is shared, and entries land in it from separate
    /// pieces of work. Every entry has to point at a module that exists and
    /// away from an id nothing still claims — checked for all of them, so
    /// one arriving beside another cannot quietly invalidate either.
    func testEveryForwardingEntryResolvesIncludingTheOnesAddedBeside() {
        XCTAssertFalse(ModuleRegistry.renamedIDs.isEmpty)
        for (old, new) in ModuleRegistry.renamedIDs {
            XCTAssertNil(ModuleRegistry.standard.module(id: old),
                         "\(old) was retired, so nothing may still claim it")
            XCTAssertNotNil(ModuleRegistry.standard.module(id: new),
                            "\(old) forwards to \(new), which must exist")
        }
    }

    // MARK: - One headline for every state the link can be in

    /// **The page's whole state matrix, in the one line that carries it.**
    ///
    /// Both panes used to draw a status line and the two were worded
    /// differently — the roster said how many machines, the link pane said
    /// whether the socket was up, and neither said both. The merged page has
    /// one, so it has to answer both halves in all four states.
    func testTheHeadlineAnswersBothHalvesInEveryState() {
        let notListening = snapshot(state: .idle, guests: [])
        XCTAssertEqual(notListening.headline, "Not listening")
        XCTAssertTrue(notListening.isIdle)

        let waiting = snapshot(state: .listening(port: 5250), guests: [])
        XCTAssertEqual(waiting.headline,
                       "Listening on 5250 — no guest connected",
                       "the port AND the emptiness, in one line")
        XCTAssertTrue(waiting.isIdle)

        let one = snapshot(state: .connected(guestName: "NOW 0.14"),
                           guests: [guest("pb1400c", active: true)])
        XCTAssertEqual(one.headline, "1 guest connected")
        XCTAssertNil(one.headline.range(of: "driving"),
                     "one machine is not a choice, so naming the driven one "
                     + "would dress it up as one")

        let several = snapshot(
            state: .connected(guestName: "NOW 0.14"),
            guests: [guest("q950"), guest("pb1400c", active: true, at: 5)])
        XCTAssertEqual(several.headline,
                       "2 guests connected — driving pb1400c",
                       "with a choice, the line says which way it went")
        XCTAssertEqual(several.driving?.machineID, "pb1400c")
    }

    /// The one word the merged page may not use for the machines it lists.
    ///
    /// This is the page that lists several machines, read from a Mac, so
    /// "no Mac connected" and "2 Macs connected" each had two readings and
    /// the wrong one was the alarming one. `MachineNaming` exists so the
    /// choice is a position rather than a phrase; this guard is what stops
    /// the phrase drifting back in.
    func testNoHeadlineCallsTheDrivenMachineAMac() {
        let lines = [
            snapshot(state: .listening(port: 5250), guests: []).headline,
            snapshot(state: .connected(guestName: "NOW 0.14"),
                     guests: []).headline,
            snapshot(state: .connected(guestName: "NOW 0.14"),
                     guests: [guest("pb1400c", active: true)]).headline,
            snapshot(state: .connected(guestName: "NOW 0.14"),
                     guests: [guest("q950"),
                              guest("pb1400c", active: true, at: 5)]).headline,
        ]
        for line in lines {
            XCTAssertFalse(line.contains("Mac connected"),
                           "\"\(line)\" names the wrong machine")
            XCTAssertFalse(line.contains("Macs connected"),
                           "\"\(line)\" names the wrong machine")
        }
    }

    // MARK: - Multi-guest, on the merged page

    /// Switching which machine is driven still moves the whole host through
    /// the one seam, and the page's headline follows it — the fold changed
    /// where the roster is drawn, not what choosing a row does.
    func testDrivingAnotherMachineStillMovesTheHostAndTheHeadline() {
        let listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"))
        var asked: [GuestKey] = []
        let model = ConnectionsModel(
            listener: listener,
            resolve: { _ in nil },
            select: { key in asked.append(key); return true })

        let before = snapshot(
            state: .connected(guestName: "NOW 0.14"),
            guests: [guest("pb1400c", active: true), guest("q950", at: 5)])
        XCTAssertEqual(before.headline,
                       "2 guests connected — driving pb1400c")

        let other = before.rows.first { $0.machineID == "q950" }!
        XCTAssertTrue(model.drive(other))
        XCTAssertEqual(asked, [GuestKey.synthetic("q950")])

        let after = snapshot(
            state: .connected(guestName: "NOW 0.14"),
            guests: [guest("pb1400c", at: 5), guest("q950", active: true)])
        XCTAssertEqual(after.headline,
                       "2 guests connected — driving q950")
    }

    /// A machine arriving or leaving while the page is open moves it between
    /// the roster and Remembered without either half of the page going
    /// stale: the link section is still the same link, and the headline
    /// re-answers who is on it.
    func testAMachineArrivingAndLeavingMovesBetweenTheHalves() throws {
        let empty = snapshot(state: .listening(port: 5250), guests: [],
                             known: [record("pb1400c")])
        XCTAssertTrue(empty.isIdle)
        XCTAssertEqual(empty.known.map(\.machineID), ["pb1400c"])
        XCTAssertTrue(empty.connected.isEmpty)

        let arrived = snapshot(state: .connected(guestName: "NOW 0.14"),
                               guests: [guest("pb1400c", active: true)],
                               known: [record("pb1400c")])
        XCTAssertFalse(arrived.isIdle)
        XCTAssertTrue(arrived.known.isEmpty,
                      "a remembered row never shadows the live machine")
        XCTAssertEqual(arrived.headline, "1 guest connected")

        let left = snapshot(state: .listening(port: 5250), guests: [],
                            known: [record("pb1400c")])
        XCTAssertEqual(left.headline,
                       "Listening on 5250 — no guest connected",
                       "a machine that left leaves the link up, not broken")
        XCTAssertEqual(try XCTUnwrap(left.known.first).presence, .known)
    }

    // MARK: - Fixtures

    private func snapshot(state: GuestListener.State,
                          guests: [ConnectedGuest],
                          known: [GuestRegistry.Record] = [])
        -> ConnectionsSnapshot {
        ConnectionsSnapshot.make(state: state, guests: guests, known: known,
                                 ended: [:], resolve: { _ in nil })
    }

    private func guest(_ id: String,
                       active: Bool = false,
                       at seconds: TimeInterval = 0) -> ConnectedGuest {
        ConnectedGuest(
            key: GuestKey.synthetic(id),
            id: GuestID(id)!,
            idIsAutoAssigned: false,
            idIsAnchored: true,
            name: "NOW 0.14",
            displayName: id,
            address: GuestAddress(text: "10.91.5.34"),
            version: "0.14",
            build: "b12",
            agentAccess: .readOnly,
            operatingSystem: "9.1",
            connectedAt: Date(timeIntervalSince1970: 1_000 + seconds),
            isActive: active)
    }

    private func record(_ id: String) -> GuestRegistry.Record {
        GuestRegistry.Record(
            id: GuestID(id)!, address: "10.91.5.34",
            fingerprint: "now|9.1", slot: 0, autoAssigned: false,
            lastSeen: Date(timeIntervalSince1970: 500),
            lastName: "NOW 0.13", displayName: id)
    }
}
