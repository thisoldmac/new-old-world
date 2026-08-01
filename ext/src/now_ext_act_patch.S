/*
 * now_ext_act_patch.S - the act plane's six guarded trap trampolines.
 *
 * A trap patch is not a C callback. The classic Pascal convention pushes
 * the RESULT SLOT first, then the arguments left to right, and makes the
 * CALLEE remove the arguments - so every frame below is stated in the
 * comment above its trampoline and none of them is recalled from memory.
 *
 * WHY THAT MATTERS MORE THAN USUAL HERE: getting a frame wrong is QUIET.
 * Writing the result over the argument slot and returning without
 * popping leaves the caller reading a stale value and its stack four
 * bytes out - the patch reports firing and the application does nothing,
 * because the value it read was never the value we wrote. A wrong ABI
 * does not crash, it lies. That is upstream's own first attempt, and it
 * is why the plane carries a selftest op that runs the real convention
 * against a known answer (now_ext_act.c, act_serve_selftest).
 *
 * Each trampoline preserves the registers C may clobber, calls its C
 * answer function, and then either answers in the caller's own result
 * slot or chains to the trap that was installed before us with the stack
 * UNTOUCHED - so a declined call behaves exactly as it would with no
 * extension present. Every "decline" value is one the real trap could
 * itself have returned, which is what makes a decline indistinguishable
 * from an ordinary miss.
 *
 * The two Boolean results are the subtle case and the reason the frames
 * were verified against the compiler rather than assumed. GCC emits, for
 * `Boolean TrackGoAway(WindowRef, Point)`:
 *
 *     subq.l #2,%sp            ; a 2-byte result slot
 *     move.l 6(%sp),-(%sp)     ; window
 *     move.l 14(%sp),-(%sp)    ; Point
 *     .short 0xa91e
 *     move.b (%sp),%d0         ; <-- ONE BYTE, at the LOWER address
 *     addq.l #2,%sp
 *
 * So a Pascal Boolean occupies a 2-byte slot and the value lives in the
 * HIGH byte. `move.w #1,(%sp)` would write 0x0001 - high byte zero - and
 * the caller would read FALSE from a patch that reported firing. Hence
 * `move.w #0x0100,(%sp)`. A `short` is different again: the same
 * compiler reads FindWindow's result with `move.w (%sp),%d0`, a full
 * word. Two 2-byte slots, two different writes.
 *
 * Ported from the sibling Mirror project's ptgne.S (parked, complete),
 * where these frames are metal-proven. Nothing here has been run on any
 * machine in this repository.
 */

/*
 * now_act_menuselect_patch - `pascal long MenuSelect(Point startPt)`.
 *
 *     8(%sp)  the 4-byte result slot   (pushed first, by the caller)
 *     4(%sp)  the Point argument
 *     0(%sp)  return address
 *
 * The Point is handed down to C because it IS the guard: a menu press
 * carries no handle, so the identity checked is the press itself, and
 * the C side cannot check it unless we pass it. After the movem the
 * frame is 12 bytes of saved registers plus the return address, so the
 * argument sits at 16(%sp) - read BEFORE the push, since MOVE fetches
 * its source before predecrementing the destination.
 */
    .text
    .even
    .globl now_act_menuselect_patch
    .extern now_act_patch_menuselect
    .extern gNowActOldMenuSelect

now_act_menuselect_patch:
    movem.l %d1/%a0-%a1,-(%sp)      /* d0 carries the verdict out of C */
    move.l 16(%sp),-(%sp)           /* the Point argument, for the guard */
    jsr now_act_patch_menuselect
    addq.l #4,%sp                   /* C is caller-pops */
    movem.l (%sp)+,%d1/%a0-%a1
    tst.l %d0
    beq.s now_act_menuselect_chain

    /* Answer in the caller's own slot, honouring the Pascal ABI: stash
       the return address, drop the argument the callee owns, write the
       result where the caller reserved space, and return straight to it.
       The real MenuSelect never runs, so no menu is drawn and no
       tracking loop starts. */
    movea.l (%sp)+,%a1              /* a1 = return address; sp -> argument */
    addq.l #4,%sp                   /* drop the Point; sp -> result slot   */
    move.l %d0,(%sp)
    jmp (%a1)

now_act_menuselect_chain:
    movea.l gNowActOldMenuSelect,%a0
    jmp (%a0)

