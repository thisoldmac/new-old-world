#ifndef NOW_FILESHARE_H
#define NOW_FILESHARE_H

#include <Carbon.h>

/* The guest's file share. NOTE the file name: a header called
   files.h shadows the system Files.h on a case-insensitive volume,
   breaking every Carbon include.

   The share: everything is addressed RELATIVE to the
   configured share root (prefs; default = the boot volume root), so a
   path outside the share is inexpressible rather than checked. Colon
   path semantics make an empty segment mean "parent", so any path
   containing "::" (or a bare leading/trailing colon) is refused. */

enum {
    kFilesOK = 0,
    kFilesBadPath = -1,               /* traversal, overlong segment */
    kFilesNotFound = -2,
    kFilesNotAFolder = -3,
    kFilesIOError = -4,
    kFilesTooBig = -5                 /* could not stage the file in RAM */
};

typedef struct {
    char name[32];
    Boolean folder;
    OSType file_type, creator;        /* 0 for folders */
    long data_bytes, rsrc_bytes;
    unsigned long modified;           /* classic seconds since 1904 */
} FileEntry;

typedef enum {
    kContainerAuto = 0,
    kContainerData,
    kContainerMacBinary
} FileContainer;

/* A file staged for the wire. blob is a temp-mem handle the caller owns
   (DisposeHandle); container says what the bytes are. */
typedef struct {
    Handle blob;
    long total_bytes;
    FileContainer container;          /* kContainerData or kContainerMacBinary */
    char name[32];
    OSType file_type, creator;
    long data_bytes, rsrc_bytes;
    unsigned long modified;
} FileStage;

/* Lists one page of a folder. `start` is the 1-based catalog index to
   begin at; fills up to max entries, returns the count and sets *more
   when another page remains (continue at *next_start). Negative = a
   kFiles error. */
int now_files_list(const char *rel_path, short start,
                   FileEntry *out, int max,
                   Boolean *more, short *next_start);

/* Stages a file for sending. container kContainerAuto applies the fork
   rule: data-only ships the data fork, resource-only ships MacBinary,
   both-forks ships the data fork (ask for MacBinary explicitly to get
   the whole artifact). */
int now_files_stage(const char *rel_path, FileContainer container,
                    FileStage *stage);
void now_files_stage_dispose(FileStage *stage);

/* One-line description of an entry as both consoles show it: "folder",
   or type plus fork sizes. A folder never reports a byte count - that
   would mean walking it, which a listing must not do. */
void now_files_describe(const FileEntry *entry, char *out, long cap);

/* The share root as a display string ("Macintosh HD:Lab:"), for UI. */
void now_files_root_name(char *out, long cap);

/* NavChooseFolder; persists the chosen root in prefs. 1 = changed,
   0 = cancelled, -1 = a folder was chosen but could not be saved. */
int now_files_choose_root(void);

/* File > File Sharing...: shows the current root and offers to change
   it. The host sees only what is inside. */
void now_files_sharing_dialog(void);

#endif /* NOW_FILESHARE_H */
