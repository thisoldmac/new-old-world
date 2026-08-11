<!-- now-doc-provenance: generated reviewed=false -->

# What Open Transport will tell us, and what it will not

**Date:** 2026-07-31 · **Status:** survey done; rungs 1–2 **BUILT and TESTED,
not metal-verified** (2026-08-01); rung 4 unstarted · **Scope:** PowerPC /
Open Transport only — 68K machines are offline for this slice, so MacTCP is
deliberately unexamined.

> **Corrected 2026-08-01, from reading the struct rather than the prose.**
> `InetInterfaceInfo` carries `fHWAddr`, `fHWAddrLen`, `fIfMTU` and
> `fDomainName` — so **the hardware address and the MTU come from the
> ordinary client call**, not from DLPI, where this document originally
> filed them. That is a strictly better answer and it downgrades the DLPI
> rung to *statistics only*. Both were confirmed populated on a real
> PowerBook 1400c the same day: `00:60:1d:23:2c:05`, MTU 1500.

A read-only investigation, run before designing a networking module, to answer
one question: **is a connection table reachable, and at what cost?** The answer
decides whether "expose networking connections" is a cheap Tier A page or a
piece of archaeology with a provenance class attached.

Source for everything below: the **Universal Interfaces 3.4** headers shipped
with Retro68 (`InterfacesAndLibraries/AppleUniversal/Interfaces/CIncludes`).
Provenance class **`P-DOC`** for every citation here.

> **A caveat this document must carry.** These are the *headers*. A negative
> here is not a negative in the documentation — *Inside Macintosh: Networking
> With Open Transport* is a separate source and has not been consulted. "Not in
> the headers" is a weaker claim than "does not exist", and the difference
> matters most for exactly the thing that came back empty.

## Three tiers, not two

The survey's main result is that the surface is not "documented client API" and
"undocumented internals". There is a middle.

### Tier A — the ordinary client API. Free.

| What | Call |
| --- | --- |
| Enumerate the machine's network **ports** | `OTGetIndexedPort`, `OTFindPort`, `OTFindPortByRef` |
| Which port a provider is using | `OTGetProviderPortRef` |
| IP address, netmask, gateway, DNS per interface | `OTInetGetInterfaceInfo` |
| Per-endpoint options (ours only) | `TCP_NODELAY`, `TCP_MAXSEG`, `TCP_KEEPALIVE`, `IP_TTL`, `IP_TOS`, … |

`OTGetIndexedPort` is worth calling out: it enumerates the **machine's**
network ports, not ours. That is "networking hardware as a first-class thing"
answered by a documented call, which is most of one of this module's stated
goals for approximately no cost.

### Tier B — DLPI. Documented, but not the client API.

`OpenTransportProtocol.h` is the module writer's header and it ships in the
Universal Interfaces, so this is `P-DOC` rather than archaeology. It carries the
Data Link Provider Interface:

| What | Primitive |
| --- | --- |
| The link's **physical (MAC) address** | `DL_PHYS_ADDR_REQ` / `DL_PHYS_ADDR_ACK` |
| **Link-layer statistics** from the driver | `DL_GET_STATISTICS_REQ` / `DL_GET_STATISTICS_ACK` |

**This is the find of the survey.** Driver-level counters, documented, no
below-the-line work — and they serve the diagnostics goal directly. It is the
difference between a page that says "you have an Ethernet card" and one that
says what that card has actually been doing.

The posture is worth naming honestly: reaching DLPI means opening a stream to
the link driver rather than using the ordinary client API. Documented, but a
step down from `OTInetGetInterfaceInfo`. It wants its own care and probably its
own rung — a wedged link driver is a real failure mode on this hardware
(`ot-listener-wedge`, `silent-connection-wedge`), and a hardware-facing probe on
metal is exactly the class of thing that froze the 1400c with `cis`.

### Tier C — a connection table. **Not in the headers.**

Searched for and **not found**: any MIB or SNMP surface, any route table, any
call that enumerates connections belonging to the machine rather than to us.
The STREAMS ioctl families that do exist (`MIOC_DLPI`, `MIOC_SAD`,
`MIOC_STREAMIO`, `MIOC_STRLOG`) are stream administration, not a TCP
connection list.

So a `netstat`-shaped view is **not** reachable from the documented client API.

**But the earlier reasoning about *why* was wrong and is worth correcting in
place.** An earlier draft of this idea claimed the obstacle was the same
process-local wall that hides windows and menus (`observe-process-local-ui`).
It is not. Window and menu roots are per-process *by architecture* — swapped
low-memory globals — and no privilege changes that. Network stack state is
**system-global**: OT is STREAMS, and the modules and stack state live in the
system, not in the process that opened an endpoint. There is no process
boundary to defeat here.

