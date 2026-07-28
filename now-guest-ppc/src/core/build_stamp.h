#ifndef NOW_BUILD_STAMP_H
#define NOW_BUILD_STAMP_H

/* "Mmm dd yyyy hh:mm:ss" of the build. Shown in the console banner and
   the File Sharing panel so "is the running app the one I just
   deployed?" is answerable at a glance. */
const char *now_build_stamp(void);

#endif /* NOW_BUILD_STAMP_H */
