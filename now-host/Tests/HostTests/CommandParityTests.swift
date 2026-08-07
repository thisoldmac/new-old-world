import Foundation
import XCTest
@testable import Host

/// Every capability a guest has must be reachable from BOTH of its faces:
/// the console a human types into at the machine, and the wire the host
/// drives it over. This reads the guests' own source and fails when one
/// face gains a verb the other did not.
///
/// It exists because that drift happened and was invisible. `process.list`
/// shipped on NOW-68K's wire on 2026-07-25 and its console could not list
/// processes at all — nothing failed, no test noticed, and the gap
/// surfaced only because someone asked out loud what the console could do.
/// The console is where a person standing at a PowerBook debugs a machine
/// whose display is the only thing they have; the wire is where everything
/// automated happens. A capability on one face is half a feature.
///
/// The check is deliberately textual, like GuestWireConformanceTests: it
/// reads the same dispatch lines a human reads. A parser that understood C
/// properly would be a second compiler with its own bugs; this one fails
/// loudly and is fixed by looking.
final class CommandParityTests: XCTestCase {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// A guest source **with its comments removed** — see `GateSource`.
    ///
    /// Not tidiness, and not free of history: on 2026-07-31 the
    /// `proc_list_rows` check below was found to be satisfied entirely by
    /// the comment above `show_processes`, whose text is "proc_list_rows()
    /// is the one implementation." NOW-68K's console could be given a
    /// second, divergent process walk — a change that builds, that the
    /// native suite passes, and that the whole host suite passes — while
    /// this file's own failure message, "two process walks that can
    /// disagree", described exactly what had happened.
    ///
    /// Every identifier this file looks for is an identifier worth
    /// explaining in a comment beside the code, so the prose reliably
    /// names it. That is the third time this defect has been found here.
    private func source(_ path: String) throws -> String {
        try GateSource.guestC(path)
    }

    /// The contract, read as written: YAML's comments are not C's, and no
    /// gate here scans it for an identifier.
    private func contractText() throws -> String {
        try GateSource.raw("contract/asyncapi.yaml")
    }

    /// The premise of the four message-family checks below: NOW-68K's wire
    /// still serves the capability whose console face they are about.
    ///
    /// **This used to be `guard … else { return }`** — the test evaporated,
    /// silently, and the run stayed green. Mutation on 2026-07-31: renaming
    /// `strcmp(type, "process.list")` in wire68.c to anything else takes
    /// away the capability this entire file was written for, builds clean,
    /// passes the native suite, and passes all 913 host tests. The reasoning
    /// behind the `return` was sound — a capability the wire has dropped has
    /// no console face to check — but "the premise stopped holding" is news,
    /// not a reason to say nothing.
    ///
    /// A guest that deliberately stops serving one of these answers here, by
    /// deleting the check with the rest of the capability. That is the same
    /// shape as `consoleOnly`: a divergence is legal, and quietly *becoming*
    /// one is not.
    private func wireStillServes(
        _ evidence: String, in wire: String, _ capability: String,
        file: StaticString = #filePath, line: UInt = #line) -> Bool {
        if wire.contains(evidence) { return true }
        XCTFail("""
            NOW-68K's wire no longer serves \(capability): wire68.c does \
            not name \(evidence). This test's premise was that it did, and \
            everything it checks about the console face is now moot — so \
            it is checking nothing, which is worth saying out loud. If the \
            capability was dropped on purpose, delete this test with it; \
            if it was renamed, follow it here.
            """, file: file, line: line)
        return false
    }

    /// Every file in either guest that dispatches a verb, and which face it
    /// answers. **This list is the premise of the whole file**, and
    /// `testEveryDispatchSiteIsOneThisFileReads` below is what keeps it true:
    /// a new dispatch site is otherwise invisible here, and invisible is how
    /// `ps` shipped.
    ///
    /// `conwin.c` was exactly that for as long as this file existed. It
    /// answers `clear` before delegating the rest to `n68_exec.c`, so its
    /// contents were harmless — but nothing read it, several assertions here
    /// name it in their prose while reading `n68_exec.c`, and a second verb
    /// added beside `clear` was a console-only capability the host cannot
    /// reach, with every gate in this file green. Found by mutation on
    /// 2026-07-31.
    private static let dispatchSites: [String: String] = [
        // NOW-PPC
        "now-guest-ppc/src/commands/commands.c": "wire",
        "now-guest-ppc/src/console/console_model.c": "console",
        // NOW-68K
        "now-guest-68k/src/commands/commands68.c": "wire",
        "now-guest-68k/src/commands/n68_exec.c": "console",
        "now-guest-68k/src/console/conwin.c": "console",
    ]

