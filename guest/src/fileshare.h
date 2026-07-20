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
    kFilesTooBig = -5,                /* could not stage the file in RAM */
    kFilesExists = -6                 /* would overwrite; caller must ask */
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

/* --- receiving ----------------------------------------------------------
   Incoming files stream to disk as chunks arrive rather than being
   staged in RAM: the app partition is smaller than the files people
   will send, and a transfer that can be written incrementally can also
   be cancelled by deleting what exists so far. MacBinary is therefore
   decoded incrementally too — header, then data fork, then padding,
   then resource fork — because there is no buffer to parse from.

   Bytes land under a temp name in the destination folder and are
   renamed on completion, so a truncated file never appears under the
   real one. That matters most here: a half-written application is
   something a human might double-click. */

typedef struct {
    Boolean active;
    FSSpec temp;                      /* what we are writing */
    FSSpec final;                     /* what it becomes on success */
    short data_ref, rsrc_ref;         /* open forks, -1 when closed */
    FileContainer container;
    long expected, received;
    /* MacBinary decode state */
    unsigned char header[128];
    long header_have;
    long mb_data_len, mb_rsrc_len;
    long mb_data_done, mb_rsrc_done;
    OSType file_type, creator;
    unsigned long modified;
} FileReceive;

/* Opens `name` in the folder `rel_path` for writing. Creates missing
   parent folders inside the share. Returns kFiles* — kFilesExists when
   the file is there and overwrite is false. */
int now_files_receive_begin(const char *rel_path, const char *name,
                            FileContainer container, long bytes,
                            OSType file_type, OSType creator,
                            unsigned long modified, Boolean overwrite,
                            FileReceive *rx);

/* Writes the next chunk. Returns kFiles* ; the caller stops on error. */
int now_files_receive_chunk(FileReceive *rx, const void *bytes, long len);

/* Closes the forks, stamps the file, and renames it into place.
   Returns kFiles*. */
int now_files_receive_finish(FileReceive *rx);

/* Abandons a transfer: closes anything open and deletes the temp. */
void now_files_receive_abort(FileReceive *rx);

/* The share root as a display string ("Macintosh HD:Lab:"), for UI. */
void now_files_root_name(char *out, long cap);

/* NavChooseFolder; persists the chosen root in prefs. 1 = changed,
   0 = cancelled, -1 = a folder was chosen but could not be saved (why
   is written into `why`, which the dialog shows rather than guessing). */
int now_files_choose_root(char *why, long why_cap);


#endif /* NOW_FILESHARE_H */
