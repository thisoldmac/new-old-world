import XCTest
@testable import Host
import MirrorKit
import NOWAgentIntegration

/// **What a click on a rendered scene now reaches, and what it still does
/// not.**
///
/// The driver is the seam MirrorKit deliberately does not have. So the
/// properties worth holding are about the SEAM rather than about either
/// side: that it never sends an act the vocabulary calls unsendable, that
/// it never invents a target, and that when it cannot carry a gesture the
/// person is told which half is missing rather than shown nothing.
@MainActor
final class MirrorActionDriverTests: XCTestCase {
    private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    private static let element =
        "now-element-11111111-2222-4333-8444-555555555555"

    private func driver(_ listener: GuestListener) -> MirrorActionDriver {
        MirrorActionDriver(
            adapter: AgentIntegrationHostAdapter(listener: listener))
    }

    private func installResponder(
        on guest: FakeGuest, verb: String,
        seen: Box<[String: String]?> = Box(nil)
    ) {
        guest.onMessage = { message in
            switch message {
            case .commandRequest(let request) where request.name == verb:
                seen.value = request.args
                try? guest.send(.commandResult(.init(
                    id: request.id, ok: true,
                    output: [verb: [["Dispatch", "dispatched"],
                                    ["Mechanism", "the application's own"]]],
                    error: nil)))
            default:
                break
            }
        }
    }

    /// A menu click reaches the machine, carrying the identity check.
    ///
    /// `titleLeft` is asserted on the wire and not merely in the request,
    /// because it is the whole basis on which the guest agrees to treat this
    /// press as the agent's rather than the person's. A driver that dropped
    /// it would produce a call the guest refuses — after a person had
    /// already been shown a menu that looked clickable.
    func testAMenuClickReachesTheMachineWithItsIdentityCheck() async throws {
        let (listener, guest) = try await connectedListener()
        defer { guest.connection.cancel(); listener.stop() }
        let seen = Box<[String: String]?>(nil)
        installResponder(on: guest, verb: "menuact", seen: seen)

        /* The action a click on File▸Open produces. It is spelled here
           rather than composed through `ActionModel.menuSelect`, whose
           routing is asserted in `HitActionTests` where the scene types'
           memberwise inits are reachable; what THIS test is about is what
           the driver does with the action once it has one. */
        let outcomes = await driver(listener).drive(
            [.menuInvoke(menuID: 129, itemIndex: 2, titleLeft: 38)])

        XCTAssertEqual(seen.value?["menu"], "129")
        XCTAssertEqual(seen.value?["item"], "2")
        XCTAssertEqual(seen.value?["titleLeft"], "38")
        guard case .dispatched(let sentence) = outcomes.first else {
            return XCTFail("a menu click reaches the lane: \(outcomes)")
        }
        for claimed in ["clicked", "selected", "opened", "performed"] {
            XCTAssertFalse(
                sentence.contains(claimed),
                "the driver's own sentence claims \"\(claimed)\"; the event "
                    + "was dispatched and nothing here saw what the "
                    + "application did with it")
        }
    }

    /// **A control with no reference is not clicked at a coordinate
    /// instead.** The refusal names which half is missing.
    ///
    /// This is the shape a papering-over would take: the control is drawn,
    /// the person clicks it, and something has to happen. The something that
    /// must not happen is a positional click — it names nothing, so it lands
    /// on whatever is in front, which is the 18/20 defect arrived at by
    /// convenience.
    func testAControlWithNoReferenceIsRefusedRatherThanClickedByPosition()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer { guest.connection.cancel(); listener.stop() }
        let asked = Box<Bool>(false)
        guest.onMessage = { message in
            if case .commandRequest = message { asked.value = true }
        }

        let outcomes = await driver(listener).drive(
            [.axdo(ref: "", count: 1, mods: 0, text: nil)])

