import Foundation
import NOWAgentIntegration

/// **The one implementation behind `now_host_log_tail`.**
///
/// Two callers reach it — the local socket's `host_log_tail` branch in
/// `App.swift`, and the in-process `HostAgentIntegrationClient` — and it is
/// one function because the alternative is the shape of defect this project
/// keeps paying for: two readings of one ring, free to bound differently.
///
/// It reads `HostLog.lines`, which is the ring the Logs page draws. Nothing
/// here opens the log FILE, and that is the design rather than an omission:
/// the file is a switch that can be off, and a log surface that reads empty
/// because of a switch cannot be told apart from a quiet machine.
@MainActor
enum HostLogTailReader {
    /// The whole read: filter, count, budget, and the sentence that says
    /// which of those bound.
    ///
    /// `lines` and `area` arrive already validated by whichever face was
    /// asked, and are clamped rather than refused here — this function is
    /// the renderer, not a second refusal point with its own vocabulary.
    static func read(
        from log: HostLog = .shared,
        lines requested: Int?,
        area: String?,
        now: Date = Date()
    ) -> AgentIntegrationHostLogTail {
        let policy = AgentIntegrationHostLogPolicy.self
        let count = min(max(requested ?? policy.defaultLineCount, 1),
                        policy.maximumLineCount)

        /* The filter is padded the way the tag was, so what a caller matches
           on is exactly what a reader sees — including the truncation a tag
           longer than the field already took. */
        let wanted = area.map {
            $0.padding(toLength: policy.areaTagScalars,
                       withPad: " ", startingAt: 0)
        }
        let matching = log.lines.filter { wanted == nil || $0.area == wanted }

        /* Newest last, so the window is taken from the END. */
        var kept = Array(matching.suffix(count)).map {
            sanitize($0.text, limit: policy.maximumLineScalars)
        }
        let asked = kept.count

        /* The budget drops the OLDEST first: a diagnosis reads backwards
           from what just happened, and an answer cut from the recent end
           would remove the half that was asked for. */
        var total = kept.reduce(0) { $0 + $1.unicodeScalars.count }
        var dropped = false
        while total > policy.maximumTotalScalars, !kept.isEmpty {
            total -= kept.removeFirst().unicodeScalars.count
            dropped = true
        }

        return AgentIntegrationHostLogTail(
            lines: kept,
            requested: count,
            matching: matching.count,
            shown: "\(kept.count) of \(asked)"
                + (dropped ? " (older ones did not fit)" : ""),
            area: area,
            ringCapacity: HostLog.ringCapacity,
            persistsToDisk: log.persistsToDisk,
            file: log.url?.path,
            observedAt: now)
    }

    /// One line, made safe to carry without being made unreadable.
    ///
    /// A host log line is prose this side wrote, and some of it quotes a
    /// guest or a filesystem — so a control character can reach it. They are
    /// written as `\xNN` rather than passed through, for the reason the guest
    /// row states: a raw one corrupts the row it travels in, and dropping it
    /// silently loses evidence in the one place somebody is looking for it.
    private static func sanitize(_ text: String, limit: Int) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.properties.generalCategory == .control {
                out.append(contentsOf: String(
                    format: "\\x%02X", scalar.value).unicodeScalars)
            } else {
                out.append(scalar)
            }
        }
        var result = String(out)
        if result.unicodeScalars.count > limit {
            result = String(String.UnicodeScalarView(
                result.unicodeScalars.prefix(limit - 1))) + "…"
        }
        return result
    }
}
