/* n68_filelist.c - implementation of n68_filelist.h. No Toolbox, no
 * allocation, no printf family (numfmt.h only, matching the rest of this
 * guest), so guest68k/tests/test_filelist.c can compile and run it here. */

#include "n68_filelist.h"

#include "numfmt.h"

#include <string.h>

/* ---- file.listing --------------------------------------------------------- */

/* One entry's bytes, appended whole or not at all. The caller restores
 * `pos` on a 0 return: numfmt.h leaves it unspecified on failure, so it
 * cannot be trusted to have stopped anywhere in particular. */
static int append_entry(const N68FileRow *row, int first,
                        char *out, long avail, long *pos)
{
    int ok = 1;

    ok = ok && now68k_fmt_append_str(out, avail, pos, first ? "{" : ",{");
    ok = ok && now68k_fmt_append_str(out, avail, pos, "\"name\":\"");
    ok = ok && now68k_json_append_escaped(out, avail, pos, row->name);
    ok = ok && now68k_fmt_append_str(out, avail, pos, "\",\"kind\":\"");
    ok = ok && now68k_fmt_append_str(out, avail, pos,
                                      row->folder ? "folder" : "file");
    ok = ok && now68k_fmt_append_str(out, avail, pos, "\"");

    /* A folder has no type, no creator and no forks. The PowerPC guest
     * omits them there too, and the schema makes all four optional - a
     * folder carrying "dataBytes":0 would be answering a question nobody
     * asked, in the frame where there is least room to answer it. */
    if (!row->folder) {
        ok = ok && now68k_fmt_append_str(out, avail, pos, ",\"fileType\":\"");
        ok = ok && now68k_json_append_escaped(out, avail, pos, row->file_type);
        ok = ok && now68k_fmt_append_str(out, avail, pos, "\",\"creator\":\"");
        ok = ok && now68k_json_append_escaped(out, avail, pos, row->creator);
        ok = ok && now68k_fmt_append_str(out, avail, pos, "\",\"dataBytes\":");
        ok = ok && now68k_fmt_append_long(out, avail, pos, row->data_bytes);
        ok = ok && now68k_fmt_append_str(out, avail, pos, ",\"rsrcBytes\":");
        ok = ok && now68k_fmt_append_long(out, avail, pos, row->rsrc_bytes);
    }
    ok = ok && now68k_fmt_append_str(out, avail, pos, ",\"modified\":");
    /* Unsigned: `long` is 32 bits signed on this toolchain, so a Mac epoch
     * second past 2040 comes out NEGATIVE through append_long - and a
     * negative date decodes perfectly well into 1904. Same hazard the send
     * half's file.offer carries, same fix (n68_puttx.c). */
    ok = ok && now68k_fmt_append_u32(out, avail, pos, row->modified);
    ok = ok && now68k_fmt_append_str(out, avail, pos, "}");
    return ok;
}

long n68_filelist_build(long id, const char *path, long cursor,
                        const N68FileRow *rows, long row_count,
                        int more_beyond, const char *root,
                        char *out, long cap,
                        long *next_cursor, int *more)
{
    long avail = cap > 0 ? cap - 1 : 0;   /* one byte held for the NUL */
    long pos = 0;
    long emitted = 0;
    long i;
    int ok = 1;
    int left_over;

    if (cursor < 1) {
        cursor = 1;   /* an absent cursor means the first page */
    }
    if (path == NULL) {
        path = "";
    }
    if (next_cursor != NULL) {
        *next_cursor = cursor;
    }
    if (more != NULL) {
        *more = more_beyond ? 1 : 0;
    }
    if (out == NULL || avail <= 0) {
        return 0;
    }

    ok = ok && now68k_fmt_append_str(out, avail, &pos,
                                      "{\"type\":\"file.listing\",\"id\":");
    ok = ok && now68k_fmt_append_long(out, avail, &pos, id);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, ",\"path\":\"");
    ok = ok && now68k_json_append_escaped(out, avail, &pos, path);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, "\",\"entries\":[");
    if (!ok) {
        out[0] = '\0';
        return 0;
    }

    for (i = 0; i < row_count; ++i) {
        long saved = pos;

        /* Room for the tail is checked BEFORE committing to a row. A page
         * that spends its last bytes on an entry and then cannot close the
         * JSON is a frame that decodes to nothing - the whole page lost to
         * save one row of it. */
        if (!append_entry(&rows[i], emitted == 0, out, avail, &pos)
            || pos > avail - NOW68K_FILELIST_TAIL_MAX) {
            pos = saved;
            break;
        }
        ++emitted;
    }

    /* A page with rows left to give and none in it would make the host ask
     * again for the same cursor forever. Refuse instead: the caller's
     * buffer is below NOW68K_FILELIST_MIN_CAP, which is a build-time bug,
     * and the static assert at the send site is what keeps it unreachable. */
    if (emitted == 0 && row_count > 0) {
        out[0] = '\0';
        return 0;
    }

    left_over = (emitted < row_count) || more_beyond;
    ok = ok && now68k_fmt_append_str(out, avail, &pos, "],\"more\":");
    ok = ok && now68k_fmt_append_str(out, avail, &pos,
                                      left_over ? "true" : "false");
    ok = ok && now68k_fmt_append_str(out, avail, &pos, ",\"cursor\":");
    ok = ok && now68k_fmt_append_long(out, avail, &pos, cursor + emitted);
    if (!ok) {
        out[0] = '\0';
        return 0;
    }

    /* Only the root listing carries `root`: it names the place, and a
     * subfolder listing already knows where it is. Appended last and
     * dropped WHOLE if it does not fit - the field is a caption, and half a
     * caption truncates the frame mid-string and costs the whole listing.
     * Built into the live buffer and rolled back rather than staged in a
     * second one: 400 bytes of stack for a label is not a trade this
     * partition can make. */
    if (root != NULL && root[0] != '\0' && path[0] == '\0') {
        long saved = pos;
        int fit = 1;

        fit = fit && now68k_fmt_append_str(out, avail, &pos, ",\"root\":\"");
        fit = fit && now68k_json_append_escaped(out, avail, &pos, root);
        fit = fit && now68k_fmt_append_str(out, avail, &pos, "\"");
        /* One byte for the closing brace, which is not optional. */
        if (!fit || pos >= avail) {
            pos = saved;
        }
    }

    if (!now68k_fmt_append_str(out, avail, &pos, "}") || pos <= 0) {
        out[0] = '\0';
        return 0;
    }
    out[pos] = '\0';
    if (next_cursor != NULL) {
        *next_cursor = cursor + emitted;
    }
    if (more != NULL) {
        *more = left_over ? 1 : 0;
    }
    return pos;
}

