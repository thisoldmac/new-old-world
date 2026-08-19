import Foundation
import NOWAgentIntegration

/* What the model is told about its situation: a fixed body, plus ONE
   computed block — `machineFrame` — that says which machines exist right
   now and what the words for them mean from where this conversation is
   being typed.

   Two things put it in one place rather than sprinkled through the body.

   **"This Mac" is deictic, and this app has two speakers.** The prompt
   used to teach the model that "this Mac" meant the CLASSIC machine.
   That was defensible while it was the model's private context, but the
   answer is drawn back into a window where `MachineNaming` has already
   promised the reader that "this Mac" is the modern one — so the model
   was handed the vocabulary that makes its own sentences name the wrong
   machine. Which machine "here" means genuinely does depend on the
   origin; what does not depend on anything is that the model NAMES the
   classic machine rather than pointing at it.

   **The model must know when there is nothing to look at.** Composed
   per turn from live session health (`ChatHarness.turn`), never captured
   at pane construction — a prompt built once would still be saying "no
   machine is connected" an hour after one dialled in. Without this the
   model cheerfully promises to go and look at a machine that is not on,
   and offers to "connect to" one, which this side cannot do at all: the
   guest dials this Mac and this Mac only listens. */

enum ChatSystemPrompt {
    enum Origin {
        /// The host app's own chat pane.
        case hostPane
        /// A chat.send that arrived over the wire from the guest.
        case guestWire
    }

    /// The connected machine's screen, in the only form this file will
    /// accept one: measured by the guest and carried here, or absent.
    ///
    /// **There is no default.** Telling a model a false fact about the
    /// machine it is driving is the most consequential kind of wrong
    /// available in this app and the hardest to notice, because the model
    /// will not complain — it will aim at the wrong place and be
    /// confident. This prompt said 640x480 for as long as it existed
    /// while the host sized its window for 800x600; a model told the
    /// smaller number keeps its output short for a screen that is not
    /// there, and would keep a coordinate for one either.
    struct Screen: Sendable, Equatable {
        let w: Int
        let h: Int
        init?(w: Int, h: Int) {
            guard w > 0, h > 0 else { return nil }   // unknown, not zero
            self.w = w
            self.h = h
        }
    }

    static func compose(
        health: AgentIntegrationSessionHealthResult, origin: Origin,
        screen: Screen? = nil, reach: ChatToolReach = .harness
    ) -> String {
        var sections = [preamble]
        sections.append(machineFrame(health: health, origin: origin))
        sections.append(reachFrame(reach))
        if case .none = reach {} else {
            sections.append(projectAuthority)
            sections.append(toolGuidance)
        }
        if case .guestWire = origin {
            sections.append(wireOutputRules(screen: screen))
        }
        return sections.joined(separator: "\n\n")
    }

    /// What this turn's hands are. Composed from the provider's own
    /// declaration rather than written into the fixed body, because the
    /// same prompt serves six providers and two of them cannot act at
    /// all — and a model that has not been told so will promise to go
    /// and look, which is the most misleading thing this app can say.
    static func reachFrame(_ reach: ChatToolReach) -> String {
        switch reach {
        case .harness:
            return """
                You have New Old World's own tools this turn: they \
                observe and act on the connected classic machine, and on \
                this app's Projects storage.
                """
        case .workspace(let summary):
            return """
                You are also a coding agent in a workspace on the modern \
                Mac (\(summary)), with your own file and command tools. \
                New Old World's capabilities are supplied alongside them \
                as tools whose names begin with "now_". Use the workspace \
                for source, builds and tests; use the now_ tools to \
                observe and act on the connected classic machine. Say \
                which of the two you are about to touch before a change \
                that is hard to undo.
                """
        case .none(let reason):
            return """
                YOU HAVE NO TOOLS THIS TURN. \(reason). You cannot look \
                at the classic machine, read a file, or run anything. \
                Answer from knowledge, and where an answer needs the \
                machine, say plainly that this model cannot reach it and \
                that a tool-capable model can. Never say you will go and \
                check, and never describe a tool result you did not get.
                """
        }
    }

    private static let preamble = """
        You are the assistant built into New Old World, a bridge between \
        a modern Mac and a classic Macintosh running Mac OS. Machine \
        tools observe and act only on the connected classic machine. \
        Project tools, when supplied, act only inside New Old World's \
        application-owned Projects storage on the modern Mac.
        """

    /// Supplied whenever the turn has tools at all. It used to be
    /// conditional on a keyword sniffer over the person's own words,
    /// which meant the authority rules for project work arrived only
    /// when somebody happened to say "project".
    private static let projectAuthority = """
        Project and Development tools are supplied. Every \
        project result names its home. A host-home project is authoritative \
        in New Old World's bounded Projects storage. A guest-home project \
        is authoritative on the connected classic machine; edits happen in \
        a recoverable host workspace until a separately authorized, \
        digest-guarded promotion. Never describe that workspace or its \
        history mirror as current guest truth. Guest reads require Read \
        Only access; publication, build, run and handoff require Full access.
        """

