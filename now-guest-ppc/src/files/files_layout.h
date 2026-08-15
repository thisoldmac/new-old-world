#ifndef NOW_FILES_LAYOUT_H
#define NOW_FILES_LAYOUT_H

/* Pure rectangle arithmetic for the Files page. No Toolbox calls, so the
   same file compiles under the host cc for the native test - the
   workshop_layout.h pattern, Rect shim included.

   THE SHAPE, and the argument for it. The page had one disclosure
   triangle labelled "Shared from this Mac" over two unrelated things:
   what this Mac shares (a setting) and how files move (Send, the
   downloads folder). Collapsing it to see more of the listing took away
   the only way to send a file. So there is no triangle here. The page is
   two named halves, both always on screen:

     Their Files - <peer>      the other Mac's listing, labelled at last
     My Shared Folder          what this Mac offers, and the two verbs

   and the bottom half is measured from the window's bottom edge upward,
   so it is the LISTING that grows with the window - the one part of the
   page whose usefulness scales with its height. */

#if TARGET_API_MAC_CARBON
#include <MacTypes.h>
#else
typedef struct Rect {
    short top;
    short left;
    short bottom;
    short right;
} Rect;
typedef unsigned char Boolean;
#endif

enum {
    kFilesMargin = 12,
    kFilesHeadingHeight = 14,
    kFilesTextHeight = 14,
    kFilesRowHeight = 20,             /* a row holding a control */
    kFilesPathRowHeight = 24,
    kFilesRowGap = 6,
    kFilesTightGap = 2,
    kFilesSectionGap = 10,            /* either side of the divider */
    kFilesGap = 8,                    /* control to the thing beside it */

    kFilesUpWidth = 44,
    kFilesStopWidth = 54,
    kFilesCountWidth = 96,            /* "128 items (more not shown)" */
    kFilesXferWidth = 210,            /* "Report.cwk - 340K of 1.2MB (28%)" */
    kFilesPathFloor = 90,             /* the path never shrinks past this */

    kFilesChooseWidth = 118,          /* "Choose Folder..." */
    kFilesFolderRadioWidth = 104,     /* "One folder" */
    kFilesDiskRadioWidth = 168,       /* "The whole startup disk" */
    kFilesSendWidth = 100,            /* "Send File..." */
    kFilesChangeWidth = 76,           /* "Change..." */
    kFilesOpenWidth = 88,             /* "Open Folder" */
    kFilesIntoLabelWidth = 128,       /* "Files you get land in:" */
    kFilesSharingLabelWidth = 52,     /* "Sharing:" */
    kFilesMineHeadingWidth = 118,     /* "My Shared Folder" */
    kFilesProgressHeight = 12,

    /* What the window's minimum size must leave for the listing. The
       native test asserts it at kWorkshopMinContentH's body, because a
       page that fits only on a big screen is a page nobody with a 640x480
       Mac has seen. */
    kFilesBrowserMinHeight = 150
};

typedef struct FilesLayoutRects {
    /* Their half. */
    Rect their_heading;               /* "Their Files - <peer>" */
    Rect up_btn;
    Rect path;                        /* room while the count is shown */
    Rect path_busy;                   /* room while the transfer line is */
    Rect count;                       /* right-aligned item count */
    Rect xfer;                        /* right-aligned transfer line */
    Rect stop_btn;
    Rect browser;

    /* The seam. */
    Rect divider;

    /* My half. */
    Rect mine_heading;                /* "My Shared Folder" */
    Rect mine_caption;                /* "<peer> can browse ..." */
    Rect sharing_label;               /* "Sharing:" */
    Rect sharing_value;               /* the effective root, emphasized */
    Rect folder_radio;                /* "One folder" */
    Rect disk_radio;                  /* "The whole startup disk" */
    Rect choose_btn;
    Rect send_btn;
    Rect progress;                    /* the SEND's bar, beside Send File */
    Rect into_label;                  /* "Files you get land in:" */
    Rect into_value;                  /* the folder's name */
    Rect change_btn;
    Rect open_btn;
} FilesLayoutRects;

void files_layout_compute(const Rect *body, FilesLayoutRects *out);

/* The baseline for a run drawn inside `r`, for both faces of the one
   walk: drawing moves to it, describing reports the rect. Stated once so
   a run cannot be drawn at one height and described at another. */
short files_layout_baseline(const Rect *r);

#endif /* NOW_FILES_LAYOUT_H */
