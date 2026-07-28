#ifndef NOW_SW_VERS_PARSE_H
#define NOW_SW_VERS_PARSE_H

/* Parsing a 'vers' resource is pure byte work — the fixed layout IS the
   contract — so it lives here, Toolbox-free, and a host cc compiles it
   against synthetic bytes. That is the whole point: the bounds a
   truncated old-file resource must survive get watched failing on the
   host, not discovered on the PowerBook.

   The layout, once, where both readers see it:
     b[0]      major, BCD
     b[1]      minor (high nibble) / bugfix (low nibble), BCD
     b[2]      stage: 0x20 dev, 0x40 alpha, 0x60 beta, 0x80 final
     b[3]      non-release revision
     b[4..5]   region code (ignored)
     b[6]      short-version Pascal length; the string follows at b[7]
     b[7+b[6]] Get Info Pascal length; that string follows */

/* Parse a 'vers' resource's raw bytes. Fills the short version string
   ("1.4"), a numeric rendering ("1.4.0 final", or with " (prerelease)"),
   and the Get Info string — each bounded, NUL-terminated, "" when the
   field is absent or the buffer is too small. Returns 1 if the resource
   was well-formed enough to yield a short version, else 0. Any of the
   three out buffers may be NULL (with its cap 0) to skip that field. */
int sw_parse_vers(const unsigned char *bytes, long size,
                  char *shortv, long shortcap,
                  char *numeric, long numcap,
                  char *info, long infocap);

#endif /* NOW_SW_VERS_PARSE_H */
