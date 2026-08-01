/*
 * ptgne.S - classic 68K GetNextEvent filter shim for the Portal.
 *
 * GNEFilter is not a C ABI callback: Apple documents inputs in A1, D0 and the
 * stack, with the Boolean result returned on the stack. Preserve the incoming
 * register state and stack exactly, run the server, then tail-chain whatever
 * filter was installed before us.
 *
 * Unlike AXPeek's shim there is no sampling throttle. The server's first act is
 * a single compare — is a request pending, and is it addressed to the A5 world
 * we are currently running in — and it returns immediately when not. Throttling
 * would only add latency to the one call that matters.
 */

    .text
    .even
    .globl pt_gne_filter
    .extern pt_gne_serve
    .extern gOldGNEFilter

pt_gne_filter:
    movem.l %d0-%d7/%a0-%a6,-(%sp)
    jsr pt_gne_serve
    movem.l (%sp)+,%d0-%d7/%a0-%a6

    /* A0 is not an input to the documented filter ABI. */
    movea.l gOldGNEFilter,%a0
    cmpa.l #0,%a0
    beq.s 1f
    jmp (%a0)
1:
    rts

/*
 * pt_menuselect_patch - the guarded _MenuSelect patch.
 *
 * MenuSelect is `pascal long MenuSelect(Point startPt)`, and the classic Pascal
 * ABI is specific about both ends of that: the caller pushes SPACE FOR THE
 * RESULT first, then the argument, and the CALLEE removes the argument before
 * returning. So on entry the frame is
 *
 *     8(%sp)  the 4-byte result slot   (pushed first, by the caller)
 *     4(%sp)  the Point argument
 *     0(%sp)  return address
 *
 * Getting this wrong is quiet rather than loud: writing the result over the
 * ARGUMENT slot and returning without popping leaves the caller reading a stale
 * value and its stack 4 bytes out — which is exactly what happened on the first
 * attempt. The patch reported firing and the application did nothing, because
 * the value it read was never the value we wrote.
 *
 * pt_menuselect_answer() returns the packed (menuID<<16 | item) to answer with,
 * or 0 for "not ours" — in which case we chain to the real trap with the stack
 * untouched, so an ordinary user click behaves as though we were never here.
 */
    .even
    .globl pt_menuselect_patch
    .extern pt_menuselect_answer
    .extern gOldMenuSelect

pt_menuselect_patch:
    movem.l %d1/%a0-%a1,-(%sp)      /* d0 carries the verdict out of C */
    jsr pt_menuselect_answer
    movem.l (%sp)+,%d1/%a0-%a1
    tst.l %d0
    beq.s pt_menuselect_chain

    /* Answer it ourselves, honouring the Pascal ABI: stash the return address,
     * drop the argument the callee owns, write the result into the slot the
     * caller reserved, and return straight to it. The real MenuSelect never
     * runs, so no menu is drawn and no tracking loop starts. */
    movea.l (%sp)+,%a1              /* a1 = return address; sp -> argument */
    addq.l #4,%sp                   /* drop the Point; sp -> result slot   */
    move.l %d0,(%sp)                /* the caller reads its result here    */
    jmp (%a1)

pt_menuselect_chain:
    movea.l gOldMenuSelect,%a0
    jmp (%a0)

/*
 * pt_trackcontrol_patch - the guarded _TrackControl patch.
 *
 * `pascal short TrackControl(ControlHandle c, Point p, ControlActionUPP a)`.
 * The Pascal ABI pushes the result slot first, then the arguments left to
 * right, and the callee removes the arguments. A `short` result occupies 2
 * bytes. So on entry:
 *
 *     16(%sp)  the 2-byte result slot   (pushed first, by the caller)
 *     12(%sp)  ControlHandle
 *      8(%sp)  Point
 *      4(%sp)  ControlActionUPP
 *      0(%sp)  return address
 *
 * The same trap as MenuSelect, one size larger — and the same silent failure
 * mode if the offsets are wrong.
 *
 * Corrected 2026-07-31: this comment used to claim PT_OP_SELFTEST covers this
 * patch too. It does not — the selftest exercises MenuSelect only, and a
 * 2-byte result is exactly the case a 4-byte selftest cannot speak for. What
 * proves this ABI is effect: a control's own value, re-read out of the guest,
 * moves the way the part code names, 20/20. That is weaker than a selftest
 * (it needs a live app with a control) and it is what we have.
 *
 * pt_trackcontrol_answer() gets the ControlHandle so it can check the
 * request names THIS control, and returns the part code to answer with, or 0
 * for "not ours" (0 is also TrackControl's own "released outside", so it is a
 * safe value to decline with).
 */
    .even
    .globl pt_trackcontrol_patch
    .extern pt_trackcontrol_answer
    .extern gOldTrackControl

pt_trackcontrol_patch:
    movem.l %d1/%a0-%a1,-(%sp)      /* 12 bytes of saves */
    /* ControlHandle: 12 saves + 4 retaddr + 4 actionProc + 4 Point = 24.
     * Load it via a register rather than `move.l 24(%sp),-(%sp)`, whose
     * source/destination evaluation order against a predecrementing %sp is the
     * kind of subtlety that produces a patch that works until it doesn't. */
    move.l 16(%sp),%a0              /* ControlActionUPP */
    move.l %a0,-(%sp)
    move.l 28(%sp),%a0              /* ControlHandle (offsets +4 after push) */
    move.l %a0,-(%sp)
    jsr pt_trackcontrol_answer
    addq.l #8,%sp                   /* drop both arguments we pushed */
    movem.l (%sp)+,%d1/%a0-%a1
    tst.w %d0
    beq.s pt_trackcontrol_chain

    movea.l (%sp)+,%a1              /* a1 = return address; sp -> actionProc */
    lea 12(%sp),%sp                 /* drop the three arguments             */
    move.w %d0,(%sp)                /* 2-byte result, where the caller looks */
    jmp (%a1)

pt_trackcontrol_chain:
    movea.l gOldTrackControl,%a0
    jmp (%a0)
