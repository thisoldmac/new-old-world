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
 *
 * It takes the Point, added 2026-07-31: "not ours" used to mean only "not this
 * A5", so a user's press on any other menu was answered with the armed command
 * (measured 18/20). The C side now checks the press against the point the verb
 * posted, which it cannot do unless we hand it down. After the movem the frame
 * is 12 bytes of saved registers, then the return address, so the argument sits
 * at 16(%sp) — read BEFORE the push, since MOVE fetches its source operand
 * before predecrementing the destination.
 */
    .even
    .globl pt_menuselect_patch
    .extern pt_menuselect_answer
    .extern gOldMenuSelect

pt_menuselect_patch:
    movem.l %d1/%a0-%a1,-(%sp)      /* d0 carries the verdict out of C */
    move.l 16(%sp),-(%sp)           /* the Point argument, for the guard */
    jsr pt_menuselect_answer
    addq.l #4,%sp                   /* C is caller-pops                  */
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

/*
 * ===========================================================================
 * PT_OP_WINDOW_ACT — four more patches, same shape.
 *
 * Every frame below was VERIFIED against the compiler rather than recalled:
 * compiling a call to each trap with the 68K Retro68 toolchain and reading the
 * generated caller. That matters most for the two Booleans, where the obvious
 * guess is wrong in a way nothing would catch. GCC emits, for
 * `Boolean TrackGoAway(WindowRef, Point)`:
 *
 *     subq.l #2,%sp            ; a 2-byte result slot
 *     move.l 6(%sp),-(%sp)     ; window
 *     move.l 14(%sp),-(%sp)    ; Point
 *     .short 0xa91e
 *     move.b (%sp),%d0         ; <-- the Boolean is ONE BYTE, the HIGH byte
 *     addq.l #2,%sp
 *
 * So a Pascal Boolean occupies a 2-byte slot and the value lives in the byte
 * at the LOWER address. Answering with `move.w #1,(%sp)` would write 0x0001 —
 * high byte zero — and the caller would read FALSE from a patch that reported
 * firing. That is the identical silent-lie failure the MenuSelect comment above
 * describes, and it is why these are written as `move.w #0x0100,(%sp)`.
 *
 * `short` is different again: the same compiler reads FindWindow's result with
 * `move.w (%sp),%d0` — a full word. Two 2-byte slots, two different writes.
 * ===========================================================================
 */

/*
 * pt_findwindow_patch - the guarded _FindWindow patch.
 *
 * `pascal short FindWindow(Point thePoint, WindowPtr *theWindow)`.
 *
 *     12(%sp)  the 2-byte result slot   (pushed first, by the caller)
 *      8(%sp)  Point thePoint
 *      4(%sp)  WindowPtr *theWindow     (an OUT parameter)
 *      0(%sp)  return address
 *
 * This is the patch that keeps chrome geometry out of the contract. Without
 * it, driving a window's grow box or close box means computing where the WDEF
 * drew them — a title-bar height and a 15x15 corner that no guest structure
 * reports, i.e. exactly the phantom constants this project forbids. With it,
 * the click may land anywhere in the window and the app is still told which
 * part it hit.
 *
 * pt_findwindow_answer() also writes the target WindowPtr through the out
 * parameter. It returns 0 to decline; 0 is inDesk, a legitimate answer, so we
 * chain rather than return it.
 */
    .even
    .globl pt_findwindow_patch
    .extern pt_findwindow_answer
    .extern gOldFindWindow

pt_findwindow_patch:
    movem.l %d1/%a0-%a1,-(%sp)      /* 12 bytes of saves; d0 carries the verdict */
    move.l 16(%sp),%a0              /* theWindow  (12 saves + 4 retaddr)         */
    move.l %a0,-(%sp)
    move.l 24(%sp),%a0              /* thePoint   (20, +4 after the push)        */
    move.l %a0,-(%sp)
    jsr pt_findwindow_answer
    addq.l #8,%sp
    movem.l (%sp)+,%d1/%a0-%a1
    tst.w %d0
    beq.s pt_findwindow_chain

    movea.l (%sp)+,%a1              /* a1 = return address; sp -> theWindow */
    addq.l #8,%sp                   /* drop both arguments; sp -> result    */
    move.w %d0,(%sp)                /* a `short` result is a full word      */
    jmp (%a1)

pt_findwindow_chain:
    movea.l gOldFindWindow,%a0
    jmp (%a0)

