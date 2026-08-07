import Foundation

/* Asking again, and asking differently. Both are one operation: wind
   the conversation back to just before some prompt, then send a prompt
   from there.

   The care is in winding BOTH halves to the same place. The page draws
   `[ChatDisplayRow]` and the provider is sent `[ChatTurn]`, and the
   two do not line up row-for-turn — one prompt can leave a tool row,
   an answer row and a note behind it. Rewinding the visible half only
   is how a retry would have re-sent a question with the failed
   answer still in the model's context. So the anchor is counted, not
   guessed: the Nth prompt in the transcript is the Nth user turn in
   the conversation. */

enum ChatRewind {
    struct Result: Equatable {
        let rows: [ChatDisplayRow]
        let turns: [ChatTurn]
        /// What the person originally asked, for a retry to re-send or
        /// an edit to start from.
        let prompt: String
    }

    /// Back to the most recent prompt — "answer that again".
    static func toLastPrompt(
        rows: [ChatDisplayRow], turns: [ChatTurn]
    ) -> Result? {
        guard let index = rows.lastIndex(where: { $0.kind == .person })
        else { return nil }
        return rewind(rows: rows, turns: turns, to: index)
    }

    /// Back to one named prompt — "let me put that differently".
    /// A row that is not a prompt answers nil rather than guessing at
    /// a nearby one.
    static func toPrompt(
        id: UUID, rows: [ChatDisplayRow], turns: [ChatTurn]
    ) -> Result? {
        guard let index = rows.firstIndex(where: { $0.id == id }),
            rows[index].kind == .person
        else { return nil }
        return rewind(rows: rows, turns: turns, to: index)
    }

    private static func rewind(
        rows: [ChatDisplayRow], turns: [ChatTurn], to index: Int
    ) -> Result {
        let kept = Array(rows[..<index])
        let priorPrompts = kept.filter { $0.kind == .person }.count
        var seen = 0
        var cut = turns.count
        for (position, turn) in turns.enumerated() where turn.role == .user {
            if seen == priorPrompts {
                cut = position
                break
            }
            seen += 1
        }
        return Result(rows: kept, turns: Array(turns[..<cut]),
                      prompt: rows[index].text)
    }
}
