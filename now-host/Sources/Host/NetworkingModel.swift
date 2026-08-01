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

        listener.runCommand("net") { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isLoading = false
                self.hasRun = true

                guard result.ok else {
                    /* The guest's sentence, verbatim. A machine that
                       declined said why, and rewording it here would put
                       this side's guess in front of the machine's
                       answer. */
                    self.refusal = result.error?.message ?? "The Mac declined."
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
    static func group(_ rows: [[String]]) -> [Section] {
        var out: [Section] = []
        var rowID = 0

        for pair in rows {
            guard pair.count >= 2 else { continue }
            let label = pair[0]
            let value = pair[1]

            let isHeader = !label.hasPrefix("  ")
            if isHeader {
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
            rowID += 1
            out[out.count - 1].rows.append(Row(id: rowID, label: trimmed,
                                               value: value))
        }
        return out
    }
}
