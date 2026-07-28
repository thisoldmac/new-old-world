#ifndef N68_DEVSETTINGS_FILE_H
#define N68_DEVSETTINGS_FILE_H

/*
 * The DEV-ONLY settings file: File Manager half. The parser, the format and
 * the design rule ("a settings file must never make the application worse
 * than having none") are in n68_devsettings.h; this file only finds the
 * bytes and hands them over.
 *
 * Split out so the parser stays Toolbox-free and testable under the host cc
 * - the same split log.h/log.c and connfields.c already draw. Nothing in
 * here is testable off the target: it is System 7.1 File Manager calls and
 * a Process Manager lookup, and its verification status is BUILDS until
 * someone watches it on the PowerBook.
 */

#include "n68_devsettings.h"

/* The file the lab drops beside the application. Named for what it is, so
 * that finding one on a machine that should not have one is obvious rather
 * than mysterious. 20 characters, inside HFS's 31. A Pascal literal because
 * the only thing that ever reads it is a Toolbox call. */
#define kN68DevSettingsFileName "\pNOW-68K Dev Settings"

/* Reads and parses the settings file sitting BESIDE THE APPLICATION - not
 * in the System Folder, and not in the launch directory, which are not the
 * same place (log.c and main.c's chdir_to_app_folder both had to learn
 * this: Rumpus deposits builds on the Desktop and the launch default dir
 * follows).
 *
 * `s` is initialized here; the caller does not have to.
 *
 * Returns 1 if a file was found and parsed - which does NOT mean anything
 * in it was valid, only that the caller may look at s->bad_lines and
 * s->keys_set and say something honest about it. Returns 0 when there is no
 * file, which is the NORMAL case and the shipping one: it is completely
 * silent - no dialog, no log line, no console line - because on every
 * machine but a lab bench the absence of this file is not an event.
 *
 * A file that exists but cannot be read (locked, busy, damaged) also
 * returns 0, and for the same reason: there is nothing the human can do
 * about it that a startup they did not ask for should interrupt.
 */
int now68k_devsettings_load(N68DevSettings *s);

#endif /* N68_DEVSETTINGS_FILE_H */
