import XCTest

@testable import Host
@testable import NOWAgentIntegration

/* The one computed part of the system prompt: which machines exist, and
   what the words for them mean from where the conversation is typed.

   This is a two-halves case of the kind AGENTS.md names, with both
   halves on this side: the prompt teaches the model a vocabulary, and
   `MachineNaming` promises the reader the same one in the window the
   answer is drawn into. Nothing in the app makes them meet, so it is
   asserted here — every check below reads the phrase from MachineNaming
   rather than spelling it, so a change to the vocabulary fails this
   test instead of silently splitting the two. */

private func health(
    guest: AgentIntegrationSessionHealth.Guest?,
    roster: [String] = []
) -> AgentIntegrationSessionHealthResult {
    guard let guest else { return .unavailable(.guest) }
    return .available(.init(
        state: .connected,
        observedAt: Date(timeIntervalSince1970: 0),
        listeningPort: 5252,
        sessionID: nil,
        guest: guest,
        roster: roster.map {
            AgentIntegrationGuestReference(
                id: $0, sessionID: $0, name: $0,
                idIsAutoAssigned: false, idIsAnchored: true)
        },
        failure: nil))
}

private func machine(
    _ name: String,
    access: AgentIntegrationGuestAccess? = .fullAccess
) -> AgentIntegrationSessionHealth.Guest {
    .init(name: name, version: "0.1.0", agentAccess: access,
          operatingSystem: "Mac OS 9.1", connectedAt: nil,
          lastTraffic: nil, quietFor: nil, pingsAnswered: nil,
          framesReceived: nil)
}

final class ChatSystemPromptTests: XCTestCase {

    // MARK: - What the words mean, per speaker

    /// **The bug this block exists for.** The prompt used to define "this
    /// Mac" as the CLASSIC machine, and the model's answer is drawn into a
    /// window where that phrase means the modern one — so the model named
    /// the wrong machine in the reader's own vocabulary.
    func testTheHostPaneIsToldThisMacIsTheModernMac() {
        let text = ChatSystemPrompt.machineFrame(
            health: health(guest: machine("pb1400c")), origin: .hostPane)
        XCTAssertTrue(text.contains("\"\(MachineNaming.thisMac)\" and "
                                    + "\"here\" mean THAT modern Mac"), text)
        // And the classic machine is NAMED rather than pointed at.
        XCTAssertTrue(text.contains("Call the classic machine \"pb1400c\""),
                      text)
    }

    /// Sitting at the 1400c, "here" really does mean the classic machine —
    /// the deixis is the person's and it is correct. What must not follow
    /// is the model answering in the phrase this app has spent on the other
    /// machine.
    func testTheGuestWireKeepsThePersonsDeixisButNotThePhrase() {
        let text = ChatSystemPrompt.machineFrame(
            health: health(guest: machine("pb1400c")), origin: .guestWire)
        XCTAssertTrue(text.contains("sitting AT the classic machine"), text)
        XCTAssertTrue(text.contains("THEY say \"here\""), text)
        XCTAssertTrue(
            text.contains("You still do not say \"\(MachineNaming.thisMac)\""),
            text)
    }

    // MARK: - What is on the wire

    /// Nothing connected: the model must know its tools cannot succeed —
    /// left to itself it promises to go and look at a machine that is off —
    /// and must not offer to connect to one, which this side cannot do.
    func testNothingConnectedSaysSoAndForbidsOfferingToDial() {
        let text = ChatSystemPrompt.machineFrame(
            health: health(guest: nil), origin: .hostPane)
        XCTAssertTrue(
            text.contains("no \(MachineNaming.commonNoun) is connected"), text)
        XCTAssertTrue(text.contains("Do not promise to go and look"), text)
        XCTAssertTrue(text.contains("Never offer to connect to a machine"),
                      text)
        // With no machine there is no name, so the fallback register is
        // what the model is handed — both halves of it.
        XCTAssertTrue(text.contains(MachineNaming.simpleReference), text)
        XCTAssertTrue(text.contains(MachineNaming.properNoun), text)
    }

    /// The dialling asymmetry is true whether or not anything is connected,
    /// and it is the fact that changes what the model may OFFER.
    func testTheDiallingAsymmetryIsSaidInEveryState() {
        for result in [health(guest: nil),
                       health(guest: machine("pb1400c"))] {
            let text = ChatSystemPrompt.machineFrame(
                health: result, origin: .hostPane)
            XCTAssertTrue(
                text.contains("dials \(MachineNaming.thisMac)"), text)
        }
    }

    /// Several machines, one driven. A model that cannot see the others
    /// reads a refusal about the wrong machine as a broken tool.
    func testSeveralConnectedNamesThemAndSaysWhichOneAnswers() {
        let text = ChatSystemPrompt.machineFrame(
            health: health(guest: machine("pb1400c"),
                           roster: ["pb1400c", "q950", "se30"]),
            origin: .hostPane)
        XCTAssertTrue(text.contains("the machine being driven is "
                                    + "\"pb1400c\""), text)
        XCTAssertTrue(text.contains("q950"), text)
        XCTAssertTrue(text.contains("se30"), text)
        XCTAssertTrue(
            text.contains("your tools reach only \"pb1400c\""), text)
        // The driven machine is not also listed as one of the others,
        // and a machine's own name keeps its own spelling: "q950" must
        // never reach the model as "Q950".
        XCTAssertTrue(text.contains("Also connected: q950 and se30"), text)
    }

    // MARK: - Assembly

    func testTheComposedPromptCarriesTheBlock() {
        let result = health(guest: machine("pb1400c"))
        let block = ChatSystemPrompt.machineFrame(
            health: result, origin: .hostPane)
        let whole = ChatSystemPrompt.compose(
            health: result, origin: .hostPane)
        XCTAssertTrue(whole.contains(block))
    }
}
