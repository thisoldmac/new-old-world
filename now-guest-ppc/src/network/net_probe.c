/*
 * net_probe.c - the Open Transport half of the networking module.
 *
 * Everything here calls the Toolbox, which is why nothing here decides
 * anything: it fills a NetFacts and hands it to code a host test can
 * reach (net_facts.c). The split is the one peek_read.c/peek_oracle.c
 * uses, for the same reason - the interesting mistakes are in the
 * arithmetic and the vocabulary, not in the call.
 *
 * PROVENANCE: P-DOC throughout, against Universal Interfaces 3.4.
 *   OTInetGetInterfaceInfo, InetInterfaceInfo, kDefaultInetInterface,
 *   kInetInterfaceInfoVersion  -> OpenTransportProviders.h
 *   OTGetIndexedPort, OTPortRecord                -> OpenTransport.h
 * No offset here is measured, inferred, or copied from a disassembly.
 * A field Open Transport does not fill stays ABSENT rather than zero.
 *
 * WHAT THIS DELIBERATELY DOES NOT DO: enumerate the machine's TCP
 * connections. No documented Open Transport call does
 * (docs/ot-networking-surface.md - zero `mib`/`snmp` across 16,316 lines
 * of headers), so NetFacts.connections stays kNetFactUndocumented and
 * the page says why. Guessing at a driver's private structures to fill
 * that in is exactly the phantom-constant this project forbids, and it
 * would be dereferencing a foreign heap on the strength of a hunch.
 */

#include "net_probe.h"

#include <string.h>

#include <OpenTransport.h>
#include <OpenTransportProviders.h>

#include "ot_carbon.h"

/* OT's client calls are resolved at runtime alongside the rest of the
   Networking fragment (ot_carbon.h explains why a strong import would
   abort launch on stock CarbonLib 1.2). These two are not in NowOTTable
   because nothing else needed them; they are looked up the same way, so
   a Mac without the fragment answers "no Open Transport" through the UI
   instead of failing to launch. */
typedef OSStatus (*NetGetInterfaceInfoProc)(InetInterfaceInfo *info,
                                            SInt32 index);
typedef Boolean (*NetGetIndexedPortProc)(OTPortRecord *rec,
                                         OTItemCount index);

static NetGetInterfaceInfoProc gGetInterfaceInfo;
static NetGetIndexedPortProc gGetIndexedPort;
static Boolean gLookedUp;

static void lookup_once(void)
{
    CFragConnectionID id;
    Ptr addr;
    Str255 err;

    if (gLookedUp) {
        return;
    }
    gLookedUp = true;
    if (GetSharedLibrary("\pOTClientLib", kCompiledCFragArch,
                         kLoadCFrag, &id, &addr, err) != noErr) {
        return;                       /* stays NULL; probe reports no OT */
    }
    if (FindSymbol(id, "\pOTInetGetInterfaceInfo", &addr, NULL) == noErr) {
        gGetInterfaceInfo = (NetGetInterfaceInfoProc)addr;
    }
    if (FindSymbol(id, "\pOTGetIndexedPort", &addr, NULL) == noErr) {
        gGetIndexedPort = (NetGetIndexedPortProc)addr;
    }
}

/* Copy a fixed-width C field out of an OT record. OT's char arrays are
   NUL-terminated in practice but the header does not promise it, so the
   copy is bounded by BOTH lengths and terminated by us. */
static void copy_field(char *out, long cap, const char *src, long src_cap)
{
    long n = 0;

    if (out == NULL || cap <= 0) {
        return;
    }
    out[0] = '\0';
    if (src == NULL) {
        return;
    }
    while (n < src_cap && n < cap - 1 && src[n] != '\0') {
        out[n] = src[n];
        ++n;
    }
    out[n] = '\0';
}

