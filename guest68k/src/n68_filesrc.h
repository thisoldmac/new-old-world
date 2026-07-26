#ifndef NOW68K_FILESRC_H
#define NOW68K_FILESRC_H

/*
 * A file's data fork, behind n68_bytesrc.h. The FIRST implementation of
 * that interface, and deliberately not the only one it was shaped for -
 * read n68_bytesrc.h before writing a second.
 *
 * This is the send-side twin of n68_putfile.h: everything here is a File
 * Manager call and nothing here is a decision. What to send, whether it
 * fits, when it ends and what its checksum is all live in n68_puttx.c,
 * where a test can reach them.
 *
 * ---- Which fork, and what this does NOT do ---------------------------
 *
 * The DATA fork, always. The contract's container rule is that data-only
 * files travel as the raw data fork, resource-only files as MacBinary,
 * and a file with both defaults to the data fork with MacBinary only on
 * request (contract/asyncapi.yaml, guestServesFiles). So sending the
 * data fork is the contract's own default and not a shortcut - but it
 * does mean a file whose content lives in its RESOURCE fork (most
 * classic Mac applications, and every ResEdit document) arrives as a
 * zero-length or meaningless file.
 *
 * MacBinary encoding is not implemented here, and that is the honest gap
 * rather than a hidden one: it is a second source (a header, then the
 * data fork, then padding, then the resource fork, each in bands) and it
 * is exactly the second implementation this interface exists to make
 * cheap. It is in docs/open-issues.md.
 *
 * ---- Promise (2), on a machine with a real disk ----------------------
 *
 * fill() is one synchronous FSRead of at most the chunk (4096), from the
 * main loop, like everything else in this guest. Measured on the
 * PowerBook 1400c at ~12 ms per 32 KB (docs/large-transfers.md), so a
 * 4 KB read is roughly 1.5 ms of deafness per chunk - well inside what
 * the wire tolerates, and the reason the chunk is not larger.
 */

#include "n68_bytesrc.h"

#include <Files.h>

/* One open source. File scope in wire68.c, never on a stack: it has to
 * outlive every call from file.offer to file.end. */
typedef struct {
    short ref;          /* open data fork; 0 when closed */
    long  remaining;    /* bytes not yet read */
    OSErr err;          /* the OSErr behind the last failure, or noErr */
} N68FileSrc;

/* Opens `leaf` in the application's own folder for reading and fills
 * `out` with a byte source over its data fork.
 *
 * Returns 1 on success. On success the CALLER still owns the source
 * until n68_puttx_begin() takes it - and if that refuses, the caller
 * must close it itself (out->ops->close), because a begin that refuses
 * takes nothing.
 *
 * On 0 nothing was opened and `fs->err` names why. The metadata outs may
 * be NULL when the caller does not want them; `name_out` receives the
 * leaf as a C string, which is the name the file will land under on the
 * host.
 */
int now68k_filesrc_open(N68FileSrc *fs, const char *leaf,
                        N68ByteSource *out,
                        char *name_out, long name_cap,
                        char *type_out, char *creator_out,
                        unsigned long *modified_out);

/* The OSErr behind the most recent failure, or noErr. "Could not read
 * that file" names no cause; the number does, and on this machine the
 * number is usually the whole diagnosis. */
OSErr now68k_filesrc_last_error(const N68FileSrc *fs);

#endif /* NOW68K_FILESRC_H */
