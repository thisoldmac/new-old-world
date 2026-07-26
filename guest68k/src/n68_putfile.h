#ifndef NOW68K_PUTFILE_H
#define NOW68K_PUTFILE_H

/*
 * The File Manager behind n68_putrx.h's ops table: where an incoming
 * file actually lands on a System 7.1 disk.
 *
 * Everything in here is a Toolbox call and nothing in here is a
 * decision. The judgements - is there room, is the name legal, did the
 * whole stream arrive, does the checksum agree - live in n68_putrx.c
 * where they can be tested off-metal. This file is the part that cannot
 * be, so it is kept as small and as dull as it can be made.
 *
 * ---- Where files land, and why it is the application's own folder ----
 *
 * NOW-68K has no preferences and no share root. That is a product
 * property rather than an omission (main.c's header, and the README say
 * so), so there is nothing to read a destination out of and no dialog
 * this thing is allowed to put up. The application's own folder is the
 * one place a person can find without being told, it is where the dev
 * settings file and the logs already are (n68_devsettings_file.c,
 * log.c), and it needs no new state to remember.
 *
 * That is a SPIKE decision, not a product one. A real share is a real
 * decision - which volume, which folder, who chooses it, what stops a
 * host writing over the application - and none of that is settled here.
 * The contract's `path` is honoured relative to this folder, so the
 * shape is already the shape a share would have; only the root moves.
 *
 * ---- Bytes land under a temporary name -------------------------------
 *
 * "NOW incoming <hex>" in the destination folder, renamed on success.
 * A truncated file that appears under the real name is something a human
 * double-clicks, and on this machine the real name is often an
 * application. The PowerPC guest stages the same way and for the same
 * reason (now/guest/src/fileshare.h).
 *
 * ---- No completion routines, no interrupt time ------------------------
 *
 * Every call here is the synchronous high-level form, made from the main
 * loop, exactly like log.c. That is the same standing precondition
 * net.h documents: nothing of ours runs at interrupt time, and virtual
 * memory must stay off. A 4 MB transfer means several hundred FSWrite
 * calls, each of which blocks the cooperative event loop for as long as
 * the disk takes - measured at ~12 ms per 32 KB on the PowerBook 1400c
 * (docs/large-transfers.md), which is why the batch is 8 KB rather than
 * something larger that would stall the wire noticeably.
 */

#include "n68_putrx.h"

#include <Files.h>

/* One in-flight destination. File scope in wire68.c, never on a stack:
 * an FSSpec is 70 bytes and this holds two of them plus the open fork,
 * and it has to outlive every call between file.offer and file.done. */
typedef struct {
    short  vref;
    long   dir;              /* the destination folder's dirID */
    FSSpec temp;             /* what is being written */
    FSSpec final;            /* what it becomes on success */
    short  ref;              /* open data fork; 0 when closed */
    int    have_temp;        /* a staging file exists on disk */
    OSType file_type, creator;
    unsigned long modified;  /* Mac epoch seconds, straight from the offer */
    int    overwrite;
    OSErr  err;              /* the OSErr behind the last failure */
} N68PutFile;

/* The ops table to hand n68_putrx_init, with a N68PutFile as its ctx. */
const N68PutFileOps *now68k_putfile_ops(void);

/* Puts a N68PutFile at "nothing in flight". Call once at startup. */
void now68k_putfile_init(N68PutFile *pf);

/* The OSErr behind the most recent failure, or noErr. "The File Manager
 * refused" names no cause; the number does, and on this machine the
 * number is often the whole diagnosis. */
OSErr now68k_putfile_last_error(const N68PutFile *pf);

/* The destination folder's name, for the console to say where things
 * land. Empty when it cannot be resolved. `out` is a C string. */
void now68k_putfile_where(char *out, long cap);

#endif /* NOW68K_PUTFILE_H */
