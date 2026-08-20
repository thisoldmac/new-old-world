import Foundation
import SwiftUI
import MirrorKit

/// **One time-ordered stream, out of the two the Mirror actually keeps.**
///
/// The module measures two things and displayed them as two stacked
/// cards: acts (a person clicked and waited) and scene cycles (one look
/// at the Mac). Read as cards they answer "what is the latest of each",
/// which is the wrong question during a drive — the question is *what
/// just happened, in order*, because an act that waited waited behind
/// something, and the something is usually a cycle.
///
/// So they merge. The kinds stay labelled, because the two are charged to
/// different repairs (`MirrorActClocks` and `MirrorCycleClocks` both
/// carry that argument at length), but the ordering is time and the unit
/// is one line.
///
/// **Cycles are off by default and that is the whole reason this is a
/// stream rather than a log dump.** A running Mirror publishes a cycle
/// about twice a second and a person acts a few times a minute; merged
/// unfiltered, the acts are gone inside ten seconds. `MirrorEventFilter`
/// is what makes the merge legible, so it lives beside it rather than in
/// a view's `@State`.
struct MirrorEvent: Identifiable, Equatable {

    enum Kind: String, Equatable {
        /// A person (or an agent) asked the Mac to do something.
        case act
        /// The Mirror looked at the Mac.
        case cycle
    }

    /// How the row reads at a glance, before any word of it is read.
    enum Tone: Equatable {
        case ordinary
        /// Something did not happen: a refusal, a timeout, a failed walk.
        case trouble
    }

    var id: String
    var kind: Kind
    var at: Date
    /// The one line. Short enough for a 260-point column at the default
    /// text size — long labels are truncated by the view, never here.
    var title: String
    /// The right-hand column: what became of it.
    var status: String
    /// Milliseconds, already rounded. Nil for an event with no duration
    /// worth showing.
    var durationMs: Int?
    var tone: Tone
    /// The detail, revealed on demand. The same monospaced `NOWBASE` line
    /// the log carries, so a person reading the drawer and a person
    /// reading `acts.log` are reading the same characters and can talk to
    /// each other about them.
    var detail: String

    /// Newest first, which is the order a drawer is read in: the thing
    /// that just happened is at the top, where the eye already is.
    ///
    /// Pure and static so the merge rule — and in particular what happens
    /// when an act and a cycle land in the same millisecond — is testable
    /// without a view or a running poll.
    static func stream(acts: [MirrorActClocks],
                       cycles: [MirrorCycleClocks],
                       filter: MirrorEventFilter,
                       limit: Int = 200) -> [MirrorEvent] {
        var events: [MirrorEvent] = []
        if filter.showsActs { events += acts.map(MirrorEvent.init(act:)) }
        if filter.showsCycles { events += cycles.map(MirrorEvent.init(cycle:)) }
        /* Ties broken by kind, acts first. Not cosmetic: a cycle and the
           act it settled routinely share a timestamp to the millisecond,
           and an unstable sort would let the pair swap places between two
           renders of the same data — which reads as the list jittering. */
        events.sort {
            $0.at == $1.at ? ($0.kind == .act && $1.kind == .cycle)
                           : $0.at > $1.at
        }
        return Array(events.prefix(limit))
    }

    init(act clocks: MirrorActClocks) {
        id = "act-\(clocks.kind.rawValue)-\(clocks.operationID)-"
            + "\(clocks.releasedAt.timeIntervalSince1970)"
        kind = .act
        at = clocks.releasedAt
        title = clocks.label.isEmpty ? clocks.operationID : clocks.label
        status = clocks.outcome.rawValue
        durationMs = Int((clocks.total * 1000).rounded())
        /* An act that never settled is trouble even when its outcome word
           is mild: "released" with no confirmation is exactly the case
           the clocks exist to stop looking like success. */
        tone = clocks.outcome.isTrouble || clocks.settledAt == nil
            ? .trouble : .ordinary
        detail = clocks.narrative + "\n" + clocks.baselineLine
    }

    init(cycle clocks: MirrorCycleClocks) {
        id = "cycle-\(clocks.publishedAt.timeIntervalSince1970)-\(clocks.walk)"
        kind = .cycle
        at = clocks.publishedAt
        title = clocks.walk
        status = clocks.outcome
        durationMs = Int((clocks.total * 1000).rounded())
        tone = clocks.outcome == "ok" ? .ordinary : .trouble
        detail = clocks.baselineLine
    }
}

/// Which kinds the stream is showing. A closed set rather than two
/// independent `Bool`s, because two booleans have four states and only
/// three of them are a thing anybody wants: "cycles only" is a view of
/// the poll with the person's own actions hidden.
struct MirrorEventFilter: Equatable {
    enum Kinds: String, CaseIterable, Identifiable, Equatable {
        /// **The default.** See `MirrorEvent`: a cycle every half second
        /// buries the handful of acts a person is actually looking for.
        case acts
        case actsAndCycles
        case everything

        var id: String { rawValue }

