#include "n68_linesplit.h"

#include <string.h>

void n68_linesplit_init(N68LineSplit *split)
{
    memset(split, 0, sizeof(*split));
}

static int emit_line(N68LineSplit *split, N68LineCallback callback,
                      void *context)
{
    if (split->dropping) {
        split->partial_length = 0;
        split->dropping = 0;
        split->truncated_line_count++;
        return 0;
    }
    /* A zero-length partial is a real empty line (two terminators back to
     * back, or a terminator with nothing before it), not "no line here" -
     * it must still reach the callback. The byte that would otherwise
     * make this look like the tail of a CRLF pair never gets this far:
     * skip_lf's `continue` in the feed loop consumes it before the
     * '\r'/'\n' check that calls emit_line, so every call here already
     * corresponds to exactly one real terminator. */
    split->partial[split->partial_length] = '\0';
    callback(split->partial, split->partial_length, context);
    split->partial_length = 0;
    return 1;
}

int n68_linesplit_feed(N68LineSplit *split, const char *data, size_t length,
                        N68LineCallback callback, void *context)
{
    size_t i;
    int emitted = 0;

    for (i = 0; i < length; i++) {
        unsigned char value = (unsigned char)data[i];

        if (split->skip_lf) {
            split->skip_lf = 0;
            if (value == '\n') {
                continue;
            }
        }
        if (value == '\r' || value == '\n') {
            emitted += emit_line(split, callback, context);
            split->skip_lf = value == '\r';
        } else if (!split->dropping) {
            if (split->partial_length + 1 < sizeof(split->partial)) {
                split->partial[split->partial_length++] = (char)value;
            } else {
                split->dropping = 1;
            }
        }
    }
    return emitted;
}

unsigned long n68_linesplit_truncated_lines(const N68LineSplit *split)
{
    return split == NULL ? 0 : split->truncated_line_count;
}
