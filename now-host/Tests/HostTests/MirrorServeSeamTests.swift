import XCTest
import MirrorKit
@testable import Host

/// **`serve`'s wiring, tested at its own level for the first time.**
///
/// Every fix to the plan-to-command translation used to be verified one
/// level below where it lives — `finderScript(activate:)` had a test,
/// and the CALL SITE passing `activate: !ownApp` had none, so a mutation
/// reinstating the exact Finder-activate defect it fixes left nine tests
/// green (2026-08-05, plan 011 § F). The `GuestCommandSend` seam is the
/// closure these tests hold: the command a plan became is read here,
/// verbatim, at the door it would have left through.
@MainActor
final class MirrorServeSeamTests: XCTestCase {

    /// One captured command: what `serve` composed, and the completion the
    /// test answers when it chooses — which is also how a later test wedges
    /// the lane on purpose.
    @MainActor
    private final class SentCommands {
        struct Sent {
            var verb: String
            var args: [String: CommandArg]?
            var completion: (CommandResult) -> Void
        }
        var all: [Sent] = []
        var seam: GuestCommandSend {
            { [self] verb, args, completion in
                all.append(.init(verb: verb, args: args,
                                 completion: completion))
            }
        }
        func scriptSource(_ index: Int) -> String? {
            guard case .text(let source)? = all[index].args?["source"] else {
                return nil
            }
            return source
        }
    }

    /// The identified fixture with a desktop roster stamped on, because a
    /// `finderOpen`'s activate decision reads the item's TYPE from the
    /// published desktop items — an unread desktop classifies nothing and
    /// always takes the activate branch.
    private func documentWithDesktopItems(seq: Int) throws -> Data {
        var scene = try XCTUnwrap(JSONSerialization.jsonObject(
            with: identifiedSceneDocument(seq: seq)) as? [String: Any])
        scene["desktopItems"] = [
            ["name": "Date & Time", "kind": "file", "type": "cdev",
             "creator": "time", "x": 40, "y": 40, "placed": true,
             "alias": false, "invisible": false],
            ["name": "Projects", "kind": "folder",
             "x": 40, "y": 90, "placed": true,
             "alias": false, "invisible": false],
        ]
        return try JSONSerialization.data(withJSONObject: scene)
    }

    /// A source over a connected listener whose act band leaves through
    /// the seam, with one identified scene already displayed.
    private func sourceWithSeam(
        _ sent: SentCommands
    ) async throws -> (NOWMirrorSource, MirrorCycleHarness,
                       GuestListener, FakeGuest) {
        let (listener, guest) = try await connectedListener()
        try await waitUntil("the guest is the active Mac") {
            listener.activeKey != nil
        }
        let key = try XCTUnwrap(listener.activeKey)
        let harness = MirrorCycleHarness(activeKey: key)
        let session = UUID()
        let act = AgentIntegrationActControl(
            listener: listener, currentSessionID: { session },
            sendCommand: sent.seam)
        let source = NOWMirrorSource(
            listener: listener, engineRegistry: MirrorStateEngineRegistry(),
            act: act, interval: 3_600,
            finderRefreshOverride: { _, _, completion in completion() },
            visibilityRefreshOverride: { _, _, completion in completion() },
            cycleIO: harness.io,
            sendCommand: sent.seam)
        source.start()
        harness.completeScene(0, with: .success(sceneDelivery(
            try documentWithDesktopItems(seq: 1), seq: 1, for: key)))
        harness.completeJoin(0)
        return (source, harness, listener, guest)
    }

    private func doubleClick(_ item: String) -> Interaction {
        .init(object: .finderItem(.init(name: item, container: nil,
                                        point: .init(x: 40, y: 40))),
              gesture: .click(count: 2, mods: 0, at: .init(x: 40, y: 40)))
    }

    /// **The mutation this file exists to catch.** `serve` must pass
    /// `activate: !ownApp` — a control panel opens as its OWN application,
    /// and a script that activates the Finder afterwards pushes the panel
    /// that just opened behind it (measured 2026-08-05: control panels
    /// "open quickly, but still immediately push them behind Finder").
    /// Reinstating `activate: true` at the call site must fail HERE.
    func testOpeningAControlPanelLeavesTheFinderBehindIt() async throws {
        let sent = SentCommands()
        let (source, _, listener, guest) = try await sourceWithSeam(sent)
        defer { guest.connection.cancel(); listener.stop() }

        XCTAssertEqual(source.scene?.desktopItems?.count, 2,
                       "the roster must survive delivery, or the activate "
                           + "decision below is about an unread desktop")

        source.perform(doubleClick("Date & Time"))
        try await waitUntil("the open reaches the seam") {
            sent.all.contains { $0.verb == "script" }
        }

        let script = try XCTUnwrap(sent.scriptSource(0))
        XCTAssertTrue(script.contains(
            "open item \"Date & Time\" of desktop"), script)
        XCTAssertFalse(script.contains("activate"),
                       "a cdev opens as its own application and must stay "
                           + "in front; this script would cover it with "
                           + "the Finder: \(script)")
    }

