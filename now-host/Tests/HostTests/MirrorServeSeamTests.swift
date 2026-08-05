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
    ) async throws -> (NOWMirrorSource, GuestListener, FakeGuest) {
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
        return (source, listener, guest)
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
        let (source, listener, guest) = try await sourceWithSeam(sent)
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
    func testOpeningAFolderBringsTheFinderForward() async throws {
        let sent = SentCommands()
        let (source, listener, guest) = try await sourceWithSeam(sent)
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
