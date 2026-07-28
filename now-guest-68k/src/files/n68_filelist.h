/*
 * n68_filelist.h - the file.listing serializer, Toolbox-free.
 *
 * NOW-68K's share of the symmetric file family's BROWSE half: "whoever
 * RECEIVES file.list serves its OWN share" (contract/asyncapi.yaml,
 * hostBrowsesFiles). n68_fileenum.h walks the catalog; this module turns
 * one page of that walk into one file.listing, and into the `ls` command's
 * rows. It is split off for the reason n68_proclist.c is: the paging
 * arithmetic and the never-truncate-a-row rule are the parts that get
 * subtly wrong, and here they can be tested by the host cc with no
 * Macintosh anywhere near them.
 *
 * This direction needed NO CONTRACT CHANGE. FileList and FileListing have
 * been in contract/asyncapi.yaml since revision 1, the host already decodes
 * both (ContractMessages.swift), and the PowerPC guest already answers them
 * (now-guest-ppc/src/core/wire.c, serve_file_list). Checked rather than assumed, per
 * AGENTS.md - a behaviour change starts at the contract, and this one is
 * additive on this guest alone.
 *
 * ---- The page is small here, and that is the honest answer -------------
 *
 * The PowerPC guest fits sixteen entries in a page because its control
 * frames run to 4 KB. NOW-68K's outbound payload cap is 1024 bytes
 * (NOW68K_CONTROL_SEND_CAP, wire68.h), sized against a 384 KB partition
 * where every slot is charged four times over. So a page here carries
 * whatever fits - typically six or seven entries, and in the worst case
 * ONE, because an HFS name is MacRoman and a name of 31 accented
 * characters escapes to 186 bytes of \uXXXX.
 *
 * That is paging working, not paging failing: `more` and `cursor` say so,
 * and the host asks again. What must never happen is the other two
 * outcomes, and both are ruled out below - a page that truncates a row
 * mid-JSON (which decodes to nothing on the host and costs the WHOLE page),
 * and an empty page with more:true (which makes the host page forever).
 *
 * THE PAGE SIZE IS NOT A NUMBER, exactly as n68_proclist.h says: it is
 * whatever fits the caller's buffer, bounded above by the contract's own
 * maxItems. The _MAX values below are not a second statement of the wire's
 * limit - they are the worst-case sizes of the PARTS, which is what lets a
 * compiler check at build time that a page can always hold one row.
 */
#ifndef NOW68K_N68_FILELIST_H
#define NOW68K_N68_FILELIST_H

#include "n68_cmdresult.h"

/* FileListing.entries has maxItems: 16 in the contract. A page stops there
 * even if the buffer would hold more - the schema is the limit, not our
 * buffer. (In practice the buffer stops it first; see the header.) */
#define NOW68K_FILELIST_MAX_ROWS 16

/* Longest relative path this guest will list, before escaping. The
 * contract puts no ceiling on FileList.path, so this is ours, and it is
 * stated here because both the refusal that enforces it and the head-size
 * bound below are derived from it.
 *
 * 64 rather than the 224 the receive half accepts (kN68PutPathCap): the
 * path is ECHOED in every page of the reply, and at six bytes per escaped
 * MacRoman character a 224-byte path alone would be 1344 bytes - larger
 * than the whole frame. A path longer than this is refused with bad-path
 * rather than silently shortened onto a folder nobody asked for.
 *
 * The two numbers being different is deliberate and is the one asymmetry
 * between the browse and receive halves. It is safe in the direction that
 * matters: everything this guest will LIST, it will also accept a file
 * into. */
#define NOW68K_FILELIST_PATH_MAX 64

/* Same ceiling for the root LABEL, which is display-only text the guest
 * composes from its own volume and folder names. */
#define NOW68K_FILELIST_ROOT_MAX 64

/* One catalog entry, in plain C so this file never sees a CInfoPBRec or a
 * Str255. n68_fileenum.h fills these; nothing else does.
 *
 * NO `identity`. The contract's FileEntry.identity is optional and is a
 * responder-generated precondition for MUTATIONS - "a mutation may carry it
 * back only as a guest-side precondition recomputed immediately before
 * acting". NOW-68K serves no mutation in this family: no file.move, no
 * file.trash, no file.get. A token whose only purpose is to guard an
 * operation this guest refuses would be 30 bytes a page of a 1024-byte
 * frame spent on a promise it cannot keep, and the host does not read it
 * (nothing in now-host/Sources reads FileEntry.identity). It is the field to
 * add first if a mutation ever lands here. */
typedef struct {
    char          name[32];       /* HFS leaf, 31 + NUL */
    char          file_type[5];   /* "TEXT"; "" for a folder */
    char          creator[5];
    unsigned char folder;
    long          data_bytes;
    long          rsrc_bytes;
    unsigned long modified;       /* Mac epoch seconds, straight from the
                                   * catalog - unsigned because a date past
                                   * 2040 is negative in this toolchain's
                                   * 32-bit signed long, and a negative
                                   * date decodes fine and lands in 1904 */
} N68FileRow;

