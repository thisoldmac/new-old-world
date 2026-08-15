#include "files_layout.h"

static void set_rect(Rect *r, short left, short top, short right,
                     short bottom)
{
    r->left = left;
    r->top = top;
    r->right = right;
    r->bottom = bottom;
}

short files_layout_baseline(const Rect *r)
{
    /* 9pt Geneva sits on a baseline 11 down from the top of a 14-tall
       run; a taller run centres the same text block. */
    return (short)(r->top + 11 + (r->bottom - r->top - kFilesTextHeight) / 2);
}

void files_layout_compute(const Rect *body, FilesLayoutRects *out)
{
    short left = (short)(body->left + kFilesMargin);
    short right = (short)(body->right - kFilesMargin);
    short y = (short)(body->top + 6);
    short bottom = (short)(body->bottom - 6);
    short row;
    short text_left;
    short floor;

    /* --- their half, from the top down ---------------------------------- */

    set_rect(&out->their_heading, left, y, right,
             (short)(y + kFilesHeadingHeight));
    y = (short)(y + kFilesHeadingHeight + kFilesTightGap);

    set_rect(&out->up_btn, left, (short)(y + 2),
             (short)(left + kFilesUpWidth), (short)(y + 22));
    set_rect(&out->stop_btn, (short)(right - kFilesStopWidth),
             (short)(y + 2), right, (short)(y + 22));
    set_rect(&out->count, (short)(right - kFilesCountWidth), y, right,
             (short)(y + kFilesTextHeight));

    /* The transfer line takes the right-hand end of the row and leaves
       the path at least a readable stub. On a narrow window the path
       gives way first: which file is coming down and how far along it is
       are the facts that change, and the path is still legible in the
       heading and the list below. */
    text_left = (short)(out->stop_btn.left - kFilesGap - kFilesXferWidth);
    floor = (short)(out->up_btn.right + kFilesPathFloor);
    if (text_left < floor) {
        text_left = floor;
    }
    set_rect(&out->xfer, text_left, y,
             (short)(out->stop_btn.left - kFilesGap),
             (short)(y + kFilesTextHeight));

    set_rect(&out->path, (short)(out->up_btn.right + 10), y,
             (short)(out->count.left - kFilesGap),
             (short)(y + kFilesTextHeight));
    set_rect(&out->path_busy, out->path.left, y,
             (short)(out->xfer.left - kFilesGap),
             (short)(y + kFilesTextHeight));
    y = (short)(y + kFilesPathRowHeight);

    /* --- my half, from the bottom up ------------------------------------ */

    /* Where files LAND, and the two things a person does with that
       folder. A static label carries the name; the buttons say what they
       do. The old row was a push button whose TITLE was the setting -
       "Get files into: Downloads" - which reads as a status line right up
       until you click it by accident. */
    row = (short)(bottom - kFilesRowHeight);
    set_rect(&out->open_btn, (short)(right - kFilesOpenWidth), row, right,
             bottom);
    set_rect(&out->change_btn,
             (short)(out->open_btn.left - kFilesRowGap - kFilesChangeWidth),
             row, (short)(out->open_btn.left - kFilesRowGap), bottom);
    /* Full row height, not a 14-tall text box at the top of it: the
       baseline is then centred the way a push button centres its own
       title, and the label reads as being ON the row with the two
       buttons rather than floating above them. */
    set_rect(&out->into_label, left, row,
             (short)(left + kFilesIntoLabelWidth), bottom);
    set_rect(&out->into_value, (short)(out->into_label.right + 4), row,
             (short)(out->change_btn.left - kFilesGap), bottom);

    /* Sending, with its own bar beside it. The bar used to float above
       the buttons saying nothing about which direction it measured; here
       it is on the same row as the button that starts it. */
    row = (short)(row - kFilesRowGap - kFilesRowHeight);
    set_rect(&out->send_btn, left, row, (short)(left + kFilesSendWidth),
             (short)(row + kFilesRowHeight));
    set_rect(&out->progress, (short)(out->send_btn.right + 10),
             (short)(row + (kFilesRowHeight - kFilesProgressHeight) / 2),
             right,
             (short)(row + (kFilesRowHeight + kFilesProgressHeight) / 2));

    /* What is shared: two real radio buttons, because it is one choice
       with two answers. It was a checkbox that disabled a button, which
       is the same mutual exclusion with none of it said out loud. */
    row = (short)(row - kFilesRowGap - kFilesRowHeight);
    set_rect(&out->folder_radio, left, row,
             (short)(left + kFilesFolderRadioWidth),
             (short)(row + 16));
    set_rect(&out->disk_radio,
             (short)(out->folder_radio.right + kFilesGap), row,
             (short)(out->folder_radio.right + kFilesGap
                     + kFilesDiskRadioWidth),
             (short)(row + 16));
    set_rect(&out->choose_btn, (short)(right - kFilesChooseWidth),
             (short)(row - 2), right,
             (short)(row - 2 + kFilesRowHeight));

    /* The one line that is true under either radio: what a request from
       the other Mac actually resolves against. */
    row = (short)(row - kFilesTightGap - kFilesTextHeight);
    set_rect(&out->sharing_label, left, row,
             (short)(left + kFilesSharingLabelWidth),
             (short)(row + kFilesTextHeight));
    set_rect(&out->sharing_value, (short)(out->sharing_label.right + 4), row,
             right, (short)(row + kFilesTextHeight));

    row = (short)(row - kFilesTightGap - kFilesHeadingHeight);
    set_rect(&out->mine_heading, left, row,
             (short)(left + kFilesMineHeadingWidth),
             (short)(row + kFilesHeadingHeight));
    set_rect(&out->mine_caption, (short)(out->mine_heading.right + kFilesGap),
             row, right, (short)(row + kFilesHeadingHeight));

    /* Two pixels tall, not one: the Appearance separator is a dark line
       over a light one, and a one-pixel rect gives it nowhere to draw
       the second. */
    set_rect(&out->divider, left, (short)(row - kFilesSectionGap), right,
             (short)(row - kFilesSectionGap + 2));

    /* --- and the listing takes everything between them ------------------ */

    set_rect(&out->browser, left, (short)(y + 2), right,
             (short)(out->divider.top - kFilesSectionGap));
}