    /// Files that match this file's `strcmp(name,` heuristic and dispatch
    /// **no verb**, with what they actually do.
    ///
    /// The heuristic is a substring search, and it cannot tell a verb from a
    /// parameter that happens to be called `name`. Both entries below map an
    /// argument's VALUE onto an enum — a window action, an Apple Event
    /// mnemonic — inside a Toolbox-free half that never sees a wire message.
    ///
    /// This is kept apart from `dispatchSites` rather than folded into it
    /// with a made-up face, because they are different claims. That map says
    /// "this file answers verbs on this face", and everything else here
    /// reads it and means it. Calling `act_args.c` a face would put a file
    /// with no faces at all into the two-face rule, and the first check to
    /// read it would compare a window action against a command table.
    ///
    /// An entry here is a statement that the heuristic misfired, so it costs
    /// a sentence saying what the file really does. If one of these ever
    /// grows a real dispatch, the sentence is what makes that visible.
    private static let argumentVocabularies: [String: String] = [
        "now-guest-ppc/src/act/act_args.c":
            "maps winact's `action` and `zoom` arguments onto enums; the "
          + "parameter is called `name` because it names an ACTION, not a "
          + "command",
        "now-guest-ppc/src/input/input_args.c":
            "maps aesend's `event` argument onto one of the four core Apple "
          + "Events. The vocabulary is closed by design (input_args.h), so "
          + "this is exactly a value lookup and never a dispatch",
    ]

    /// NOW-68K's console face, which is **two** files: the shared dispatch in
    /// `n68_exec.c` that the wire's exec plane reaches too, and the
    /// window-local arm in `conwin.c` that runs before the delegation.
    private func sixtyEightKConsoleVerbs() throws -> Set<String> {
        var out: Set<String> = []
        for (path, face) in Self.dispatchSites
        where face == "console" && path.hasPrefix("now-guest-68k/") {
            out.formUnion(dispatched(in: try source(path)))
        }
        return out
    }

    /// The list above names every file that dispatches a verb.
    ///
    /// Without this the list is a hand-maintained premise, and every check in
    /// this file silently narrows to whatever it happens to name. A guest
    /// grows a new console window, a new plane, a second table — and the
    /// two-face rule stops applying to it without one test going red. That is
    /// the shape of the defect this file was written for, one level up: the
    /// gate itself drifts out of contact with the thing it gates.
    ///
    /// Comments stripped, so a `strcmp(name, …)` quoted in prose does not
    /// invent a site — and a dispatch commented OUT stops counting as one.
    func testEveryDispatchSiteIsOneThisFileReads() throws {
        var found: Set<String> = []
        for half in ["now-guest-ppc/src", "now-guest-68k/src"] {
            let dir = Self.repoRoot.appendingPathComponent(half)
            let names = (FileManager.default.enumerator(atPath: dir.path)?
                .compactMap { $0 as? String } ?? [])
                .filter { $0.hasSuffix(".c") }
            XCTAssertFalse(names.isEmpty, "no guest sources at \(dir.path)")
            for n in names where try source("\(half)/\(n)")
                .contains("strcmp(name,") {
                found.insert("\(half)/\(n)")
            }
        }
        XCTAssertTrue(
            Set(Self.dispatchSites.keys)
                .isDisjoint(with: Self.argumentVocabularies.keys), """
            A file is listed both as a dispatch site and as a file that \
            dispatches nothing. Those are different claims and at most one \
            is true.
            """)
        XCTAssertEqual(found, Set(Self.dispatchSites.keys)
            .union(Self.argumentVocabularies.keys), """
            The set of files matching this file's dispatch heuristic \
            changed. Every check here reads a NAMED list, so a site missing \
            from it is a face the two-face rule quietly stopped applying to \
            — add it to dispatchSites with the face it answers, and make \
            sure the checks below actually read it. If the file dispatches \
            no verb at all and merely has a parameter called `name`, say so \
            in argumentVocabularies with what it really does.
            """)
        // Every file claimed to dispatch nothing must still be a file this
        // heuristic finds. An entry for a file that never matched is a
        // subtraction that hides nothing but itself, and would survive the
        // file being deleted.
        for path in Self.argumentVocabularies.keys {
            XCTAssertTrue(found.contains(path), """
                \(path) is listed as a file that matches the dispatch \
                heuristic without dispatching, and it does not match it. \
                Delete the entry.
                """)
        }
    }