/*
 * now_act_trackcontrol_patch -
 * `pascal short TrackControl(ControlHandle c, Point p, ControlActionUPP a)`.
 *
 *     16(%sp)  the 2-byte result slot   (pushed first, by the caller)
 *     12(%sp)  ControlHandle
 *      8(%sp)  Point
 *      4(%sp)  ControlActionUPP
 *      0(%sp)  return address
 *
 * The ControlHandle goes down to C because it is this patch's identity
 * check - the clause that measured 0/20 upstream while the menu patch
 * without its equivalent measured 18/20. The action procedure goes down
 * because a scroll bar does its work DURING tracking rather than from
 * the part code.
 *
 * The selftest cannot speak for this frame: it exercises MenuSelect
 * only, and a 2-byte result is exactly the case a 4-byte selftest cannot
 * cover. What proves this one is effect - a control's own value, re-read
 * out of the guest, moving the way the part code names.
 */
    .even
    .globl now_act_trackcontrol_patch
    .extern now_act_patch_trackcontrol
    .extern gNowActOldTrackControl

now_act_trackcontrol_patch:
    movem.l %d1/%a0-%a1,-(%sp)      /* 12 bytes of saves */
    /* Loaded via a register rather than `move.l 24(%sp),-(%sp)`, whose
       source/destination evaluation order against a predecrementing %sp
       is the kind of subtlety that produces a patch that works until it
       doesn't. */
    move.l 16(%sp),%a0              /* ControlActionUPP */
    move.l %a0,-(%sp)
    move.l 28(%sp),%a0              /* ControlHandle (offsets +4 after push) */
    move.l %a0,-(%sp)
    jsr now_act_patch_trackcontrol
    addq.l #8,%sp                   /* drop both arguments we pushed */
    movem.l (%sp)+,%d1/%a0-%a1
    tst.w %d0
    beq.s now_act_trackcontrol_chain

    movea.l (%sp)+,%a1              /* a1 = return address; sp -> actionProc */
    lea 12(%sp),%sp                 /* drop the three arguments              */
    move.w %d0,(%sp)                /* a `short` result is a full word       */
    jmp (%a1)

now_act_trackcontrol_chain:
    movea.l gNowActOldTrackControl,%a0
    jmp (%a0)

/*
 * now_act_findwindow_patch -
 * `pascal short FindWindow(Point thePoint, WindowPtr *theWindow)`.
 *
 *     12(%sp)  the 2-byte result slot   (pushed first, by the caller)
 *      8(%sp)  Point thePoint
 *      4(%sp)  WindowPtr *theWindow     (an OUT parameter)
 *      0(%sp)  return address
 *
 * This is the patch that keeps chrome geometry out of the contract.
 * Without it, driving a window's grow box or close box means computing
 * where the WDEF drew them - a title-bar height and a corner size no
 * guest structure reports, which is a phantom constant by another name.
 * With it, the click may land anywhere in the window and the
 * application is still told which part it hit.
 *
 * Declines with 0, which is inDesk - a legitimate answer - so we chain
 * rather than returning it.
 */
    .even
    .globl now_act_findwindow_patch
    .extern now_act_patch_findwindow
    .extern gNowActOldFindWindow

now_act_findwindow_patch:
    movem.l %d1/%a0-%a1,-(%sp)      /* 12 bytes of saves */
    move.l 16(%sp),%a0              /* theWindow  (12 saves + 4 retaddr) */
    move.l %a0,-(%sp)
    move.l 24(%sp),%a0              /* thePoint   (20, +4 after the push) */
    move.l %a0,-(%sp)
    jsr now_act_patch_findwindow
    addq.l #8,%sp
    movem.l (%sp)+,%d1/%a0-%a1
    tst.w %d0
    beq.s now_act_findwindow_chain

    movea.l (%sp)+,%a1              /* a1 = return address; sp -> theWindow */
    addq.l #8,%sp                   /* drop both arguments; sp -> result    */
    move.w %d0,(%sp)                /* a `short` result is a full word      */
    jmp (%a1)

now_act_findwindow_chain:
    movea.l gNowActOldFindWindow,%a0
    jmp (%a0)

/*
 * now_act_growwindow_patch -
 * `pascal long GrowWindow(WindowPtr w, Point startPt, const Rect *bBox)`.
 *
 *     16(%sp)  the 4-byte result slot
 *     12(%sp)  WindowPtr
 *      8(%sp)  Point
 *      4(%sp)  const Rect *bBox
 *      0(%sp)  return address
 *
 * Answering makes the application call SizeWindow itself and then adjust
 * its own content, which is the whole reason this is a patch and not a
 * direct SizeWindow: a window resized behind the application's back
 * keeps its scroll bars where they were. 0 declines, and 0 is
 * GrowWindow's own "the user changed nothing".
 */
    .even
    .globl now_act_growwindow_patch
    .extern now_act_patch_growwindow
    .extern gNowActOldGrowWindow

