#ifndef NOW_CLOUD_FILTER_H
#define NOW_CLOUD_FILTER_H

/* The live search's pure half. Toolbox-free so the host cc tests it
   directly (cloud_filter_test.c) — the same split cloud_model.h and
   cloud_layout.h already draw between the bytes/rects worth testing
   and the controls/QuickDraw that are not.

   The idiom is software_module.c's hand-drawn search field
   (case-insensitive ASCII substring, folded once per keystroke rather
   than per comparison) — reused, not reinvented, and generalized to
   more than one haystack per row: a CloudRow's card searches its title
   AND subtitle, a Drive FileEntry searches its name alone. MacRoman is
   ASCII-clean in the A-Z/a-z range this touches, so no locale or
   Str255 handling belongs here. */

#if TARGET_API_MAC_CARBON
#include <MacTypes.h>
#else
typedef unsigned char Boolean;
#endif

/* True if `haystack` contains `needle` ANYWHERE, folding `haystack`'s
   case as it scans; `needle` must already be lowercased (cloud_filter_lower
   — the per-keystroke cost paid once, not per row). An empty needle
   matches everything, including a NULL or empty haystack. */
Boolean cloud_filter_matches(const char *haystack, const char *needle);

/* True if EITHER field contains needle — a CloudRow's title/subtitle
   pair, searched together the way a person scanning the list would
   read them. */
Boolean cloud_filter_matches_either(const char *a, const char *b,
                                    const char *needle);

/* Lowercases `in` (ASCII A-Z only) into `out`, capped at `cap` bytes
   including the terminator. Called once per keystroke on the search
   field's own text, not once per row. */
void cloud_filter_lower(const char *in, char *out, long cap);

#endif /* NOW_CLOUD_FILTER_H */