That makes this an **undocumented-layout** problem, not an isolation problem —
the same shape as the `LMGetMenuList()` blocker, with the same resolution path:
find a document, find a third-party source, or measure it. And there is
existence proof that it is possible at all: classic-Mac tools showed live
connections on real machines.

It also means NOW already owns the safety machinery. `peek_validate.c` validates
a foreign pointer against the process's partition **or the system heap**
(`in_readable()` checks both), and the system-heap widening exists precisely
because partition-only validation read "unreadable" for everything but oneself.
A driver's globals in the system heap are a validated foreign-memory read in the
application — permitted by charter, with a bounded fail-closed reader already
written for it. No extension is required: nothing needs to execute in another
context, because the data is not in another context.

## What kind of source would settle rung 4

The negative above is now properly verified: **zero occurrences of `mib` or
`snmp` across all 16,316 lines of the OT headers.** Nothing is *declared*. That
does not mean nothing is *implemented*, and the distinction decides which
sources are worth chasing.

The lineage is the key fact to chase: **Open Transport is a licensed Mentat
implementation** — Mentat Portable Streams, with a System V STREAMS TCP. So the
structures are unlikely to be Apple inventions, and the question becomes which
published description of *that* stack applies.

Ordered by what they would cost us, and by what the charter lets us take:

| # | Source | Class | Why it is worth trying |
| --- | --- | --- | --- |
| 1 | **Open Transport Module Developer Note / OTMDK** | `P-DOC` | A STREAMS module lives *inside* the stack, so its documentation must describe the structures. The strongest candidate by far. |
| 2 | *Inside Macintosh: Networking With Open Transport* | `P-DOC` | Probably client-API only, but it is the book and it is unread. |
| 3 | **Mentat's own developer documentation** | `P-DOC` | If the TCP is Mentat's, the control blocks are Mentat's. |
| 4 | SVR4 / System V STREAMS references | `P-DOC` | The scaffolding (`queue_t`, `stdata`, `msgb`) is already exposed in `OpenTransportProtocol.h`, so this is corroboration for what we can already cite. |
| 5 | **Solaris / illumos STREAMS TCP** | `P-3P` | The closest living relative. Read for the **pattern**, not the code: its `T_OPTMGMT_REQ` + `MIB2_TCP_CONN` mechanism is exactly the shape an undeclared OT analogue would take. |
| 6 | Our own probe | `P-OBS` | Decisive, but needs a starting address that sources 1–5 supply. |
| 7 | Disassembling `OpenTransportLib` | `P-BIN` | Last resort. Offsets and sequences cross the line; function bodies, control flow and identifiers do not. |

### Try the call before poking the memory

The cheapest experiment is not archaeology at all. If the Mentat/SVR4 lineage
holds, OT may **implement** an option-management or ioctl path it never
declares. That is testable with `OTOptionManagement` / `OTIoctl` against an
ordinary TCP endpoint, using SVR4-shaped requests, and reading what comes back.

It fails closed — a rejected option is an error return, not a wild pointer —
and it costs one emulator session. **If anything answers, rung 4 collapses from
archaeology into Tier B**, with the finding recorded as `P-OBS`: we would have
measured that a documented call accepts an undocumented argument, which is a
fact about this machine rather than a claim about Apple's source.

That experiment should run **before** anyone reads a disassembler, and before
any offset is written down.

## What this changes about scoping

The module splits into rungs with genuinely different risk, and they should not
be bundled:

1. **Ports, interfaces, addresses** — Tier A, documented, cheap. This is the
   module's resting state and most of the "hardware and state" goal.
2. **The bench** — port tbt's `net` / `bench echo` / `bench send LEN CHUNK` /
   `bench recv` atom (`workshop/plugins/wsp_net.c`, 259 lines). One call is one
   point; the host composes the sweep. Inherits the one-transfer-lane rule.
3. **DLPI link statistics** — Tier B, documented, but driver-facing and
   metal-risky. Its own rung, emulator first. **Narrower than first
   thought:** the address and MTU came from Tier A, so what is left here is
   the counters alone.
4. **A connection table** — archaeology. Needs a declared provenance class
   (`P-DOC` if *Inside Macintosh: Networking With Open Transport* documents it,
   `P-OBS` if measured, `P-3P` if read off someone else's source) **before any
   code**, per the charter. Do not start this by guessing offsets.

## Corpus impact

`corpus_impact: none` — a header survey, not a measurement. Every citation is
`P-DOC` against Universal Interfaces 3.4 and asserts only what those headers
contain. The finding that would be owed is rung 4's: whether a connection table
has a citable layout, and from which source.
