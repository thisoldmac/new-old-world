#include <stdio.h>

#include "carbon_warning_model.h"

#define CHECK(condition, message) \
    do { if (!(condition)) { fprintf(stderr, "%s\n", message); return 1; } } \
    while (0)

int main(void)
{
    CHECK(now_carbon_warning_needed(1, 0x0150UL, 0),
          "CarbonLib 1.5 did not warn");
    CHECK(!now_carbon_warning_needed(1, 0x0160UL, 0),
          "CarbonLib 1.6 warned");
    CHECK(!now_carbon_warning_needed(1, 0x0161UL, 0),
          "CarbonLib 1.6.1 warned");
    CHECK(now_carbon_warning_needed(0, 0, 0),
          "missing CarbonLib identity did not warn");
    CHECK(!now_carbon_warning_needed(1, 0x0100UL, 1),
          "suppression did not suppress an old runtime");
    return 0;
}
