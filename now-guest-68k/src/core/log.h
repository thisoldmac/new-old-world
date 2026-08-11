/*
 * log.h - the launch log for NOW-68K.
 *
 * main.c opens this BEFORE any connection setup work. The existing PPC guest
 * opens its log after conn_init (docs/guest-ui-start-here.md); a hang during
 * connection setup then leaves no log at all, which is exactly the failure
 * this milestone is about. Do not move the open call after transport init.
 *
 * File Manager rather than stdio, for four reasons that only bite on metal:
 * one file per launch (mode "w" destroys the hung run's log the moment you
 * relaunch to read it), CR line endings (a log full of '\n' is one endless
 * line in TeachText on System 7.1), 'ttxt'/'TEXT' so it is double-clickable
 * rather than an '????' brick, and FlushVol so the catalog EOF is committed
 * before the forced restart a wedge requires. It also keeps newlib's stdio
 * and its float-formatting tail out of the link entirely.
 */
#ifndef NOW68K_LOG_H
#define NOW68K_LOG_H

/* Creates this launch's log beside the application. Safe to call once. */
void now68k_log_open(void);

/* One line, CR-terminated, committed to disk before returning. ASCII only:
 * this text is also the first thing a human reads on the machine itself. */
void now68k_log(const char *msg);

/* Same, with a signed decimal appended after a space - avoids dragging in
 * printf for the one thing the log actually needs to interpolate. */
void now68k_log_num(const char *msg, long value);

void now68k_log_close(void);

#endif /* NOW68K_LOG_H */
