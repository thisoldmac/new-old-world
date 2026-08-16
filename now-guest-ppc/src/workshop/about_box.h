#ifndef NOW_ABOUT_BOX_H
#define NOW_ABOUT_BOX_H

/* The Apple-menu "About" window: name, version, build stamp. One OK
   button, not a two-choice confirm.c dialog - there is nothing here to
   decide, so a Cancel button would offer a choice that does not exist. */

void now_about_box_show(void);

#endif /* NOW_ABOUT_BOX_H */
