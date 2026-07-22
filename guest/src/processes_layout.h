#ifndef NOW_PROCESSES_LAYOUT_H
#define NOW_PROCESSES_LAYOUT_H

/* Pure rectangle arithmetic and text formatting for the Processes
   page. No Toolbox calls live here, so the same file compiles under
   the host's cc for the native test (guest/tests/
   processes_layout_test.c) - the pattern workshop_layout.c set. */

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
    kProcMargin = 12,         /* body edge to the panes */
    kProcPaneGap = 10,        /* list to detail */
    kProcListWide = 218,
    kProcListNarrow = 190,
    kProcListNarrowBelow = 560,   /* body width, not window width */
    kProcFactLabelWidth = 62, /* right-aligned labels, one column */
    kProcFactLineHeight = 16,
    kProcMemBarHeight = 11,
    kProcMemBarMaxWidth = 200,
    kProcButtonHeight = 20,
    kProcGroupMinHeight = 40, /* the extension box never collapses */
    kProcDetailWindows = 3,   /* window rows shown in the detail pane */
    kProcWindowRowHeight = 13
};

typedef struct ProcessesLayout {
    Rect list;                /* the Data Browser */
    Rect detail;              /* everything to its right */
    Rect title_line;          /* selected process name */
    Rect kind_line;
    Rect type_line;
    Rect mem_line;
    Rect mem_bar;
    Rect cpu_line;
    Rect launched_line;
    Rect windows_line;        /* "Windows: N" header */
    Rect window_rows[kProcDetailWindows];   /* per-window title + size */
    Rect menus_line;          /* the menu-bar readout (stubbed) */
    Rect front_btn;
    Rect quit_btn;
    Rect group;               /* the NOW Extension group box */
    Rect peek_line;           /* status text inside the group box */
} ProcessesLayout;

void processes_layout_compute(const Rect *body, ProcessesLayout *out);

/* Four printable characters and a terminator; anything unprintable
   becomes a period, so a garbage type cannot smuggle control bytes
   into DrawString. */
void proc_fourcc_text(unsigned long code, char out[5]);

/* The word a person reads for a process type: application, background
   only, the Finder - or the raw four characters when we do not know. */
void proc_kind_text(unsigned long type, char *out, long cap);

/* "312K used of 1,024K" - classic thousands grouping, ASCII only. */
void proc_mem_text(long used_kb, long size_kb, char *out, long cap);

/* Fill width for the partition bar, clamped to [0, bar_width]. */
long proc_mem_fill(long used_kb, long size_kb, long bar_width);

/* "7 processes - 12.4 MB free" for the status placard. */
void proc_status_text(int count, long free_kb, char *out, long cap);

/* How long a process has been running, from the tick delta between now
   and its launch. ProcessInfoRec.processLaunchDate is ticks since boot,
   NOT a calendar date (rendering it as one gave "1/1/04" for
   everything - caught on the PowerBook), and the same-epoch delta is
   the only honest thing it yields. 60 ticks per second. */
void proc_uptime_text(long ticks_ago, char *out, long cap);

/* Cumulative CPU time (processActiveTime, in ticks) as a duration:
   "12 sec", "3 min 20 sec". Distinct from uptime - no "ago". */
void proc_cpu_text(unsigned long active_ticks, char *out, long cap);

/* The one-word kind for a process: 0 application, 1 background only,
   2 the Finder. Determined from processMode by the caller; this only
   names it. */
enum { kProcKindApp = 0, kProcKindBackground = 1, kProcKindFinder = 2 };
void proc_kind_name(short kind, char *out, long cap);

/* How stale a window snapshot is, from the tick age of its anchor. An
   actively-pumping app is live and produces an empty string (no marker
   needed); only a process that has not pumped recently gets an honest
   "as of ..." - coarse, so it does not tick every second. Empty when
   fresh. 60 ticks per second. */
void proc_freshness_text(unsigned long age_ticks, char *out, long cap);

#endif /* NOW_PROCESSES_LAYOUT_H */
