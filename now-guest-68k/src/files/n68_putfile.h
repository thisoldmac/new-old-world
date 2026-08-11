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
 * ---- Where files land: the Desktop -----------------------------------
 *
 * NOW-68K has no preferences and no share root - a product property
 * rather than an omission (main.c's header and the README both say so)
 * - so there is nothing to read a destination out of and no dialog this
 * thing is allowed to put up. The Desktop needs none of that: the
 * Folder Manager knows where it is, it is where a person looks for
 * something that just arrived, and nothing on the system cares what
 * appears there.
 *
 * It was the application's own folder, briefly, and that had an obvious
 * hazard: a host could write into the folder the application lives in,
 * which on this machine is frequently the System Folder.
 *
 * NOT A SHARE, and deliberately not gated. The contract's `path` still
 * resolves relative to this root, so a host may name a subfolder and
 * nothing stops it reaching one. That is the right amount of structure
 * for now - a boundary drawn before there is anything to browse would be
 * a guess dressed as a policy.
 *
 * There IS something to browse now: file.list and `ls` land here too
 * (n68_fileenum.h), which is why now68k_desktop_folder() is published.
 * Three directions, one root, decided in one place - and they share
 * n68_putrx_path_ok() for what a path may say, so a folder a host can
 * list is a folder it can also be written into.
 *
 * ---- Bytes land under a temporary name -------------------------------
 *
 * "NOW incoming <hex>" in the destination folder, renamed on success.
 * A truncated file that appears under the real name is something a human
 * double-clicks, and on this machine the real name is often an
 * application. The PowerPC guest stages the same way and for the same
 * reason (now/now-guest-ppc/src/files/fileshare.h).
 *
 * ---- MacBinary: two forks, one staging file ---------------------------
 *
 * n68_putrx.c decodes the envelope and says which fork each run belongs
 * to; this file opens the second one when first asked. The forks are
 * written in order - data, then resource - because that is the order
 * MacBinary stores them, and nothing here seeks: each fork is appended
 * to through its own refNum, and the File Manager keeps a separate mark
 * per refNum.
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
    short  rsrc_ref;         /* open resource fork; 0 when closed.
                                Opened lazily, on the first resource-fork
                                write a MacBinary transfer asks for - a
                                data-only file never opens one, and a
                                resource fork created and left empty is
                                not the same file as one never created. */
    int    have_temp;        /* a staging file exists on disk */
    OSType file_type, creator;
    unsigned long modified;  /* Mac epoch seconds, straight from the offer */
    int    overwrite;
    OSErr  err;              /* the OSErr behind the last failure */

    /* The resource fork's first 512 bytes, kept as they were WRITTEN so
       the head can be verified - and rewritten - after close. On the
       Mac OS 8.1 emulator, FSClose of a written resource fork splices
       77 bytes of File Manager catalog state into the fork's first
       block; see the read-back block in the .c for the evidence and
       docs/open-issues.md for the investigation. 512 bytes of BSS
       against a corruption that is otherwise silent. */
    unsigned char rsrc_head[512];
    long   rsrc_written;     /* total resource-fork bytes written */
} N68PutFile;

/* The application's own folder, through the Process Manager rather than
 * the launch default directory - which is NOT the same place, because
 * Rumpus deposits builds on the Desktop. Returns 1 and fills both, or 0.
 *
 * Published because BOTH directions of the file family must agree on
 * one root. Receiving lands here; sending reads from here. They were
 * briefly different roots - receive on the Desktop, send in the
 * application's own folder - which every native test passed and no
 * conflict marked, because only a real file system can notice that a
 * file put down in one place is looked for in another. The round-trip
 * ladder found it on the emulator as fnfErr on every rung. */
int now68k_desktop_folder(short *vref, long *dir);

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
