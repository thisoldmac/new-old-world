#ifndef NOW_PROC_ACTIONS_H
#define NOW_PROC_ACTIONS_H

#include <Processes.h>

/* The two process actions that are honest on this platform, factored out
   so the Processes page (acting on its selection) and the host-driven
   wire verbs (acting on a PSN off the wire) share ONE implementation
   rather than two copies of the same Apple Event. */

/* Bring a process to the front. Thin over SetFrontProcess. */
OSErr now_proc_bring_to_front(const ProcessSerialNumber *psn);

/* Ask a process to quit: a 'quit' Apple Event it is free to decline or
   take its time over. noErr means the event was SENT, never that the
   application has gone. */
OSErr now_proc_ask_quit(const ProcessSerialNumber *psn);

#endif /* NOW_PROC_ACTIONS_H */
