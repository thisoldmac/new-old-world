/*
 * log.h - the verb library's log sinks. Two channels, both DEFINED BY THE
 * LINKING SHELL (part of the shell contract in verbs.h; the worker's live in
 * worker/main_mac.c and land in worker.log):
 *
 *   hlog - verbose diagnostics -> the log file ONLY. The wire traces (OT
 *          events, send-shape) and per-stage probes go here; flushed per call
 *          so the last checkpoint survives a crash or wedge (read it back over
 *          the `read` verb). Callable from any verb.
 *
 *   alog - the curated ACTIVITY stream: lifecycle events and one
 *          `verb  target  result` line per request. A windowed shell may mirror
 *          it on screen (the retired harness app did); keep it terse - it is a
 *          human-facing log, not a trace.
 */
#ifndef TIMBOTTU_LOG_H
#define TIMBOTTU_LOG_H

void hlog(const char *fmt, ...);
void alog(const char *fmt, ...);

#endif /* TIMBOTTU_LOG_H */
