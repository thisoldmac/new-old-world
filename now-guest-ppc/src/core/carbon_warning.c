#include "carbon_warning.h"

#include <Carbon.h>
#include <stdio.h>

#include "carbon_warning_model.h"
#include "confirm.h"
#include "nowlog.h"
#include "prefs.h"

void now_carbon_warning_show_if_needed(void)
{
    NowPrefs prefs;
    long version = 0;
    Boolean available;
    char detail[256];

    now_prefs_load(&prefs);
    available = Gestalt(gestaltCarbonVersion, &version) == noErr;
    if (!now_carbon_warning_needed(available, (unsigned long)version,
                                   prefs.carbon_warning_suppressed)) {
        return;
    }

    if (available) {
        snprintf(detail, sizeof detail,
                 "This Mac has CarbonLib %ld.%ld. New Old World is "
                 "supported on CarbonLib 1.6. Run the bundled Apple "
                 "installer to upgrade; you may continue for now.",
                 (version >> 8) & 0xFF, (version >> 4) & 0x0F);
    } else {
        snprintf(detail, sizeof detail,
                 "New Old World could not identify this Mac's CarbonLib. "
                 "CarbonLib 1.6 is the supported version. Run the bundled "
                 "Apple installer to upgrade; you may continue for now.");
    }
    if (now_choose("CarbonLib 1.6 Recommended", detail,
                   "Continue", "Don't Warn Again")
        != kNowChoiceAlternative) {
        return;
    }

    prefs.carbon_warning_suppressed = true;
    if (now_prefs_save(&prefs) != noErr) {
        now_log(kLogWarn, "app", "could not save CarbonLib warning choice");
    }
}
