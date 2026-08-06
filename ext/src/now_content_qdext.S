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
    .extern gNowContentOldQDExt

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
    movea.l gNowContentOldQDExt,%a0
    jmp (%a0)