/*
 * pt_growwindow_patch - the guarded _GrowWindow patch.
 *
 * `pascal long GrowWindow(WindowPtr w, Point startPt, const Rect *bBox)`.
 *
 *     16(%sp)  the 4-byte result slot
 *     12(%sp)  WindowPtr
 *      8(%sp)  Point
 *      4(%sp)  const Rect *bBox
 *      0(%sp)  return address
 *
 * Answering makes the app call SizeWindow itself and then adjust its own
 * content, which is the whole reason this is a patch and not a direct
 * SizeWindow. 0 declines — and 0 is GrowWindow's own "the user changed
 * nothing", so declining is indistinguishable from an ordinary cancelled grow.
 */
    .even
    .globl pt_growwindow_patch
    .extern pt_growwindow_answer
    .extern gOldGrowWindow

pt_growwindow_patch:
    movem.l %d1/%a0-%a1,-(%sp)
    move.l 20(%sp),%a0              /* Point     (12 + 4 retaddr + 4 bBox) */
    move.l %a0,-(%sp)
    move.l 28(%sp),%a0              /* WindowPtr (24, +4 after the push)   */
    move.l %a0,-(%sp)
    jsr pt_growwindow_answer
    addq.l #8,%sp
    movem.l (%sp)+,%d1/%a0-%a1
    tst.l %d0
    beq.s pt_growwindow_chain

    movea.l (%sp)+,%a1              /* a1 = return address; sp -> bBox */
    lea 12(%sp),%sp                 /* drop the three arguments        */
    move.l %d0,(%sp)
    jmp (%a1)

pt_growwindow_chain:
    movea.l gOldGrowWindow,%a0
    jmp (%a0)

/*
 * pt_trackbox_patch - the guarded _TrackBox patch.
 *
 * `pascal Boolean TrackBox(WindowPtr w, Point thePt, short partCode)`.
 * The `short` argument occupies 2 bytes on the stack, not 4, so this frame is
 * the one that is 2 out of step with the others:
 *
 *     14(%sp)  the 2-byte result slot   (Boolean: HIGH byte only)
 *     10(%sp)  WindowPtr
 *      6(%sp)  Point
 *      4(%sp)  short partCode
 *      0(%sp)  return address
 */
    .even
    .globl pt_trackbox_patch
    .extern pt_trackbox_answer
    .extern gOldTrackBox

pt_trackbox_patch:
    movem.l %d1/%a0-%a1,-(%sp)
    move.w 16(%sp),%d0              /* short partCode (12 + 4 retaddr) */
    ext.l %d0                       /* C promotes it to a 4-byte arg   */
    move.l %d0,-(%sp)
    move.l 26(%sp),%a0              /* WindowPtr (22, +4 after the push) */
    move.l %a0,-(%sp)
    jsr pt_trackbox_answer
    addq.l #8,%sp
    movem.l (%sp)+,%d1/%a0-%a1
    tst.w %d0
    beq.s pt_trackbox_chain

    movea.l (%sp)+,%a1              /* a1 = return address; sp -> partCode */
    lea 10(%sp),%sp                 /* partCode 2 + Point 4 + WindowPtr 4  */
    move.w #0x0100,(%sp)            /* TRUE in the high byte; see the note  */
    jmp (%a1)

pt_trackbox_chain:
    movea.l gOldTrackBox,%a0
    jmp (%a0)

/*
 * pt_trackgoaway_patch - the guarded _TrackGoAway patch.
 *
 * `pascal Boolean TrackGoAway(WindowPtr w, Point thePt)`.
 *
 *     12(%sp)  the 2-byte result slot   (Boolean: HIGH byte only)
 *      8(%sp)  WindowPtr
 *      4(%sp)  Point
 *      0(%sp)  return address
 *
 * Answering TRUE tells the application the user clicked its close box and let
 * go inside it. What happens next is the APPLICATION's, not ours: it may put up
 * a save-changes dialog and leave the window open. That is the correct outcome
 * and the reason this op closes windows by asking rather than by calling
 * CloseWindow, which would destroy a document with no prompt at all.
 */
    .even
    .globl pt_trackgoaway_patch
    .extern pt_trackgoaway_answer
    .extern gOldTrackGoAway

pt_trackgoaway_patch:
    movem.l %d1/%a0-%a1,-(%sp)
    move.l 16(%sp),%a0              /* Point     (12 + 4 retaddr) */
    move.l %a0,-(%sp)
    move.l 24(%sp),%a0              /* WindowPtr (20, +4 after the push) */
    move.l %a0,-(%sp)
    jsr pt_trackgoaway_answer
    addq.l #8,%sp
    movem.l (%sp)+,%d1/%a0-%a1
    tst.w %d0
    beq.s pt_trackgoaway_chain

    movea.l (%sp)+,%a1              /* a1 = return address; sp -> Point */
    addq.l #8,%sp                   /* Point 4 + WindowPtr 4            */
    move.w #0x0100,(%sp)            /* TRUE in the high byte            */
    jmp (%a1)

pt_trackgoaway_chain:
    movea.l gOldTrackGoAway,%a0
    jmp (%a0)