    /// The other half of the same call site: a folder open makes a FINDER
    /// window, and a selection nobody can see is not a selection — the
    /// Finder must come forward for it.
    /// **Clearing a selection must not front the Finder.**
    ///
    /// A select fronting the Finder is decided behaviour — "a selection
    /// nobody can see is not a selection" — but a DESELECT has nothing to
    /// show, and it inherited `activate: true` from its sibling rather
    /// than from anyone's decision.
    ///
    /// The cost is not cosmetic. Fronting the Finder backgrounds the guest
    /// application, and that application is the ONLY context permitted to
    /// give back its own content-plane port hooks: `content_uninstall_context`
    /// skips every row whose a5 is not the caller's, and the jGNE filter
    /// that drives it runs in whatever process happens to pump. Measured on
    /// the PowerBook 1400c 2026-08-08: 22 hooks installed against 1
    /// uninstalled, four ports still hooked at `a5 0x0`, and the guest
    /// logging "not scheduled for 14s" while the host fronted the Finder
    /// at it.
    ///
    /// Tested HERE rather than on `finderScript(activate:)`, for this
    /// file's founding reason: a mutation at the CALL SITE once left nine
    /// tests green.
    func testClearingASelectionDoesNotFrontTheFinder() async throws {
        let sent = SentCommands()
        let (source, _, listener, guest) = try await sourceWithSeam(sent)
        defer { guest.connection.cancel(); listener.stop() }

        let front = MirrorObject.App(psn: "0.3", name: "Finder",
                                     isFront: true)
        source.perform(
            Interaction(object: .desktop(front),
                        gesture: .click(count: 1, mods: 0,
                                        at: .init(x: 300, y: 300))))
        try await waitUntil("the deselect reaches the seam") {
            sent.all.contains { $0.verb == "script" }
        }

        let script = try XCTUnwrap(sent.scriptSource(0))
        XCTAssertTrue(script.contains("select {}"), script)
        XCTAssertFalse(
            script.contains("activate"),
            "clearing a selection has nothing to show, and fronting the "
                + "Finder here backgrounds the guest — which is the only "
                + "context that may give its own port hooks back: \(script)")
    }

    func testOpeningAFolderBringsTheFinderForward() async throws {
        let sent = SentCommands()
        let (source, _, listener, guest) = try await sourceWithSeam(sent)
        defer { guest.connection.cancel(); listener.stop() }

        source.perform(doubleClick("Projects"))
        try await waitUntil("the open reaches the seam") {
            sent.all.contains { $0.verb == "script" }
        }

        let script = try XCTUnwrap(sent.scriptSource(0))
        XCTAssertTrue(script.contains(
            "open item \"Projects\" of desktop"), script)
        XCTAssertTrue(script.hasSuffix("activate\nend tell"), script)
    }

    /// **A dead guest ends the lane on the next cycle, not by timeout.**
    /// Measured 2026-08-05: the session ended with a socket left CLOSED
    /// while the host still believed it had a guest, and the acts in the
    /// lane learned it only by each spending its own deadline. The wire
    /// notices a death; this asserts the missing hop — the failed cycle
    /// consults connectivity and ends the lane once, typed
    /// `sessionChanged`.
    func testADeadGuestEndsTheLaneOnTheNextCycleNotByTimeout() async throws {
        let sent = SentCommands()
        let (source, harness, listener, guest) = try await sourceWithSeam(sent)
        defer { guest.connection.cancel(); listener.stop() }

        // An act the guest will never answer — it is about to die.
        source.perform(doubleClick("Projects"))
        try await waitUntil("the act reaches the seam") {
            sent.all.count == 1
        }
        XCTAssertEqual(source.waitingActs, 1)

        harness.guestConnected = false
        source.planePolicyDidChange()          // the test's way to ask for one
        try await waitUntil("the follow-up cycle is requested") {
            harness.sceneCompletions.count == 2
        }
        harness.completeScene(1, with: .failure(
            .init(message: "No Mac is connected")))

        XCTAssertEqual(source.waitingActs, 0,
                       "the lane must not wait out a timeout against a "
                           + "machine that is gone")
        let record = try XCTUnwrap(
            source.shadowEngine?.operations.records.last)
        XCTAssertEqual(record.outcome, .sessionChanged)

        // Answer the held command so the abandoned serve can return.
        sent.all[0].completion(.init(
            id: 1, ok: false, output: nil,
            error: .init(code: "disconnected", message: "gone")))
    }

