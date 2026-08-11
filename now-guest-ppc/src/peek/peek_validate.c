#include "peek_validate.h"

enum {
    /* No classic Mac display is anywhere near this wide or tall, and a
       window's structure rect stays well inside it. A value past this
       is a wrong-offset read, not a real window. */
    kMaxCoord = 4096,
    kMinCoord = -256          /* a title bar may sit above the menu bar */
};

int now_peek_range_in_partition(unsigned long addr, unsigned long len,
                                unsigned long loc, unsigned long size)
{
    unsigned long end;

    if (addr == 0 || len == 0 || size == 0) {
        return 0;
    }
    if (addr < loc) {
        return 0;
    }
    /* addr + len must not wrap and must not pass loc + size. Both sums
       are checked for overflow before comparing. */
    end = addr + len;
    if (end < addr) {
        return 0;                     /* addr + len wrapped */
    }
    if (loc + size < loc) {
        return 0;                     /* partition end wrapped */
    }
    return end <= loc + size;
}

int now_peek_rect_sane(short top, short left, short bottom, short right)
{
    if (right <= left || bottom <= top) {
        return 0;                     /* empty or inverted */
    }
    if (left < kMinCoord || top < kMinCoord
        || right > kMaxCoord || bottom > kMaxCoord) {
        return 0;
    }
    return 1;
}