now_act_growwindow_patch:
    movem.l %d1/%a0-%a1,-(%sp)
    move.l 20(%sp),%a0              /* Point     (12 + 4 retaddr + 4 bBox) */
    move.l %a0,-(%sp)
    move.l 28(%sp),%a0              /* WindowPtr (24, +4 after the push)   */
    move.l %a0,-(%sp)
    jsr now_act_patch_growwindow
    addq.l #8,%sp
    movem.l (%sp)+,%d1/%a0-%a1
    tst.l %d0
    beq.s now_act_growwindow_chain

    movea.l (%sp)+,%a1              /* a1 = return address; sp -> bBox */
    lea 12(%sp),%sp                 /* drop the three arguments        */
    move.l %d0,(%sp)
    jmp (%a1)

now_act_growwindow_chain:
    movea.l gNowActOldGrowWindow,%a0
    jmp (%a0)

/*
 * now_act_trackbox_patch -
 * `pascal Boolean TrackBox(WindowPtr w, Point thePt, short partCode)`.
 *
 * The `short` argument occupies 2 bytes on the stack, not 4, so this
 * frame is the one that is 2 out of step with the others:
 *
 *     14(%sp)  the 2-byte result slot   (Boolean: HIGH byte only)
 *     10(%sp)  WindowPtr
 *      6(%sp)  Point
 *      4(%sp)  short partCode
 *      0(%sp)  return address
 */
    .even
    .globl now_act_trackbox_patch
    .extern now_act_patch_trackbox
    .extern gNowActOldTrackBox

now_act_trackbox_patch:
    movem.l %d1/%a0-%a1,-(%sp)
    move.w 16(%sp),%d0              /* short partCode (12 + 4 retaddr) */
    ext.l %d0                       /* C promotes it to a 4-byte arg   */
    move.l %d0,-(%sp)
    move.l 26(%sp),%a0              /* WindowPtr (22, +4 after the push) */
    move.l %a0,-(%sp)
    jsr now_act_patch_trackbox
    addq.l #8,%sp
    movem.l (%sp)+,%d1/%a0-%a1
    tst.w %d0
    beq.s now_act_trackbox_chain

    movea.l (%sp)+,%a1              /* a1 = return address; sp -> partCode */
    lea 10(%sp),%sp                 /* partCode 2 + Point 4 + WindowPtr 4  */
    move.w #0x0100,(%sp)            /* TRUE in the HIGH byte; see the note */
    jmp (%a1)

now_act_trackbox_chain:
    movea.l gNowActOldTrackBox,%a0
    jmp (%a0)

/*
 * now_act_trackgoaway_patch -
 * `pascal Boolean TrackGoAway(WindowPtr w, Point thePt)`.
 *
 *     12(%sp)  the 2-byte result slot   (Boolean: HIGH byte only)
 *      8(%sp)  WindowPtr
 *      4(%sp)  Point
 *      0(%sp)  return address
 *
 * Answering TRUE tells the application the user clicked its close box
 * and let go inside it. What happens next is the APPLICATION's: it may
 * put up a save-changes dialog and leave the window open. That is the
 * correct outcome, and it is the reason this op closes a window by
 * asking rather than by calling CloseWindow, which would destroy a
 * document with no prompt at all and leave the application holding a
 * pointer to a window that no longer exists.
 */
    .even
    .globl now_act_trackgoaway_patch
    .extern now_act_patch_trackgoaway
    .extern gNowActOldTrackGoAway

now_act_trackgoaway_patch:
    movem.l %d1/%a0-%a1,-(%sp)
    move.l 16(%sp),%a0              /* Point     (12 + 4 retaddr)        */
    move.l %a0,-(%sp)
    move.l 24(%sp),%a0              /* WindowPtr (20, +4 after the push) */
    move.l %a0,-(%sp)
    jsr now_act_patch_trackgoaway
    addq.l #8,%sp
    movem.l (%sp)+,%d1/%a0-%a1
    tst.w %d0
    beq.s now_act_trackgoaway_chain

    movea.l (%sp)+,%a1              /* a1 = return address; sp -> Point */
    addq.l #8,%sp                   /* Point 4 + WindowPtr 4            */
    move.w #0x0100,(%sp)            /* TRUE in the HIGH byte            */
    jmp (%a1)

now_act_trackgoaway_chain:
    movea.l gNowActOldTrackGoAway,%a0
    jmp (%a0)