        var label: String {
            switch self {
            /* Short enough for a 260-point column's header strip beside
               the lane depth. The long form is the help text; a pop-up
               whose widest item sets the control's width is how the
               lane depth came to render as "1 in…". */
            case .acts: return "Acts"
            case .actsAndCycles: return "Acts + cycles"
            case .everything: return "All"
            }
        }
    }

    var kinds: Kinds = .acts
    var showsActs: Bool { true }
    var showsCycles: Bool { kinds != .acts }
}

extension MirrorOperationOutcome {
    /// Whether this outcome is the kind a person is looking FOR when they
    /// open the drawer. Kept here rather than in `MirrorKit` because it is
    /// a presentation judgement about a drawer, not a property of the
    /// operation.
    var isTrouble: Bool {
        switch self {
        case .queued, .dispatched, .confirmed, .unconfirmed:
            return false
        /* `confirmedAfterTimeout` and `confirmedAfterRefusal` count as
           trouble even though the effect landed. The act still held the
           lane for its full timeout and everything behind it waited —
           which is precisely the case `MirrorActClocks` exists because
           nothing named. */
        default:
            return true
        }
    }
}

/// **The event drawer's contents, in whatever container it is given.**
///
/// It owns the list and nothing about where the list is — the trailing
/// sidebar, a bottom drawer and a segment of a tab view all render this
/// same view, which is what keeps the arrangement a question anyone can
/// still change.
struct MirrorEventStreamView: View {
    @ObservedObject var timeline: MirrorActTimeline
    @ObservedObject var cycles: MirrorCycleTimeline
    @Binding var filter: MirrorEventFilter
    /// Rows already open. Held by the container rather than by each row
    /// so that a redraw — and there is one twice a second — does not
    /// close what a person just opened.
    @State private var expanded: Set<String> = []

    private var events: [MirrorEvent] {
        MirrorEvent.stream(acts: timeline.records, cycles: cycles.records,
                           filter: filter)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if events.isEmpty {
                empty
            } else {
                MirrorScrollBox {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(events) { event in
                            MirrorEventRow(
                                event: event,
                                isExpanded: expanded.contains(event.id),
                                toggle: { toggle(event.id) })
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(MirrorLaneDepth.sentence(timeline.depth))
                .font(.callout.weight(.medium))
                .foregroundStyle(timeline.depth > 1 ? .primary : .secondary)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 4)
            /* A pop-up over the closed set of kinds, rather than a
               `Menu` of toggles. Two reasons and the second is the
               deciding one: the kinds are mutually informative rather
               than independent — a person wants acts, or acts and
               cycles, not cycles alone often enough to be worth a
               checkbox each — and a bordered `Menu` returns the
               prohibited placeholder in the offscreen renderer, so
               choosing one would mean this drawer could never be
               reviewed again without a person at the machine.
               (`MirrorReviewRendering` carries the measurements.) */
            Picker("", selection: $filter.kinds) {
                ForEach(MirrorEventFilter.Kinds.allCases) { kinds in
                    Text(kinds.label).tag(kinds)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help("Which kinds of event this list shows. Scene cycles are "
                  + "off by default: the Mirror publishes one about twice a "
                  + "second and they bury the acts.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Text("No events.").font(.callout)
            Text("Clicking on the Macintosh puts an act here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else {
            expanded.insert(id)
        }
    }
}

/// One event: a line, and its detail when asked for.
///
/// **A `DisclosureGroup` would have been the obvious furniture and it is
/// the wrong one here.** Its triangle takes a fixed leading indent from
/// every row, which at 260 points is most of the room the label needs,
/// and it puts the affordance where the eye scans rather than at the end
/// of the line. So the whole row is the control — a plain button, the
/// chevron trailing and secondary — which is how a mail message row or a
/// Console line behaves.
struct MirrorEventRow: View {
    let event: MirrorEvent
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                        .foregroundStyle(event.tone == .trouble
                                         ? AnyShapeStyle(Color.orange)
                                         : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                        .font(.caption)
                        .frame(width: 13)
                    Text(event.title)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let ms = event.durationMs {
                        Text(Self.duration(ms))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(event.status)

            if isExpanded {
                /* The status word gets its own line only when the row is
                   open. Collapsed it is a tooltip and a colour, because a
                   260-point row cannot hold a label, a duration and a
                   word like "unconfirmed" without truncating the one
                   thing a person came to read. */
                Text(event.status)
                    .font(.caption)
                    .foregroundStyle(event.tone == .trouble
                                     ? AnyShapeStyle(Color.orange)
                                     : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                Text(event.detail)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var symbol: String {
        switch event.kind {
        case .act: return event.tone == .trouble
            ? "exclamationmark.triangle" : "cursorarrow.click"
        case .cycle: return "eye"
        }
    }

    /// Milliseconds under a second, seconds above it. A drawer of
    /// four-digit millisecond counts is a table nobody can scan.
    static func duration(_ ms: Int) -> String {
        ms < 1000 ? "\(ms)ms"
                  : String(format: "%.1fs", Double(ms) / 1000)
    }
}
