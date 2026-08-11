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

/* --- what hello carries -------------------------------------------------
 *
 * The `identity` probe's three facts, as VALUES rather than as rows in a
 * page. `hello` sends them typed (contract, 2026-08-07) so the host can
 * key an asset pack on which Macintosh and which System answered, and
 * these are the same Gestalt reads the probe already performs - not new
 * ones. That matters on this guest specifically: it is the one that
 * refuses the `selectors` walk outright for want of 32 KB in a 384 KB
 * partition, so an identity route that cost a new probe would not be
 * affordable here.
 *
 * They are declared beside the census rather than in hello.h because
 * hello.c is deliberately Toolbox-free - that is what lets the host cc
 * compile and run it in test_framecodec. */

/* This machine's MODEL, e.g. "PowerBook 180c". Gestalt 'mnam' first (the
 * machine's own name for itself beats any table), then this file's short
 * table of 68K Macs, then "machine id <n>". Never empty, and a machine
 * outside the table reports its NUMBER rather than a guess. */
void now68k_machine_model(char *out, long cap);

/* The raw gestaltMachineType response, or 0 where Gestalt did not answer.
 * A MODEL, never a unit: two PowerBook 1400cs answer identically, and
 * nothing may read this as identifying one machine. */
long now68k_machine_type(void);

/* This machine's system version as `major.minor.bugfix`, or `unknown`
 * where Gestalt did not answer. Decoded through
 * contract/guest_identity.h, which is what makes it comparable with the
 * PowerPC guest's answer rather than merely similar to it. Size the
 * buffer from kNowIdentityVersionCap. */
void now68k_system_version(char *out, long cap);

#endif /* NOW68K_CENSUS68_H */