        guard case .unavailable(let reason) = outcomes.first else {
            return XCTFail("a ref-less control cannot be acted on: "
                               + "\(outcomes)")
        }
        XCTAssertFalse(asked.value,
                       "nothing may reach the machine for a control this "
                           + "side cannot name")
        XCTAssertTrue(reason.contains("reference"),
                      "the refusal has to say which half is missing: "
                          + reason)
    }

    /// **The lane is ready for references.** Given one, the same gesture
    /// reaches `ctlact` — so the day a scene carries refs, nothing here
    /// changes.
    ///
    /// The reference is a real one rather than the empty string a scene
    /// carries today, which is exactly the point: this asserts the readiness
    /// claim rather than restating the gap above.
    func testAReferencedControlReachesCtlact() async throws {
        let (listener, guest) = try await connectedListener()
        defer { guest.connection.cancel(); listener.stop() }
        let seen = Box<[String: String]?>(nil)
        installResponder(on: guest, verb: "ctlact", seen: seen)

        let outcomes = await driver(listener).drive(
            [.axdo(ref: Self.element, count: 1, mods: 0, text: nil)])

        XCTAssertEqual(seen.value?["element"], Self.element)
        XCTAssertEqual(seen.value?["part"], "10",
                       "a press on a plain control lands in the button part")
        guard case .dispatched = outcomes.first else {
            return XCTFail("a referenced control reaches ctlact: "
                               + "\(outcomes)")
        }
    }

    /// Typing into a referenced control is a text REPLACEMENT, and goes to
    /// `textset` rather than to a keystroke — which is the one route NOW
    /// does not have.
    func testTypingIntoAReferencedControlReachesTextset() async throws {
        let (listener, guest) = try await connectedListener()
        defer { guest.connection.cancel(); listener.stop() }
        let seen = Box<[String: String]?>(nil)
        installResponder(on: guest, verb: "textset", seen: seen)

        _ = await driver(listener).drive(
            [.axdo(ref: Self.element, count: 1, mods: 0, text: "Untitled")])

        XCTAssertEqual(seen.value?["element"], Self.element)
        XCTAssertEqual(seen.value?["text"], "Untitled")
    }

    /// **A plain keystroke reaches `key`, posting whatever the caller
    /// resolved.** The counterpart to `testAMenuClickReachesTheMachine…`,
    /// for the other half of the input plane: `mods:0` is the only value
    /// the guest's own `key` verb accepts, and this is the one row of the
    /// input plane's coverage `docs/mcp-coverage.md`'s W3 named as
    /// "planned" before this driver had a route for it.
    func testAPlainKeystrokeReachesKey() async throws {
        let (listener, guest) = try await connectedListener()
        defer { guest.connection.cancel(); listener.stop() }
        let seen = Box<[String: String]?>(nil)
        guest.onMessage = { message in
            switch message {
            case .commandRequest(let request) where request.name == "key":
                seen.value = request.args
                /* The `key` verb's own row shape — lower-case, and
                   `posted` rather than `Dispatch` — see
                   `now-guest-ppc/src/input/input_cmds.c:now_input_run_key`
                   and `AgentIntegrationActControl.key`'s own comment on
                   why this is read separately from the act plane's four. */
                try? guest.send(.commandResult(.init(
                    id: request.id, ok: true,
                    output: ["key": [["code", "45"], ["char", "110"],
                                     ["posted", "true"]]],
                    error: nil)))
            default:
                break
            }
        }

        let outcomes = await driver(listener).drive(
            [.key(name: nil, code: 45, char: 110, mods: 0)])

        XCTAssertEqual(seen.value?["code"], "45")
        XCTAssertEqual(seen.value?["char"], "110")
        XCTAssertEqual(seen.value?["mods"], "0",
                       "mods:0 is sent explicitly — a caller saying \"no "
                           + "modifiers\" is what this verb does")
        XCTAssertNil(seen.value?["name"],
                    "no name was sent, so none should be on the wire")
        guard case .dispatched(let sentence) = outcomes.first else {
            return XCTFail("a plain keystroke reaches key: \(outcomes)")
        }
        /* "posted means queued, never typed" — still the rule. But the ban
           is on "typed" only, and "acted" is deliberately NOT in this list:
           the shared sentence denies the claim USING that word ("Whether it
           acted on it is a question for the next scene"), so a substring
           test cannot tell a claim from its own denial. Banning it made a
           correctly-worded disclaimer read as an overclaim. Assert the
           positive instead — the sentence must say what actually happened. */
        XCTAssertFalse(sentence.contains("typed"),
                       "posted means queued, never typed — the driver must "
                           + "not claim more than the guest did")
        XCTAssertTrue(sentence.contains("dispatched"),
                      "the driver reports dispatch, which is the only thing "
                          + "the guest's reply establishes")
    }

    /// A NAMED key (Return, an arrow, …) sends `name` and no code/char —
    /// this host does not derive the guest's own table for them.
    func testANamedKeystrokeSendsNameOnly() async throws {
        let (listener, guest) = try await connectedListener()
        defer { guest.connection.cancel(); listener.stop() }
        let seen = Box<[String: String]?>(nil)
        guest.onMessage = { message in
            switch message {
            case .commandRequest(let request) where request.name == "key":
                seen.value = request.args
                try? guest.send(.commandResult(.init(
                    id: request.id, ok: true,
                    output: ["key": [["code", "36"], ["char", "13"],
                                     ["posted", "true"]]],
                    error: nil)))
            default:
                break
            }
        }

        _ = await driver(listener).drive(
            [.key(name: "return", code: 36, char: 0, mods: 0)])

        XCTAssertEqual(seen.value?["name"], "return")
    }

    /// **RETRACTED 2026-08-01, lane L7 (was
    /// `testAModifiedKeystrokeNeverReachesTheWire`).** A modified keystroke
    /// used to be refused by this driver before a request was even built.
    /// It is not any more: the guest's `key` verb now routes a nonzero
    /// `mods` through the act plane's own key op, so this driver forwards
    /// it and the WIRE decides. This is the armed half — the guest answers
    /// `ok` and the routed reply's own shape (`mechanism":
    /// "act-plane-post-event"`, `contract/asyncapi.yaml:key`) comes back as
    /// a dispatch, with `mods` seen on the wire exactly as the caller sent
    /// it.
    func testAModifiedKeystrokeReachesKeyWithModsForwarded() async throws {
        let (listener, guest) = try await connectedListener()
        defer { guest.connection.cancel(); listener.stop() }
        let seen = Box<[String: String]?>(nil)
        guest.onMessage = { message in
            switch message {
            case .commandRequest(let request) where request.name == "key":
                seen.value = request.args
                try? guest.send(.commandResult(.init(
                    id: request.id, ok: true,
                    output: ["key": [["code", "45"], ["char", "110"],
                                     ["mods", "256"], ["posted", "true"],
                                     ["mechanism", "act-plane-post-event"]]],
                    error: nil)))
            default:
                break
            }
        }

        let outcomes = await driver(listener).drive(
            [.key(name: nil, code: 45, char: 110, mods: 256)])

        XCTAssertEqual(seen.value?["mods"], "256",
                       "a held modifier must reach the wire, not be "
                           + "smoothed to 0 or blocked before it gets there")
        guard case .dispatched = outcomes.first else {
            return XCTFail("an armed act plane dispatches the modified "
                               + "keystroke: \(outcomes)")
        }
    }

    /// **The other half of the same route: the guest's OWN refusal, when
    /// the act plane is not armed, crosses as a refusal rather than a
    /// silent nothing or an invented reason.** No extension installed is
    /// the concrete case the guest's `act_client.c` names
    /// `act-plane-absent`; the driver must forward that sentence and must
    /// not report `.unavailable` — the machine was asked, and answered.
    func testAModifiedKeystrokeIsRefusedHonestlyWhenTheActPlaneIsAbsent()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer { guest.connection.cancel(); listener.stop() }
        let asked = Box<Bool>(false)
        guest.onMessage = { message in
            switch message {
            case .commandRequest(let request) where request.name == "key":
                asked.value = true
                try? guest.send(.commandResult(.init(
                    id: request.id, ok: false, output: nil,
                    error: .init(
                        code: "act-plane-absent",
                        message: "the NOW Extension is not installed on "
                            + "this Mac, so no application can be driven "
                            + "from a scene"))))
            default:
                break
            }
        }

        let outcomes = await driver(listener).drive(
            [.key(name: nil, code: 45, char: 110, mods: 256)])

        XCTAssertTrue(asked.value,
                      "a modified keystroke must reach the guest — asking "
                          + "and being told no is the honest refusal, not "
                          + "a host-side guess made in advance")
        guard case .refused(let reason) = outcomes.first else {
            return XCTFail("an absent extension is the guest's own refusal, "
                               + "not this side's unavailable: \(outcomes)")
        }
        XCTAssertTrue(reason.contains("NOW Extension")
                      || reason.contains("extension"),
                      "the refusal should be the guest's own sentence, not "
                          + "a generic one: \(reason)")
    }

    /// **The remaining acts NOW cannot carry stay uncarried, and each says
    /// why.**
    ///
    /// `.key` LEFT this list 2026-08-01 (lane L7) — a modified keystroke now
    /// has a route through the act plane, asserted in the two tests above
    /// with the wire watched directly. `type` is the one this test is still
    /// really about: a bare `.type` names no target at all. A driver that
    /// quietly turned it into a positional click, or into a `ctlact` on
    /// something plausible, would close the gap in the UI while leaving it
    /// open on the wire — which is the failure mode "degrades honestly"
    /// names.
    func testTheActsNOWCannotCarryReachNothingAndSayWhy() async throws {
        let (listener, guest) = try await connectedListener()
        defer { guest.connection.cancel(); listener.stop() }
        let asked = Box<Bool>(false)
        guest.onMessage = { message in
            if case .commandRequest = message { asked.value = true }
        }
        let driver = driver(listener)

        for action: MirrorAction in [
            .type(text: "hello"),
            .click(x: 100, y: 100),
            .drag(x0: 0, y0: 0, x1: 10, y1: 10),
            .qmpClick(x: 4, y: 4),
            .qmpDoubleClick(x: 4, y: 4),
            .thumbDrag(x0: 0, y0: 0, x1: 0, y1: 40),
        ] {
            guard case .unavailable(let reason) =
                    await driver.drive(action) else {
                return XCTFail("\(action) reached the act lane. NOW carries "
                                   + "no command for it, and inventing one "
                                   + "here would be a second way to touch a "
                                   + "machine.")
            }
            XCTAssertFalse(reason.isEmpty,
                           "a refusal with no reason is a silent no-op")
        }
        XCTAssertFalse(asked.value, "one of them reached the wire")
    }

    /// **`activate` is not quietly turned into a bring-to-front.**
    ///
    /// They look like one act. `bringToFront` takes an opaque reference that
    /// `process.list` minted and re-validates against a live PSN; a scene
    /// carries `"hi.lo"`, which no observation on this host took. Feeding
    /// one to the other would resolve a target out of a listing this side
    /// never made.
    func testActivateIsNotSubstitutedForBringToFront() async throws {
        let (listener, guest) = try await connectedListener()
        defer { guest.connection.cancel(); listener.stop() }
        let asked = Box<[ControlMessage]>([])
        guest.onMessage = { asked.value.append($0) }

        let outcome = await driver(listener).drive(.activate(psn: "0.8421376"))

        guard case .unavailable(let reason) = outcome else {
            return XCTFail("there is no host lane for activate: \(outcome)")
        }
        XCTAssertTrue(reason.contains("activate"))
        for message in asked.value {
            if case .processFront = message {
                return XCTFail(
                    "a scene's process serial was fed to the process lane, "
                        + "whose reference vocabulary it is not")
            }
        }
    }

    /// A sequence stops at the first act that did not dispatch.
    ///
    /// A background-window click activates before it clicks. Running the
    /// click after the activation failed would put it on whichever
    /// application happened to be in front — the target-free act, arrived at
    /// by accident.
    func testASequenceStopsAtTheFirstActThatDidNotDispatch() async throws {
        let (listener, guest) = try await connectedListener()
        defer { guest.connection.cancel(); listener.stop() }
        let seen = Box<[String: String]?>(nil)
        installResponder(on: guest, verb: "menuact", seen: seen)

        let outcomes = await driver(listener).drive([
            .activate(psn: "0.8421376"),
            .menuInvoke(menuID: 129, itemIndex: 2, titleLeft: 38),
        ])

        XCTAssertEqual(outcomes.count, 1)
        XCTAssertNil(seen.value,
                     "the menu act ran after the activation it depends on "
                         + "had already failed")
    }
}
