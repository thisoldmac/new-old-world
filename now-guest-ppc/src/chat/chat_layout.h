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
    kChatTopRowHeight = 20,           /* popup + New Chat */
    kChatPopupWidth = 240,
    kChatNewButtonWidth = 76,
    kChatStatusHeight = 14,           /* the transient status line */
    kChatInputHeight = 22,            /* hand-drawn prompt well */
    kChatSendButtonWidth = 58,
    kChatScrollBarWidth = 16,
    kChatRowGap = 6,
    kChatLineHeight = 12              /* transcript rows, 9pt Geneva */
};

typedef struct ChatLayoutRects {
    Rect popup;                       /* model choice, top left */
    Rect new_button;                  /* New Chat, top right */
    Rect transcript;                  /* the text pane, scrollbar excluded */
    Rect scrollbar;                   /* flush against the pane's right */
    Rect status;                      /* one quiet line under the pane */
    Rect input;                       /* the prompt well */
    Rect send_button;                 /* Send / Stop, right of the well */
} ChatLayoutRects;

void chat_layout_compute(const Rect *body, ChatLayoutRects *out);

/* How many whole transcript rows the pane shows - the scroll math's
   one shared number. */
int chat_layout_visible_lines(const ChatLayoutRects *r);

#endif /* NOW_CHAT_LAYOUT_H */
