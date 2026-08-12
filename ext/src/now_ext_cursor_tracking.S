/*
 * now_ext_cursor_tracking.S - chain-only task-time redraw opportunities.
 *
 * A classic tracking loop can stop calling GetNextEvent while it owns a
 * drag, but it continues calling GetMouse, StillDown, or Button. Continuity's
 * Time Manager writer may update MouseLocation during that loop; it may not
 * call QuickDraw or the Cursor Device Manager. These hooks give the already
 * published point a task-time QuickDraw moment in the tracking process.
 *
 * They never answer a trap. The idle path is one resident-byte test and a
 * tail jump. When redraw debt exists, every data and address register is
 * preserved around one bounded C call, then the incumbent receives its
 * original stack and registers. Once installed these hooks remain chained
 * until reboot; removing a link after another extension has chained behind
 * it would be unsafe.
 */

    .text
    .even
    .globl now_cursor_getmouse_patch
    .globl now_cursor_stilldown_patch
    .globl now_cursor_button_patch
    .extern gNowCursorTrackingRedrawOwed
    .extern now_ext_cursor_settle_continuity_tracking
    .extern gNowCursorOldGetMouse
    .extern gNowCursorOldStillDown
    .extern gNowCursorOldButton

now_cursor_getmouse_patch:
    tst.b gNowCursorTrackingRedrawOwed
    beq.s .Lgetmouse_chain
    movem.l %d0-%d7/%a0-%a6,-(%sp)
    jsr now_ext_cursor_settle_continuity_tracking
    movem.l (%sp)+,%d0-%d7/%a0-%a6
.Lgetmouse_chain:
    movea.l gNowCursorOldGetMouse,%a0
    jmp (%a0)

now_cursor_stilldown_patch:
    tst.b gNowCursorTrackingRedrawOwed
    beq.s .Lstilldown_chain
    movem.l %d0-%d7/%a0-%a6,-(%sp)
    jsr now_ext_cursor_settle_continuity_tracking
    movem.l (%sp)+,%d0-%d7/%a0-%a6
.Lstilldown_chain:
    movea.l gNowCursorOldStillDown,%a0
    jmp (%a0)

now_cursor_button_patch:
    tst.b gNowCursorTrackingRedrawOwed
    beq.s .Lbutton_chain
    movem.l %d0-%d7/%a0-%a6,-(%sp)
    jsr now_ext_cursor_settle_continuity_tracking
    movem.l (%sp)+,%d0-%d7/%a0-%a6
.Lbutton_chain:
    movea.l gNowCursorOldButton,%a0
    jmp (%a0)
