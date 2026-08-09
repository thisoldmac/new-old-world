import Foundation
import NOWAgentIntegration

/// The connected Mac's networking, as it reports it.
///
/// **This model asks the guest and renders what comes back — it derives
/// nothing.** The guest already owns a Networking page built on
/// `net_probe.c`/`net_layout.c`, and the `net` verb emits the same four
/// groups from the same code. Re-deriving the grouping here would be a
/// second producer of one fact, and the two would disagree the first time
/// either moved. That is the rule the Software page learned the hard way:
/// two surfaces that group differently are worse than one that does not
/// group at all, because the disagreement is invisible until somebody
/// compares them.
///
/// The verb reuses the ordinary `[label, value]` row shape, so nothing
/// here needed a new wire type or a decoder — a section header is a row
/// whose value is empty, and an indented label is a row inside one.
@MainActor
final class NetworkingModel: ObservableObject, GuestScopedModel {
    /// One group as the guest ordered them. Not an enum: the guest owns
    /// the order and the titles, and an enum here would be this side
    /// asserting it knows them.
    struct Section: Identifiable {
        let id: Int
        let title: String
        var rows: [Row] = []
        /// The one line a group shows when it has no rows — already
        /// written by the guest, in the guest's words.
        var sentence: String?
        /// The guest's own token for why there are no rows
        /// (`undocumented`, `noOpenTransport`, `refused`, `notServed`).
        /// Kept apart from the sentence so this side can style on it
        /// without matching on prose.
        var reason: String?

        /// What the page shows beside the group's name.
        ///
        /// Derived from the guest's TOKEN, never from its sentence — the
        /// token is the contract's, the sentence is prose and will be
        /// rewritten one day. A token this side has never met lands on
        /// `.silent`, which says only "the group said nothing" and does
        /// not accuse the machine of anything; guessing that an unknown
        /// token means trouble is how a page starts reporting faults a
        /// machine never had.
        var state: State {
            guard rows.isEmpty else { return .reported }
            switch reason {
            case "noOpenTransport": return .unavailable
            case "refused":         return .declined
            case "notServed":       return .notMeasured
            case "undocumented":    return .undocumented
            default:                return .silent
            }
        }

        enum State {
            /// The group has rows. The machine answered.
            case reported
            /// The subsystem that would answer is not on that machine —
            /// a Mac without Open Transport. A fact, not a fault.
            case unavailable
            /// The machine was asked and said no.
            case declined
            /// Nothing has measured it yet.
            case notMeasured
            /// Nobody can ask. There is no documented call.
            case undocumented
            /// A token this side does not know, or none at all.
            case silent

            /// The word beside the group's name. Short enough to sit in a
            /// chip, and deliberately none of them is "error": exactly one
            /// of these six states is the machine's doing.
            var label: String {
                switch self {
                case .reported:     return "reported"
                case .unavailable:  return "not available"
                case .declined:     return "declined"
                case .notMeasured:  return "not measured"
                case .undocumented: return "not documented"
                case .silent:       return "nothing said"
                }
            }

            /// Whether this state is the machine's fault, and so the only
            /// one the page may colour as a problem.
            ///
            /// `undocumented` is the state this exists to keep OUT of that
            /// set: it is the page's whole argument, and an amber chip
            /// beside it would tell a person their Mac is broken when the
            /// truth is that Open Transport never published the question.
            var isProblem: Bool { self == .declined }
        }
    }

    /// The page's one-line verdict, for the chip beside the title.
    ///
    /// Counted, not judged: "partly" is what a page says when some groups
    /// answered and some did not, whatever the reasons were. The reasons
    /// stay in the groups, where the guest's own sentence is beside them.
    enum Health {
        /// Nothing asked yet, or the answer had no groups at all.
        case unknown
        /// Every group has rows.
        case reporting
        /// Some groups have rows; some do not.
        case partial
        /// No group has rows.
        case silent
    }

    var health: Health { Self.health(of: sections) }
    var reportedCount: Int { Self.reportedCount(of: sections) }

    /* Static because a test may not build a model: constructing one needs
       a live `GuestListener`, and a verdict that can only be checked
       through a socket is a verdict nothing checks. */
    static func health(of sections: [Section]) -> Health {
        guard !sections.isEmpty else { return .unknown }
        let reported = reportedCount(of: sections)
        if reported == sections.count { return .reporting }
        return reported == 0 ? .silent : .partial
    }

    static func reportedCount(of sections: [Section]) -> Int {
        sections.filter { !$0.rows.isEmpty }.count
    }