    /// The one part of the prompt that is not fixed: who is speaking,
    /// which machines are on the wire this second, and therefore what
    /// the words for them mean.
    ///
    /// Every machine phrase in here comes from `MachineNaming` rather
    /// than being spelled out, so the model is taught the same
    /// vocabulary the window around its answer already uses. A second
    /// hand-written copy of it is exactly how the two came apart.
    static func machineFrame(
        health: AgentIntegrationSessionHealthResult, origin: Origin
    ) -> String {
        let snapshot: AgentIntegrationSessionHealth?
        if case .available(let s) = health { snapshot = s } else {
            snapshot = nil
        }
        let guest = snapshot?.guest
        /* What to call it: its own name once it has said one, and the
           plain reference until then — `MachineNaming.sentence` is that
           rule, and it is also what the pane beside this is showing. */
        let driven = MachineNaming.sentence(guest?.name)

        var lines: [String] = []
        switch origin {
        case .hostPane:
            lines.append("""
                The person is at the modern Mac, typing into New Old \
                World's own Chat page. "\(MachineNaming.thisMac)" and \
                "here" mean THAT modern Mac, for them and for you.
                """)
        case .guestWire:
            lines.append("""
                The person is sitting AT the classic machine, typing into \
                its Chat page, and everything you say is drawn on its own \
                screen. So when THEY say "here" or "this machine" they \
                mean the classic one. You still do not say \
                "\(MachineNaming.thisMac)" back to them: in this app that \
                phrase always means the modern Mac relaying the \
                conversation.
                """)
        }
        let nameRule = guest == nil
            ? "\"\(MachineNaming.simpleReference)\" (lowercase, in a "
                + "sentence) or \"\(MachineNaming.properNoun)\" where a "
                + "name would stand"
            : "\"\(driven)\""
        lines.append("""
            Call the classic machine \(nameRule) - never \
            "\(MachineNaming.thisMac)", "this machine", or "the host".
            """)

        /* The asymmetry, said whatever the state: it is the difference
           between an answer a person can act on and an offer nothing on
           this side can honour. */
        lines.append("""
            \(MachineNaming.startingSentence(MachineNaming.simpleReference)) \
            dials \(MachineNaming.thisMac); \(MachineNaming.thisMac) only \
            listens and cannot reach out. Never offer to connect to a \
            machine, dial one, or bring one online - somebody has to \
            start NOW on the classic machine itself.
            """)

        guard let guest else {
            lines.append("""
                RIGHT NOW no \(MachineNaming.commonNoun) is connected, so \
                every tool that acts on one will answer unavailable. \
                Answer from knowledge and say what you would need a \
                connected machine for. Do not promise to go and look.
                """)
            return lines.joined(separator: "\n\n")
        }

        var facts = "RIGHT NOW the machine being driven is \"\(guest.name)\""
        if let os = guest.operatingSystem {
            facts += ", running \(os)"
        }
        if let id = guest.reference?.id {
            facts += " (machine id \(id))"
        }
        facts += "."
        /* The roster is every machine on the wire, and only ONE of them
           answers a tool call. A model that cannot see the others reads
           a refusal about the wrong machine as a broken tool. */
        let others: [String?] = (snapshot?.roster ?? [])
            .map(\.name)
            .filter { MachineNaming.sentence($0) != driven }
        if !others.isEmpty {
            facts += " Also connected: \(MachineNaming.several(others))"
                + " - but your tools reach only \"\(guest.name)\"."
        }
        if let access = guest.agentAccess {
            switch access {
            case .disabled:
                facts += """
                     Its owner has DISABLED agent access: tools will be \
                    declined. Say so plainly rather than retrying.
                    """
            case .readOnly:
                facts += """
                     Its owner granted READ-ONLY access: observing works, \
                    acting will be declined. Relay a decline as an \
                    answer, do not retry it.
                    """
            case .fullAccess:
                facts += " Its owner granted full agent access."
            case .unrecognized:
                facts += " Its consent answer was unrecognized; tools may decline."
            }
        }
        lines.append(facts)
        return lines.joined(separator: "\n\n")
    }

    private static let toolGuidance = """
        Using the tools well:
        - Observe before acting. References that acts take come from the \
        rows observation calls answered this session; never invent one.
        - The machine may be a 68030 with 8 MB of RAM. A screen capture \
        or a whole-volume software sweep costs it real time - do not \
        loop them; prefer now_machine_facts or the census for identity \
        questions.
        - Launching software: now_launch_software takes the EXACT \
        catalog name (or a reference it answered earlier). Do not guess \
        names - page now_software_inventory (domain "apps") once and \
        read the real name from an entry; later cursors reuse the \
        cached sweep. An ambiguous launch answers with candidates you \
        can launch by reference.
        - A refusal with a reason is an ANSWER. Relay it to the person; \
        do not retry the same call.
        - One thing at a time: the wire underneath runs one transfer at \
        a time, so a busy answer means wait, not escalate.
        """

    private static func wireOutputRules(screen: Screen?) -> String {
        /* The screen sentence is composed, not written, because the only
           honest versions of it are "it is exactly this" and "nobody has
           measured it". A hardcoded size is neither. */
        let display: String
        if let screen {
            display = "the screen is \(screen.w)x\(screen.h)"
        } else {
            display = """
                the screen size is not known here - nothing has measured \
                it this session, so do not assume one; ask \
                now_machine_facts if a size matters
                """
        }
        return """
            Output rules for this conversation - the display is a classic \
            Mac screen:
            - Plain text only. No markdown headers, tables, code fences, \
            bold, or emoji; they render as their raw characters.
            - Keep paragraphs short and the whole answer compact; \
            \(display), and every byte crosses a slow wire.
            - Accented and typographic characters may not survive; prefer \
            plain ASCII punctuation.
            """
    }
}
