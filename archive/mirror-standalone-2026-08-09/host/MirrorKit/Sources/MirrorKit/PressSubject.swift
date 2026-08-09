import Foundation

/// **What can be shown pressed, and what deliberately cannot.**
///
/// A press mark is a claim: *this object took your click and we are waiting
/// on it.* So it is drawn only where all three parts of that claim are true —
/// there is an object, it has the identity the act itself will name, and we
/// know where it is on screen. Anything short of that gets the old behaviour:
/// the act is sent and the status line does the talking.
///
/// This is the direct sibling of `DragTargeting.subject`, which declines an
/// item whose position this side cannot vouch for, and it declines for the
/// same reasons in the same order.
///
/// ## Why not everything clickable
///
/// - **No `ref`, no mark.** The renderer matches the pressed control by ref,
///   because two sheets can both carry an OK and a rect moves when the window
///   does. An object the guest never named cannot be the one that lights up.
/// - **No rect, no mark.** `Scene.Control.rect` is genuinely optional — "nil
///   when the wire had none" — and a press drawn at a guessed rectangle would
///   mark whatever happens to be there.
/// - **A menu row, the desktop, a window: no mark.** Not because they cannot
///   be clicked, but because none of them is a *control that stays put and
///   then changes*. A menu closes on the click; the desktop has no boundary
///   to press. Drawing feedback there would be inventing an object.
/// - **A disabled control: no mark.** The Control Manager will not act on it,
///   so showing it pressed promises something that is not going to happen —
///   the same reason `drawButton` declines to ring a disabled default item.
public struct PressSubject: Equatable {
    /// The identity the act names and the renderer matches on.
    public let ref: String
    /// What to call it to a person, in a status line.
    public let title: String
    /// Content-relative, like every control rect in the IR.
    public let frame: Rect

    public init(ref: String, title: String, frame: Rect) {
        self.ref = ref
        self.title = title
        self.frame = frame
    }

    /// The one constructor the view uses. nil means "this is not something a
    /// press mark can honestly be drawn on", which is a normal answer and not
    /// a failure.
    public init?(_ object: MirrorObject) {
        switch object {
        case .control(let c):
            /* A scroll bar is excluded by its `part`: pressing an arrow or a
               thumb is a tracking gesture with its own live feedback from the
               guest, not a discrete press with a verdict, and marking the
               whole bar would be marking the wrong extent. */
            guard c.part == nil, c.isEnabled, let rect = c.rect,
                  rect.r > rect.l, rect.b > rect.t else { return nil }
            self.init(ref: c.ref,
                      title: c.title.isEmpty ? "that control" : c.title,
                      frame: rect)
        case .dialogItem(let d):
            guard let ref = d.ref, d.isEnabled,
                  d.rect.r > d.rect.l, d.rect.b > d.rect.t else { return nil }
            /* Static text and icons are drawn, not pressed. `semanticKind` is
               the guest's own evidence, and where it is absent this declines
               rather than guessing — 62% of elements carry no determined
               kind, and a press mark on a label is the cursor-over-everything
               mistake in another costume. */
            guard let kind = d.semanticKind,
                  ["pushButton", "checkBox", "radioButton"].contains(kind)
            else { return nil }
            self.init(ref: ref,
                      title: d.title.isEmpty ? "that item" : d.title,
                      frame: d.rect)
        case .window, .menu, .menuItem, .applicationMenuAction, .app,
             .desktop, .finderItem:
            return nil
        }
    }
}
