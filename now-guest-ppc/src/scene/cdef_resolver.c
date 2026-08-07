/* The Resource Manager half of the CDEF route. See cdef_resolver.h. */

#include "cdef_resolver.h"

#include <Resources.h>

enum {
    kCdefType = 'CDEF'
};

/* A handle is a master pointer slot: even, and inside the zone the walk
   validated. The same shape axwalk.c requires before it will call a
   longword a handle - repeated rather than shared because this file may
   not include the walk, and a second copy of a two-line predicate is
   cheaper than a dependency between a Toolbox file and a Toolbox-free
   one. */
static int plausible(unsigned long handle,
                     unsigned long lo, unsigned long hi)
{
    if (handle == 0 || (handle & 1) != 0) return 0;
    if (hi <= lo) return 0;                 /* an unset zone claims nothing */
    return handle >= lo && (handle + 4) <= hi;
}

/* One question, asked of one candidate. Returns 1 and fills id when the
   Resource Manager names a `CDEF`; sets *named when it names ANYTHING,
   so the caller can tell "this is not a resource" from "this is the
   wrong kind of resource". */
static int ask(unsigned long candidate, short *out_id, int *named)
{
    ResType type = 0;
    short   id = 0;
    Str255  name;

    name[0] = 0;
    /* GetResInfo compares the handle against the entries of every open
       resource map; it does not dereference what it is given, which is
       what makes it safe to offer an address we did not mint. A handle
       in no map answers resNotFound. */
    GetResInfo((Handle)candidate, &id, &type, name);
    if (ResError() != noErr) return 0;
    *named = 1;
    if (type != (ResType)kCdefType) return 0;
    *out_id = id;
    return 1;
}

short now_cdef_resolve(unsigned long def_proc,
                       unsigned long system_lo, unsigned long system_hi,
                       short *out_id, short *out_variant)
{
    unsigned long masked = def_proc & 0x00FFFFFFUL;
    short         high = (short)((def_proc >> 24) & 0xFF);
    int           named = 0;

    *out_id = 0;
    *out_variant = 0;
    if (!plausible(def_proc, system_lo, system_hi)) {
        /* Not a system-heap handle: an application's own CDEF, or a
           field that is not an address at all. Either way there is no
           lookup to make, and saying so is not the same as saying the
           lookup failed. */
        return (short)kNowCdefUnattempted;
    }
    if (ask(def_proc, out_id, &named)) {
        /* The whole longword is the handle, so no variation code rode in
           the high byte for this control. */
        *out_variant = 0;
        return (short)kNowCdefNamed;
    }
    if (high != 0 && plausible(masked, system_lo, system_hi)
        && ask(masked, out_id, &named)) {
        /* The MACHINE has now said the high byte was not part of the
           address: the masked value is a resource and the raw one is
           not. That is the only evidence this project will accept for
           the mask, and it is per control rather than a global belief. */
        *out_variant = high;
        return (short)kNowCdefNamed;
    }
    return named ? (short)kNowCdefNotCdef : (short)kNowCdefUnnamed;
}
