#ifndef NOW68K_HELLO_H
#define NOW68K_HELLO_H

/* This guest's fixed answers to the Hello schema's optional fields
 * (contract/asyncapi.yaml, components.schemas.Hello). name and os are
 * "for display only"; chunk is this side's preferred bulk chunk size --
 * the connection uses the smaller of the two sides' preferences.
 *
 * chunk is 4096, not the contract's stated default of 8192: MacTCP
 * advertises a ~8K receive window regardless of rcvBuff, and a chunk
 * that large stalls ~220ms per write on delayed-ACK window updates (see
 * the project design notes). This is a NOW-68K-specific choice within a
 * contract-legal range (Hello.chunk: minimum 512, maximum 32768), not a
 * contract requirement.
 */
#define NOW68K_HELLO_NAME  "now-68k"
#define NOW68K_HELLO_OS    "7.1"
#define NOW68K_HELLO_CHUNK 4096

/* Builds a hello control payload into buf (NUL-terminated). contract is
 * the sender's contract revision (Hello.contract, required); app_version
 * is the sending app's own version string (Hello.version, required),
 * shown for display only per the schema. side, name, os and chunk are
 * fixed by this file. Returns the length written excluding the NUL, or 0
 * if buf/app_version is NULL, cap <= 0, or the payload does not fit. */
long now68k_hello_build(char *buf, long cap, long contract,
                         const char *app_version);

#endif