    /// **The third state reaches the person driving.** A starved Macintosh
    /// is neither connected nor gone, and showing it as either is a lie
    /// somebody acts on: as connected they conclude the Mirror is broken,
    /// as gone they go and check a machine that is fine.
    func testAStarvedMacIsSaidToBeStarvedRatherThanGoneOrHealthy()
        async throws {
        let sent = SentCommands()
        let (source, harness, listener, guest) = try await sourceWithSeam(sent)
        defer { guest.connection.cancel(); listener.stop() }

        // Alive on another channel, not scheduling this application.
        harness.guestConnected = true
        harness.guestAnswering = false
        source.planePolicyDidChange()
        try await waitUntil("the follow-up cycle is requested") {
            harness.sceneCompletions.count == 2
        }
        harness.completeScene(1, with: .failure(
            .init(message: "the guest did not answer in time")))

        XCTAssertTrue(source.isStarved)
        XCTAssertTrue(source.status.contains("not answering"), source.status)
        XCTAssertFalse(source.status.contains("did not answer in time"),
                       "the transport's own words describe a poll; the "
                           + "person needs the machine's state: \(source.status)")

        /* **And it survives an act's answer replacing the ambient line.**
           An act's sentence holds the status for four seconds — exactly
           the window in which a person clicks again — so a Mirror that
           only said this in its idle text would go quiet about it at the
           moment it matters most. Asserted with the ambient line proven
           displaced, or this passes on the ambient text and tests
           nothing. */
        source.perform(doubleClick("Projects"))
        XCTAssertFalse(source.lastAct.isEmpty,
                       "the act line must have displaced the ambient one, "
                           + "or the assertion below is about the wrong half")
        XCTAssertTrue(source.status.hasPrefix(source.lastAct), source.status)
        XCTAssertTrue(source.status.contains("not answering"),
                      "the starved state must ride the act line too: "
                          + source.status)

        /* **And the act was ACCEPTED, not refused.** This is the whole
           practical difference between starved and gone: the machine will
           serve it when it comes back, so the lane takes it and says so
           rather than turning a person away from a Macintosh that is
           still there. */
        XCTAssertEqual(source.waitingActs, 1,
                       "a starved guest still takes acts; a gone one "
                           + "would have had this refused")
        XCTAssertNotEqual(
            source.shadowEngine?.operations.records.last?.outcome,
            .sessionChanged,
            "§ A3's dead-guest notice must NOT fire for a starved guest — "
                + "that pairing is the regression this state introduces")
    }

    /// The act-control half of the seam: the composed act command is
    /// readable and answerable without a wire, which is what the lane
    /// tests need to wedge a guest deliberately.
    func testAWindowActLeavesThroughTheSeamAndReadsTheAnswer() async throws {
        let sent = SentCommands()
        let listener = GuestListener(
            identity: .init(version: "test", name: "Test Host"))
        let session = UUID()
        let act = AgentIntegrationActControl(
            listener: listener, currentSessionID: { session },
            sendCommand: { verb, args, completion in
                sent.all.append(.init(verb: verb, args: args,
                                      completion: completion))
                completion(.init(id: 1, ok: true, output: [
                    "winact": [["Dispatch", "dispatched"],
                               ["Settlement", "pending"],
                               ["Correlation", "c-1"]],
                ]))
            })

        let result = await act.windowAct(.init(
            window: "now-window-00000000-0000-4000-8000-000000000000",
            action: .close))

        XCTAssertEqual(sent.all.first?.verb, "winact")
        XCTAssertEqual(sent.all.first?.args?["action"], .text("close"))
        guard case .completed(let receipt) = result else {
            return XCTFail("the canned dispatch row must complete: \(result)")
        }
        XCTAssertEqual(receipt.settlement, "pending")
        XCTAssertEqual(receipt.correlation, "c-1")
    }
}
