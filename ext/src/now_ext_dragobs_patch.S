/*
 * now_ext_dragobs_patch.S - the drag observer's two shims.
 *
 * ONE TRAP, NOT SIX. The act plane patches six traps because it answers
 * six calls. This plane patches ONE - `_DragDispatch`, 0xABED - because
 * on 68K the entire Drag Manager is selectors on that single trap, with
 * the selector in D0. Universal Interfaces 3.4 spells TrackDrag
 * `TWOWORDINLINE(0x700D, 0xABED)`: `moveq #13,%d0` then the trap. So
 * every Drag Manager call in the machine comes through the shim below,
 * and the C side sorts them out.
 *
 * That makes two rules non-negotiable and both are enforced here rather
 * than hoped for in C:
 *
 *   1. D0 MUST SURVIVE. It is the selector the incumbent dispatcher is
 *      about to read. It is in the movem set and nothing after the
 *      restore touches it.
 *   2. THE CHAIN IS UNCONDITIONAL. There is no branch anywhere below
 *      that skips `jmp (%a0)`. This plane observes; a shim that could
 *      decline would be a shim that could change what a drag does, and
 *      the whole slice is defined by not doing that.
 *
 * A0/A1 and D0-D2 are the Toolbox's scratch registers, which is why the
 * chain may load A0 after the restore - the same latitude the act
 * plane's trampolines take, for the same documented reason.
 *
 * THE FRAME. A ToolTrap arrives with the stack shaped like a JSR from
 * the caller, arguments already pushed Pascal-style (result slot first,
 * then arguments left to right, callee pops). For
 * `pascal OSErr TrackDrag(DragRef, const EventRecord *, RgnHandle)`:
 *
 *      16(%sp)  the 2-byte result slot   (pushed first, by the caller)
 *      12(%sp)  DragRef            theDrag
 *       8(%sp)  const EventRecord *theEvent
 *       4(%sp)  RgnHandle          theRegion
 *       0(%sp)  return address
 *
 * FOR EVERY OTHER SELECTOR THOSE TWO SLOTS MEAN SOMETHING ELSE. They
 * are read unconditionally because branching on D0 in assembly to avoid
 * two harmless stack loads buys nothing, but the C side must - and does
 * - refuse to dereference either unless the selector is 13. Reading a
 * word of the caller's own stack is safe; believing it is not.
 *
 * Nothing here has run on any Macintosh at the time of writing.
 */

    .text
    .even
    .globl now_dragobs_patch
    .globl now_dragobs_return_thunk
    .extern now_dragobs_enter
    .extern now_dragobs_leave
    .extern gNowDragObsOldDispatch
    .extern gNowDragObsSavedReturn

/*
 * now_dragobs_patch - the shim in the trap table.
 *
 * Calls `int now_dragobs_enter(unsigned long selector, void *theEvent,
 * void *theDrag)`. A nonzero answer means "this was a TrackDrag we
 * managed to record, and we want its return too" - which is arranged by
 * swapping our own thunk in for the caller's return address, the only
 * write this file makes to anybody's stack.
 */
now_dragobs_patch:
    movem.l %d0-%d2/%a0-%a1,-(%sp)  /* 20 bytes; D0 is the selector */
    moveq #0,%d2
    move.w %d0,%d2                  /* zero-extend the selector for C */
    move.l 32(%sp),-(%sp)           /* theDrag   (20 saved + 4 ret + 8) */
    move.l 32(%sp),-(%sp)           /* theEvent  (28, plus the push above) */
    move.l %d2,-(%sp)               /* selector, first C argument */
    jsr now_dragobs_enter
    lea 12(%sp),%sp                 /* C is caller-pops */
    tst.l %d0
    beq.s now_dragobs_chain

    movem.l (%sp)+,%d0-%d2/%a0-%a1
    /* Borrow the caller's return. gNowDragObsSavedReturn is written only
       here and only when the C side has already confirmed no other
       interception is outstanding, so this can never lose a return
       address that somebody is still waiting on. */
    move.l (%sp),gNowDragObsSavedReturn
    move.l #now_dragobs_return_thunk,(%sp)
    movea.l gNowDragObsOldDispatch,%a0
    jmp (%a0)

now_dragobs_chain:
    movem.l (%sp)+,%d0-%d2/%a0-%a1
    movea.l gNowDragObsOldDispatch,%a0
    jmp (%a0)

/*
 * now_dragobs_return_thunk - where TrackDrag comes back to.
 *
 * The callee has popped its own twelve bytes of arguments, so on entry
 * 0(%sp) is the caller's 2-byte result slot, holding TrackDrag's OSErr.
 * A Pascal 2-byte result is a full word here (a `short`, not the Boolean
 * case the act plane documents), so it is read with MOVE.W and
 * sign-extended.
 *
 * Nothing is written to that slot. The caller reads exactly what the
 * real TrackDrag returned.
 *
 * The return is completed by pushing the saved address and executing
 * RTS - a form that needs no register at all, so every register is
 * already restored when control leaves.
 */
now_dragobs_return_thunk:
    movem.l %d0-%d2/%a0-%a1,-(%sp)  /* 20 bytes */
    move.w 20(%sp),%d2              /* TrackDrag's result, in place */
    ext.l %d2
    move.l %d2,-(%sp)
    jsr now_dragobs_leave           /* void now_dragobs_leave(long result) */
    addq.l #4,%sp
    movem.l (%sp)+,%d0-%d2/%a0-%a1
    move.l gNowDragObsSavedReturn,-(%sp)
    rts
