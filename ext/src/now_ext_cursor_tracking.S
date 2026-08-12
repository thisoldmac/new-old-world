/*
 * now_ext_cursor_tracking.S - task-time redraw and optional GetMouse answer.
 *
 * A classic tracking loop can stop calling GetNextEvent while it owns a
 * drag, but it continues calling GetMouse, StillDown, or Button. Continuity's
 * Time Manager writer may update MouseLocation during that loop; it may not
 * call QuickDraw or the Cursor Device Manager. These hooks give the already
 * published point a task-time QuickDraw moment in the tracking process.
 *
 * Baseline mode never answers a trap. The experimental Virtual GetMouse mode
 * answers only while a held source is active; it writes the caller's Point
 * and performs the Pascal callee cleanup. StillDown and Button always chain.
 * Once installed these hooks remain linked until reboot; removing a link
 * after another extension has chained behind it would be unsafe.
 */

    .text
    .even
    .globl now_cursor_getmouse_patch
    .globl now_cursor_stilldown_patch
    .globl now_cursor_button_patch
    .extern gNowCursorTrackingRedrawOwed
    .extern gNowCursorTrackingSourceActive
    .extern gNowCursorTrackingVirtualGetMouse
    .extern now_ext_cursor_settle_continuity_tracking
    .extern now_ext_cursor_answer_continuity_getmouse
    .extern gNowCursorOldGetMouse
    .extern gNowCursorOldStillDown
    .extern gNowCursorOldButton

now_cursor_getmouse_patch:
    tst.b gNowCursorTrackingSourceActive
    bne.s .Lgetmouse_settle
    tst.b gNowCursorTrackingRedrawOwed
    beq.s .Lgetmouse_chain
.Lgetmouse_settle:
    movem.l %d0-%d7/%a0-%a6,-(%sp)
    jsr now_ext_cursor_settle_continuity_tracking
    movem.l (%sp)+,%d0-%d7/%a0-%a6
.Lgetmouse_chain:
    tst.b gNowCursorTrackingVirtualGetMouse
    beq.s .Lgetmouse_tail
    /* Pascal `void GetMouse(Point *)`: return address at 0(sp), pointer at
       4(sp), with the callee owning those four argument bytes. Four saved
       registers put the pointer at 20(sp). */
    movem.l %d0-%d1/%a0-%a1,-(%sp)
    move.l 20(%sp),-(%sp)
    jsr now_ext_cursor_answer_continuity_getmouse
    addq.l #4,%sp
    tst.l %d0
    beq.s .Lgetmouse_restore_tail
    movem.l (%sp)+,%d0-%d1/%a0-%a1
    movea.l (%sp)+,%a1
    addq.l #4,%sp
    jmp (%a1)
.Lgetmouse_restore_tail:
    movem.l (%sp)+,%d0-%d1/%a0-%a1
.Lgetmouse_tail:
    movea.l gNowCursorOldGetMouse,%a0
    jmp (%a0)

now_cursor_stilldown_patch:
    tst.b gNowCursorTrackingSourceActive
    bne.s .Lstilldown_settle
    tst.b gNowCursorTrackingRedrawOwed
    beq.s .Lstilldown_chain
.Lstilldown_settle:
    movem.l %d0-%d7/%a0-%a6,-(%sp)
    jsr now_ext_cursor_settle_continuity_tracking
    movem.l (%sp)+,%d0-%d7/%a0-%a6
.Lstilldown_chain:
    movea.l gNowCursorOldStillDown,%a0
    jmp (%a0)

now_cursor_button_patch:
    tst.b gNowCursorTrackingSourceActive
    bne.s .Lbutton_settle
    tst.b gNowCursorTrackingRedrawOwed
    beq.s .Lbutton_chain
.Lbutton_settle:
    movem.l %d0-%d7/%a0-%a6,-(%sp)
    jsr now_ext_cursor_settle_continuity_tracking
    movem.l (%sp)+,%d0-%d7/%a0-%a6
.Lbutton_chain:
    movea.l gNowCursorOldButton,%a0
    jmp (%a0)
