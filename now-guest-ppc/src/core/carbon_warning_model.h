#ifndef NOW_CARBON_WARNING_MODEL_H
#define NOW_CARBON_WARNING_MODEL_H

/* `version` uses gestaltCarbonVersion's 0xMMmB encoding. */
int now_carbon_warning_needed(int version_available, unsigned long version,
                              int suppressed);

#endif
