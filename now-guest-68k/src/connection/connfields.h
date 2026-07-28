#ifndef NOW_CONNFIELDS_H
#define NOW_CONNFIELDS_H

/*
 * Pure-C validation for the Connection tab's three hand-typed fields
 * (Host, Port, Connect timeout). No Toolbox calls, no allocation -
 * every buffer here is fixed and owned by the caller, so this compiles
 * and runs unchanged on the host (for this test) and under Retro68 68K.
 *
 * There are no saved preferences in this pass: the human retypes all
 * three fields every launch, so a wrong or ambiguous value has to be
 * caught immediately and explained, not silently coerced.
 *
 * Each validator returns a small result struct: an ok flag, the parsed
 * value on success, and a short ASCII reason always filled in (success
 * or failure) so the caller can draw it under the field with DrawString
 * without a NULL check. Reason text is ASCII only - see AGENTS.md
 * (guest-ui-start-here.md): a UTF-8 dash in a DrawString literal comes
 * out as mojibake on a Mac OS system script.
 */

#define kConnReasonMax 40

/* ---- Host: dotted-quad IPv4 only -----------------------------------
 *
 * MacTCP name resolution (.INETD/DNR) is a separate subsystem this
 * milestone does not take on, so a hostname is a hard rejection, not
 * a fallback. Rules, closest first:
 *   - exactly four decimal octets separated by '.', each 0-255
 *   - a leading zero on a multi-digit octet ("007", "010") is
 *     ACCEPTED and read as decimal (010 -> 10). An earlier draft
 *     refused it on the theory that some parsers (and scanf %i) read
 *     a leading zero as octal - but this validator never calls scanf
 *     and is decimal-only by construction (it only recognizes '0'-'9'
 *     and never branches on a base prefix), so that risk does not
 *     apply here. The shipping PPC guest's dotted-quad validator
 *     (now/now-guest-ppc/src/connection/conn_fields.c, now_conn_ipv4_valid) already
 *     accepts a leading zero for the same reason; this validator
 *     matches it so the same address is not valid on one NOW client
 *     and refused on the other.
 *   - no surrounding whitespace, no trailing characters after the
 *     fourth octet
 */
typedef struct {
    int           ok;
    unsigned long addr;   /* host byte order: (a<<24)|(b<<16)|(c<<8)|d, valid only if ok */
    char          reason[kConnReasonMax];
} ConnHostResult;

ConnHostResult now_conn_host_validate(const char *text);

/* ---- Port -----------------------------------------------------------
 *
 * Range is 1..65535, the full TCP port space - NOT floored at 1024.
 * The CodeKitten agent-control validator
 * (codekitten/core/agent_control_config.c:23-48) floors at 1024
 * because that port is one CodeKitten itself BINDS on the guest, and
 * refusing the reserved range is a sane default for a service you are
 * standing up. This field is the opposite direction: it names a NOW
 * HOST's listening port that some other operator already chose and
 * that we only DIAL OUT to (dial-out only, no listening socket - see
 * project design decisions). We have no basis to declare any host's
 * choice invalid, so the only real constraint is the protocol's own
 * range. Port 0 is refused (not a connectable port).
 *
 * The contract (now/contract/asyncapi.yaml) is transport-agnostic and
 * states no default port number - "port-select" is mentioned only in
 * the abstract, alongside ws://wss:// (line 28). The project's actual
 * default of 5250 lives in code, not the contract: the existing PPC
 * guest's contract.h (kNowDefaultHostPort) and the host's
 * SettingsModel.swift (defaultPort) both hardcode 5250. That is a UI
 * default for this field, not a validation bound.
 */
#define kNowDefaultHostPort 5250

typedef struct {
    int            ok;
    unsigned short port;   /* valid only if ok */
    char           reason[kConnReasonMax];
} ConnPortResult;

ConnPortResult now_conn_port_validate(const char *text);

/* ---- Connect timeout, whole seconds ---------------------------------
 *
 * The existing MacTCP client (chat/client/src/net_mactcp.c) hands
 * TCPActiveOpen a fixed ulpTimeoutValue of 15 with abort action, so
 * MacTCP itself aborts a dead address rather than hanging forever;
 * that 15 s figure is this field's default. ulpTimeoutValue is a
 * single byte in MacTCP's csParam.open (0-255 s), so 255 is the
 * hard protocol ceiling - but nobody sitting at the Connection tab
 * wants to type "200", and a value that large defeats the point of a
 * user-facing timeout (report and stop, per the no-retry design
 * decision). 60 s is a generous, still-human upper bound comfortably
 * inside the protocol ceiling; 1 s is the floor because 0 would mean
 * "never even try."
 */
#define kConnTimeoutDefaultSecs 15
#define kConnTimeoutMinSecs     1
#define kConnTimeoutMaxSecs     60

typedef struct {
    int   ok;
    short seconds;   /* valid only if ok */
    char  reason[kConnReasonMax];
} ConnTimeoutResult;

ConnTimeoutResult now_conn_timeout_validate(const char *text);

#endif /* NOW_CONNFIELDS_H */