    /// Every `strcmp(name, "verb")` in a file — how both guests dispatch.
    private func dispatched(in text: String) -> Set<String> {
        var found: Set<String> = []
        let pattern = #"strcmp\(name,\s*"([a-z_.]+)"\)"#
        let re = try! NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0,
                                                     length: ns.length)) {
            found.insert(ns.substring(with: m.range(at: 1)))
        }
        return found
    }

    /// Verbs that live on one face for a stated reason. An entry here is a
    /// DECISION with a justification, not a to-do — anything not listed is
    /// a failure, and adding a line here should feel like a small act of
    /// documentation.
    private static let consoleOnly: [String: String] = [
        "help": "prints the console's own verbs; meaningless over a wire",
        "clear": "clears this window's pane; acts on nothing else",
        "?": "an alias for help",
        // The PowerPC guest's file verbs act through the file.* message
        // families rather than x-commands, so the host reaches the same
        // capability by a different route and needs no console verb.
        // Chat asks the OTHER Mac's model through the chat.* family;
        // the host reaches chat by SERVING it, so there is nothing for
        // it to type at this Mac - and it reaches this verb anyway
        // through the exec plane, which is the command-first proof.
        "chat": "chat.* family served BY the host; nothing to serve it to",
        "put": "file.* family from the host side, not an x-command",
        "mv": "file.* family from the host side, not an x-command",
        "trash": "file.* family from the host side, not an x-command",
        "untrash": "file.* family from the host side, not an x-command",
        "mkdir": "file.* family from the host side, not an x-command",
        // NOW-68K's own console face on the file.* family. The host does
        // not reach it as a command — it pushes a file and reads the
        // file.progress / file.done it gets back — so this is a
        // renderer for a capability the wire already has, not a verb the
        // wire is missing.
        "xfer": "renders the file.* family's state; the host reads it "
              + "from file.progress and file.done instead",
    ]

    /// Verbs a person would have nothing to do with, so the guest's console
    /// deliberately does not offer them.
    ///
    /// **EMPTY, and how it emptied is the lesson.** Its only entry was
    /// `putstat`, recorded on 2026-07-25 as a deliberate asymmetry: a
    /// diagnostic the host reads to size a transfer, with nothing for a
    /// person at the guest to do with it. On 2026-08-05 someone typed it at
    /// the guest anyway and got "command failed" — which meant the verb had
    /// had a console face the whole time, reached through
    /// `console_model.c`'s fallback, and the only thing missing was a
    /// renderer that could read its answer. The asymmetry was never a
    /// decision; it was a defect nobody had run into, wearing a
    /// justification.
    ///
    /// So the entry did not move to another map. It went away, and
    /// `putstat` prints its eleven rows at the machine like every other
    /// verb. Leave this empty until a verb genuinely earns it — and when
    /// one seems to, check first that a person typing it gets an answer.
    private static let wireOnly: [String: String] = [:]

    /// Verbs the console reaches WITHOUT a `strcmp` of their own, because
    /// `console_model.c` falls through to `now_command_run` and renders
    /// whatever comes back.
    ///
    /// This map exists because the dispatch-table comparison below cannot
    /// see them: there is no line in the console's source with their name
    /// in it, and there does not need to be. That is the good shape — the
    /// same delegation NOW-68K gets from `now68k_commands_run` — but it
    /// means a verb can be reachable and invisible to this file at once,
    /// which is how `putstat` stayed exempt for eleven days.
    ///
    /// Only verbs that take **no arguments** belong here. The fallback
    /// passes `request_json = NULL`, so an argument-taking verb reaches it
    /// and can only be refused; those are `consoleDebt`, and the debt is
    /// the arguments rather than the dispatch.
    private static let reachedByFallback: [String: String] = [
        "putstat": "no arguments; renders as rows through console_reply.c",
        "mouseloc": "no arguments; renders as rows through console_reply.c",
    ]

    /// Verbs with no console face because **a person cannot usefully type
    /// one**, as the contract itself says.
    ///
    /// This is a different fact from `wireOnly` above and is kept apart from
    /// it for that reason. `putstat` is a verb a person COULD type and has
    /// no reason to; every verb here takes an opaque reference, or a
    /// coordinate a scene supplies, or answers with references no one can
    /// read back — a console line cannot carry any of them. The distinction
    /// is not decorative: one is a judgement about usefulness that could be
    /// revisited, the other is a property of the argument.
    ///
    /// **The reason is not this file's to assert.** Each entry is checked
    /// against the contract's own `x-line`, which must say NOT TYPEABLE —
    /// so an exemption here cannot outlive the declaration that justifies
    /// it, and a verb given a real console grammar later fails this rather
    /// than sitting exempt. That check is
    /// `testTheNotTypeableExemptionsAreTheContractsOwn`.
    private static let notTypeable: [String: String] = [
        "winact": "takes an opaque window reference",
        "textget": "takes an opaque element reference",
        "textset": "takes an opaque element reference",
        "ctlact": "takes an opaque element reference and a part code",
        "ditemact": "takes one observed control reference and DITL item",
        "dragpress": "takes an opaque element reference",
        // The nonce is minted by dragpress and held by the caller that
        // began the gesture. A person could type a number, but not THIS
        // number: it exists only inside one drag, and typing a stale one
        // is the case the resident drops on purpose.
        "dragmove": "takes a session nonce dragpress minted",
        "dragrelease": "takes a session nonce dragpress minted",
        "menuact": "the identity check is a coordinate the scene supplies",
        "handle": "takes an opaque reference",
        "observe": "answers with references no person can read or retype",
        "axtree": "the same walk, so the same answer",
        "elements": "the same walk aimed at one process",
    ]

    /// Verbs a person **could** usefully type at the guest and cannot,
    /// with what each is waiting on.
    ///
    /// **A debt, not a resting place** — the same shape and the same rule as
    /// `CommandRegistryTests.servedByNoGuestYet`. Everything here is a
    /// capability the host can reach and a person standing at the machine
    /// cannot, which is the exact defect this file was written for; naming
    /// them as "wire-only" would have been a lie, because their arguments
    /// are numbers and words a person has.
    ///
    /// Seven arrived on 2026-07-31, when six verbs that had been built
    /// and dispatched by nothing were registered, and `axsnap` — which
    /// takes no arguments at all — was found to have been in the same
    /// position since the reference layer landed. The console face for them
    /// is a `console_model.c` change and is not in the emulator-readiness
    /// scope; it is written down here rather than smuggled into the map
    /// above, so that the next person reads a list of owed console verbs
    /// instead of a settled asymmetry.
    ///
    /// **Six remain.** `mouseloc` left for `reachedByFallback` on
    /// 2026-08-06, once the renderer fix made the fallback a complete face
    /// for a verb that takes no arguments. Count the list, not this
    /// sentence — a stale count here is what sent docs/command-parity.md
    /// citing a set of twelve that never existed.
    private static let consoleDebt: [String: String] = [
        "axsnap": "takes nothing and answers about the front process; owed "
                + "since the reference layer landed",
        "activate": "takes two serial numbers",
        "actselftest": "takes nothing, or two serial numbers",
        "script": "takes the script source, which is the rest of the line",
        "aesend": "takes an event name, two serials and a path",
        "qdtrace": "takes an op and its arguments",
    ]

    /// The PowerPC guest: `commands.c` answers the wire, `console_model.c`
    /// answers the Console page. Two lists, so two chances to drift.
    func testThePowerPCGuestsTwoFacesAgree() throws {
        let wire = dispatched(in: try source("now-guest-ppc/src/commands/commands.c"))
        let console = dispatched(in: try source("now-guest-ppc/src/console/console_model.c"))

        let missingFromConsole = wire.subtracting(console)
            .subtracting(Self.wireOnly.keys)
            .subtracting(Self.reachedByFallback.keys)
            .subtracting(Self.notTypeable.keys)
            .subtracting(Self.consoleDebt.keys)
        XCTAssertTrue(missingFromConsole.isEmpty, """
            the PowerPC guest answers \(missingFromConsole.sorted()) over \
            the wire but not in its own console. A person at the machine \
            cannot reach what the host can. Add it to console_model.c, or \
            name it in ONE of the three maps above — notTypeable if a \
            console line cannot carry its argument (and say so in the \
            contract's x-line), consoleDebt if it could and the face is \
            owed, wireOnly if a person would have nothing to do with the \
            answer.
            """)

        let missingFromWire = console.subtracting(wire)
            .subtracting(Self.consoleOnly.keys)
        XCTAssertTrue(missingFromWire.isEmpty, """
            the PowerPC guest's console answers \(missingFromWire.sorted()) \
            but the wire does not. Add it to commands.c and the contract's \
            x-commands, or name it in consoleOnly with its reason.
            """)
    }

    /// The three exemption maps are three different claims, and the
    /// `notTypeable` one is the contract's claim rather than this file's.
    ///
    /// Without this, "not typeable" is an assertion a test author makes
    /// about a verb, in a test, where nobody looking at the verb would find
    /// it. With it, the exemption is the contract's `x-line` — the same
    /// prose the guest's own console implementation reads — and a verb that
    /// is given a real grammar later cannot stay exempt: the moment its
    /// `x-line` stops saying NOT TYPEABLE, this goes red and the verb moves
    /// to `consoleDebt` or grows the console face it now describes.
    func testTheNotTypeableExemptionsAreTheContractsOwn() throws {
        let contract = try contractText()

        for maps in [(Self.notTypeable, Self.consoleDebt),
                     (Self.notTypeable, Self.wireOnly),
                     (Self.consoleDebt, Self.wireOnly),
                     (Self.notTypeable, Self.reachedByFallback),
                     (Self.consoleDebt, Self.reachedByFallback)] {
            XCTAssertTrue(Set(maps.0.keys).isDisjoint(with: maps.1.keys), """
                A verb is exempted twice, under two claims that cannot both \
                be true: overlap between \(maps.0.keys.sorted()) and \
                \(maps.1.keys.sorted()).
                """)
        }

        for (name, reason) in Self.notTypeable {
            XCTAssertFalse(
                reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\"\(name)\" is exempted as not typeable with no reason.")
            guard let start = contract.range(of: "\n    \(name):\n") else {
                XCTFail("""
                    "\(name)" is exempted as not typeable and the contract's \
                    x-commands does not declare it at all.
                    """)
                continue
            }
            let rest = contract[start.upperBound...]
            let end = rest.range(of: "\n    [a-z]",
                                 options: .regularExpression)?.lowerBound
                ?? rest.endIndex
            let row = String(rest[..<end])
            guard let line = row.range(of: "x-line:") else {
                XCTFail("""
                    "\(name)" is exempted here as not typeable and its \
                    contract row states no x-line at all. The exemption \
                    rests on a declaration that is not there.
                    """)
                continue
            }
            XCTAssertTrue(
                row[line.upperBound...]
                    .contains("NOT TYPEABLE"), """
                "\(name)" is exempted from having a console face because a \
                person cannot type it, and the contract's x-line for it no \
                longer says NOT TYPEABLE. One of the two is now wrong: give \
                the verb its console face and move it out of notTypeable, \
                or say in the contract why a line cannot carry its argument.
                """)
        }

        for (name, reason) in Self.consoleDebt {
            XCTAssertFalse(
                reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\"\(name)\" is recorded as a console debt with no reason.")
            let console = dispatched(
                in: try source("now-guest-ppc/src/console/console_model.c"))
            XCTAssertFalse(console.contains(name), """
                the PowerPC guest's console now answers "\(name)", which is \
                recorded here as a console face it still owes. Delete the \
                entry — this is the good outcome, and leaving it means the \
                two faces stop being compared for that verb.
                """)
        }
    }

    /// NOW-68K: `commands68.c` is the command table both faces share, and
    /// `conwin.c` adds the console-local verbs plus any capability that is
    /// a message family rather than a command.
    func testTheSixtyEightKGuestsTwoFacesAgree() throws {
        let consoleText = try source("now-guest-68k/src/commands/n68_exec.c")

        // The console does not re-dispatch launch/quit; it hands the name
        // to the SAME table the wire uses. That delegation is the whole
        // anti-drift property, and it is stronger than any list this test
        // could compare: a verb added to commands68.c reaches the console
        // the moment it exists, with nobody having to remember.
        //
        // The trailing `(` is load-bearing. `now68k_commands_run` alone is
        // a PREFIX of `now68k_commands_run_rows`, which the same function
        // calls twenty lines earlier for the table-shaped verbs — so the
        // delegation this check exists for could be deleted outright and
        // the row call kept the string alive. Found by mutation on
        // 2026-07-31, on the one assertion the comment above calls "the
        // whole anti-drift property".
        XCTAssertTrue(consoleText.contains("now68k_commands_run("), """
            n68_exec.c no longer delegates to now68k_commands_run, so the \
            console and the wire now have separate command paths that can \
            disagree. That is the defect class this project has paid the \
            most for — see two-halves-never-met-in-a-test.
            """)

        // `help` is dispatched on BOTH faces on purpose, and it is the
        // one case where that is right: the wire answers a row per
        // command as JSON, the console prints text and adds its own
        // console-local verbs, and no single result struct holds both
        // shapes. What makes it safe is that both render the SAME list.
        XCTAssertTrue(consoleText.contains("now68k_commands_docs"), """
            n68_exec.c prints a help list it wrote itself instead of \
            rendering commands68.h's published table. A hand-written list \
            agrees with the wire's until someone adds a command, and then \
            the machine has two different answers to "what can you do" — \
            which is the whole reason that table is published.
            """)

        // `ps` is the second and, so far, last case of the same shape: a
        // row per PROCESS, which an N68CmdResult cannot hold either. Both
        // faces render proc_list_rows() — the wire as the contract's
        // [name, detail] pairs, the console as text for a 58-column pane
        // — so the walk they describe is one walk. Adding a third name
        // here should be argued for; the reason is always "one result
        // struct cannot hold this reply", never "it was easier".
        //
        // Any OTHER verb on both faces is two implementations of one verb.
        let table = dispatched(in: try source("now-guest-68k/src/commands/commands68.c"))
        // vprobe is the THIRD row-array command, and each exemption has to
        // buy its place with the thing that makes it safe. help renders the
        // published doc table; ps renders proc_list_rows(); vprobe BORROWS
        // the single measurement table rather than measuring again — which
        // matters more here than for the other two, because a second run
        // would cost ~12s AND could not agree with the first, the screen
        // having moved in between.
        XCTAssertTrue(consoleText.contains("now68k_commands_vprobe"), """
            n68_exec.c runs its own vprobe instead of borrowing the table \
            commands68.c filled. Two measurements of a changing screen \
            cannot agree, so the console and the wire would report \
            different numbers for the same machine and both would be \
            defensible — the worst kind of disagreement to debug.
            """)

        // Both console files, not just n68_exec.c: conwin.c dispatches too,
        // and a verb it answers that commands68.c also answers is the same
        // two-implementations defect one file over.
        let duplicated = table.intersection(try sixtyEightKConsoleVerbs())
            .subtracting(["help", "ps", "vprobe"])
        XCTAssertTrue(duplicated.isEmpty, """
            n68_exec.c dispatches \(duplicated.sorted()) itself while \
            commands68.c also does. Two implementations of one verb is how \
            the console and the wire start telling a person different \
            things about the same machine.
            """)
    }

    /// The direction the first version of this file did not check, and the
    /// one that broke: a verb NOW-68K's own console answers must also be a
    /// verb its wire answers. The host console is a **dumb shell** — it
    /// relays the line a person types and keeps no command list — so a
    /// capability the guest offers only at its own keyboard is a
    /// capability the host cannot reach at all.
    ///
    /// That is not hypothetical. `ps` lived in conwin.c alone; a person at
    /// the PowerBook could list processes, and the same guest answered
    /// `unknown-command` to `ps` from the host's console, while serving
    /// `process.list` on that same wire the whole time (2026-07-25). The
    /// message family made the capability LOOK present on both faces —
    /// and a message family is not something anyone can type.
    ///
    /// **Both** console files. `conwin.c` answers `clear` before delegating
    /// the rest, and it was unread here until 2026-07-31 — a second verb
    /// beside it was a console-only capability with every gate green, which
    /// is this test's own defect committed inside the test meant to catch it.
    func testEveryVerbTheSixtyEightKConsoleAnswersIsAlsoOnItsWire() throws {
        let console = try sixtyEightKConsoleVerbs()
        let wire = dispatched(in: try source("now-guest-68k/src/commands/commands68.c"))

        let missingFromWire = console.subtracting(wire)
            .subtracting(Self.consoleOnly.keys)
        XCTAssertTrue(missingFromWire.isEmpty, """
            NOW-68K's console answers \(missingFromWire.sorted()) but its \
            wire does not, so the host console — which sends whatever is \
            typed and knows no command list — gets unknown-command for a \
            verb the machine plainly has. Add it to commands68.c and the \
            contract's x-commands, or name it in consoleOnly with the \
            reason it cannot cross a wire.
            """)
    }

    /// The capability that is not a command. `process.list` is its own
    /// message family, so the parity rule cannot be checked by comparing
    /// command tables — and that is exactly how it shipped wire-only.
    func testTheSixtyEightKConsoleCanListProcesses() throws {
        let wire = try source("now-guest-68k/src/core/wire68.c")
        let console = try source("now-guest-68k/src/commands/n68_exec.c")

        guard wireStillServes("\"process.list\"", in: wire,
                              "process.list") else { return }
        XCTAssertTrue(console.contains("\"ps\""), """
            NOW-68K serves process.list on the wire, so the host can ask \
            what is running — but its console cannot. That is the exact \
            gap this file was written for: a message family is a \
            capability too, and comparing command tables alone would never \
            have caught it.
            """)
        XCTAssertTrue(console.contains("proc_list_rows"), """
            the console lists processes without using proc_list_rows(), so \
            there are now two process walks that can disagree. One \
            implementation, two renderers — see docs/command-parity.md.
            """)
    }

    /// The second capability that is not a command. Receiving a pushed
    /// file is the `file.*` message family, so — exactly like
    /// `process.list` above — no command table compares the two faces,
    /// and a wire-only implementation would look complete from every
    /// angle except a person standing at the machine.
    func testTheSixtyEightKConsoleCanSeeAnIncomingFile() throws {
        let wire = try source("now-guest-68k/src/core/wire68.c")
        let console = try source("now-guest-68k/src/commands/n68_exec.c")

        guard wireStillServes("\"file.offer\"", in: wire,
                              "the file.* receive half") else { return }
        XCTAssertTrue(console.contains("\"xfer\""), """
            NOW-68K accepts a file.offer over the wire, so the host can \
            push a file to it — but its console cannot say whether one is \
            arriving, how far it has got, or where it will land. A \
            transfer in flight shows no window and a finished one lands \
            somewhere the app never mentioned, so this is the whole of \
            what a person at the machine can know about it.
            """)
        XCTAssertTrue(console.contains("now68k_wire_put_status"), """
            n68_exec.c reports on transfers without reading \
            now68k_wire_put_status(), so the console and the wire now \
            keep separate counts of the same transfer. One \
            implementation, two renderers — see docs/command-parity.md.
            """)
    }

    /// The third capability that is not a command — and the one where
    /// the lesson was applied before it cost anything. SENDING a file is
    /// the `file.*` family read from the other end, so again no command
    /// table compares the two faces on its own.
    ///
    /// Two things are asserted, and they are different. The first is
    /// that a person at the machine can SEE an outgoing transfer, which
    /// is `xfer`'s job in both directions. The second is that `put` is
    /// in commands68.c rather than only in conwin.c, so the host console
    /// — a dumb shell with no knowledge of message families — can type
    /// it. `ps` satisfied the first and failed the second for a day.
    func testTheSixtyEightKConsoleCanSeeAnOutgoingFile() throws {
        let wire = try source("now-guest-68k/src/core/wire68.c")
        let console = try source("now-guest-68k/src/commands/n68_exec.c")
        // dispatched(), not contains("\"put\"") — the doc table names
        // every verb too, so a substring check passes on a guest that
        // merely ADVERTISES the command and answers unknown-command to
        // it. Caught by mutation: renaming the dispatch arm left the
        // first version of this test green.
        let table = dispatched(in: try source("now-guest-68k/src/commands/commands68.c"))

        guard wireStillServes("now68k_wire_send_file", in: wire,
                              "the file.* send half") else { return }
        XCTAssertTrue(console.contains("now68k_wire_send_status"), """
            NOW-68K can send a file, but its console cannot say whether \
            one is going out or what became of the last one. A person who \
            types `put` and then has no way to ask what happened is in \
            exactly the position `xfer` was written to fix, facing the \
            other way.
            """)
        XCTAssertTrue(table.contains("put"), """
            `put` is not in commands68.c's table, so the host console \
            gets unknown-command for it while a person at the PowerBook \
            can send files happily. That is the `ps` failure exactly: the \
            host console sends the line a person types and knows no \
            message families, so a capability reachable only from the \
            guest's own keyboard is one the host cannot reach at all.
            """)
    }

    /// The fourth capability that is not a command: BROWSING. `file.list`
    /// is a message family, so — like `process.list` and the two transfer
    /// directions above — no command table compares the two faces on its
    /// own, and a wire-only implementation would look complete from every
    /// angle except a person standing at the machine.
    ///
    /// Three things are asserted and they are different. That `ls` is in
    /// commands68.c, so the host console — a dumb shell with no knowledge
    /// of message families — can type it. That the console does NOT also
    /// dispatch it, because the whole point of the rows result type is
    /// that conwin.c reaches this verb by delegating. And that both faces
    /// read one enumeration.
    func testTheSixtyEightKConsoleCanListFiles() throws {
        let wire = try source("now-guest-68k/src/core/wire68.c")
        let console = try source("now-guest-68k/src/commands/n68_exec.c")
        let table = dispatched(in: try source("now-guest-68k/src/commands/commands68.c"))

        guard wireStillServes("\"file.list\"", in: wire,
                              "file.list") else { return }
        XCTAssertTrue(table.contains("ls"), """
            NOW-68K serves file.list on the wire, so the host can see \
            what is on the machine — but `ls` is not in commands68.c's \
            table, so the host console gets unknown-command for it. That \
            is the `ps` failure exactly: a capability that is a family on \
            the wire is not something anyone can type.
            """)
        XCTAssertTrue(console.contains("now68k_commands_run_rows"), """
            conwin.c does not reach the table-shaped commands, so `ls` is \
            a verb the host can type and a person at the PowerBook cannot \
            — the same gap as `ps`, facing the other way.
            """)
        XCTAssertFalse(dispatched(in: console).contains("ls"), """
            n68_exec.c dispatches `ls` itself. It must not: \
            docs/command-parity.md's ruling on the third row-array command \
            was that a fourth should be a result type that holds rows, not \
            another exemption — and a strcmp here is exactly the fourth \
            arm that ruling forbids.
            """)
        XCTAssertTrue(
            try source("now-guest-68k/src/commands/commands68.c")
                .contains("n68_fileenum_page"), """
            `ls` lists files without going through n68_fileenum_page(), so \
            there are now two catalog walks that can disagree. One \
            implementation, two renderers — see docs/command-parity.md.
            """)
        XCTAssertTrue(wire.contains("n68_fileenum_page"), """
            the wire serves file.list from something other than \
            n68_fileenum_page(), which is the same drift from the other \
            side.
            """)
    }

    // MARK: - Present on both faces is not the same as working on both

    /// Everything above this line compares DISPATCH TABLES, and a table can
    /// only say whether a verb is present. On 2026-08-05 `putstat` was
    /// found answering its whole table over the wire and printing
    /// "command failed" at the guest's own console — present on both faces
    /// and working on one, which every check in this file was blind to.
    ///
    /// The cause was not `putstat`. `console_model.c`'s fallback read a
    /// top-level "message" out of the reply and called its absence a
    /// failure, and NO PowerPC verb has ever carried one on success: they
    /// all answer `output: {<verb>: [rows]}`. So the fallback ran its
    /// failure branch for every command that worked, and printed the
    /// command's own words only when it did not. Six verbs were measured
    /// saying "command failed" while succeeding — `putstat`, `axsnap`,
    /// `axtree`, `elements`, `mouseloc`, `observe`.
    ///
    /// The three checks below are the static half. The behavioural half is
    /// `now-guest-ppc/tests/console_reply_test.c`, which runs the renderer
    /// over one reply of every shape the guest emits; neither is
    /// sufficient alone, because this file cannot execute a renderer and
    /// that one cannot see whether the guest still calls it.
    func testTheConsoleRendersAnAnswerAndNotOnlyAFailure() throws {
        let console = try source("now-guest-ppc/src/console/console_model.c")

        XCTAssertTrue(console.contains("console_reply_render"), """
            console_model.c no longer hands the command.result to \
            console_reply_render. Whatever it does instead is a second \
            renderer for replies — and the first one printed \
            "command failed" for every verb that succeeded, for as long as \
            anybody had been typing them. One implementation, two \
            renderers: see docs/command-parity.md.
            """)
        XCTAssertFalse(console.contains("\"command failed\""), """
            console_model.c decides for itself that a command failed. That \
            sentence belongs in console_reply.c and only for a reply that \
            cannot be read at all; a copy here is how it came to be printed \
            for eighteen verbs that had answered perfectly well.
            """)
    }

    /// The other half of the same defect, and the one AGENTS.md already has
    /// a rule for: **state a limit once, where both sides read it.**
    ///
    /// `wire.c` gave a `command.result` 3072 bytes and `console_model.c`
    /// gave it 512, and neither number said so. Every verb answering more
    /// than 512 bytes was therefore truncated mid-JSON for a person at the
    /// keyboard — unparseable, reported as a failure — while the identical
    /// verb answered the host in full. Measured: `qdtrace` at the guest's
    /// own console said "no room for a qdtrace status reply" on a machine
    /// whose wire had just returned the whole table.
    func testBothFacesGiveACommandResultTheSameRoom() throws {
        for path in ["now-guest-ppc/src/core/wire.c",
                     "now-guest-ppc/src/console/console_model.c"] {
            let text = try source(path)
            guard let line = text.split(separator: "\n").first(where: {
                $0.contains("char result[")
            }) else {
                XCTFail("\(path) no longer declares a command.result buffer")
                continue
            }
            XCTAssertTrue(line.contains("kNowCommandResultCap"), """
                \(path) sizes its command.result with a literal rather than \
                commands.h's kNowCommandResultCap. Two numbers for one \
                limit is how the console came to truncate replies the wire \
                carried whole — a capability that works on one face only, \
                with nothing in either file admitting there was a limit.
                """)
        }
    }

    /// Why the renderer may assume rows: because every success reply IS
    /// one. This pins the assumption rather than leaving it as folklore —
    /// a verb that answered `ok:true` with a bare "message" would render as
    /// nothing at all, and would look exactly like the defect above.
    func testEverySuccessfulPowerPCReplyCarriesAnOutputObject() throws {
        let files = [
            "now-guest-ppc/src/commands/commands.c",
            "now-guest-ppc/src/act/act_cmds.c",
            "now-guest-ppc/src/input/input_cmds.c",
            "now-guest-ppc/src/machine/mach_reply.c",
        ]
        for path in files {
            let text = try source(path)
            // The success templates, as written: a snprintf of a
            // command.result with ok true. What must follow, in the same
            // literal or the next one, is an "output" key.
            var searched = text.startIndex..<text.endIndex
            while let hit = text.range(of: #"\"ok\":true,"#,
                                       range: searched) {
                let window = text[hit.upperBound...].prefix(200)
                XCTAssertTrue(window.contains(#"\"output\""#), """
                    \(path) has an ok:true command.result that does not \
                    open an "output" object. The console's renderer shows \
                    a verb's answer by walking output's rows, so a reply \
                    of another shape is invisible to a person at the \
                    machine while reading perfectly on the wire. Give it \
                    rows, or teach console_reply.c the new shape and say \
                    here which verb has it.
                    """)
                searched = hit.upperBound..<text.endIndex
            }
        }
    }

    /// Both guests must only claim verbs the contract declares. The
    /// contract's registry is the source of truth; a guest inventing one
    /// is how a host learns to ask for something no schema describes.
    func testNeitherGuestInventsCommandsTheContractDoesNotDeclare() throws {
        let contract = try contractText()
        let declared: Set<String> = {
            guard let start = contract.range(of: "\n  x-commands:") else {
                return []
            }
            let tail = contract[start.upperBound...]
            var names: Set<String> = []
            for line in tail.split(separator: "\n") {
                if !line.hasPrefix("  ") && !line.isEmpty { break }
                let t = line.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("    "), t.hasSuffix(":"),
                      !t.hasPrefix("x-") else { continue }
                let name = String(t.dropLast())
                if name.allSatisfy({ $0.isLowercase || $0 == "-" }) {
                    names.insert(name)
                }
            }
            return names
        }()
        XCTAssertFalse(declared.isEmpty, "could not read x-commands")

        for (file, verbs) in [
            ("now-guest-ppc/src/commands/commands.c",
             dispatched(in: try source("now-guest-ppc/src/commands/commands.c"))),
            ("now-guest-68k/src/commands/commands68.c",
             dispatched(in: try source("now-guest-68k/src/commands/commands68.c"))),
        ] {
            let undeclared = verbs.subtracting(declared)
                .subtracting(Self.consoleOnly.keys)
            XCTAssertTrue(undeclared.isEmpty, """
                \(file) answers \(undeclared.sorted()) on the wire, which \
                the contract's x-commands does not declare. The contract \
                changes FIRST — a verb the host cannot find in the schema \
                is a verb it can only learn about by accident.
                """)
        }
    }
}
