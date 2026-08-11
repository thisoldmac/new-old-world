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

/* One classic WindowRecord, read by offset - and BOTH of its regions.
 *
 * Two questions, two answers, one reader. `top/left/bottom/right` is the
 * CONTENT region's bounding box, which is what a control's local rect is
 * relative to and what `origin_top`/`origin_left` convert against.
 * `struc_*` is the STRUCTURE region - the frame a person sees, title bar
 * and border included - which is what a window's position and size MEAN
 * to anyone looking at the screen.
 *
 * THEY ARE HERE TOGETHER BECAUSE THEY WERE APART. peek_read.c read the
 * structure region and this file read the content region, from separate
 * offset tables with opposite failure policies, and on 2026-08-02 the
 * two disagreed about whether the Finder had any windows at all
 * (scene_collect.c:129). The bind was made authoritative that day; the
 * READERS were not merged, so `windows[].rect` went on having three
 * derivations inside the scene plane alone - and one of them was this
 * region grown upward by a fixed title-bar constant, which is a guess
 * wearing arithmetic: title bars are not one height across window kinds
 * and the Appearance Manager draws them procedurally.
 *
 * So the structure region is read from the machine, beside the content
 * region, in the same walk that already has the WindowRecord in hand.
 * A window whose structure region cannot be read is refused whole - the
 * same policy this file already applies to an unreadable content region,
 * and the same one peek_read.c applies by skipping the window. Reporting
 * one region under the other's name is the outcome neither reader was
 * ever willing to produce and this merge must not introduce. */
typedef struct {
    unsigned long address;
    unsigned long next_window;
    unsigned long control_list;
    short         kind;
    unsigned char visible;
    /* WHICH TITLE-BAR WIDGETS THE MACHINE DRAWS, which `kind` cannot say.
     * MacWindows.h lays them out beside `windowKind`: `goAwayFlag` at 112 is
     * the close box, `spareFlag` at 113 the zoom box, one byte each, both
     * inside the 148 bytes this reader already validates.
     *
     * They are here because the consumer had been GUESSING from `kind`, and
     * the corpus falsifies that guess with a single pair: Extensions Manager
     * is `kind == 2` and has a zoom box, Memory is `kind == 2` and has none.
     *
     * THERE IS NO grow FIELD, and that is a finding rather than an omission.
     * The record holds no grow flag. The variation code in the high byte of
     * `windowDefProc` is the only other candidate and it is ambiguous without
     * the WDEF's resource id — kWindowDocumentDefProcResID 64 and
     * kWindowDialogDefProcResID 65 number their variants independently — and
     * a Handle cannot be named by a foreign Resource Manager. Same wall as
     * `contrlDefProc` below, one level up. */
    unsigned char go_away;
    unsigned char zoom;
    short         origin_top;
    short         origin_left;
    short         top;
    short         left;
    short         bottom;
    short         right;
    short         struc_top;
    short         struc_left;
    short         struc_bottom;
    short         struc_right;
    unsigned char title_len;
    char          title[kNowAxTitleMax + 1];
} NowAxWindow;

/* WHERE a control's definition function lives, which is not the same
   question as WHAT the control is.
 *
 * `contrlDefProc` (Controls.h: `Handle contrlDefProc;` at offset 24, the
 * field Carbon marks "not supported in Carbon" - there is no accessor,
 * which is why it is read as bytes) holds a Handle to the loaded CDEF.
 * The resource ID would name the family - Multiverse.h:18029 gives
 * `pushButProc = 0`, `checkBoxProc = 1`, `radioButProc = 2`,
 * `scrollBarProc = 16`, and a procID is `16 * CDEF_id + variant`, so
 * CDEF 0 is the button family and CDEF 1 the scroll bar. But a Handle is
 * not an ID, and the Resource Manager can only name a handle that is in
 * the CALLER's resource chain.
 *
 * What a foreign read CAN answer is which heap the handle came from,
 * because the walk is already told both bounds. The System file's CDEFs
 * carry the `sysheap` resource attribute, so they load once into the
 * system heap and every process's controls share them; a CDEF in an
 * application's own resource fork loads into that application's
 * partition. So the zone the handle sits in separates a system-supplied
 * definition from an application-supplied one WITHOUT naming either.
 *
 * That is deliberately less than a kind. A system definition says "the
 * Toolbox drew this, so a documented answer exists"; it does not say
 * button rather than scroll bar, and this enum must never be flattened
 * into one. Guessing a widget from where its code lives is the same
 * class of error as guessing one from a value range, which drew Mail's
 * alert buttons as three scroll bars on 2026-08-03.
 *
 * `Indeterminate` is a real answer and is expected to be non-empty: it
 * covers an unreadable handle, and it covers the possibility that this
 * field carries something besides a bare address. The classic Control
 * Manager is documented to keep a control's variation code, and
 * `GetControlVariant` (CarbonLib exports it) retrieves one from a
 * control we may not touch; if the variant rides in this field's high
 * byte, the raw longword lands in neither zone and lands HERE rather
 * than in a wrong bucket. A first live histogram with a large
 * Indeterminate column is therefore evidence about the field's layout,
 * not a failed read - and no masking is applied on a guess, because a
 * 24-bit mask on a 32-bit-clean machine is its own defect. */
typedef enum {
    kNowAxDefProcAbsent = 0,        /* the field is zero */
    kNowAxDefProcSystem = 1,        /* handle sits in the system heap */
    kNowAxDefProcApplication = 2,   /* handle sits in the target partition */
    kNowAxDefProcIndeterminate = 3  /* neither zone claims it */
} NowAxDefProcOrigin;

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
    unsigned long def_proc;       /* contrlDefProc @24, raw and unmasked */
    short         def_proc_origin;/* a NowAxDefProcOrigin */
} NowAxControl;

enum {
    kNowAxDialogUserItem = 0,
    kNowAxDialogPushButton = 1,
    kNowAxDialogCheckBox = 2,
    kNowAxDialogRadioButton = 3,
    kNowAxDialogPopupMenu = 4,
    kNowAxDialogStaticText = 5,
    kNowAxDialogEditText = 6,
    kNowAxDialogIcon = 7,
    kNowAxDialogPicture = 8,
    /* A `resCtrl` DITL row says only that its Handle names a ControlRecord
       created from a CNTL resource. It does not say which CDEF owns it.
       In particular, Date & Time uses these for group boxes and custom
       date/time displays; treating every one as a popup made both drawing
       and actuation confidently wrong. */
    kNowAxDialogResourceControl = 9
};

enum { kNowAxDialogMaxItems = 96 };

/* A validated cursor over a live Dialog Manager item list. Dialog items are
   not controls: edit/static text have no ControlHandle and resource controls
   use a different act path. The cursor keeps that distinction intact. */
typedef struct {
    unsigned long next;
    short remaining;
    short index;
    short default_item;       /* 1-based, <=0 means not proven */
    short edit_item;          /* 1-based, <=0 means no focused edit item */
} NowAxDialogCursor;

typedef struct {
    short number;
    short kind;
    unsigned long handle;
    short top, left, bottom, right; /* content-relative */
    unsigned char enabled;
    unsigned char visible;
    unsigned char title_len;
    char title[kNowAxTitleMax + 1];
} NowAxDialogItem;

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
int now_ax_open_dialog_items(const NowAxMemory *memory,
                             unsigned long window,
                             NowAxDialogCursor *cursor);
int now_ax_dialog_next(const NowAxMemory *memory, NowAxDialogCursor *cursor,
                       NowAxDialogItem *item);

#endif /* NOW_AXWALK_H */
