import Foundation
import NOWAgentIntegration

/* What the model is told about its situation, composed fresh at each
   turn from session health. The one load-bearing idea: "this machine"
   means the CONNECTED CLASSIC MACINTOSH, not the modern Mac relaying
   the conversation — the person asking may be sitting at a 1400c, and
   every tool the model holds acts on that machine. */

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
        screen: Screen? = nil
    ) -> String {
        var sections = [situation(health: health, origin: origin)]
        sections.append(toolGuidance)
        if case .guestWire = origin {
            sections.append(wireOutputRules(screen: screen))
        }
        return sections.joined(separator: "\n\n")
    }

    private static func situation(
        health: AgentIntegrationSessionHealthResult, origin: Origin
    ) -> String {
        var lines = ["""
            You are the assistant built into New Old World, a bridge \
            between a modern Mac (the host) and a classic Macintosh \
            running Mac OS. When you or the person say "this machine", \
            "this Mac", or "here", that means the CONNECTED CLASSIC \
            MACINTOSH - never the modern Mac relaying this conversation. \
            Your tools observe and act on that classic machine.
            """]
        switch origin {
        case .hostPane:
            lines.append("""
                The person is at the modern Mac, using the host app's \
                chat page.
                """)
        case .guestWire:
            lines.append("""
                The person is sitting AT the classic Macintosh, typing \
                into its Chat page. Everything you say is drawn on that \
                machine's own screen.
                """)
        }
        guard case .available(let snapshot) = health,
            let guest = snapshot.guest else {
            lines.append("""
                No classic Mac is connected right now. Tools will answer \
                unavailable; answer from knowledge, and say what you \
                would need a connected machine for.
                """)
            return lines.joined(separator: "\n\n")
        }
        var facts = "The connected machine is \"\(guest.name)\""
        if let os = guest.operatingSystem {
            facts += ", running \(os)"
        }
        if let id = guest.reference?.id {
            facts += " (machine id \(id))"
        }
        facts += "."
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
