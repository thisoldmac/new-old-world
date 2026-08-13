#include "carbon_warning_model.h"

int now_carbon_warning_needed(int version_available, unsigned long version,
                              int suppressed)
{
    if (suppressed) return 0;
    return !version_available || version < 0x0160UL;
}
