#ifndef NOW_CHAT_LAYOUT_H
#define NOW_CHAT_LAYOUT_H

/* Pure rectangle arithmetic for the Chat page. No Toolbox calls, so
   the same file compiles under the host cc for the native test - the
   workshop_layout.h pattern, Rect shim included. */

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
    kChatMargin = 8,
    /* The chats sidebar: the Workshop rail's idiom brought inside one
       page, because a person who can collapse the rail expects the same
       affordance for the same kind of list. Rows are one line of 9pt
       Geneva plus breathing room, the rail's own row shape. */
    kChatSidebarWidth = 132,
    kChatSidebarRowHeight = 14,
    kChatSidebarRows = 20,            /* slots the panel can hold */
    kChatToggleWidth = 20,            /* the collapse button */
    kChatModePopupWidth = 74,
    kChatProjectPopupWidth = 150,
    kChatTopRowHeight = 20,           /* the two popups + New Chat */
    kChatProviderPopupWidth = 120,
    kChatModelPopupWidth = 200,
    kChatNewButtonWidth = 76,
    kChatStatusHeight = 14,           /* the transient status line */
    kChatInputHeight = 22,            /* the prompt well at ONE line */
    kChatPromptMaxLines = 5,          /* the well grows this far, then
                                         TE scrolls inside it */
    kChatSendButtonWidth = 58,
    kChatScrollBarWidth = 16,
    kChatRowGap = 6,
    kChatLineHeight = 12              /* transcript rows, 9pt Geneva */
};

/* What the page looks like right now, passed in rather than read from
   anywhere: this file must stay arithmetic so the host cc can compile
   it for the native test. The Workshop rail's spec, one page down. */
typedef struct ChatLayoutSpec {
    Boolean sidebar_shown;            /* the saved-chats list is open */
    int prompt_lines;                 /* TE line count, clamped here */
} ChatLayoutSpec;

typedef struct ChatLayoutRects {
    Rect provider_popup;              /* who serves, top left */
    Rect model_popup;                 /* which model, beside it */
    Rect new_button;                  /* New Chat, top right */
    /* The second row: what this turn may do, and what it is filed
       under. Their own row because at 640x480 the first one is full,
       and because mode and project are chosen far less often than a
       model - the row a person reads first stays the row they use. */
    Rect sidebar_toggle;              /* collapse/expand, leftmost */
    Rect mode_popup;
    Rect project_popup;
    /* EMPTY (all zero) when the sidebar is collapsed, so a stale draw
       lands nowhere rather than on top of the transcript. */
    Rect sidebar;                     /* framed white panel */
    Rect sidebar_rows[kChatSidebarRows];
    int sidebar_visible;              /* slots that fit; <= the max */
    Rect transcript;                  /* the text pane, scrollbar excluded */
    Rect scrollbar;                   /* flush against the pane's right */
    Rect status;                      /* one quiet line under the pane */
    Rect input;                       /* the prompt well */
    Rect send_button;                 /* Send / Stop, right of the well */
} ChatLayoutRects;

/* spec->prompt_lines is the TE line count, clamped here to
   [1, kChatPromptMaxLines]: the well grows upward with the text and
   the transcript gives up the rows. The Send button stays one line
   tall, anchored at the bottom beside the well.

   spec may be NULL, which means an open sidebar and a one-line prompt. */
void chat_layout_compute(const Rect *body, const ChatLayoutSpec *spec,
                         ChatLayoutRects *out);

/* Which sidebar slot a point lands in, or -1. The click and the draw
   read one answer, so a row can never be highlighted and act as its
   neighbour. */
int chat_layout_sidebar_row_at(const ChatLayoutRects *r, short h, short v);

/* How many whole transcript rows the pane shows - the scroll math's
   one shared number. */
int chat_layout_visible_lines(const ChatLayoutRects *r);

#endif /* NOW_CHAT_LAYOUT_H */
