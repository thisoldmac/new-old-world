#ifndef NOW_CTLACT_LINE_H
#define NOW_CTLACT_LINE_H

/* `ctlact`'s CONSOLE grammar: `<element> <part> [h v]`.
 *
 * Two faces, one implementation - the rule in docs/command-parity.md.
 * Until 2026-08-07 this verb had a help row and a usage string and NO
 * console grammar at all, so a person who typed exactly what `help
 * ctlact` printed was told the command "requires element". That is the
 * asymmetry `CommandParityTests` cannot catch, because the verb is
 * present on both faces and only working on one.
 *
 * A reference is not a thing a person invents, but it IS a thing a
 * person can copy: `elements` prints one per row. So the console face is
 * usable, and it is the only face available at the machine itself.
 *
 * Toolbox-free, so the bounds are watched failing here rather than on a
 * Macintosh. Returns 1 when the line names at least an element and a
 * part. `*has_point` is 1 only when BOTH coordinates were given - one
 * alone is a malformed line, not a half-request, and the caller says so
 * with its own sentence. */
enum { kNowCtlactLineMax = 256 };

int now_ctlact_parse_line(const char *line, char *element, long cap,
                          long *part, int *has_point, long *h, long *v,
                          int *half_point);

/* The parsed line, written back out as the TYPED request this command
   already serves. One implementation, two doors: the console's line
   becomes args and then takes the same path a host's args take, so a
   behaviour can never be right on one face and missing on the other.
   Returns 0 when the element would not fit, which is the only way it can
   fail - a reference longer than the registry mints is not one. */
int now_ctlact_line_request(const char *element, long part, int has_point,
                            long h, long v, char *out, long cap);

#endif
