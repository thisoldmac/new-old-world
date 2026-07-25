#include "n68_console_ring.h"

#include <string.h>

static void append_line(const char *line, size_t length, void *context)
{
    N68ConsoleRing *ring = (N68ConsoleRing *)context;
    size_t slot = (size_t)(ring->total_appended % N68_CONSOLE_RING_CAPACITY);

    /* memcpy, not strcpy: n68_linesplit already bounds `length` to
     * < N68_LINE_CAPACITY, so no truncation check belongs here too. */
    memcpy(ring->lines[slot], line, length);
    ring->lines[slot][length] = '\0';
    ring->lengths[slot] = length;
    ring->total_appended++;
    ring->generation++;
}

void n68_console_init(N68ConsoleRing *ring)
{
    n68_linesplit_init(&ring->splitter);
    ring->total_appended = 0;
    ring->generation = 0;
    /* Line storage is left uninitialised on purpose: every read path
     * goes through n68_console_retained_count/lengths, so bytes past a
     * slot's recorded length are never observed. Zeroing 8 KB on every
     * (re)init is idle work this module does not need to pay for. */
}

void n68_console_feed(N68ConsoleRing *ring, const char *data, size_t length)
{
    unsigned long dropped_before =
        n68_linesplit_truncated_lines(&ring->splitter);

    n68_linesplit_feed(&ring->splitter, data, length, append_line, ring);

    if (n68_linesplit_truncated_lines(&ring->splitter) != dropped_before) {
        /* The dropped-line count is part of what the view shows (a "N
         * lines dropped" indicator), so a drop invalidates the view even
         * though no line was appended to the ring. */
        ring->generation++;
    }
}

unsigned long n68_console_dropped_line_count(const N68ConsoleRing *ring)
{
    return n68_linesplit_truncated_lines(&ring->splitter);
}

unsigned long n68_console_generation(const N68ConsoleRing *ring)
{
    return ring->generation;
}

size_t n68_console_retained_count(const N68ConsoleRing *ring)
{
    return ring->total_appended < N68_CONSOLE_RING_CAPACITY
               ? (size_t)ring->total_appended
               : (size_t)N68_CONSOLE_RING_CAPACITY;
}

size_t n68_console_visible_slice(const N68ConsoleRing *ring,
                                  size_t first_index,
                                  N68ConsoleLine *out_lines,
                                  size_t row_capacity)
{
    size_t retained = n68_console_retained_count(ring);
    unsigned long oldest_logical = ring->total_appended - (unsigned long)retained;
    size_t filled = 0;

    while (filled < row_capacity && first_index + filled < retained) {
        unsigned long logical = oldest_logical + (unsigned long)(first_index + filled);
        size_t slot = (size_t)(logical % N68_CONSOLE_RING_CAPACITY);

        out_lines[filled].text = ring->lines[slot];
        out_lines[filled].length = ring->lengths[slot];
        filled++;
    }
    return filled;
}
