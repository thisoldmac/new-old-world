#include "mirror_show.h"

/* MacRoman-expressible ASCII only — these go through DrawString. */

const char *now_mirror_show_button_title(void)
{
    return "Show Mirror on Host";
}

const char *now_mirror_show_waiting_text(void)
{
    return "Asking that Mac to show its Mirror...";
}
