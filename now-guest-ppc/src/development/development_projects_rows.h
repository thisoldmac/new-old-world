#ifndef NOW_DEVELOPMENT_PROJECTS_ROWS_H
#define NOW_DEVELOPMENT_PROJECTS_ROWS_H

/* The catalog answer's shape, kept apart from the walk that fills it so
   the host compiler can test it (the walk is File Manager, this is not). */

enum {
    kDevProjectsListMax = 8,          /* one wire page, and one screenful */
    kDevProjectsIDCap = 33,
    kDevProjectsNameCap = 96
};

typedef struct DevProjectRow {
    char id[kDevProjectsIDCap];
    char name[kDevProjectsNameCap];
} DevProjectRow;

/* What the page shows about ONE project: the few manifest fields a
   person reads, lifted out of DevProject so the page never holds a
   16-kilobyte parse (its file list dominates that struct) for a
   selection. */
typedef struct DevProjectFacts {
    char id[kDevProjectsIDCap];
    char name[kDevProjectsNameCap];
    char target[64];
    char configuration[64];
    char toolchain_id[40];
    char toolchain_version[32];
    char product[128];
    int build_actions;
} DevProjectFacts;

/* One `Project` row's value: identity first so a name containing `|`
   stays parseable from the left, which is what the host already does. */
int dev_projects_record(char *out, long cap, const DevProjectRow *row);

/* The whole command.result. `next` is the cursor to ask for next, or -1
   at the end of the root; `active_id` may be NULL or empty when this Mac
   has no chosen project. Returns the length written, or 0 if the answer
   did not fit. */
long dev_projects_reply(char *out, long cap, long id,
                        const DevProjectRow *rows, int count,
                        long next, const char *active_id);

#endif
