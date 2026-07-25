#ifndef N68_CONSOLE_RING_H
#define N68_CONSOLE_RING_H

/*
 * Fixed-capacity scrollback ring for the Console tab. Feeds raw wire
 * bytes through n68_linesplit and stores completed lines in a circular
 * buffer sized at compile time - no malloc/NewPtr/NewHandle. No Toolbox
 * calls: this file exposes data for a caller to draw, it does not draw.
 *
 * Memory budget: N68_CONSOLE_RING_CAPACITY * N68_LINE_CAPACITY
 *              = 32 * 256 = 8192 bytes (8 KB) of line storage,
 *              plus one size_t length per slot (32 * 4 = 128 bytes on a
 *              32-bit target) and a handful of scalar counters - call it
 *              8.2 KB total. That is under 1% of the 1 MB free-memory
 *              design target, leaving headroom for the rest of the app.
 */

#include <stddef.h>

#include "n68_linesplit.h"

enum {
    /* See n68_linesplit.h - 32 lines of 256-byte scrollback. Raise this
     * alone to trade RAM for deeper history once the PB 180c's actual
     * viewport row count is known. */
    N68_CONSOLE_RING_CAPACITY = 32
};

typedef struct N68ConsoleLine {
    const char *text;
    size_t length;
} N68ConsoleLine;

typedef struct N68ConsoleRing {
    char lines[N68_CONSOLE_RING_CAPACITY][N68_LINE_CAPACITY];
    size_t lengths[N68_CONSOLE_RING_CAPACITY];

    /* Total lines ever appended (not clamped to capacity). Logical line
     * index `total_appended - 1` is the newest; slot for logical index L
     * is L % N68_CONSOLE_RING_CAPACITY. This is the whole ring: no
     * separate head/tail bookkeeping needed. */
    unsigned long total_appended;

    /* Bumped once for every visible-state change (a line appended, or
     * the dropped-line counter moving) and never otherwise. The view
     * reads this once per event-loop pass and repaints only when it
     * differs from the value it last saw - idle work stays free. */
    unsigned long generation;

    N68LineSplit splitter;
} N68ConsoleRing;

void n68_console_init(N68ConsoleRing *ring);

/* Appends `length` bytes as received off the wire. Internally drives the
 * line splitter and copies each completed line into the ring, evicting
 * the oldest stored line once the ring is full. */
void n68_console_feed(N68ConsoleRing *ring, const char *data, size_t length);

/* Lines dropped for exceeding N68_LINE_CAPACITY - a wire bug or garbage
 * data, not something the ring truncates silently. */
unsigned long n68_console_dropped_line_count(const N68ConsoleRing *ring);

unsigned long n68_console_generation(const N68ConsoleRing *ring);

/* Number of lines currently retained (<= N68_CONSOLE_RING_CAPACITY). */
size_t n68_console_retained_count(const N68ConsoleRing *ring);

/* Fills out_lines[0 .. row_capacity) with the visible slice starting at
 * retained-line offset `first_index` (0 = oldest line still retained,
 * n68_console_retained_count(ring) - 1 = newest). Returns the number of
 * rows actually filled, which is less than row_capacity once the slice
 * runs off the newest retained line. Pure data access: no drawing, no
 * Toolbox calls, safe to call from a host unit test. */
size_t n68_console_visible_slice(const N68ConsoleRing *ring,
                                  size_t first_index,
                                  N68ConsoleLine *out_lines,
                                  size_t row_capacity);

#endif