static void probe_interface(NetInterface *out)
{
    InetInterfaceInfo info;
    OSStatus err;

    if (gGetInterfaceInfo == NULL) {
        out->state = kNetFactNoOT;
        return;
    }
    memset(&info, 0, sizeof info);
    err = gGetInterfaceInfo(&info, kDefaultInetInterface);
    if (err != noErr) {
        /* A Mac with Open Transport installed and TCP/IP unconfigured
           lands here, which is an ordinary state rather than a fault -
           the module renders it as refused-with-a-reason, not as an
           error. */
        out->state = kNetFactRefused;
        return;
    }

    out->state = kNetFactPresent;
    now_net_format_ip(info.fAddress, out->address, (long)sizeof out->address);
    now_net_format_ip(info.fNetmask, out->netmask, (long)sizeof out->netmask);
    now_net_format_ip(info.fBroadcastAddr, out->broadcast,
                      (long)sizeof out->broadcast);

    /* Absent rather than 0.0.0.0. A machine on a flat network genuinely
       has no gateway, and printing an address it does not have is the
       kind of confident wrong answer this module is built to avoid. */
    out->has_gateway = (info.fDefaultGatewayAddr != 0);
    if (out->has_gateway) {
        now_net_format_ip(info.fDefaultGatewayAddr, out->gateway,
                          (long)sizeof out->gateway);
    }
    out->has_dns = (info.fDNSAddr != 0);
    if (out->has_dns) {
        now_net_format_ip(info.fDNSAddr, out->dns, (long)sizeof out->dns);
    }

    /* fHWAddrLen travels with fHWAddr and is NOT promised to be six -
       the formatter takes the length for that reason. A link that is not
       Ethernet is the case that would otherwise read past the end. */
    out->has_hw = (info.fHWAddr != NULL && info.fHWAddrLen > 0);
    if (out->has_hw) {
        now_net_format_hw((const unsigned char *)info.fHWAddr,
                          (long)info.fHWAddrLen,
                          out->hw_address, (long)sizeof out->hw_address);
        if (out->hw_address[0] == '\0') {
            out->has_hw = false;      /* did not fit; say nothing */
        }
    }

    out->has_mtu = (info.fIfMTU != 0);
    out->mtu = (unsigned long)info.fIfMTU;

    copy_field(out->domain, (long)sizeof out->domain,
               (const char *)info.fDomainName, (long)sizeof info.fDomainName);
}

static void probe_ports(NetFacts *out)
{
    OTPortRecord rec;
    OTItemCount index = 0;

    if (gGetIndexedPort == NULL) {
        out->ports_state = kNetFactNoOT;
        return;
    }
    out->ports_state = kNetFactPresent;
    out->port_count = 0;

    /* OTGetIndexedPort walks the MACHINE'S ports, not ours - which is
       most of "networking hardware as a first-class thing" for the price
       of this loop. Bounded by kNetMaxPorts as well as by the Boolean
       return: a walk that never terminates on a machine with an unusual
       port table would hang the event loop, and the cap costs nothing. */
    while (out->port_count < (short)kNetMaxPorts) {
        memset(&rec, 0, sizeof rec);
        if (!gGetIndexedPort(&rec, index)) {
            break;
        }
        ++index;
        {
            NetPort *p = &out->ports[out->port_count];

            copy_field(p->name, (long)sizeof p->name,
                       rec.fPortName, (long)sizeof rec.fPortName);
            copy_field(p->device, (long)sizeof p->device,
                       rec.fModuleName, (long)sizeof rec.fModuleName);
            copy_field(p->slot, (long)sizeof p->slot,
                       rec.fSlotID, (long)sizeof rec.fSlotID);
            p->ref = (unsigned long)rec.fRef;
            p->capabilities = (unsigned long)rec.fCapabilities;
            p->active = (rec.fPortFlags != 0);
            ++out->port_count;
        }
    }
}

void now_net_probe(const NetLinkSample *link, NetFacts *out)
{
    if (out == NULL) {
        return;
    }
    now_net_facts_clear(out);

    lookup_once();

    /* The link is ours and needs no Open Transport lookup at all - NOW
       is holding the endpoint, so its peer and counters are facts we
       already have. Filled first and unconditionally, so a Mac without
       OT still shows a real measurement rather than an empty page. */
    if (link != NULL && link->connected) {
        out->link.state = kNetFactPresent;
        copy_field(out->link.peer, (long)sizeof out->link.peer,
                   link->peer, (long)sizeof link->peer);
        out->link.port = link->port;
        out->link.up_ticks = link->up_ticks;
        out->link.bytes_in = link->bytes_in;
        out->link.bytes_out = link->bytes_out;
        out->link.resets = link->resets;
    } else {
        out->link.state = kNetFactNotServed;
    }

    if (gGetInterfaceInfo == NULL && gGetIndexedPort == NULL) {
        out->ot = kNetFactNoOT;
        copy_field(out->ot_reason, (long)sizeof out->ot_reason,
                   "Networking fragment not found", 30);
        out->inet.state = kNetFactNoOT;
        out->ports_state = kNetFactNoOT;
        return;
    }
    out->ot = kNetFactPresent;

    probe_interface(&out->inet);
    probe_ports(out);
    /* out->connections stays kNetFactUndocumented from clear(). Nothing
       below this line could honestly change it. */
}
