#ifndef N68_LINESPLIT_H
#define N68_LINESPLIT_H

/*
 * Zero-allocation byte-stream -> line splitter. Ported from
 * timbottu/codekitten/core/transcript_model.{h,c} and renamed under this
 * project's n68_ ownership prefix. Same terminator contract as the
 * original: CR, LF, and CRLF all end a line - a bare CR immediately
 * followed by a bare LF is ONE line break, not two. A line that does not
 * fit in N68_LINE_CAPACITY bytes is DROPPED and counted, never silently
 * truncated. No Toolbox calls, no malloc/NewPtr/NewHandle - this file
 * builds and tests on the host.
 *
 * Departs from the ported original in one place: an empty line (two
 * terminators back to back) is emitted like any other line instead of
 * being swallowed. The original fed a transcript model where a run of
 * blank lines was noise; this one feeds console output straight off the
 * wire, where a blank line is content (e.g. a paragraph break) that must
 * not silently disappear.
 */

#include <stddef.h>

enum {
    /* Console log/status lines rarely need more than a terminal width;
     * 256 bytes (255 chars + NUL) leaves slack for prefixes/timestamps
     * while keeping N68_CONSOLE_RING_CAPACITY lines of ring storage cheap
     * (see n68_console_ring.h, which sizes its slots to this constant). */
    N68_LINE_CAPACITY = 256
};

/*
 * Unlike the ported original's callback (which handed back only a NUL-
 * terminated C string), this one also passes the line's length. The
 * splitter already knows it exactly - passing it avoids a strlen() over
 * the line in the ring's append path, a scan the 68K has no reason to
 * redo. The buffer is still NUL-terminated at `length` for callers that
 * want plain C-string semantics too.
 */
typedef void (*N68LineCallback)(const char *line, size_t length,
                                 void *context);

typedef struct N68LineSplit {
    char partial[N68_LINE_CAPACITY];
    size_t partial_length;
    int dropping;
    unsigned long truncated_line_count;
    int skip_lf;
} N68LineSplit;

void n68_linesplit_init(N68LineSplit *split);

/* Feeds `length` bytes of wire data through the splitter. Calls
 * `callback` once per completed line (CR, LF, or CRLF - a CRLF is one
 * line break, not two). Returns the number of lines emitted by this
 * call. */
int n68_linesplit_feed(N68LineSplit *split, const char *data, size_t length,
                        N68LineCallback callback, void *context);

unsigned long n68_linesplit_truncated_lines(const N68LineSplit *split);

#endif