    struct Row: Identifiable {
        let id: Int
        let label: String
        let value: String
    }

    @Published private(set) var sections: [Section] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasRun = false
    /// The machine's own words when it declined. Never this side's.
    @Published private(set) var refusal: String?
    @Published private(set) var fetchedAt: Date?
    /// The guest does not serve `net` at all — a 68K guest, or a build
    /// from before this verb. Distinct from a refusal: nothing was
    /// denied, the question does not exist there.
    @Published private(set) var isServed = true

    /// Everything here describes ONE Mac, so a switch discards it rather
    /// than showing the previous machine's address under the new
    /// machine's name. The Software page's cache taught this: a stale
    /// listing under the wrong name is a confident wrong answer, which is
    /// strictly worse than an empty page. Nothing is cached ACROSS
    /// machines here on purpose - `net` is two calls and a bounded walk,
    /// so re-asking costs less than being wrong.
    @Published var connection: GuestConnectionState = .disconnected {
        didSet {
            guard connection != oldValue else { return }
            sections = []
            hasRun = false
            refusal = nil
            fetchedAt = nil
            isLoading = false
            isServed = true
        }
    }

    private let listener: GuestListener

    init(listener: GuestListener) {
        self.listener = listener
    }

    // MARK: asking

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        refusal = nil

        listener.runScheduledCommand(
            "net", purpose: .command("network status"),
            workClass: .foreground) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isLoading = false
                self.hasRun = true

                guard result.ok else {
                    /* The guest's sentence, verbatim. A machine that
                       declined said why, and rewording it here would put
                       this side's guess in front of the machine's
                       answer. */
                    /* "The Mac" meant the machine being driven, and the
                       page's own heading already says that machine
                       declined — so the fallback says the one thing the
                       heading cannot: that no reason came with it. */
                    self.refusal = result.error?.message
                        ?? "\(MachineNaming.title(self.connection)) gave no "
                        + "reason."
                    return
                }
                guard let rows = result.output?["net"] else {
                    /* ok with no `net` key: the guest answered but does
                       not serve this verb. Not a refusal. */
                    self.isServed = false
                    return
                }
                self.isServed = true
                self.sections = Self.group(rows)
                self.fetchedAt = Date()
            }
        }
    }

    /// Turn the guest's flat rows back into its four groups.
    ///
    /// The encoding is the guest's and is deliberately plain: a **section
    /// header** is a row whose value is empty; every row inside a section
    /// arrives with its label indented by two spaces. A group with no
    /// rows sends one row whose label is `  (token)` and whose value is
    /// the sentence.
    ///
    /// Parsing shape rather than matching titles is what keeps this side
    /// from knowing the guest's vocabulary — a guest that adds a fifth
    /// group renders here without a change.
    ///
    /// **A member row with no value is dropped rather than drawn.** The
    /// PowerPC guest already omits a field it could not measure — that is
    /// `net_layout.c`'s whole argument, and why there is no "Router: 0.0.0.0"
    /// row on a Mac with no router. But a guest that reports LESS is the
    /// normal case, not the exception, and one that emits the label with an
    /// empty value would put a labelled blank on this page: a field that
    /// looks measured and reads as nothing. Absent is a fact; blank is a
    /// costume.
    static func group(_ rows: [[String]]) -> [Section] {
        var out: [Section] = []
        var rowID = 0

        for pair in rows {
            guard pair.count >= 2 else { continue }
            let label = pair[0]
            let value = pair[1]

            let isHeader = !label.hasPrefix("  ")
            if isHeader {
                /* A header IS a label with an empty value, so a wholly
                   blank pair would otherwise open a nameless group and
                   swallow every row after it. */
                guard !label.trimmingCharacters(in: .whitespaces).isEmpty
                else { continue }
                out.append(Section(id: out.count, title: label))
                continue
            }
            guard !out.isEmpty else { continue }

            let trimmed = String(label.dropFirst(2))
            // `  (undocumented)` — a group explaining why it is empty.
            if trimmed.hasPrefix("("), trimmed.hasSuffix(")") {
                out[out.count - 1].reason = String(trimmed.dropFirst().dropLast())
                out[out.count - 1].sentence = value
                continue
            }
            guard !value.trimmingCharacters(in: .whitespaces).isEmpty,
                  !trimmed.trimmingCharacters(in: .whitespaces).isEmpty
            else { continue }
            rowID += 1
            out[out.count - 1].rows.append(Row(id: rowID, label: trimmed,
                                               value: value))
        }
        return out
    }
}
