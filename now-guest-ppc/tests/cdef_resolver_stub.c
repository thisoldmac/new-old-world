/* The Resource Manager is not reachable from the host cc, so the walk's
   native test links this. It answers "not asked", which is the walk's
   own behaviour for every control outside the system heap - so a scene
   built here carries no derived kinds and the walk's other claims are
   tested unchanged. The MAPPING that the real resolver feeds has its own
   test (control_cdef_test.c); this stub is not standing in for it. */
#include "cdef_resolver.h"

short now_cdef_resolve(unsigned long def_proc,
                       unsigned long system_lo, unsigned long system_hi,
                       short *out_id, short *out_variant)
{
    (void)def_proc; (void)system_lo; (void)system_hi;
    *out_id = 0;
    *out_variant = 0;
    return (short)kNowCdefUnattempted;
}