/* Worst cases, in bytes, of the three parts of the message. Each is the
 * exact count plus a little slack, and test_filelist.c builds the actual
 * worst case and fails if it grows past these - a bound nobody re-measures
 * is a bound that quietly stopped being one.
 *
 *   head  {"type":"file.listing","id":<11>,"path":"<64 escaped>",
 *         "entries":[                                             = 445
 *   row   ,{"name":"<31 escaped>","kind":"folder","fileType":"<4
 *         escaped>","creator":"<4 escaped>","dataBytes":<11>,
 *         "rsrcBytes":<11>,"modified":<10>}                        = 359
 *   tail  ],"more":false,"cursor":<11>} + NUL                      =  36
 *
 * `root` is NOT in this arithmetic. It is appended only if it fits, and
 * dropped whole if it does not - see the note at the build function. */
#define NOW68K_FILELIST_HEAD_MAX 448
#define NOW68K_FILELIST_ROW_MAX  368
#define NOW68K_FILELIST_TAIL_MAX  40

/* The smallest buffer that can carry a page with a row in it. Anything less
 * and every page is empty-with-more:true, which is an infinite paging loop
 * rather than a small listing. */
#define NOW68K_FILELIST_MIN_CAP                                            \
    (NOW68K_FILELIST_HEAD_MAX + NOW68K_FILELIST_ROW_MAX                    \
     + NOW68K_FILELIST_TAIL_MAX)

/* Builds ONE page of file.listing into out[0, cap).
 *
 * id        - echoed from the request (required by the schema).
 * path      - the request's path, echoed verbatim (required). "" is the
 *             root. Longer than NOW68K_FILELIST_PATH_MAX is a caller bug:
 *             refuse it before getting here, because a page that cannot
 *             echo its own path cannot be built at all.
 * cursor    - the 1-based catalog index `rows[0]` was read from. This is
 *             what next_cursor counts on from; the rows are ALREADY
 *             positioned, unlike n68_proclist_build's whole snapshot,
 *             because a catalog walk pages at the source rather than in
 *             memory.
 * rows      - the entries read for this page, in catalog order.
 * row_count - how many of `rows` are valid.
 * more_beyond - 1 if the enumerator saw at least one entry past `rows`.
 *             Combined with any rows this page could not fit.
 * root      - the share's own name for the place, or NULL. Emitted only
 *             for the root listing (a subfolder listing already knows
 *             where it is) and only if it fits - see below.
 * out/cap   - destination; cap must be >= NOW68K_FILELIST_MIN_CAP for a
 *             non-empty page to be possible.
 * next_cursor - OUT, may be NULL. The cursor a host sends to continue:
 *             cursor + rows actually emitted.
 * more      - OUT, may be NULL. 1 if entries remain past this page,
 *             whether because the enumerator saw more or because a row did
 *             not fit.
 *
 * Returns the bytes written before the NUL, or 0 if the page could not be
 * built - which happens only when cap cannot hold the envelope, or when
 * rows remain and not one of them fits. Both are caller bugs (the static
 * assert at wire68.c's send site makes them unreachable in the shipping
 * build) and both are refusals rather than a short page.
 *
 * A cursor past the end is NOT a failure: it produces a legitimate empty
 * final page with more:false, which is what a host that raced a folder
 * being emptied should see.
 *
 * `root` is appended last and dropped whole if it does not fit. Dropping
 * the label costs the host a caption; half a label would truncate the frame
 * mid-string and cost it the entire listing. The PowerPC guest's
 * serve_file_list makes the same trade for the same reason.
 *
 * Every string that reaches the wire is escaped by
 * now68k_json_append_escaped (n68_cmdresult.h) - one implementation, so a
 * MacRoman file name cannot be corrupted here in a way it is not corrupted
 * everywhere else.
 */
long n68_filelist_build(long id, const char *path, long cursor,
                        const N68FileRow *rows, long row_count,
                        int more_beyond, const char *root,
                        char *out, long cap,
                        long *next_cursor, int *more);

/* ---- the same rows, as the `ls` command --------------------------------- */

/* Describes one entry the way a person reads it: "folder", or the file's
 * type and its fork sizes in KB. Byte-for-byte the PowerPC guest's
 * now_files_describe (now-guest-ppc/src/files/fileshare.c), because the two consoles
 * should not describe one machine's disk in two different vocabularies.
 * `out` is NUL-terminated; cap should be kN68CmdRowValueCap. */
void n68_filelist_describe(const N68FileRow *row, char *out, long cap);

/* Renders the SAME rows as the `ls` command's table.
 *
 * The second renderer over one enumeration (docs/command-parity.md):
 * n68_fileenum.c walks the catalog once, n68_filelist_build renders that
 * walk as file.listing for the host's Files module, and this renders it as
 * the contract's [label, value] rows - which n68_cmdresult.h then renders
 * as JSON for the host's console (a dumb shell that knows no message
 * families) or as text for a person at the PowerBook.
 *
 * `ls` does NOT paginate: the contract gives command.result no cursor, and
 * a console has none to send back. So a folder longer than one page is
 * truncated, and the truncation is STATED - a trailing ["...", "more
 * entries follow"] row when the enumerator saw more, and a second, separate
 * statement from the JSON renderer if the buffer ran out first. Two
 * different reasons for a short list, both said out loud, because a short
 * list that silently claimed to be the whole folder is the failure this
 * exists to prevent.
 *
 * path is the folder as the request named it (""), root is the share's own
 * name for the place; both become heading rows so a listing says WHERE it
 * is looking. Fills `out` completely - the caller does not init it.
 */
void n68_filelist_rows(const char *path, const char *root,
                       const N68FileRow *rows, long row_count,
                       int more_beyond, N68CmdRows *out);

#endif /* NOW68K_N68_FILELIST_H */
