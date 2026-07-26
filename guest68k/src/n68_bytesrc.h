#ifndef NOW68K_BYTESRC_H
#define NOW68K_BYTESRC_H

/*
 * A stream of bytes of known length, produced on demand.
 *
 * This is the ONLY thing the sender (n68_puttx.h) knows how to send. It
 * is not a file interface and it must never quietly become one: the
 * first implementation is a file (n68_filesrc.h), but the reason this
 * interface exists is a screen capture.
 *
 * ---- Why an interface, and not just a file ----------------------------
 *
 * A screenshot of this machine's display is ~300 KB against a 384 KB
 * application partition. There is no moment at which those bytes can all
 * exist at once. The capture cannot be staged to a temporary file first
 * either - that needs the same bytes on a disk that may not have room,
 * and doubles the slowest part of the job. It has to be produced in
 * bands and handed away as each band is made.
 *
 * A file sender with a screenshot special case bolted on would be two
 * send paths, and the second one would be written by someone who could
 * not see the first one's back-pressure rule. So the sender takes its
 * bytes from behind this interface and has never heard of a file. If a
 * screenshot ever needs its own parallel send path, this was built
 * wrong.
 *
 * ---- What an implementation PROMISES ----------------------------------
 *
 * 1. `total` IS EXACT AND KNOWN BEFORE THE FIRST FILL. The contract
 *    requires the byte count in file.offer and again in file.begin, both
 *    sent before any byte is produced, and the receiver sizes its
 *    staging from it. A source that cannot say how long it is cannot be
 *    sent by this sender. (A capture can: depth, width and rowBytes are
 *    all known before the first band is drawn.)
 *
 * 2. fill() RETURNS PROMPTLY. It runs on the cooperative main loop
 *    between WaitNextEvent calls, and nothing underneath it pumps the
 *    wire. Every millisecond inside fill() is a millisecond this guest
 *    is deaf, and the host declares a silent guest dead after ~65 s. One
 *    FSRead of a few KB is the intended cost. A source with more work
 *    than that must split it across calls and return short.
 *
 * 3. fill() DOES NOT ALLOCATE. No NewPtr, no NewHandle, no GetResource.
 *    The partition is 384 KB and the transfer is already in flight, so a
 *    failure here has nowhere to go but a cancelled transfer - and on
 *    this machine a memory failure under load arrives as heap corruption
 *    rather than as a NULL anyone checks. Whatever the source needs, it
 *    owns before the sender takes it.
 *
 * 4. fill() DOES NOT TOUCH THE WIRE. Not wire_idle(), not
 *    WaitNextEvent, not anything that reaches them. The sender pumps
 *    BETWEEN chunks, never inside one; a source that pumped would
 *    re-enter the state machine that is at that moment asking it a
 *    question. This is the same re-entry hazard proc68.c and vprobe68.c
 *    each carry a static guard for, and here it is excluded by contract
 *    instead.
 *
 * 5. THE SOURCE DOES NOT OUTLIVE THE TRANSFER. close() is called exactly
 *    once for every source the sender accepts, on every ending there is -
 *    completion, refusal, cancellation, a dropped connection, quit - and
 *    the sender touches nothing behind the interface afterwards. A source
 *    holding an open fork may rely on that, and on nothing else.
 *
 * A SHORT FILL IS NORMAL AND NOT AN ERROR. Returning fewer bytes than
 * `cap` without setting *done is how a source that reads in its own units
 * keeps promise (2). The sender re-asks.
 */

#include <stddef.h>

typedef struct N68ByteSourceOps {
    /* Produce up to `cap` bytes into `dst`. Returns the count (0..cap),
       or -1 if the source has failed and the transfer must be abandoned.

       Sets *done to 1 when the bytes returned by THIS call are the last
       ones, so a source that knows it has finished says so without
       costing an extra call. *done is 0 on entry; a source that only
       discovers the end on the following call may return 0 with *done
       set, and that is legal too.

       Returning 0 with *done clear means "nothing right now". It is
       legal, but the sender has no way to wait for a source, so one that
       answers this forever stalls its own transfer with no error to
       report. Return short instead. */
    long (*fill)(void *ctx, void *dst, long cap, int *done);

    /* Release everything the source holds. Called exactly once per
       source the sender took - see promise (5). Returns nothing on
       purpose: there is nothing useful to do about a failed close, and
       reporting it would replace the real outcome with a worse one. Same
       reasoning as n68_putrx.h's discard(). */
    void (*close)(void *ctx);
} N68ByteSourceOps;

typedef struct {
    /* Required, like every ops table in this guest, and never tested for
       NULL before it is called: a half-wired source that silently sends
       nothing is worse than the crash that names it. */
    const N68ByteSourceOps *ops;
    void *ctx;      /* the source's own, handed back untouched */
    long total;     /* exact; see promise (1) */
} N68ByteSource;

#endif /* NOW68K_BYTESRC_H */
