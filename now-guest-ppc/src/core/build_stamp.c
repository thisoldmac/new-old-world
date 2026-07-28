#include "build_stamp.h"

/* __DATE__/__TIME__ record when THIS file was compiled, which is only
   the build time if this file is recompiled every build — CMake forces
   that (see the touch_build_stamp target). Without it the stamp silently
   reports the last time some unrelated edit happened to touch it, which
   is worse than no stamp at all. */
const char *now_build_stamp(void)
{
    return __DATE__ " " __TIME__;
}
