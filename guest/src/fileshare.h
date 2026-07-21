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
int now_files_stage_spec(const FSSpec *from, FileContainer container,
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

/* Counters for the receive path, readable with the `putstat` command.
   Timing where the work actually happens beats inferring it from the
   far end of a wire. */
typedef struct {
    long chunks;                      /* calls into receive_chunk */
    long writes;                      /* FSWrite calls made */
    long bytes;
    unsigned long us_write;           /* time inside FSWrite */
    unsigned long us_total;
    long resumed_from;                /* byte this attempt started at */
    unsigned long us_reseed;          /* time re-reading the partial's CRC */
    unsigned long crc;                /* CRC-32 the guest computed */
} FileReceiveStats;

void now_files_receive_stats(FileReceiveStats *out);

/* CRC-32 (IEEE, the zlib polynomial 0xEDB88320) with zlib's own
   convention: seed with 0, feed successive runs of bytes, and the
   return value is always the finished CRC of everything fed so far. The
   composition property is the point — a file stitched from two sessions
   must check out the same as one written in a single pass. */
unsigned long now_crc32(unsigned long crc, const void *bytes, long len);

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
    /* Writes are batched: a trap per 4 KB chunk is a trap per chunk too
       many, and each write that EXTENDS a file pays for allocation and
       catalog updates. */
    Ptr buf;
    long buf_len;
    /* Running CRC-32 of the WHOLE file, seeded on resume from the bytes
       already on disk, so it covers the seam between two sessions. */
    unsigned long crc;
    /* A partial worth resuming from: abort keeps it instead of deleting
       it. Only ever set when the sender named the file with a
       resumeToken, so an old peer's failures still clean up after
       themselves. */
    Boolean keep_partial;
} FileReceive;

/* Bytes of a resumable partial already held for `resume_token` in the
   folder `rel_path`, or 0 when there is nothing to resume from. This is
   what the guest answers file.accept's `have` with.

   The token IS the storage: the temp's name is derived from it, so
   there is no sidecar to fall out of step with the file. A 32-bit hash
   can collide, so a partial only counts when its size is also <=
   total_bytes; the end-to-end CRC on file.end is the real backstop, and
   the only thing that can prove the bytes are the right ones. */
long now_files_partial_bytes(const char *rel_path, const char *resume_token,
                             long total_bytes);

/* Opens `name` in the folder `rel_path` for writing. Creates missing
   parent folders inside the share. Returns kFiles* — kFilesExists when
   the file is there and overwrite is false.

   resume_token (NULL or "" when the sender did not name the file)
   decides two things at once: the temp is named after the token rather
   than the clock, and a failed transfer KEEPS its partial instead of
   deleting it. Without a token the old behavior stands exactly —
   clock-named temp, deleted on abort — so a peer that never learned to
   resume is not made worse.

   resume_offset > 0 reopens the existing partial and continues at that
   byte, seeding the CRC from what is already on disk (which also proves
   the partial is readable). It requires a token and the data container;
   0 is a fresh start. */
int now_files_receive_begin(const char *rel_path, const char *name,
                            FileContainer container, long bytes,
                            OSType file_type, OSType creator,
                            unsigned long modified, Boolean overwrite,
                            const char *resume_token, long resume_offset,
                            FileReceive *rx);

/* The same, into a folder named by volume and directory ID rather than
   through the share: where a PULLED file lands is the person's own
   downloads folder, deliberately outside what the other machine can
   reach. */
int now_files_receive_begin_at(short vref, long dir_id, const char *name,
                               FileContainer container, long bytes,
                               OSType file_type, OSType creator,
                               unsigned long modified, Boolean overwrite,
                               const char *resume_token, long resume_offset,
                               FileReceive *rx);

/* The downloads folder from preferences, or the Desktop. */
int now_files_downloads(short *vref, long *dir);

/* Its short name, for a button that says where things land. */
void now_files_downloads_name(char *out, long cap);

/* Chooses it (NavChooseFolder) and remembers it. 1 = changed,
   0 = cancelled, -1 = failed. */
int now_files_choose_downloads(char *why, long why_cap);

/* Opens it in the Finder, so "where did it go" has an answer that is
   one click rather than a hunt. */
int now_files_reveal_downloads(void);

/* Writes the next chunk. Returns kFiles* ; the caller stops on error. */
int now_files_receive_chunk(FileReceive *rx, const void *bytes, long len);

/* Closes the forks, stamps the file, and renames it into place.
   Returns kFiles*. */
int now_files_receive_finish(FileReceive *rx);

/* Abandons a transfer: closes anything open, and deletes the temp
   UNLESS it is resumable, in which case the partial is flushed and
   truncated to the bytes actually written and left for a later attempt.
   Truncation is what makes the temp's EOF an honest byte count, which
   is the whole basis on which `have` is reported. */
void now_files_receive_abort(FileReceive *rx);

/* Abandons a transfer and deletes the temp whatever its token says.
   For bytes that failed their own checksum: a file that cannot prove it
   is correct is not a resume candidate, it is garbage, and leaving it
   would let the same bad bytes be resumed onto forever. */
void now_files_receive_discard(FileReceive *rx);
/* The OSErr behind the most recent kFilesIOError. "The File Manager
   refused" names no cause; the number does. */
OSErr now_files_last_error(void);

/* --- changing the share ------------------------------------------------
   Every change here is reversible, which is what lets the other side
   offer undo. Deleting moves an item to the volume's Trash rather than
   erasing it; the caller gets a token that puts it back, because the
   Trash is outside the share and has no path this protocol can name. */

/* Moves and/or renames. `to_rel` is the full destination path including
   the new name. Parents are NOT created — moving into a folder that is
   not there is a mistake, not an instruction. */
int now_files_move(const char *rel, const char *to_rel, Boolean overwrite);

/* Moves an item to the Trash. On success `trashed_as` is the name it
   landed under there — the Trash may already hold that name, so it is
   not always the name it had. That name, plus the path it came from, is
   everything a restore needs; nothing is remembered here. */
int now_files_trash(const char *rel, char *trashed_as, long cap);

/* Moves an item back out of the Trash to `to_rel`. Both halves are
   names, so this works across a restart of this app. kFilesNotFound
   when the Trash no longer holds it (emptied, or dragged out by hand). */
int now_files_restore(const char *trashed_as, const char *to_rel);

/* Creates a folder. kFilesExists if something is already there. */
int now_files_mkdir(const char *rel);


/* The share root as a display string ("Macintosh HD:Lab:"), for UI. */
void now_files_root_name(char *out, long cap);

/* NavChooseFolder; persists the chosen root in prefs. 1 = changed,
   0 = cancelled, -1 = a folder was chosen but could not be saved (why
   is written into `why`, which the dialog shows rather than guessing). */
int now_files_choose_root(char *why, long why_cap);

/* NavGetFile, for sending a file the human picks. 1 = chosen (spec
   written), 0 = cancelled, -1 = failed (why explains). */
int now_files_pick_file(FSSpec *out, char *why, long why_cap);


#endif /* NOW_FILESHARE_H */
