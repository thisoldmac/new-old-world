/*
 * now_content_qdext.S - the content plane's trap patch on _QDExtensions
 * ($AB1D), which is how the plane meets a world it could never chase.
 *
 * WHY A TRAP PATCH AT ALL (plan 014). The sight-then-chase discovery
 * hooks an offscreen world one event-loop pass after sighting a blit
 * from it. Applications that build a TRANSIENT world - created, drawn,
 * blitted and disposed inside one pass - are therefore unreachable:
 * measured 2026-08-06, Sherlock 2 offered 7 full-window composites and
 * the chase hooked 0 of them. Only creation-time notification can hook
 * a world that does not outlive the pass that made it.
 *
 * WHY THIS CAN WORK ON A NATIVE PPC CALLER, which is the objection that
 * looks fatal and is not: a native application executes no A-trap
 * itself, but it calls an InterfaceLib export whose glue reads the trap
 * dispatch table at call time (IM: PowerPC System Software; Apple's own
 * warning about the ~15 us mode-switch cost of a 68K patch on a PPC
 * caller is only coherent if that path exists). Sherlock 2, Appearance
 * and the Finder all resolve NewGWorld against InterfaceLib - read
 * statically from their own PEF import tables, tools/pef.py --imports.
 * Everything on $AB1D is selector-dispatched and can carry only 68K
 * patches, which is exactly what this resident is.
 *
 * THE SELECTOR LIVES IN D0 and must survive us. QDOffscreen.h's
 * FOURWORDINLINE for NewGWorld is `0x203C, 0x0016, 0x0000, 0xAB1D` -
 * move.l #$00160000,d0 then the trap - so d0 holds
 * (paramBytes << 16) | selector, and NewGWorld is selector 0 with 22
 * bytes of parameters. A patch that clobbers d0 sends the dispatcher to
 * the wrong routine.
 *
 * E1 IS THE COUNTING PATCH AND NOTHING MORE. It chains with the stack
 * UNTOUCHED, so a declined or unarmed call behaves exactly as it would
 * with no extension present; the only effect is a counter. Whether the
 * patch fires for a CFM caller is the one thing this slice measures,
 * and it must be measured before anything is built on top of it - the
 * applet that asked this question before could not answer it, because
 * an application's trap patch is process-local (docs/open-issues.md).
 *
 * The frames here are stated, never recalled: now_ext_act_patch.S is
 * the template and its header carries the paid lesson that a wrong trap
 * ABI does not crash, it lies.
 */

    .text
    .even
    .globl now_content_qdext_patch
    .extern now_content_qdext_note
    .extern now_content_qdext_born
    .extern now_content_qdext_died
    .extern gNowContentOldQDExt
    .extern gNowContentQDExtOut
    .extern gNowContentQDExtRet
    .extern gNowContentQDExtBusy
    .extern gNowContentQDExtDispatchAllowed

/*
 * Entry state is the caller's, exactly as the dispatcher would see it:
 *
 *     d0            (paramBytes << 16) | selector
 *     0(%sp)        return address
 *     4(%sp)...     the call's own parameters, callee-popped
 *
 * We save every register C may clobber INCLUDING d0 - the C note
 * function takes the selector as an ordinary argument and must not be
 * trusted to leave the register alone - then chain. Nothing on the
 * caller's frame is read or written.
 */
now_content_qdext_patch:
    movem.l %d0-%d2/%a0-%a1,-(%sp)  /* 20 bytes; d0 is the selector    */
    move.l %d0,-(%sp)               /* pass it to C by value           */
    jsr now_content_qdext_note
    addq.l #4,%sp                   /* C is caller-pops                */
    movem.l (%sp)+,%d0-%d2/%a0-%a1  /* d0 restored: the dispatcher's   */

    /* The patch cannot safely be removed once installed, but its invasive
       selector wrappers are probe-only. The note function sets this word
       only for the armed probe context; record mode and foreign processes
       take the incumbent dispatch with the original frame untouched. */
    tst.w gNowContentQDExtDispatchAllowed
    beq.w now_content_qdext_chain

