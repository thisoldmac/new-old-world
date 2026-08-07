#ifndef NOW68K_HELLO_H
#define NOW68K_HELLO_H

#include "guest_identity.h"   /* kNowIdentityUnknown, and the cap to size by */

/* This guest's fixed answers to the Hello schema's optional fields
 * (contract/asyncapi.yaml, components.schemas.Hello). name is "for
 * display only"; chunk is this side's preferred bulk chunk size -- the
 * connection uses the smaller of the two sides' preferences.
 *
 * chunk is 4096, not the contract's stated default of 8192: MacTCP
 * advertises a ~8K receive window regardless of rcvBuff, and a chunk
 * that large stalls ~220ms per write on delayed-ACK window updates (see
 * the project design notes). This is a NOW-68K-specific choice within a
 * contract-legal range (Hello.chunk: minimum 512, maximum 32768), not a
 * contract requirement.
 *
 * NOW68K_HELLO_OS IS GONE, and its absence is the point. It was "7.1",
 * a compile-time constant sent as the machine's system version -- a
 * field that claimed to describe the Macintosh and actually described
 * the build. It could not notice a System upgrade, it was wrong on any
 * 7.1-era machine running something else, and it could not key anything.
 * Since 2026-08-07 the version and the machine type are ARGUMENTS,
 * fetched by the caller from the census's Gestalt reads
 * (census68.h: now68k_system_version, now68k_machine_model,
 * now68k_machine_type) and decoded through contract/guest_identity.h so
 * that this guest and the PowerPC one spell the same fact identically.
 *
 * NOW68K_HELLO_NAME stays a literal, and that is not the same decision.
 * It is `name`, which the contract describes as a LABEL and explicitly
 * not an identity -- never compared, never keyed on. Filling it with the
 * machine's Sharing name would make it no more true and no more useful.
 */
#define NOW68K_HELLO_NAME  "now-68k"
#define NOW68K_HELLO_CHUNK 4096

/* Builds a hello control payload into buf (NUL-terminated).
 *
 *   contract        the sender's contract revision (Hello.contract,
 *                   required).
 *   app_version     the sending app's own version (Hello.version,
 *                   required), for display only per the schema.
 *   system_version  this machine's system version as
 *                   `major.minor.bugfix`, or `kNowIdentityUnknown` where
 *                   Gestalt did not answer. NULL is treated as unknown.
 *                   Write it with now68k_system_version() rather than by
 *                   hand -- the shape is compared against the other
 *                   guest's, so it is not a free choice.
 *   machine_id      the raw gestaltMachineType response, or 0 for "could
 *                   not establish". A MODEL, never a unit.
 *   machine_model   the machine's own name for itself, or NULL. Quotes,
 *                   backslashes and control characters are neutralised
 *                   here -- it is the one field in this message that
 *                   comes from somebody's System rather than from us.
 *
 * side, name and chunk are fixed by this file. Returns the length
 * written excluding the NUL, or 0 if buf/app_version is NULL, cap <= 0,
 * or the payload does not fit. */
long now68k_hello_build(char *buf, long cap, long contract,
                         const char *app_version,
                         const char *system_version,
                         long machine_id, const char *machine_model);

#endif
