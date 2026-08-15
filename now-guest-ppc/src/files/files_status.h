#ifndef NOW_FILES_STATUS_H
#define NOW_FILES_STATUS_H

/* The Files page's one status line, and the four kinds of news that
   compete for it.

   WHAT WAS WRONG. The placard had four independent writers - the share
   pane's errors, the browser's errors, the transfer's running commentary
   and the connection's absence - and each one did `snprintf(g_note, ...)`
   into a buffer it shared with the others. So "Not shared: the folder is
   read-only" survived exactly until the next click somewhere else, and
   nothing anywhere recorded that a person had never read it. A status
   line with several writers and one buffer does not show the most
   important thing; it shows the most RECENT thing, which is a different
   property and is only accidentally the same one.

   WHAT IS TRUE HERE. Each concern owns a channel and can only ever write
   its own. Nothing is destroyed by anyone else, so a channel that clears
   uncovers whatever was underneath it rather than falling to "Ready." -
   the property the old code could not have, since the news underneath
   had already been overwritten by the time it mattered.

   WHICH ONE SHOWS, since there is still one line:

     1. the transfer, whenever there is one. It is the only channel about
        RIGHT NOW; it changes on its own and a person watching it is
        watching it.
     2. otherwise the most recently written of the two complaint channels
        (sharing, browsing). Newest first rather than a fixed rank,
        because both are answers to something a person just did, and the
        thing they just did is the one they are waiting on.
     3. otherwise the link, which is why the rest of the page is empty.
     4. otherwise "Ready."

   Toolbox-free by construction, so the rule above is decided by
   files_status_test.c under the host cc rather than by reading a page on
   a Macintosh. */

#define kFilesStatusMax 128

typedef enum FilesStatusChannel {
    kFilesStatusTransfer = 0,         /* a file moving, right now */
    kFilesStatusShare,                /* sharing config, and sending */
    kFilesStatusBrowse,               /* listing the other Mac */
    kFilesStatusLink,                 /* whether there is a connection */
    kFilesStatusChannelCount
} FilesStatusChannel;

typedef struct FilesStatus {
    char line[kFilesStatusChannelCount][kFilesStatusMax];
    long stamp[kFilesStatusChannelCount];
    long clock;
} FilesStatus;

void now_files_status_reset(FilesStatus *s);

/* Writes one channel. A NULL or empty line clears that channel, which is
   how a concern says "nothing from me" - never how it says "and nothing
   from anyone else either". */
void now_files_status_set(FilesStatus *s, FilesStatusChannel channel,
                          const char *line);

/* The line to show, by the rule above. Always writes something. */
void now_files_status_text(const FilesStatus *s, char *out, long cap);

/* Which channel that line came from, or kFilesStatusChannelCount when
   every channel is quiet and the line is the idle one. For the test, and
   for a caller that wants to know whether its own news is being read. */
FilesStatusChannel now_files_status_source(const FilesStatus *s);

#endif /* NOW_FILES_STATUS_H */
