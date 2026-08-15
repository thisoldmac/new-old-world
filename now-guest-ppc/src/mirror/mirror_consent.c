#include "mirror_consent.h"

int now_mirror_consent_from_gates(int structure, int finder_complements,
                                  int content, int foreground_cycle)
{
    return (structure != 0 && finder_complements != 0 && content != 0
            && foreground_cycle != 0) ? 1 : 0;
}

int now_mirror_consent_to_gates(int consent)
{
    return consent != 0 ? 1 : 0;
}
