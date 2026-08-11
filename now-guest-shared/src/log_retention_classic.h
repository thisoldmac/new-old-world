#ifndef NOW_LOG_RETENTION_CLASSIC_H
#define NOW_LOG_RETENTION_CLASSIC_H

/* Best-effort File Manager adapter. Deletes only recognized session logs in
   `dir`, never `current`, and stops safely on any catalog/delete error. */
short now_log_prune_classic(short vref, long dir,
                            const unsigned char *current,
                            int dialect, unsigned short keep);

#endif