/* ---- the `ls` command ----------------------------------------------------- */

/* KB, rounded down, the way the PowerPC guest's now_files_describe does it.
 * A 400-byte file reading "0 KB" is the same answer both machines give, and
 * two consoles disagreeing about one disk is worse than a coarse unit. */
static int append_kb(char *out, long cap, long *pos, long bytes)
{
    return now68k_fmt_append_long(out, cap, pos, bytes / 1024);
}

void n68_filelist_describe(const N68FileRow *row, char *out, long cap)
{
    long avail = cap > 0 ? cap - 1 : 0;
    long pos = 0;
    int ok = 1;

    if (out == NULL || cap <= 0) {
        return;
    }
    if (row->folder) {
        if (!now68k_fmt_append_str(out, avail, &pos, "folder")) {
            pos = 0;
        }
        out[pos] = '\0';
        return;
    }

    ok = ok && now68k_fmt_append_str(out, avail, &pos,
                                      row->file_type[0] != '\0'
                                          ? row->file_type : "????");
    ok = ok && now68k_fmt_append_str(out, avail, &pos, "  ");
    if (row->rsrc_bytes > 0 && row->data_bytes > 0) {
        ok = ok && append_kb(out, avail, &pos, row->data_bytes);
        ok = ok && now68k_fmt_append_str(out, avail, &pos, " KB + ");
        ok = ok && append_kb(out, avail, &pos, row->rsrc_bytes);
        ok = ok && now68k_fmt_append_str(out, avail, &pos, " KB rsrc");
    } else if (row->rsrc_bytes > 0) {
        ok = ok && append_kb(out, avail, &pos, row->rsrc_bytes);
        ok = ok && now68k_fmt_append_str(out, avail, &pos, " KB rsrc");
    } else {
        ok = ok && append_kb(out, avail, &pos, row->data_bytes);
        ok = ok && now68k_fmt_append_str(out, avail, &pos, " KB");
    }
    if (!ok || pos < 0 || pos > avail) {
        pos = 0;   /* a description that did not fit says nothing rather
                    * than something half-written */
    }
    out[pos] = '\0';
}

void n68_filelist_rows(const char *path, const char *root,
                       const N68FileRow *rows, long row_count,
                       int more_beyond, N68CmdRows *out)
{
    long i;

    if (out == NULL) {
        return;
    }
    n68_cmdrows_init(out);
    out->ok = 1;
    /* The output key the contract's `ls` x-command declares. */
    strcpy(out->key, "ls");

    /* Two heading rows first, for the same reason the PowerPC guest's
     * run_ls emits them: a listing that does not say where it is looking
     * is a listing a person has to guess about, and on this guest the
     * place is not configurable and therefore not obvious. */
    (void)n68_cmdrows_add(out, "Share", root != NULL ? root : "(unknown)");
    (void)n68_cmdrows_add(out, "Folder",
                          (path != NULL && path[0] != '\0') ? path : "(root)");

    for (i = 0; i < row_count; ++i) {
        char value[kN68CmdRowValueCap];

        n68_filelist_describe(&rows[i], value, (long)sizeof value);
        if (!n68_cmdrows_add(out, rows[i].name, value)) {
            more_beyond = 1;   /* the table filled before the folder did */
            break;
        }
    }

    if (more_beyond) {
        /* Distinct from the JSON renderer's own "N more not shown", which
         * counts rows this table HELD and the frame could not carry. This
         * one says the folder goes on past what was enumerated at all -
         * two different reasons for a short list, and a reader that saw
         * only one of them would draw the wrong conclusion about the
         * other. */
        (void)n68_cmdrows_add(out, "...", "more entries follow");
    }
}
