# What Open Transport will tell us, and what it will not

**Date:** 2026-07-31 · **Status:** first-pass header survey, nothing built ·
**Scope:** PowerPC / Open Transport only — 68K machines are offline for this
slice, so MacTCP is deliberately unexamined.

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

## What this changes about scoping

The module splits into rungs with genuinely different risk, and they should not
be bundled:

1. **Ports, interfaces, addresses** — Tier A, documented, cheap. This is the
   module's resting state and most of the "hardware and state" goal.
2. **The bench** — port tbt's `net` / `bench echo` / `bench send LEN CHUNK` /
   `bench recv` atom (`workshop/plugins/wsp_net.c`, 259 lines). One call is one
   point; the host composes the sweep. Inherits the one-transfer-lane rule.
3. **DLPI link statistics** — Tier B, documented, but driver-facing and
   metal-risky. Its own rung, emulator first.
4. **A connection table** — archaeology. Needs a declared provenance class
   (`P-DOC` if *Inside Macintosh: Networking With Open Transport* documents it,
   `P-OBS` if measured, `P-3P` if read off someone else's source) **before any
   code**, per the charter. Do not start this by guessing offsets.

## Corpus impact

`corpus_impact: none` — a header survey, not a measurement. Every citation is
`P-DOC` against Universal Interfaces 3.4 and asserts only what those headers
contain. The finding that would be owed is rung 4's: whether a connection table
has a citable layout, and from which source.
