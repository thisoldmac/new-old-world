#ifndef NOW_PROC_ROSTER_H
#define NOW_PROC_ROSTER_H

#include <Processes.h>

/* THE ONE PLACE THIS MACHINE'S PROCESSES ARE ENUMERATED AND CLASSIFIED.

   Before this, five independent GetNextProcess walks answered the same
   question — `process.list`, the `ps` console command, the Processes
   page, the scene plane and `observe` — and the classification of what
   is faceless was copy-pasted into four of them. `commands.c` admitted
   it in a comment: "the same test serve_process_list makes." The scene
   read the bit in none of them, so a headless process was `kind:
   background` on one face and `ax_oracle_not_found` on another, at the
   same instant, about the same machine.

   The defect was never the redundancy. It was that five answers to one
   question can disagree and a caller cannot tell which it got.

   Two invariants this file exists to make STRUCTURAL rather than
   remembered:

     ONE KIND. `modeOnlyBackground` and the Finder's 'FNDR'/'MACS'
     signature are read here and nowhere else in the guest. A process's
     kind is the process's own declaration — its 'SIZE' bit — never
     inferred from "we saw no windows", which is the inference that made
     six healthy processes read as errors.

     ONE FRONT PER REPLY. `now_proc_roster_begin` samples GetFrontProcess
     and GetCurrentProcess ONCE, before the first row. A walk that
     re-reads the front per row can emit a reply in which two rows carry
     `front: true` — a snapshot that contradicts itself. Because `begin`
     is the only place the walk reads it, the invariant holds by
     construction rather than by care.

   The shape is an ITERATOR, not a table, deliberately: a table of every
   process is a kilobyte of somebody's stack on a 56 MB machine, and the
   thing worth sharing is the sampling discipline, not the storage. */

typedef enum {
    kNowProcKindApplication = 0,  /* has a face and is not the Finder     */
    kNowProcKindFinder,           /* 'FNDR' type or 'MACS' creator        */
    kNowProcKindBackground        /* declared modeOnlyBackground: faceless */
} NowProcKind;

/* Everything one walk row carries. A caller takes the fields it serves;
   nobody re-reads the record to get one more. */
typedef struct {
    ProcessSerialNumber psn;
    Str31         pname;          /* as the Toolbox gave it, Pascal      */
    char          name[32];       /* the same, C, truncated if it must be */
    unsigned long type;           /* processType                          */
    unsigned long creator;        /* processSignature                     */
    unsigned long mode;           /* processMode, raw                     */
    unsigned long launch_date;
    unsigned long location;
    unsigned long process_size;   /* bytes, as the record reports         */
    unsigned long free_mem;
    unsigned long active_time;
    FSSpec        spec;           /* processAppSpec: where it was launched */
    Boolean       have_spec;      /* the Process Manager gave us one       */
    long          size_kb;
    long          used_kb;        /* size - free, floored at 0            */
    NowProcKind   kind;
    Boolean       is_front;
    Boolean       is_self;
} NowProcRosterRow;

/* The walk's own state. `unreadable` counts rows GetProcessInformation
   refused — a fact about US, and the number a coverage field is derived
   from. It is deliberately not folded into `count`: a walk that skipped
   somebody and says so is a different thing from one that saw nobody. */
typedef struct {
    ProcessSerialNumber cursor;
    ProcessSerialNumber front;
    ProcessSerialNumber self;
    Boolean have_front;           /* GetFrontProcess answered            */
    Boolean have_self;
    short   seen;                 /* readable rows yielded so far         */
    short   unreadable;           /* GetProcessInformation said no        */
} NowProcRosterIter;

/* Samples the front process and this process ONCE. Every row this walk
   yields is `front`-tagged against that one sample, so one walk
   describes one moment. */
void now_proc_roster_begin(NowProcRosterIter *it);

/* The next readable process, or 0 at the end. Unreadable rows are
   skipped here and counted in `it->unreadable`, so no caller has to
   remember to. */
int now_proc_roster_next(NowProcRosterIter *it, NowProcRosterRow *row);

/* One known process, with the same fields and the same classification.
   For a caller holding a PSN off the wire rather than walking — it
   samples the front itself, because a single row is a single moment. */
int now_proc_roster_read(const ProcessSerialNumber *psn,
                         NowProcRosterRow *row);

/* The kind, from the record's own fields. Exposed for the single-row
   readers that already have a ProcessInfoRec in hand; the bit is read
   in this file's implementation and nowhere else. */
NowProcKind now_proc_kind_classify(unsigned long type, unsigned long creator,
                                   unsigned long mode);

/* The contract's word for a kind: "finder", "background", "application".
   Both faces render this string, so `ps` and `process.list` cannot
   drift into two vocabularies for one enum. */
const char *now_proc_kind_name(NowProcKind kind);

/* Is this process frontmost RIGHT NOW? The one implementation of a
   helper that existed byte-identically in proc_actions.c and
   mach_activate.c. */
Boolean now_proc_is_frontmost(const ProcessSerialNumber *psn);

/* The front process, for a caller that wants exactly that one row and no
   walk. Returns 0 when the Process Manager will not say. */
int now_proc_roster_front(ProcessSerialNumber *out);

#endif /* NOW_PROC_ROSTER_H */
