#include "proc_roster.h"

#include <string.h>

/* Spelled-out 4CCs: multi-character char constants warn under -Werror.
   These two lines are the whole of "what is the Finder" in this guest;
   they were three verbatim copies before. */
#define kNowProcTypeFinder   0x464E4452UL   /* 'FNDR' */
#define kNowProcSigFinder    0x4D414353UL   /* 'MACS' */

NowProcKind now_proc_kind_classify(unsigned long type, unsigned long creator,
                                   unsigned long mode)
{
    if (type == kNowProcTypeFinder || creator == kNowProcSigFinder) {
        return kNowProcKindFinder;
    }
    /* THE PROCESS'S OWN DECLARATION. modeOnlyBackground is the 'SIZE'
       bit a faceless application sets to say it has no user interface,
       and switcher membership is the same bit — one signal, not two.
       Read here, and in no other .c file in this guest. */
    if ((mode & (unsigned long)modeOnlyBackground) != 0) {
        return kNowProcKindBackground;
    }
    return kNowProcKindApplication;
}

const char *now_proc_kind_name(NowProcKind kind)
{
    switch (kind) {
    case kNowProcKindFinder:     return "finder";
    case kNowProcKindBackground: return "background";
    case kNowProcKindApplication:break;
    }
    return "application";
}

Boolean now_proc_is_frontmost(const ProcessSerialNumber *psn)
{
    ProcessSerialNumber front;
    Boolean same = false;

    if (psn == NULL || GetFrontProcess(&front) != noErr) {
        return false;
    }
    (void)SameProcess((ProcessSerialNumber *)psn, &front, &same);
    return same;
}

/* Fill a row from a PSN whose record has already been read. Split out so
   the walk and the single-row read cannot classify differently. */
static void fill_row(NowProcRosterRow *row, const ProcessSerialNumber *psn,
                     const ProcessInfoRec *info, const Str31 pname,
                     Boolean is_front, Boolean is_self)
{
    long len = (long)pname[0];

    memset(row, 0, sizeof *row);
    row->psn = *psn;
    if (len > 31) {
        len = 31;
    }
    row->pname[0] = (unsigned char)len;
    if (len > 0) {
        BlockMoveData(&pname[1], &row->pname[1], len);
        BlockMoveData(&pname[1], row->name, len);
    }
    row->name[len] = '\0';
    row->type = (unsigned long)info->processType;
    row->creator = (unsigned long)info->processSignature;
    row->mode = (unsigned long)info->processMode;
    row->launch_date = (unsigned long)info->processLaunchDate;
    row->location = (unsigned long)info->processLocation;
    row->process_size = (unsigned long)info->processSize;
    row->free_mem = (unsigned long)info->processFreeMem;
    row->active_time = (unsigned long)info->processActiveTime;
    row->size_kb = (long)(info->processSize / 1024);
    row->used_kb = (long)((info->processSize - info->processFreeMem) / 1024);
    if (row->used_kb < 0) {
        row->used_kb = 0;
    }
    row->kind = now_proc_kind_classify(row->type, row->creator, row->mode);
    row->is_front = is_front;
    row->is_self = is_self;
}

void now_proc_roster_begin(NowProcRosterIter *it)
{
    memset(it, 0, sizeof *it);
    it->cursor.highLongOfPSN = 0;
    it->cursor.lowLongOfPSN = kNoProcess;
    /* ONCE, HERE, BEFORE THE FIRST ROW — see the header. */
    it->have_front = GetFrontProcess(&it->front) == noErr;
    it->have_self = GetCurrentProcess(&it->self) == noErr;
}

int now_proc_roster_next(NowProcRosterIter *it, NowProcRosterRow *row)
{
    while (GetNextProcess(&it->cursor) == noErr) {
        ProcessInfoRec info;
        Str31 name;
        Boolean is_front = false;
        Boolean is_self = false;

        memset(&info, 0, sizeof info);
        info.processInfoLength = sizeof info;
        info.processName = name;
        info.processAppSpec = NULL;
        name[0] = 0;
        if (GetProcessInformation(&it->cursor, &info) != noErr) {
            /* A fact about us, not about the machine: counted, never
               silently dropped, because coverage is derived from it. */
            if (it->unreadable < 32767) {
                ++it->unreadable;
            }
            continue;
        }
        if (it->have_front) {
            (void)SameProcess(&it->cursor, &it->front, &is_front);
        }
        if (it->have_self) {
            (void)SameProcess(&it->cursor, &it->self, &is_self);
        }
        fill_row(row, &it->cursor, &info, name, is_front, is_self);
        if (it->seen < 32767) {
            ++it->seen;
        }
        return 1;
    }
    return 0;
}

int now_proc_roster_read(const ProcessSerialNumber *psn,
                         NowProcRosterRow *row)
{
    ProcessInfoRec info;
    Str31 name;
    ProcessSerialNumber self;
    Boolean is_self = false;

    memset(&info, 0, sizeof info);
    info.processInfoLength = sizeof info;
    info.processName = name;
    info.processAppSpec = NULL;
    name[0] = 0;
    if (GetProcessInformation((ProcessSerialNumber *)psn, &info) != noErr) {
        return 0;
    }
    if (GetCurrentProcess(&self) == noErr) {
        (void)SameProcess((ProcessSerialNumber *)psn, &self, &is_self);
    }
    fill_row(row, psn, &info, name, now_proc_is_frontmost(psn), is_self);
    return 1;
}
