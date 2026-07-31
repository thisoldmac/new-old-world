#ifndef NOW_AXWALK_H
#define NOW_AXWALK_H

/* The foreign-memory walk, ported from this project's own prototype.

   PROVENANCE. Every byte offset and every ordering decision in this
   module came across from `timbottu/mirror`, `guest/app/src/ax*.c`,
   where it was measured against real Mac OS 9.1 - emulated and on
   metal - rather than derived here. The plan that authorised the port
   (docs/plans/2026-07-31-007-feat-now-mirror-integration-plan.md,
   "the narrowed stop condition") says why: Mirror is this project's own
   test bed, the wire stays ours, and re-deriving struct layouts without
   a machine is waste rather than rigour. So the rule for anyone editing
   this file is blunt: THE NUMBERS ARE EVIDENCE, NOT STYLE. An offset
   here may be corrected by a measurement or a citation and by nothing
   else. Upstream's metal proof does NOT transfer to this copy - the
   same offsets in different surrounding code is strong evidence, not a
   measurement of this binary.

   WHAT IS DIFFERENT FROM UPSTREAM. Upstream carried its own bounds
   check. NOW already has one, and docs/resident-components.md calls
   foreign-memory-reads-live-in-the-application "the single most
   important line in this note" - so this walk routes every range test
   through now_peek_range_in_partition() (peek_validate.c) instead of
   carrying a parallel one. NOW's check is strictly the tighter of the
   two: it additionally refuses a zero address, a zero length and a zero
   partition size, all of which fail closed.

   TOOLBOX-FREE ON PURPOSE, like peek_oracle.c and scene_build.c. The
   parser knows byte layouts; it does not know how memory is obtained.
   The guest binds the read seam to one live process's partition plus
   the system heap (axbind.c); a native host test binds it to synthetic
   big-endian fixtures. Every pointer crosses this seam before it is
   interpreted, and that is the whole safety story. */

#include <stddef.h>

#define kNowAxTitleMax 255

typedef enum {
    kNowAxOk = 0,
    kNowAxReadError = -1,     /* the seam's reader refused the bytes */
    kNowAxInvalid = -2,       /* a pointer or length failed validation */
    kNowAxNotFound = -3,      /* a chain ended, or the item is absent */
    kNowAxTruncated = -4      /* a bound was hit before the data ran out */
} NowAxStatus;

/* The read seam. `read` returns nonzero on success and copies `len`
   bytes from the target address; it is only ever called for a range
   this module has already validated. */
typedef int (*NowAxReadFn)(void *ctx, unsigned long addr, void *out,
                           size_t len);

/* The two regions a foreign UI structure may legally live in: the
   target process's partition, and the system heap. Both are needed -
   validating only the partition reads "unreadable" for every process
   but oneself, because regions and master pointers live in SysZone
   (the same widening peek_read.c made, and the same one upstream's
   axtree needed). */
typedef struct {
    NowAxReadFn   read;
    void         *ctx;
    unsigned long target_lo;
    unsigned long target_hi;
    unsigned long system_lo;
    unsigned long system_hi;
} NowAxMemory;

/* One classic WindowRecord, read by offset. The rect is the CONTENT
   region's bounding box, not the structure region's - deliberately, and
   it is why `origin_top`/`origin_left` exist: a control's rect is in
   the window's local coordinates, and content-origin minus portRect
   origin is what converts it to global. peek_read.c reads the STRUCTURE
   region for the same window because it wants the frame a person sees;
   the two are different fields for different questions, not a
   disagreement. */
typedef struct {
    unsigned long address;
    unsigned long next_window;
    unsigned long control_list;
    short         kind;
    unsigned char visible;
    short         origin_top;
    short         origin_left;
    short         top;
    short         left;
    short         bottom;
    short         right;
    unsigned char title_len;
    char          title[kNowAxTitleMax + 1];
} NowAxWindow;

/* One classic ControlRecord. Bounds are already translated to global by
   the window's origin, so a consumer never has to know the local frame. */
typedef struct {
    unsigned long address;        /* the ControlHandle */
    unsigned long record;         /* the dereferenced ControlRecord */
    unsigned long next_control;
    unsigned char visible;
    unsigned char enabled;
    short         top;
    short         left;
    short         bottom;
    short         right;
    unsigned char title_len;
    char          title[kNowAxTitleMax + 1];
    short         value;          /* contrlValue @18: checkbox, scroll pos */
    short         min;            /* contrlMin   @20 */
    short         max;            /* contrlMax   @22 */
} NowAxControl;

/* Validated primitives, exposed because the menu and text parsers are
   built on exactly these and on nothing else. */
int now_ax_read_bytes(const NowAxMemory *memory, unsigned long address,
                      void *out, size_t len);
int now_ax_read_handle(const NowAxMemory *memory, unsigned long handle,
                       unsigned long *data);

int now_ax_read_window(const NowAxMemory *memory, unsigned long address,
                       NowAxWindow *out);
int now_ax_read_control(const NowAxMemory *memory, const NowAxWindow *window,
                        unsigned long handle, NowAxControl *out);

#endif /* NOW_AXWALK_H */