/*
 * E2, THE TAIL WRAP - and it applies to selector 0 alone.
 *
 * NewGWorld's result is not its return value: the caller passes
 * `GWorldPtr *offscreenGWorld` and the new world lands where that
 * points, AFTER the dispatch runs. So this is the one selector we let
 * return to us instead of chaining away. Everything else jumps, keeping
 * the "a declined call is indistinguishable from no extension" property
 * for the whole rest of the dispatch.
 *
 * THE FRAME, stated rather than recalled (now_ext_act_patch.S's rule).
 * Pascal pushes the result slot first, then the arguments left to
 * right, and the CALLEE removes the arguments. For
 *
 *   pascal QDErr NewGWorld(GWorldPtr *offscreenGWorld, short pixelDepth,
 *                          const Rect *boundsRect, CTabHandle cTable,
 *                          GDHandle aGDevice, GWorldFlags flags)
 *
 * the stack at entry is, upward from sp:
 *
 *      0(%sp)   return address
 *      4(%sp)   flags            (pushed last, so nearest)
 *      8(%sp)   aGDevice
 *     12(%sp)   cTable
 *     16(%sp)   boundsRect
 *     20(%sp)   pixelDepth       (2 bytes)
 *     22(%sp)   offscreenGWorld  <- the out parameter we need
 *     26(%sp)   the QDErr result slot
 *
 * 4 + 4 + 4 + 4 + 2 + 4 = 22 parameter bytes, which is exactly the
 * 0x0016 the caller loaded into d0's high word - the frame agreeing
 * with the selector word is the check that this layout is right.
 *
 * Popping our return address leaves sp pointing at `flags`, so a `jsr`
 * through the incumbent presents it the frame it expects with its own
 * return address on top. It pops the 22 argument bytes itself, so on
 * return sp points at the caller's result slot - untouched by us, and
 * where the caller will read it.
 *
 * RE-ENTRANCY: the two saved words are resident globals, guarded by a
 * flag rather than made re-entrant. NewGWorld allocates memory, so it
 * cannot legally be called at interrupt time, and classic Mac OS is
 * cooperative - a second entry while we are inside the first is not
 * reachable by any legal caller. If it happens anyway, the guard sends
 * the call down the plain chain, which is the behaviour of no
 * extension at all rather than a corrupted return.
 */
    cmpi.w #4,%d0                   /* low word 4 = DisposeGWorld      */
    beq.s now_content_qdext_dispose
    tst.w %d0                       /* low word: 0 = NewGWorld         */
    bne.s now_content_qdext_chain
    tst.w gNowContentQDExtBusy
    bne.s now_content_qdext_chain

    move.w #1,gNowContentQDExtBusy
    move.l 22(%sp),gNowContentQDExtOut   /* the out parameter          */
    move.l (%sp)+,gNowContentQDExtRet    /* caller's return address    */
    movea.l gNowContentOldQDExt,%a0
    jsr (%a0)                            /* the real NewGWorld         */

    movem.l %d0-%d2/%a0-%a1,-(%sp)
    movea.l gNowContentQDExtOut,%a0
    move.l (%a0),-(%sp)                  /* the newborn GWorldPtr      */
    jsr now_content_qdext_born
    addq.l #4,%sp
    movem.l (%sp)+,%d0-%d2/%a0-%a1
    clr.w gNowContentQDExtBusy
    movea.l gNowContentQDExtRet,%a0
    jmp (%a0)                            /* back to the caller         */

/*
 * DisposeGWorld is selector 4 with 4 parameter bytes
 * (`0x203C, 0x0004, 0x0004, 0xAB1D`), a pascal procedure - no result
 * slot - so its whole frame is:
 *
 *      0(%sp)   return address
 *      4(%sp)   offscreenGWorld
 *
 * We only need to be told BEFORE the world goes, so this is a head
 * action and then a plain chain: read the argument, hand it to C to
 * drop the row and emit worldDied, and leave the stack exactly as we
 * found it. The port must not be dereferenced after the real dispose
 * runs, which is precisely why this happens first.
 */
now_content_qdext_dispose:
    movem.l %d0-%d2/%a0-%a1,-(%sp)  /* 20 bytes                        */
    move.l 24(%sp),-(%sp)           /* 4(%sp) + 20 saved = 24          */
    jsr now_content_qdext_died
    addq.l #4,%sp
    movem.l (%sp)+,%d0-%d2/%a0-%a1
    /* fall through to the chain, frame untouched */

now_content_qdext_chain:
    movea.l gNowContentOldQDExt,%a0
    jmp (%a0)
