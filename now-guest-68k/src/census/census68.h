/*
 * census68.h - the Toolbox side of NOW-68K's hardware census: the probe
 * registry, and one page of one probe.
 *
 * n68_census.h holds the page, the wire renderer and the console renderer,
 * and is Toolbox-free so a host cc can test it. THIS file is the half that
 * can only run on a Macintosh: Gestalt, the drive queue, the unit table,
 * ADB, Parameter RAM, the Power Manager. Nothing here has a native test and
 * nothing here can have one - which is stated in docs/contract-coverage.md
 * rather than implied by a green suite.
 *
 * THE REGISTRY IS THE CONTRACT'S, NOT THIS BUILD'S. Every name in
 * `x-census/x-probes` is answered by this guest, including the ones this
 * machine cannot serve - because the alternative is a probe that falls
 * through to "unknown probe", which tells a host that the REGISTRY does not
 * have it rather than that this machine does not. The outcome carries which:
 *
 *   present   the probe ran and found rows here
 *   absent    the MACHINE said no - no PCI, no PC Card socket, no ATA bus
 *   partial   it ran and reached a smaller surface than its full form
 *   refused   THIS BUILD declined to look, and the note says why
 *
 * Four of the fourteen answer `absent` or `refused` on a PowerBook 180c and
 * each says so in a sentence. That is the difference the census exists to
 * carry: a machine with no PCI bus is a finding, and a probe nobody has
 * written is a gap, and they must never read the same.
 */
#ifndef NOW68K_CENSUS68_H
#define NOW68K_CENSUS68_H

#include "n68_census.h"

/* Fills one page of `probe`, starting at `cursor` (0 or negative starts
 * over). Returns 1 with the page filled - the outcome rides inside it -
 * or 0 for a name that is not in the registry at all, which the caller
 * answers with `refused` and a note the way it answers an unknown command.
 *
 * `probe` may be NULL or "": both run "overview", which is what the
 * contract's `census` verb says an empty probe means.
 *
 * NOT free of TIME. Every probe here is a read of a table the OS already
 * maintains - no bus I/O, no disk seek - so a page is microseconds to a
 * few milliseconds. The one probe that would not be (`scsi`, an INQUIRY
 * bus scan) is the one this build refuses. */
int now68k_census_gather(const char *probe, long cursor, N68CensusPage *page);

#endif /* NOW68K_CENSUS68_H */
