#include "wire.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <Processes.h>

#include "agent_access.h"
#include "act_client.h"
#include "build_stamp.h"
#include "capture.h"
#include "cloud_preview.h"
#include "fileshare.h"
#include "files_drop.h"
#include "commands.h"
#include "census.h"
#include "console_model.h"   /* the exec plane runs the Console's dispatch */
#include "continuity_intake.h"
#include "json.h"
#include "loopstat.h"
#include "mirror_policy.h"
#include "nowlog.h"
#include "pixels.h"
#include "contract.h"
#include "ot_carbon.h"
#include "peek.h"
#include "anchor_acquire.h"
#include "peek_read.h"
#include "prefs.h"
#include "proc_actions.h"
#include "proc_roster.h"
#include "product_identity.h"
#include "scene_collect.h"
#include "scene_phase.h"
#include "software.h"
#include "transitions_cmd.h"
#include "development_candidate.h"
#include "wire_sleep.h"
#include "sha256.h"
#include "update_install.h"
#include "update_model.h"
#include "update_status.h"

enum {
    /* Room for the one field whose VALUE is not known until the sizing
       pass has already run: meta.phases.us.encode, and the two counters
       the sizing pass's own clock reads move. Sixty-four bytes against a
       document measured in kilobytes, spent so that "how long did the
       encode take" can be a number in the document rather than a number
       nobody carries. */
    kSceneEncodePhaseSlack = 64,
    kConnectTimeoutTicks = 60 * 10,   /* 10s to establish the socket */
    kHelloTimeoutTicks = 60 * 8,      /* 8s for the host's hello */
    kPingIntervalTicks = 60 * 30,     /* ping after 30s of silence */
    kDeadTicks = 60 * 65,             /* no traffic for 65s => dead */
    /* **A gap between two consecutive passes of our own event loop that
       is too long to be scheduling.** Above this, the application was
       not RUNNING for that interval - and time we were not running is
       not time the host was silent.

       Ten seconds. A healthy pass is milliseconds; the pump is called
       from the main loop and from every nested Toolbox loop (pump.h), so
       even a modal or a long file operation keeps it well under a
       second. Nothing legitimate lands between one second and ten, which
       is why the threshold can be this far from both. */
    kStarvedPassTicks = 60 * 10,
    /* Diagnostic threshold only. A normal scene is sub-second even on the
       PowerBook; two seconds is already a visible application stall and far
       below the 13-25 second gaps this instrument exists to attribute. */
    kSlowSceneLogMs = 2000,
    kBackoffMinTicks = 60 * 2,        /* 2s, doubling... */
    kBackoffMaxTicks = 60 * 30,       /* ...to 30s */
    kRetryFloorTicks = 60 * 1,        /* the contract's only cadence rule */
    /* Big enough for the largest legal control frame (the contract caps
       control JSON at 4096). Bulk is never buffered whole — see
       next_frame — because one bulk frame is larger than anything this
       machine should hold in RAM merely to frame it. */
    kRxBufferSize = 4608
};

typedef struct {
    ConnPhase phase;
    char host[64];
    unsigned short port;
    Boolean want_connection;          /* false => stay disconnected */

    EndpointRef ep;
    UInt32 address;
    InetAddress connect_address;      /* async OTConnect retains both */
    TCall connect_call;
    volatile OSStatus connect_result;
    volatile Boolean connect_done;
    Boolean connect_notifier_installed;
    /* The same notifier serves two eras of one endpoint. During the dial
       it acknowledges the connect; afterwards it does nothing but notice
       that bytes arrived. It is ONE notifier because OT allows one per
       provider, and switching a mode word is the only way to have both
       without tearing the endpoint down between them. */
    volatile Boolean notify_data_era;

    unsigned char rx[kRxBufferSize];
    long rx_len;
    long discard_remaining;           /* bytes of a message too big to
                                         hold, being thrown away */
    long bulk_remaining;              /* payload left in the bulk frame
                                         being consumed; 0 when none */

    unsigned long phase_deadline;     /* connect/hello timeout */
    unsigned long last_rx_tick;       /* any inbound bytes */
    /* When this loop last ran. A long gap here means the APPLICATION was
       not scheduled, which is a different fact from the host being quiet
       - see service_heartbeat(). Zero until the first pass. */
    unsigned long last_pass_tick;
    unsigned long next_ping_tick;
    long pings_sent;                  /* since last pong */
    long ping_id;
    unsigned long ping_sent_tick;
    long last_rtt_ms;

    unsigned long backoff_ticks;
    unsigned long backoff_until;

    unsigned short transfer_seq;
    long offer_seq;
    char peer_name[64];
    char peer_version[32];
    char status[128];
    char last_fail[128];
    unsigned long connected_tick;     /* when the hello completed */
} ConnState;

static ConnState g;
static OTNotifyUPP g_connect_notifier;

static void send_hello(void);
/* The delta plane's memory of what this guest last handed a consumer.
   A baseline is a claim about ONE consumer's state, so a new connection
   has none - see serve_scene. */
static void scene_baseline_forget(void);
static void xfer_cleanup(void);
static void offer_cleanup(void);

/* Is the shared lane in use? One transfer at a time is the rule, and
   every path that starts one has to ask the same question — four
   hand-written copies of this list had already drifted apart. */
static Boolean wire_busy(void);

/* A file send outlives the transfer that carries it — it ends on the
   host's receipt — so the transfer machine has to be able to end one
   that dies on the wire. */
static void send_cleanup(void);
static void note_file(const char *line);
static Boolean send_offer(Boolean overwrite);
static Boolean send_owns_transfer(long id);
static void take_bulk_in(const unsigned char *bytes, long len);
static void put_drop(void);
static void stream_drop(void);
static void shot_drop(void);
static void note_shot(const char *line);
static void get_cleanup(Boolean keep_file);
static void chat_drop(void);
static void host_show_drop(void);
static void preview_fail(const char *reason);

/* --- the wake plane ------------------------------------------------------

   WHAT THIS EXISTS TO SETTLE. A round trip against this guest had a
   115 ms median on 2026-08-06 even when the answer was a zero-byte
   "nothing changed" - so the cost was neither the work nor the bytes,
   and the remaining candidate was the delay before the guest LOOKED at
   its socket. main.c sleeps six ticks (~100 ms) in WaitNextEvent unless
   a transfer is already in flight, which fits the number well enough to
   be believed and is exactly the kind of fit that has been wrong twice
   in one day here. So it is measured rather than assumed, at the two
   places the delay can hide:

     - g_pass_stat: how far apart consecutive conn_service passes are.
     - g_wake_stat: how long between Open Transport SAYING data is here
       and this loop reading it. That needs a timestamp taken at the
       moment of arrival, which only a notifier can take.

   NOTIFIER DISCIPLINE. An OT notifier is interrupt-time code: no
   allocation, no blocking, nothing that can move memory. Everything
   below it does is write two globals and read the microsecond clock,
   which is documented interrupt-safe. It deliberately does NOT consume
   T_DISCONNECT or T_ORDREL in the data era - those stay pending for the
   main loop's OTLook path, which is where every disconnect in this file
   is already handled, and a notifier that quietly acknowledged one would
   make the link's death invisible to the code that reports it. */
static LoopStat g_pass_stat;         /* interval between service passes */
static LoopStat g_wake_stat;         /* T_DATA -> the read that took it */
static volatile UnsignedWide g_data_stamp;
static volatile Boolean g_data_pending;
static volatile long g_data_events;  /* T_DATA notifications seen */
static long g_wake_calls;            /* WakeUpProcess calls made */
static unsigned long g_last_pass_us_hi, g_last_pass_us_lo;
static Boolean g_pass_seen;
/* Captured once, on the main thread, because GetCurrentProcess is not
   something to be calling from interrupt time. */
static ProcessSerialNumber g_self_psn;
static Boolean g_self_psn_known;
/* ON, and this is the one line in this file that wants a metal pass.

   MEASURED on an emulated G4, 2026-08-06: with it off a scene round trip
   into a quiet connection cost an 86 ms median whose walk was 0 ms and
   whose answer was zero bytes; with it on, 10 ms. The gap between Open
   Transport announcing data and this loop reading it went from a 48.5 ms
   mean to 7.5 ms. It buys that WITHOUT shortening the idle sleep, which
   is the whole reason to prefer it to the obvious alternative: the loop
   still sleeps ~110 ms when nothing is happening, so the rest of the
   Macintosh keeps the time the anchor plane needs.

   WHAT IS NOT PROVEN. Every number above is from an emulator. The
   notifier fires and WakeUpProcess is documented from CarbonLib 1.0, but
   nobody has watched this on a PowerBook 1400c, and an OT notifier is
   interrupt-time discipline where a mistake is a crash rather than a
   slow answer. The failure modes are graceful by construction - a
   notifier that never fires, or a WakeUpProcess that does nothing,
   leaves exactly the behaviour that shipped before this - and
   `wirestat wake off` restores it from either face without a rebuild. */
static Boolean g_wake_enabled = true;
/* The idle sleep main.c asks WaitNextEvent for, in ticks, stated HERE
   because the wire is what it costs and the wire is what has to defend
   it. Six ticks is ~100 ms and is where it has always been; one tick
   still yields to other applications (main.c's comment records why that
   matters - a starved Macintosh starves the anchor plane) but pays 60
   passes a second for a machine that is usually idle. Settable so both
   can be measured on one boot rather than one per rebuild. */
static long g_idle_sleep_ticks = 6;

static struct {
    Boolean pending;
    /* The replacement is canonical on disk, but this process is still the
       old file executing from the Trash. Keep the link alive so both Macs
       can say what remains: quit this instance, then launch NOW again. */
    Boolean relaunch_required;
    /* The new INIT is on disk, while the old table necessarily remains
       active until a cold boot. Keep this distinct from `pending`: the
       transfer is over, and offering the button again would install the
       same bytes twice while telling the person nothing about the one
       remaining action. Reset only by conn_init, which runs after restart. */
    Boolean restart_required;
    long id;
    NowUpdateComponent component;
    char build[65];
} g_update;

static unsigned long wide_delta_us(const UnsignedWide *then,
                                   const UnsignedWide *now)
{
    /* Microseconds() is 64-bit and this only ever spans a fraction of a
       second, so the low word alone is right except across its wrap -
       and the high word is what tells us a wrap happened. Anything
       longer than an hour is reported as an hour: a bad reading must be
       obviously bad rather than plausibly small. */
    if (now->hi != then->hi) {
        if (now->hi - then->hi > 1) {
            return 3600000000UL;
        }
        return (0xFFFFFFFFUL - then->lo) + now->lo + 1UL;
    }
    if (now->lo < then->lo) {
        return 0;
    }
    return now->lo - then->lo;
}

/* Only the connect operation runs asynchronously: on the physical
   PowerBook a synchronous OTConnect to an unreachable address blocks
   inside the call forever (the emulator forgives it - the launch
   freeze this exists to prevent lived only on metal). The notifier
   runs at deferred-task time, acknowledges the event, and publishes
   one small result; all protocol, logging and UI work stays in
   conn_service on the main loop. OT notifiers are C-convention - the
   UPP macro is the documented exception to routine descriptors. */
static pascal void connect_notifier(void *context, OTEventCode code,
                                    OTResult result, void *cookie)
{
    ConnState *state = (ConnState *)context;

    (void)cookie;
    if (state == NULL || state->ep == kOTInvalidEndpointRef) {
        return;
    }
    if (state->notify_data_era) {
        /* The link is up. Notice arrivals; acknowledge nothing. */
        if (code == T_DATA || code == T_EXDATA) {
            ++g_data_events;
            if (!g_data_pending) {
                UnsignedWide now;

                Microseconds(&now);
                g_data_stamp = now;
                g_data_pending = true;
            }
            if (g_wake_enabled && g_self_psn_known) {
                ++g_wake_calls;
                WakeUpProcess(&g_self_psn);
            }
        }
        return;
    }
    if (state->connect_done) {
        return;
    }
    if (code == T_CONNECT) {
        state->connect_result = gNowOT.rcvConnect(state->ep, NULL);
        state->connect_done = true;
    } else if (code == T_DISCONNECT) {
        gNowOT.rcvDisconnect(state->ep, NULL);
        state->connect_result = result != noErr ? result : kOTLookErr;
        state->connect_done = true;
    } else if (code == T_ORDREL) {
        gNowOT.rcvOrderlyDisconnect(state->ep);
        state->connect_result = result != noErr ? result : kOTLookErr;
        state->connect_done = true;
    }
}

/* --- helpers ------------------------------------------------------------ */

static int parse_ipv4(const char *text, UInt32 *out)
{
    unsigned long parts[4];
    int i;
    const char *p = text;
    char *end;

    for (i = 0; i < 4; ++i) {
        parts[i] = strtoul(p, &end, 10);
        if (end == p || parts[i] > 255) {
            return 0;
        }
        p = end;
        if (i < 3) {
            if (*p != '.') {
                return 0;
            }
            ++p;
        }
    }
    if (*p != '\0') {
        return 0;
    }
    *out = (UInt32)((parts[0] << 24) | (parts[1] << 16)
                    | (parts[2] << 8) | parts[3]);
    return 1;
}

/* --- control TX queue ---------------------------------------------------
   Control messages must be reliable even when the pipe is stuffed with
   bulk pixels. A streaming guest runs the send buffer at the brim, and a
   single unretried OTSnd of capture.end / stream.stopped / a heartbeat
   ping dies there of kOTFlowErr — which is exactly how the first live
   stream wedged: the guest gave up, told no one (the telling failed too),
   and the host waited forever. So control frames queue here and drain
   from the event loop, never interleaving into a partially-sent bulk
   frame. Bulk stays best-effort and unqueued; pixels are re-capturable,
   protocol words are not. */

enum { kCtlQueueSlots = 8 };

static struct {
    Ptr frames[kCtlQueueSlots];       /* whole wire frames: header+payload */
    long lens[kCtlQueueSlots];
    long sent;                        /* bytes of frames[head] on the wire */
    int head, count;
} g_ctlq;

static int service_ctl_tx(void);
static int bulk_frame_partially_sent(void);

static void ctlq_clear(void)
{
    while (g_ctlq.count > 0) {
        DisposePtr(g_ctlq.frames[g_ctlq.head]);
        g_ctlq.head = (g_ctlq.head + 1) % kCtlQueueSlots;
        --g_ctlq.count;
    }
    g_ctlq.sent = 0;
    g_ctlq.head = 0;
}

/* One contiguous send per frame: back-to-back small writes are dropped by
   real classic NICs (PB1400c Farallon TX burst drop). Returns 1 once the
   frame is QUEUED - transmission happens from service_ctl_tx. 0 means the
   message cannot be delivered on this connection (no endpoint, oversize,
   or a backlog so deep the pipe is effectively dead). */
static int send_control(const char *json)
{
    unsigned long length = (unsigned long)strlen(json);
    Ptr frame;
    int slot;

    if (g.ep == kOTInvalidEndpointRef || length > (unsigned long)kNowMaxControl) {
        return 0;
    }
    if (g_ctlq.count >= kCtlQueueSlots) {
        return 0;
    }
    frame = NewPtr((long)(kNowFrameHeaderBytes + length));
    if (frame == NULL) {
        return 0;
    }
    frame[0] = (char)kNowChannelControl;
    frame[1] = 0;
    frame[2] = 0;
    frame[3] = 0;
    frame[4] = (char)((length >> 24) & 0xFF);
    frame[5] = (char)((length >> 16) & 0xFF);
    frame[6] = (char)((length >> 8) & 0xFF);
    frame[7] = (char)(length & 0xFF);
    memcpy(frame + kNowFrameHeaderBytes, json, length);
    slot = (g_ctlq.head + g_ctlq.count) % kCtlQueueSlots;
    g_ctlq.frames[slot] = frame;
    g_ctlq.lens[slot] = (long)(kNowFrameHeaderBytes + length);
    ++g_ctlq.count;
    service_ctl_tx();                 /* opportunistic immediate drain */
    return 1;
}

static void close_endpoint(void)
{
    /* Before the notifier goes: after this the endpoint is invalid, and
       a notification arriving mid-teardown must find the era already
       shut rather than a half-closed provider. */
    g.notify_data_era = false;
    g_data_pending = false;
    if (g.ep != kOTInvalidEndpointRef) {
        if (g.connect_notifier_installed) {
            gNowOT.removeNotifier(g.ep);
            g.connect_notifier_installed = false;
        }
        gNowOT.unbind(g.ep);
        gNowOT.closeProvider(g.ep);
        g.ep = kOTInvalidEndpointRef;
    }
    g.rx_len = 0;
    g.bulk_remaining = 0;
}

/* THE PLANES THIS HOST HAS ASKED TO HAVE ARMED, remembered across
   requests.
   --------------------------------------------------------------------
   The owner lease is ten seconds and, until this existed, ONLY a
   `scene.request` renewed it - so the lease measured scene-poll cadence
   rather than whether anybody wanted the planes. A host that spent forty
   seconds clicking things and never asked for a scene between them let
   four leases expire, and then every act it sent refused with "the
   anchor plane is absent or not armed" while its Mirror kept drawing the
   windows it could no longer see (open-issues.md, 2026-08-06).

   This is now_peek_idle's mistake one layer up, and it takes the same
   shape of fix: renew from something that MEANS a consumer is there.
   That is not the event loop here - the event loop runs whether or not
   anyone is watching, and a plane armed on an unwatched machine is work
   charged to every process on it for nobody. It is host traffic: a host
   that is sending this guest requests is a host that is using it.

   Two gates keep it honest. It renews only once a scene has actually
   been asked for on THIS link, so a host that never mirrors never arms
   anything; and it does not renew on `pong`, which is the reply to our
   own heartbeat and would make "connected" mean "armed forever". Zeroed
   when the link drops, where the claim is released anyway. */
static unsigned long g_scene_plane_caps;

static void renew_scene_planes(void)
{
    if (!now_mirror_policy_enabled(kMirrorPolicyStructure)) {
        now_peek_release(kNowPeekOwnerScene,
                         (unsigned long)(kNowPeekCapAnchors
                                         | kNowPeekCapTree
                                         | kNowPeekTableCapAct));
        g_scene_plane_caps = 0;
        return;
    }
    if (g_scene_plane_caps == 0) {
        return;
    }
    now_peek_claim(kNowPeekOwnerScene, g_scene_plane_caps);
}

/* Everything in flight, dropped. ONE list, because there were two and
   they had already drifted: enter_backoff() dropped five things and
   conn_disconnect() dropped none, so disconnecting mid-pull left
   g_get.receiving true over an open temp fork. A leaving link ends every
   transfer for the same reason whichever way it leaves, so the reason is
   written once. Every call here is idle-safe and touches no wire — none
   of them can be told to a machine that is going away. */
static void link_drop_transfers(void)
{
    xfer_cleanup();                   /* a dropped link cancels any transfer */
    offer_cleanup();
    stream_drop();                    /* no stopped message on a dead wire */
    shot_drop();                      /* no deferred capture across a drop */
    put_drop();                       /* no half-written file left behind */
    get_cleanup(false);               /* nor half a file coming the other way */
    chat_drop();                      /* a streaming turn dies with the link */
    host_show_drop();                 /* nobody is going to answer now */
    preview_fail("Connection lost");  /* local hook only; no wire touched */
    ctlq_clear();
    g_scene_plane_caps = 0;            /* no consumer, nothing to renew */
    now_peek_disconnect();             /* release every wire-owned plane */
    /* And tell the resident to stay off the wire. It holds its OWN
       connection to the same host, so a link this application has given
       up on is one nothing here can still vouch for; the endpoint is
       withdrawn on every path out for the same reason every transfer is
       ended here rather than at each call site. */
    now_peek_withdraw_endpoint();
    g_update.pending = false;
    now_update_model_reset();
    now_continuity_disconnect();
}

/* Move to backoff after a failure; status keeps the reason already set. */
static void enter_backoff(void)
{
    now_log(kLogWarn, "wire", "disconnected from %s:%u: %.60s",
            g.host, g.port, g.last_fail);
    link_drop_transfers();
    close_endpoint();
    if (!g.want_connection) {
        g.phase = kConnIdle;
        return;
    }
    {
        NowPrefs prefs;

        now_prefs_load(&prefs);
        if (prefs.retry_secs > 0) {
            /* Fixed cadence from the Connection dialog: predictable
               reconnects beat adaptive politeness on a private LAN. */
            g.backoff_ticks = (unsigned long)prefs.retry_secs * 60;
        } else if (g.backoff_ticks == 0) {
            g.backoff_ticks = kBackoffMinTicks;
        } else {
            g.backoff_ticks *= 2;
            if (g.backoff_ticks > kBackoffMaxTicks) {
                g.backoff_ticks = kBackoffMaxTicks;
            }
        }
        /* The contract's one cadence obligation: >= 1s between dials, so a
           bad prefs record cannot make this a connect flood. Enforced here
           rather than trusted from the loader, because the loader's range
           check is about a plausible record and this is about the wire. */
        if (g.backoff_ticks < kRetryFloorTicks) {
            g.backoff_ticks = kRetryFloorTicks;
        }
    }
    g.backoff_until = TickCount() + g.backoff_ticks;
    g.phase = kConnBackoff;
}

static void fail(const char *reason)
{
    if (reason != NULL) {
        snprintf(g.status, sizeof g.status, "%s", reason);
        snprintf(g.last_fail, sizeof g.last_fail, "%.95s", reason);
    }
    enter_backoff();
}

static void fail_ot(const char *operation, OSStatus err)
{
    char reason[96];

    snprintf(reason, sizeof reason, "%s (OT %ld)", operation, (long)err);
    fail(reason);
}

/* --- connect ------------------------------------------------------------ */

/* Open Transport's default receive window is small enough that a sender
   can only keep about one segment in flight: measured on the PB1400c,
   inbound files arrived at ~1.4 KB every ~350 ms — one segment per
   delayed ACK — for a flat 4 KB/s no matter the file size, while the
   same wire carried 227 KB/s outbound. Asking for a window several
   segments wide is what lets the sender fill the pipe.

   Best-effort by design: an older stack that refuses the option still
   works, just slowly, and that is better than refusing to connect. */
/* Left at the stack's default. Negotiating it with OTOptionManagement
   wedged the guest: synchronous, the call waits for a completion that
   needs a notifier this app does not install, and the connect never
   returns; non-blocking, it returns without taking effect. Raising the
   window needs a notifier — or the option set in the endpoint's
   configuration at open time — and neither belongs in a fix made at
   speed. The rate stays slow and honest until then. */
/* Bytes readable at the last pass, and the high-water mark since the
   connection came up. -3 means never sampled (no OTCountDataBytes). */
static long g_rcv_window = -3;
static long g_rcv_peak = -3;
/* Passes of the event loop that reached conn_service since the last
   file receive began. A collapsed transfer with this climbing normally
   means the loop is healthy and the bytes are simply not arriving. */
static long g_service_passes = 0;

/* What this connection has actually TOLD the host about agent access, as
   opposed to what the tier currently is. They differ exactly when a send
   did not happen — no link, or a full control queue — and the page's job
   is to show that difference rather than assume it away.

   It lives here because this is the only code that knows: the page used to
   infer "hello went out carrying whatever the tier is now" from seeing the
   link come up, which was right in every case anyone tried and still an
   inference about another file's behaviour. Cleared when a connection
   starts, because it is a fact about one link. */
static Boolean g_told_known;
static AgentAccessTier g_told;

/* The connect completed (either path); the rest of the protocol is
   written synchronously, so the endpoint goes back to that mode.

   THE NOTIFIER STAYS. It used to be removed here, which left the guest
   with no way to learn that data had arrived except by asking - and
   asking is what costs the ~100 ms this arc is about. A synchronous
   provider still delivers ASYNCHRONOUS events (T_DATA, T_DISCONNECT) to
   an installed notifier; what it stops delivering is completion events,
   which the protocol below does not use. So the era flips and the
   endpoint keeps its ear. */
static void finish_connect(void)
{
    g_data_pending = false;
    g_data_events = 0;
    g_wake_calls = 0;
    loopstat_reset(&g_pass_stat);
    loopstat_reset(&g_wake_stat);
    g_pass_seen = false;
    g.notify_data_era = true;
    if (gNowOT.setSynchronous(g.ep) != noErr) {
        fail("Could not finish connection");
        return;
    }
    g.phase = kConnHandshaking;
    g.phase_deadline = TickCount() + kHelloTimeoutTicks;
    scene_baseline_forget();
    send_hello();
}

static void start_connect(void)
{
    OSStatus err, open_err = -1;

    close_endpoint();
    g.rx_len = 0;
    g.bulk_remaining = 0;
    g.pings_sent = 0;
    /* A fact about one link, and this is a different one. */
    g_told_known = false;

    if (!parse_ipv4(g.host, &g.address)) {
        fail("Enter a numeric address like 10.0.2.2");
        return;
    }
    err = now_ot_resolve();
    if (err != noErr) {
        snprintf(g.status, sizeof g.status,
                 "Networking needs CarbonLib 1.6");
        g.phase = kConnNeedsCarbonLib;
        return;
    }
    if (now_ot_ensure_inited() != noErr) {
        fail("Open Transport could not start");
        return;
    }
    if (g_connect_notifier == NULL) {
        g_connect_notifier = NewOTNotifyUPP(connect_notifier);
        if (g_connect_notifier == NULL) {
            fail("Not enough memory for networking");
            return;
        }
    }
    g.ep = gNowOT.openEndpoint(OTCreateConfiguration(kTCPName), 0, NULL,
                               &open_err, gNowOTContext);
    if (open_err != noErr || g.ep == kOTInvalidEndpointRef) {
        fail("Could not open a TCP endpoint");
        return;
    }
    g.notify_data_era = false;        /* the dial's era, until it lands */
    err = gNowOT.installNotifier(g.ep, g_connect_notifier, &g);
    if (err != noErr) {
        fail("Could not install networking callback");
        return;
    }
    g.connect_notifier_installed = true;
    err = gNowOT.bind(g.ep, NULL, NULL);      /* local operation, still sync */
    if (err != noErr) {
        fail("Bind failed");
        return;
    }
    /* Asynchronous for the dial itself: on metal a synchronous OTConnect
       to an address that never answers blocks INSIDE the call, and the
       whole application wedges before its first update event. The
       emulator forgives the synchronous form, which is how it shipped
       that way once already. */
    err = gNowOT.setAsynchronous(g.ep);
    if (err != noErr) {
        fail("Could not make connection asynchronous");
        return;
    }
    err = gNowOT.setNonBlocking(g.ep);
    if (err != noErr) {
        fail("Could not make connection nonblocking");
        return;
    }

    memset(&g.connect_address, 0, sizeof g.connect_address);
    g.connect_address.fAddressType = AF_INET;
    g.connect_address.fPort = g.port;
    g.connect_address.fHost = g.address;
    memset(&g.connect_call, 0, sizeof g.connect_call);
    g.connect_call.addr.buf = (UInt8 *)&g.connect_address;
    g.connect_call.addr.len = sizeof g.connect_address;
    g.connect_result = kOTNoDataErr;
    g.connect_done = false;
    g.phase_deadline = TickCount() + kConnectTimeoutTicks;
    snprintf(g.status, sizeof g.status, "Connecting to %s:%u...",
             g.host, g.port);
    now_log(kLogInfo, "wire", "connecting to %s:%u", g.host, g.port);
    err = gNowOT.connect(g.ep, &g.connect_call, NULL);
    if (err == noErr) {
        /* An asynchronous endpoint normally returns kOTNoDataErr and
           later delivers T_CONNECT. A local provider may still finish
           immediately; no completion event is owed in that case. */
        finish_connect();
    } else if (err == kOTNoDataErr) {
        g.phase = kConnConnecting;
    } else {
        fail_ot("Connect failed", err);
    }
}

static void service_connecting(void)
{
    if (g.connect_done) {
        OSStatus result = g.connect_result;

        g.connect_done = false;
        if (result != noErr) {
            fail_ot("Connection refused", result);
            return;
        }
        finish_connect();
        return;
    }
    if (TickCount() > g.phase_deadline) {
        fail("No answer (10s)");
    }
}

static void hello_extension_fields(char *out, long cap)
{
    char version[24];
    char build[65];

    now_update_current_identity(kNowUpdateExtension,
                                version, sizeof version,
                                build, sizeof build);
    if (version[0] != '\0' && strlen(build) == 40) {
        snprintf(out, (size_t)cap,
                 ",\"extensionVersion\":\"%s\","
                 "\"extensionBuild\":\"%s\"",
                 version, build);
    } else if (cap > 0) {
        out[0] = '\0';
    }
}

static void send_hello(void)
{
    char json[896];
    char name[64];
    char esc[256];
    char model[64];
    char model_esc[160];
    char sysver[kNowIdentityVersionCap];
    char extension_fields[160];

    /* This machine's name, not the product's: the other side puts it on
       screen ("Connected: Quadra 950"), and the product name is the one
       answer every machine running NOW would give. */
    now_machine_name(name, sizeof name);
    now_json_escape(name, esc, sizeof esc);

    /* WHICH KIND of Macintosh, as opposed to what it calls itself. `name`
       above is the Sharing name — a person edits it in a control panel,
       and on this project a deployed guest wears its MacBinary name — so
       it can never key anything. These two can, and they are what the
       asset-pack store compares (plan 021).
       Escaped, unlike `os`: a model comes from Gestalt 'mnam' or a 'STR '
       resource, so it is whatever somebody's System says it is. `sysver`
       is digits and dots or the literal `unknown`, from the shared decode
       in contract/guest_identity.h — nothing there needs escaping, and
       both guests produce it identically by construction rather than by
       two implementations agreeing. */
    now_machine_model(model, sizeof model);
    now_json_escape(model, model_esc, sizeof model_esc);
    now_system_version(sysver, sizeof sysver);
    hello_extension_fields(extension_fields, sizeof extension_fields);
    /* build carries what version cannot: two builds of one release version
       deliberately share a string, so a stale build on a machine otherwise
       looks current and a host has no way to tell them apart. It cost a misdiagnosis on
       2026-07-30. now_build_stamp() is the deterministic SHA-256 CMake
       regenerates from the complete declared build surface and toolchain.
       It deliberately carries no wall clock. Not escaped: it is generated
       lowercase hex and contains neither a quote nor a backslash. */
    /* agent is this MACHINE'S answer to whether a companion may drive it,
       stated rather than left to silence: the contract reads an absent
       field as "predates the feature", never as consent, so a machine that
       consents has to say so as plainly as one that refuses. Not escaped
       either — now_agent_access() returns one of three contract tokens. */
    snprintf(json, sizeof json,
             "{\"type\":\"hello\",\"contract\":%d,\"side\":\"guest\","
             "\"version\":\"%s\",\"build\":\"%s\","
             "\"mirrorTransfer\":true,\"agent\":\"%s\","
             "\"name\":\"%s\",\"os\":\"%s\"%s,"
             "\"machine\":{\"id\":%ld,\"model\":\"%s\"},\"chunk\":%d}",
             kNowContractRevision, PRODUCT_VERSION, now_build_stamp(),
             now_agent_access(), esc, sysver, extension_fields,
             now_machine_type(), model_esc, kNowDefaultChunk);
    if (!send_control(json)) {
        fail("Sending hello failed");
        return;
    }
    /* hello carried the tier, so this link has now been told it. Recorded
       after the send rather than before: the page's whole value is
       distinguishing what was said from what is merely true here. */
    g_told_known = true;
    g_told = now_agent_access_tier();
}

/* The same answer as hello's `agent`, said again because it changed.

   hello states this once per connection, so before this existed a tier
   changed mid-session did not reach the host until the link was rebuilt -
   and the host went on permitting what the person had just withdrawn.
   That is the one place in this product where being out of date has a
   safety edge, which is why this is a message and not a note on the page.

   Silent when nothing is connected, and that is the whole error handling:
   there is no host to tell, the tier is already in prefs, and the next
   hello carries it. Same for a send that does not fit the queue - the
   caller is a person clicking a radio button, and a modal complaint about
   a control frame would be noise about something the next connection
   fixes. It returns nothing for that reason.

   Not escaped: mcp_tier_token returns one of three contract tokens. */
void now_wire_announce_agent_access(void)
{
    char json[64];

    if (g.phase != kConnConnected) {
        return;
    }
    snprintf(json, sizeof json,
             "{\"type\":\"agent.access\",\"agent\":\"%s\"}",
             now_agent_access());
    if (send_control(json)) {
        g_told_known = true;
        g_told = now_agent_access_tier();
    }
}

Boolean now_wire_agent_access_told(AgentAccessTier *out)
{
    if (g_told_known && out != NULL) {
        *out = g_told;
    }
    return g_told_known;
}

/* --- receive ------------------------------------------------------------ */

/* Pulls available bytes into the rx buffer. Returns 0 on a fatal transport
   condition (disconnect), 1 otherwise. */
static int pump_rx(void)
{
    OTFlags flags = 0;
    OTResult got;

    /* Sampled BEFORE draining, so it is the backlog the guest was left
       holding since the previous pass — the number that separates "this
       machine cannot keep up" from "nothing is arriving". Both look the
       same from the far end of the wire, which is how three throughput
       theories died here. */
    if (gNowOT.countDataBytes != NULL && g.ep != kOTInvalidEndpointRef) {
        OTByteCount waiting = 0;

        if (gNowOT.countDataBytes(g.ep, &waiting) == noErr) {
            g_rcv_window = (long)waiting;
            if ((long)waiting > g_rcv_peak) {
                g_rcv_peak = (long)waiting;
            }
        }
    }
    for (;;) {
        if (g.rx_len >= kRxBufferSize) {
            /* Full is not broken. A bulk stream fills this buffer every
               pass by design; the caller drains it and reads again.
               Returning failure here tore the connection down the moment
               a file started arriving. */
            return 1;
        }
        got = gNowOT.rcv(g.ep, g.rx + g.rx_len,
                         (OTByteCount)(kRxBufferSize - g.rx_len), &flags);
        if (got > 0) {
            /* The measurement this arc turns on: how long the bytes sat
               readable before this loop came round to them. Taken on the
               FIRST read that follows a notification and not on every
               read, because a bulk stream reads many times per pass and
               only the first of them answers the question. */
            if (g_data_pending) {
                UnsignedWide now;
                UnsignedWide then = g_data_stamp;

                g_data_pending = false;
                Microseconds(&now);
                loopstat_add(&g_wake_stat, wide_delta_us(&then, &now));
            }
            g.rx_len += got;
            g.last_rx_tick = TickCount();
        } else if (got == kOTNoDataErr) {
            return 1;
        } else if (got == kOTLookErr) {
            OTResult look = gNowOT.look(g.ep);
            if (look == T_DISCONNECT) {
                gNowOT.rcvDisconnect(g.ep, NULL);
                return 0;
            }
            if (look == T_ORDREL) {
                gNowOT.rcvOrderlyDisconnect(g.ep);
                return 0;
            }
            return 1;
        } else {
            return 0;
        }
    }
}

/* Extracts one complete control frame into payload_out; returns 1 if one was
   dequeued, 0 if the buffer holds no full frame yet, -1 on a malformed
   frame (fatal). */
static int next_frame(char *payload_out, long cap)
{
    unsigned long length;
    long total;
    unsigned char channel;

    /* A bulk frame already under way: hand over whatever has arrived and
       wait for the rest. Bulk is NEVER buffered whole. One frame is
       larger than this buffer, and demanding the whole thing deadlocks:
       the buffer fills, the guest stops reading, TCP closes the window,
       and the sender waits forever on a transfer that has no way to
       finish. */
    if (g.discard_remaining > 0) {
        long take = g.rx_len;

        if (take <= 0) {
            return 0;
        }
        if (take > g.discard_remaining) {
            take = g.discard_remaining;
        }
        memmove(g.rx, g.rx + take, g.rx_len - take);
        g.rx_len -= take;
        g.discard_remaining -= take;
        payload_out[0] = '\0';
        return 0;
    }

    if (g.bulk_remaining > 0) {
        long take = g.rx_len;

        if (take <= 0) {
            return 0;
        }
        if (take > g.bulk_remaining) {
            take = g.bulk_remaining;
        }
        take_bulk_in(g.rx, take);
        memmove(g.rx, g.rx + take, g.rx_len - take);
        g.rx_len -= take;
        g.bulk_remaining -= take;
        payload_out[0] = '\0';
        return 1;
    }

    if (g.rx_len < kNowFrameHeaderBytes) {
        return 0;
    }
    channel = g.rx[0];
    length = ((unsigned long)g.rx[4] << 24) | ((unsigned long)g.rx[5] << 16)
        | ((unsigned long)g.rx[6] << 8) | (unsigned long)g.rx[7];
    if (length > kNowMaxPayload) {
        return -1;
    }
    if (channel != kNowChannelControl) {
        /* Take the header now; the payload streams in above. */
        memmove(g.rx, g.rx + kNowFrameHeaderBytes,
                g.rx_len - kNowFrameHeaderBytes);
        g.rx_len -= kNowFrameHeaderBytes;
        g.bulk_remaining = (long)length;
        payload_out[0] = '\0';
        return 1;
    }
    if (length + 1 > (unsigned long)cap) {
        /* Bigger than we can hold. Skipping it costs one message;
           dropping the connection costs everything in flight and looks
           like a network fault instead of a message we could not read.
           The peer is told nothing: it asked something reasonable and
           our buffer is our problem. */
        memmove(g.rx, g.rx + kNowFrameHeaderBytes,
                g.rx_len - kNowFrameHeaderBytes);
        g.rx_len -= kNowFrameHeaderBytes;
        g.discard_remaining = (long)length;
        snprintf(g.status, sizeof g.status,
                 "Ignored a %lu-byte message (too big to read)", length);
        now_log(kLogWarn, "wire", "skipped a %lu-byte control frame: bigger "
                "than this buffer holds", length);
        payload_out[0] = '\0';
        return 0;
    }
    total = kNowFrameHeaderBytes + (long)length;
    if (g.rx_len < total) {
        return 0;
    }
    memcpy(payload_out, g.rx + kNowFrameHeaderBytes, length);
    payload_out[length] = '\0';
    memmove(g.rx, g.rx + total, g.rx_len - total);
    g.rx_len -= total;
    return 1;
}

/* Returns 0 when the host's hello is refused and the caller must tear the
   connection down.

   THE REVISION GATE, on the receiving side. The contract's connection
   rules bind whoever receives a hello, and this half used to read `name`
   and `version` and nothing else — so this guest would serve a full
   session to any peer at all, and find out about the skew later, in the
   middle of a message it could not decode. It cost more than a session:
   harnesses stuck on revision 1 could never hold a link to NOW-68K, which
   gates, and held one here for a whole revision, so the missing check is
   what made a year-stale harness look healthy.

   Shaped after NOW-68K's handle_host_hello so the two guests answer the
   same way for the same reason, with two additions the contract now
   states: the reason names both numbers (a peer that is merely stale
   learns which one to be), and it goes out as a `refuse` rather than a
   silent hang-up, which from the far end is indistinguishable from a
   dropped network. An ABSENT `contract` lands here too — the field is
   required, and there is no revision to compare — but says so rather
   than reporting a number nobody sent. */
static int on_hello(const char *reply)
{
    long revision = 0;
    int read = now_json_read_int(reply, "contract", &revision);

    if (read != kNowJsonIntOk || revision != (long)kNowContractRevision) {
        char reason[96];
        char json[192];

        if (read == kNowJsonIntAbsent) {
            snprintf(reason, sizeof reason,
                     "host hello states no contract revision; this guest "
                     "speaks %d", (int)kNowContractRevision);
        } else if (read != kNowJsonIntOk) {
            snprintf(reason, sizeof reason,
                     "host hello's contract revision is not a number; this "
                     "guest speaks %d", (int)kNowContractRevision);
        } else {
            snprintf(reason, sizeof reason,
                     "contract revision %ld != %d",
                     revision, (int)kNowContractRevision);
        }
        snprintf(g.status, sizeof g.status, "Protocol error: %s", reason);
        now_log(kLogWarn, "wire", "refused the host's hello: %s", reason);
        /* Best effort, like every other frame this guest sends: the
           reason is already on this machine's own status line, and a
           refusal that could not be queued must not turn into a session
           that gets served anyway. `contract` is OURS — that is what the
           other side needs from this message. Nothing here is
           peer-controlled text, so no escaping is involved. */
        snprintf(json, sizeof json,
                 "{\"type\":\"refuse\",\"contract\":%d,\"reason\":\"%s\"}",
                 (int)kNowContractRevision, reason);
        (void)send_control(json);
        return 0;
    }

    if (!now_json_find_string(reply, "name", g.peer_name, sizeof g.peer_name)) {
        g.peer_name[0] = '\0';
    }
    if (!now_json_find_string(reply, "version", g.peer_version,
                          sizeof g.peer_version)) {
        strcpy(g.peer_version, "?");
    }
    g.phase = kConnConnected;
    now_update_model_reset();
    memset(&g_update, 0, sizeof g_update);
    g.connected_tick = TickCount();
    /* **Published here and not one step earlier.** The resident cannot
       report a failed dial to anybody - it has no UI, no log and no
       application to tell - so it is handed an address only once THIS
       side has watched the host answer. An address that has not answered
       is not one to give something that cannot complain about it. */
    now_peek_publish_endpoint((unsigned long)g.address, g.port);
    g.backoff_ticks = 0;              /* success resets backoff */
    g.last_fail[0] = '\0';
    g.pings_sent = 0;
    g.next_ping_tick = TickCount() + kPingIntervalTicks;
    /* Per LINK, so a reconnection after a long backoff does not read as
       a starvation the moment the heartbeat first runs. */
    g.last_pass_tick = 0;
    if (g.last_rtt_ms >= 0) {
        snprintf(g.status, sizeof g.status, "Connected: %s (v%s) - %ld ms",
                 g.peer_name, g.peer_version, g.last_rtt_ms);
    } else {
        snprintf(g.status, sizeof g.status, "Connected: %s (v%s)",
                 g.peer_name, g.peer_version);
    }
    return 1;
}

/* --- bulk transfer -----------------------------------------------------
   Streaming is INCREMENTAL, pumped from the event loop rather than a
   blocking loop, for three reasons learned the hard way: a non-blocking
   OT endpoint refuses bytes once its send buffer fills (kOTFlowErr) and
   must be retried; the guest has to stay responsive while ~100 KB goes
   out; and a transfer you can observe is a transfer you can cancel. */

enum {
    kXferSliceTicks = 3,              /* ~50 ms of sending per service call */
    kXferDeadlineTicks = 60 * 120     /* give up after 2 min without progress */
};

typedef enum {
    kFrameStandalone = 0,             /* one-shot capture: no frame field */
    kFrameKey,
    kFrameDelta,
    kFrameEmpty
} FrameKind;

typedef struct {
    short width, height, depth, row_bytes;
    long capture_ms;
    FrameKind kind;
    PixelRect rects[kPixelMaxRects];  /* image/field coordinates */
    short n_rects;
    short row_scale, row_phase;       /* field -> canvas row mapping */
} ShotMeta;

/* Live-stream bracket (stream.start .. stream.stopped). service_stream
   turns the guest into a frame pump: finish a frame, capture fresh, send —
   never queue. One frame in flight bounds both latency and memory, and a
   stale screen self-corrects. Its own small state so the capture step can
   later become incremental (banded CopyBits) without touching the rest. */
static struct {
    Boolean active;
    long id;
    short depth;
    Boolean pack;
    long chunk;
    short pace_ms;
    long min_interval_ticks;
    unsigned long next_frame_tick;
    long frames;
    long empty_run;                   /* consecutive nothing-changed frames */
    /* The capture pipeline: frame N+1 is captured in event-loop-pumped
       bands while frame N is still going out (banding is metal-measured
       free: 139-143 ms total for 1..16 bands, ~17 ms per band at 8). The
       capture is scheduled to COMPLETE as the send completes - minimizing
       both frame age and the shear span - using the previous frame's
       measured send and capture+encode times. */
    BandedCapture cap;
    Boolean cap_active;
    PixelBlob ready_blob;             /* encoded, waiting for the lane */
    ShotMeta ready_meta;
    Boolean ready;
    Boolean stopping;                 /* stop acked once the drain ends */
    /* Delta base: the previous frame's raw rows plus its palette. A
       keyframe is forced at start, on host refresh, on palette change,
       and when a majority of rows are dirty anyway. */
    Ptr prev;
    long prev_bytes;
    short prev_row_bytes, prev_height;
    unsigned char prev_palette[768];
    long prev_palette_bytes;
    Boolean force_key;
    /* Optional capture policies (panel toggles, read at stream start).
       Predictive: read only rows likely to have changed - last frame's
       dirty rows plus margin, plus a rotating sweep slice so an unwatched
       change is caught within kSweepFrames frames. Interlace: capture and
       send alternate fields via CopyBits' 2:1 decimation, halving both
       the VRAM read and the wire per frame. */
    Boolean predictive;
    Boolean interlace;
    short phase;                      /* next field's parity */
    long sweep_pos;                   /* canvas row where the sweep is */
    CaptureSpan dirty_hist[kPixelMaxRects];  /* canvas rows, last frame */
    short n_dirty_hist;
    short cap_scale, cap_phase;       /* of the capture in progress */
    Boolean cap_full;                 /* captured everything (keyframes) */
    unsigned long cap_start_tick;
    long est_send_ticks;
    long est_cap_ticks;               /* capture + encode, measured */
} g_stream;

enum { kStreamReqTimeoutTicks = 60 * 10 };

static struct {
    Boolean pending;                  /* asked the host to open a bracket */
    unsigned long deadline;
} g_streamreq;

typedef enum {
    kXferCapture = 0,                 /* ends with capture.end */
    kXferFile,                        /* ends with file.end */
    kXferScene                        /* ends with scene.end */
} XferKind;

/* The terminal message's type for a transfer kind. A scene rides the
   SAME lane and the same incremental sender as a capture - it differs
   only in what the bytes mean and which end message closes them - so
   the kind is the one thing the transport needs to know about it. */
static const char *xfer_end_type(XferKind kind)
{
    switch (kind) {
    case kXferFile:
        return "file";
    case kXferScene:
        return "scene";
    default:
        return "capture";
    }
}

static struct {
    Boolean active;
    Boolean pushed;                   /* guest-initiated: report to panel */
    Boolean aborting;                 /* drain to the frame boundary, then
                                         end ok:false - never mid-frame */
    Boolean file_stream;              /* bytes come from File Manager */
    XferKind kind;
    Handle data;                      /* capture bytes; ownership below */
    PixelBlob blob;
    FileStage file;
    long total, offset;
    long chunk;
    unsigned short xfer;
    long id;
    Ptr frame;                        /* one framed chunk: header + payload */
    long frame_len, frame_sent;
    unsigned long next_tick;          /* pacing gate */
    unsigned long deadline;
    unsigned long started;
    short pace_ms;
} g_xfer;

/* "Screenshot App" (process.shot): bring a process forward, let it come
   front and redraw, then capture just its front window and deliver that
   over the capture transport - the wire-driven twin of the Processes
   page's Front & Capture, cropped to the window rather than the screen.
   Two-step, like that page: front now, capture from a later service pass,
   so nothing nests an event loop while the target repaints. */
static struct {
    Boolean active;
    ProcessSerialNumber target;
    ProcessSerialNumber self;         /* NOW, to restore once captured */
    long id;
    short depth;
    long chunk;
    short pace_ms;
    Boolean pack;
    unsigned long deadline;
} g_shot;

static int bulk_frame_partially_sent(void)
{
    return g_xfer.active && g_xfer.frame_sent > 0
        && g_xfer.frame_sent < g_xfer.frame_len;
}

/* Drains queued control frames. 1 = ok (possibly still pending on flow
   control), 0 = the endpoint is dead. */
static int service_ctl_tx(void)
{
    while (g_ctlq.count > 0) {
        Ptr frame = g_ctlq.frames[g_ctlq.head];
        long len = g_ctlq.lens[g_ctlq.head];
        OTResult sent;

        if (bulk_frame_partially_sent()) {
            return 1;                 /* finish that frame's bytes first */
        }
        sent = gNowOT.snd(g.ep, frame + g_ctlq.sent,
                          (OTByteCount)(len - g_ctlq.sent), 0);
        if (sent > 0) {
            g_ctlq.sent += sent;
            if (g_ctlq.sent >= len) {
                DisposePtr(frame);
                g_ctlq.head = (g_ctlq.head + 1) % kCtlQueueSlots;
                --g_ctlq.count;
                g_ctlq.sent = 0;
            }
        } else if (sent == kOTFlowErr || sent == kOTNoDataErr) {
            return 1;
        } else {
            return 0;
        }
    }
    return 1;
}

static void xfer_cleanup(void)
{
    if (g_xfer.frame != NULL) {
        DisposePtr(g_xfer.frame);
        g_xfer.frame = NULL;
    }
    if (g_xfer.data != NULL) {
        HUnlock(g_xfer.data);
    }
    if (g_xfer.file_stream) {
        now_files_stage_dispose(&g_xfer.file);
    } else if (g_xfer.blob.data != NULL) {
        now_pixels_dispose(&g_xfer.blob);
    } else if (g_xfer.data != NULL) {
        DisposeHandle(g_xfer.data);
    }
    g_xfer.data = NULL;
    g_xfer.active = false;
}

static void xfer_finish(Boolean ok)
{
    char json[256];

    if (ok && g_xfer.file_stream
        && !now_files_stage_unchanged(&g_xfer.file)) {
        ok = false;
    }
    if (ok && g_xfer.kind == kXferFile && g_xfer.file_stream) {
        snprintf(json, sizeof json,
                 "{\"type\":\"file.end\",\"id\":%ld,\"transfer\":%u,"
                 "\"ok\":true,\"sendMs\":%ld,\"crc32\":%lu}",
                 g_xfer.id, g_xfer.xfer,
                 (long)((TickCount() - g_xfer.started) * 1000 / 60),
                 g_xfer.file.crc & 0xFFFFFFFFUL);
    } else {
        snprintf(json, sizeof json,
                 "{\"type\":\"%s.end\",\"id\":%ld,\"transfer\":%u,"
                 "\"ok\":%s,\"sendMs\":%ld}",
                 xfer_end_type(g_xfer.kind),
                 g_xfer.id, g_xfer.xfer, ok ? "true" : "false",
                 (long)((TickCount() - g_xfer.started) * 1000 / 60));
    }
    send_control(json);
    if (ok && g_stream.active && g_xfer.id == g_stream.id) {
        g_stream.est_send_ticks = (long)(TickCount() - g_xfer.started);
    }
    if (g_xfer.pushed) {
        if (ok) {
            {
                char peer[40];

                conn_peer_label(peer, sizeof peer);
                snprintf(json, sizeof json, "Sent to %s (%ld ms)", peer,
                         (long)((TickCount() - g_xfer.started) * 1000 / 60));
            }
            note_shot(json);
        } else {
            {
                char peer[40];
                char failed[96];

                conn_peer_label(peer, sizeof peer);
                snprintf(failed, sizeof failed, "Could not send to %s", peer);
                note_shot(failed);
            }
        }
    }
    /* A send that dies on the wire never gets a receipt, so this is the
       only place that can end it. Success stays quiet: the host has not
       written the file yet, and saying "sent" before it lands is the
       lie this whole path exists to avoid. */
    if (!ok && g_xfer.kind == kXferFile && send_owns_transfer(g_xfer.id)) {
        char peer[40];
        char failed[96];

        send_cleanup();
        conn_peer_label(peer, sizeof peer);
        snprintf(failed, sizeof failed, "Could not finish sending to %s",
                 peer);
        note_file(failed);
    }
    xfer_cleanup();
}

static int xfer_build_frame(void)
{
    long n = g_xfer.total - g_xfer.offset;
    long got = 0;
    Boolean last;

    if (n > g_xfer.chunk) {
        n = g_xfer.chunk;
    }
    last = (g_xfer.offset + n >= g_xfer.total);
    g_xfer.frame[0] = (char)kNowChannelBulk;
    g_xfer.frame[1] = (char)(last ? kNowFlagEnd : 0);
    g_xfer.frame[2] = (char)((g_xfer.xfer >> 8) & 0xFF);
    g_xfer.frame[3] = (char)(g_xfer.xfer & 0xFF);
    g_xfer.frame[4] = (char)((n >> 24) & 0xFF);
    g_xfer.frame[5] = (char)((n >> 16) & 0xFF);
    g_xfer.frame[6] = (char)((n >> 8) & 0xFF);
    g_xfer.frame[7] = (char)(n & 0xFF);
    if (g_xfer.file_stream) {
        if (now_files_stage_read(
                &g_xfer.file, g_xfer.frame + kNowFrameHeaderBytes,
                n, &got) != kFilesOK || got != n) {
            return 0;
        }
    } else {
        memcpy(g_xfer.frame + kNowFrameHeaderBytes,
               *g_xfer.data + g_xfer.offset, (size_t)n);
    }
    g_xfer.frame_len = kNowFrameHeaderBytes + n;
    g_xfer.frame_sent = 0;
    return 1;
}

/* Pumps the active transfer for a short slice. Partial sends and flow
   control simply resume on the next call. */
static void service_transfer(void)
{
    unsigned long slice_end = TickCount() + kXferSliceTicks;

    if (!g_xfer.active) {
        return;
    }
    if (TickCount() > g_xfer.deadline) {
        xfer_finish(false);
        return;
    }
    while (g_xfer.active && TickCount() <= slice_end) {
        OTResult sent;

        if (!g_xfer.aborting && TickCount() < g_xfer.next_tick) {
            return;                   /* paced: resume later */
        }
        if (g_xfer.frame_sent >= g_xfer.frame_len) {
            if (g_xfer.aborting) {
                xfer_finish(false);   /* boundary reached: end cleanly */
                return;
            }
            if (g_ctlq.count > 0) {
                return;               /* control goes first between frames */
            }
            g_xfer.offset += g_xfer.frame_len - kNowFrameHeaderBytes;
            if (g_xfer.offset >= g_xfer.total) {
                xfer_finish(true);
                return;
            }
            if (!xfer_build_frame()) {
                xfer_finish(false);
                return;
            }
            if (g_xfer.pace_ms > 0) {
                g_xfer.next_tick = TickCount()
                    + (unsigned long)g_xfer.pace_ms * 60 / 1000 + 1;
            }
        }
        sent = gNowOT.snd(g.ep, g_xfer.frame + g_xfer.frame_sent,
                          (OTByteCount)(g_xfer.frame_len - g_xfer.frame_sent),
                          0);
        if (sent > 0) {
            g_xfer.frame_sent += sent;
            /* This is an inactivity deadline, not a size ceiling. A
               healthy transfer larger than ~27 MB takes over two
               minutes on the measured link and must keep going. */
            g_xfer.deadline = TickCount() + kXferDeadlineTicks;
        } else if (sent == kOTFlowErr || sent == kOTNoDataErr) {
            return;                   /* buffer full: retry next pass */
        } else {
            xfer_finish(false);
            return;
        }
    }
}

/* Aborting mid-frame would corrupt the wire: the peer's decoder still
   expects the rest of the frame's bytes and would eat the next control
   message as bulk payload (the 4-bit stop bug - desync, protocol error,
   reconnect). So an abort drains to the frame boundary first; the
   remainder is at most one chunk, ~120 ms at wire speed. */
static void xfer_abort(void)
{
    if (!g_xfer.active) {
        return;
    }
    if (bulk_frame_partially_sent()) {
        g_xfer.aborting = true;
        return;
    }
    xfer_finish(false);
}

/* Panel hook: one status line about push transfers ("Sent to host"). */
static ConnShotNote g_shot_note;
static ConnFileNote g_file_note;

void conn_set_shot_note(ConnShotNote fn)
{
    g_shot_note = fn;
}

static void note_shot(const char *line)
{
    if (g_shot_note != NULL) {
        g_shot_note(line);
    }
}

void conn_set_file_note(ConnFileNote fn)
{
    g_file_note = fn;
}

/* A file's progress belongs in the window the human sent it from. */
static void note_file(const char *line)
{
    if (g_file_note != NULL) {
        g_file_note(line);
    }
}

/* JSON true/false with a fallback for an absent key. */
static int json_find_flag(const char *json, const char *key, int fallback)
{
    const char *v = now_json_value(json, key);

    if (v == NULL) {
        return fallback;
    }
    return *v == 't';
}

/* The initiator's knobs override the panel's; absent fields keep prefs. */
static void tuning_from_json(const char *json, const NowPrefs *prefs,
                             long *chunk, short *pace_ms, Boolean *pack)
{
    long v;

    v = now_json_find_int(json, "chunkKb", prefs->chunk_kb);
    if (v < 1 || v > 32) {
        v = prefs->chunk_kb;
    }
    *chunk = v * 1024;
    if (*chunk < 1024 || *chunk > kNowMaxPayload) {
        *chunk = 8192;
    }
    v = now_json_find_int(json, "paceMs", prefs->pace_ms);
    if (v < 0 || v > 100) {
        v = prefs->pace_ms;
    }
    *pace_ms = (short)v;
    *pack = json_find_flag(json, "pack", prefs->shot_pack) != 0;
}

static unsigned short next_xfer(void)
{
    ++g.transfer_seq;
    if (g.transfer_seq == 0) {
        g.transfer_seq = 1;
    }
    return g.transfer_seq;
}

/* Fills the meta and exports the wire pixels from an already-captured
   image, disposing it either way. Shared by the full-screen and
   window-cropped gatherers. */
static int export_shot(CaptureImage *image, short depth, Boolean pack,
                       unsigned long t_start, PixelBlob *blob, ShotMeta *meta)
{
    memset(meta, 0, sizeof *meta);    /* kind = kFrameStandalone */
    meta->capture_ms = (long)((TickCount() - t_start) * 1000 / 60);
    meta->width = (short)(image->bounds.right - image->bounds.left);
    meta->height = (short)(image->bounds.bottom - image->bounds.top);
    meta->depth = depth;
    meta->row_bytes = image->row_bytes;
    if (now_pixels_export(image, pack, blob) != 0) {
        capture_image_dispose(image);
        return 0;
    }
    capture_image_dispose(image);
    return 1;
}

/* Captures the screen and exports the wire pixels. On success the blob is
   the caller's to dispose. */
static int gather_shot(short depth, Boolean pack, PixelBlob *blob,
                       ShotMeta *meta)
{
    CaptureImage image;
    unsigned long t_start = TickCount();

    if (capture_screen(depth, &image) != kCaptureOK) {
        return 0;
    }
    return export_shot(&image, depth, pack, t_start, blob, meta);
}

/* As gather_shot, but captures a single screen rectangle - the anchor
   plane's payoff, used to crop "Screenshot App" to a process's window. */
static int gather_shot_rect(short depth, const Rect *rect, Boolean pack,
                            PixelBlob *blob, ShotMeta *meta)
{
    CaptureImage image;
    unsigned long t_start = TickCount();

    if (capture_screen_rect(depth, rect, &image) != kCaptureOK) {
        return 0;
    }
    return export_shot(&image, depth, pack, t_start, blob, meta);
}

/* Announces capture.begin and arms the incremental sender. Takes ownership
   of the blob either way; on failure the host gets capture.end ok:false so
   it never waits on a transfer that will not come. */
/* Appends the frame/rects fields for stream frames; standalone captures
   keep the original message shape. */
static long begin_frame_fields(const ShotMeta *meta, char *out, long cap)
{
    long pos = 0;
    short i;

    if (meta->kind == kFrameStandalone) {
        out[0] = '\0';
        return 0;
    }
    if (meta->kind == kFrameKey) {
        return snprintf(out, (size_t)cap, ",\"frame\":\"key\"");
    }
    pos = snprintf(out, (size_t)cap, ",\"frame\":\"delta\",\"rects\":[");
    for (i = 0; i < meta->n_rects; ++i) {
        short scale = meta->row_scale > 1 ? meta->row_scale : 1;
        long canvas_row = (long)meta->rects[i].row * scale
            + meta->row_phase;

        if (scale > 1) {
            pos += snprintf(out + pos, (size_t)(cap - pos),
                            "%s[%ld,%d,%d,%d,%d]", i > 0 ? "," : "",
                            canvas_row, (int)meta->rects[i].n_rows,
                            (int)meta->rects[i].col_off,
                            (int)meta->rects[i].col_bytes, (int)scale);
        } else {
            pos += snprintf(out + pos, (size_t)(cap - pos),
                            "%s[%ld,%d,%d,%d]", i > 0 ? "," : "",
                            canvas_row, (int)meta->rects[i].n_rows,
                            (int)meta->rects[i].col_off,
                            (int)meta->rects[i].col_bytes);
        }
    }
    pos += snprintf(out + pos, (size_t)(cap - pos), "]");
    return pos;
}

static int arm_xfer_common(long id, unsigned short xfer, long total,
                           long chunk, short pace_ms, XferKind kind)
{
    Ptr frame = NewPtr(chunk + kNowFrameHeaderBytes);

    if (frame == NULL) {
        return 0;
    }
    memset(&g_xfer, 0, sizeof g_xfer);
    g_xfer.kind = kind;
    g_xfer.frame = frame;
    g_xfer.active = true;
    g_xfer.total = total;
    g_xfer.offset = 0;
    g_xfer.chunk = chunk;
    g_xfer.xfer = xfer;
    g_xfer.id = id;
    g_xfer.pace_ms = pace_ms;
    g_xfer.frame_len = kNowFrameHeaderBytes;   /* primes the first build */
    g_xfer.frame_sent = kNowFrameHeaderBytes;
    g_xfer.started = TickCount();
    g_xfer.next_tick = 0;
    g_xfer.deadline = TickCount() + kXferDeadlineTicks;
    return 1;
}

/* Arms the sender over an arbitrary handle. The caller has already
   announced the transfer (capture.begin / file.begin); on success the
   transfer owns the handle. */
static int arm_blob_transfer(long id, unsigned short xfer, Handle data,
                             long total, long chunk, short pace_ms,
                             XferKind kind)
{
    if (!arm_xfer_common(id, xfer, total, chunk, pace_ms, kind)) {
        return 0;
    }
    g_xfer.data = data;
    HLock(data);
    return 1;
}

/* File bytes differ from captures only at the source boundary: one frame
   is filled from open forks instead of copied from a whole-file handle.
   After success the transfer owns `file`; the caller is reset to an
   inert value so its normal cleanup remains safe. */
static int arm_file_transfer(long id, unsigned short xfer, FileStage *file,
                             long chunk, short pace_ms)
{
    if (now_files_stage_open(file) != kFilesOK) {
        return 0;
    }
    if (!arm_xfer_common(id, xfer, file->total_bytes, chunk, pace_ms,
                         kXferFile)) {
        now_files_stage_dispose(file);
        return 0;
    }
    g_xfer.file_stream = true;
    g_xfer.file = *file;
    memset(file, 0, sizeof *file);
    file->data_ref = -1;
    file->rsrc_ref = -1;
    return 1;
}

static int arm_transfer(long id, unsigned short xfer, const ShotMeta *meta,
                        PixelBlob *blob, long chunk, short pace_ms,
                        Boolean pushed)
{
    char frame_fields[640];
    char json[1024];
    PixelBlob owned = *blob;

    memset(blob, 0, sizeof *blob);
    begin_frame_fields(meta, frame_fields, sizeof frame_fields);
    snprintf(json, sizeof json,
             "{\"type\":\"capture.begin\",\"id\":%ld,\"transfer\":%u,"
             "\"width\":%d,\"height\":%d,\"depth\":%d,"
             "\"rowBytes\":%d,\"bytes\":%ld,\"paletteBytes\":%ld,"
             "\"encoding\":\"%s\",\"captureMs\":%ld,\"encodeMs\":%ld"
             "%s}",
             id, xfer, (int)meta->width, (int)meta->height,
             (int)meta->depth, (int)meta->row_bytes, owned.total_bytes,
             owned.palette_bytes, owned.packed ? "packbits" : "raw",
             meta->capture_ms, owned.encode_ms, frame_fields);
    if (!send_control(json)
        || !arm_blob_transfer(id, xfer, owned.data, owned.total_bytes,
                              chunk, pace_ms, kXferCapture)) {
        now_pixels_dispose(&owned);
        snprintf(json, sizeof json,
                 "{\"type\":\"capture.end\",\"id\":%ld,\"transfer\":%u,"
                 "\"ok\":false}", id, xfer);
        send_control(json);
        return 0;
    }
    g_xfer.blob = owned;              /* the blob owns the handle */
    g_xfer.pushed = pushed;
    return 1;
}

/* Captures, exports wire pixels, announces with capture.begin, and arms the
   incremental sender. Returns immediately - the bytes go out from
   service_transfer so the app keeps running. */
static void serve_capture(const char *request)
{
    NowPrefs prefs;
    PixelBlob blob;
    ShotMeta meta;
    char json[256];
    long id = now_json_find_int(request, "id", 0);
    long depth_arg = now_json_find_int(request, "depth", 0);
    short depth;
    unsigned short xfer;
    long chunk;
    short pace_ms;
    Boolean pack;

    if (g_stream.active) {
        snprintf(json, sizeof json,
                 "{\"type\":\"capture.end\",\"id\":%ld,\"transfer\":%u,"
                 "\"ok\":false}", id, next_xfer());
        send_control(json);
        return;                       /* the stream owns the lane */
    }
    if (g_xfer.active) {
        snprintf(json, sizeof json,
                 "{\"type\":\"capture.end\",\"id\":%ld,\"transfer\":%u,"
                 "\"ok\":false}", id, next_xfer());
        send_control(json);
        return;                       /* one transfer at a time */
    }
    now_prefs_load(&prefs);
    depth = capture_depth_is_supported((short)depth_arg)
        ? (short)depth_arg : prefs.shot_depth;
    tuning_from_json(request, &prefs, &chunk, &pace_ms, &pack);
    xfer = next_xfer();

    memset(&blob, 0, sizeof blob);
    if (!gather_shot(depth, pack, &blob, &meta)) {
        snprintf(json, sizeof json,
                 "{\"type\":\"capture.end\",\"id\":%ld,\"transfer\":%u,"
                 "\"ok\":false}", id, xfer);
        send_control(json);
        return;
    }
    arm_transfer(id, xfer, &meta, &blob, chunk, pace_ms, false);
}

/* The one failure shape a solicited capture (or shot) owes the host, so
   it never waits on a transfer that will not come. */
static void capture_fail(long id)
{
    char json[128];

    snprintf(json, sizeof json,
             "{\"type\":\"capture.end\",\"id\":%ld,\"transfer\":%u,"
             "\"ok\":false}", id, next_xfer());
    send_control(json);
}

static void shot_drop(void)
{
    g_shot.active = false;
}

/* --- the scene plane ---------------------------------------------------
   A scene is Mirror's current IR - semantic structure, not pixels - and it is
   a TRANSFER for a measured reason: this producer encodes 9214 bytes for
   24 processes and 32 windows against a 4096-byte control cap, before
   menus or controls exist at all. So it borrows capture's pair
   (scene.begin, bulk frames, scene.end) rather than inventing anything,
   and deliberately does NOT borrow the stream bracket: a bracket exists
   to amortise a half-second capture, and a semantic walk has no such
   cost to amortise (docs/streaming-a-scene.md).

   THE FAILURE IS WHOLE. A walk that would not fit its buffer, or a scene
   that could not be allocated, is scene.end ok:false with a reason and
   NO bulk. The encoder already fails closed for the same reason: half a
   JSON document is the worst form of a partial answer because it does
   not even parse, and "a partial or failed walk must never be delivered
   as a complete scene" is the rule this whole path exists to keep. */

static long g_scene_seq;

/* WHAT THIS GUEST LAST HANDED A CONSUMER, as one key and one hash per
   entity - a few kilobytes, and nothing in it is proportional to the
   size of the document. It is what lets a scene answer "the same" for
   the cost of a control frame, and what a delta is computed against.
   See scene_digest.h and docs/scene-deltas.md. */
static NowSceneBaseline g_scene_baseline;

static void scene_baseline_forget(void)
{
    now_scene_baseline_clear(&g_scene_baseline);
}

/* The one failure shape a scene owes the host, so it never waits on a
   transfer that will not come. `reason` is prose for a human; nothing
   branches on it. */
static void scene_fail(long id, unsigned short xfer, const char *reason)
{
    char json[256];

    snprintf(json, sizeof json,
             "{\"type\":\"scene.end\",\"id\":%ld,\"transfer\":%u,"
             "\"ok\":false,\"reason\":\"%s\"}", id, xfer, reason);
    send_control(json);
}

/* What the WHOLE document would have measured, beside what the delta
   actually costs. It is published so the saving is a measurement on the
   wire rather than a claim in a plan: a host records both numbers, and a
   delta that stops paying for itself becomes visible without anyone
   instrumenting anything. */
static long g_scene_whole_bytes;

static const char *scene_delta_envelope(const char *baseline, long whole)
{
    static char buf[80];

    snprintf(buf, sizeof buf,
             "\"delta\":true,\"baseline\":\"%s\",\"wholeBytes\":%ld,",
             baseline, whole);
    return buf;
}

/* THE NO-CHANGE ANSWER. A control frame and nothing else: no transfer id
   is spent, no bulk lane is held, and there is no scene.end - because
   this is not a transfer. It is deliberately NOT a flag on scene.end,
   which would have made the cheapest and most common outcome in the
   whole protocol share a code path with failure.

   It is still a FRESH OBSERVATION: capturedAt moves, walkMs and phases
   describe this walk, and settlements reconcile against it exactly as
   they do on scene.begin. A consumer republishes what it already holds
   with the new moment; it does not treat the machine as unobserved. */
static void send_scene_same(long id, const NowScene *scene, long walk_ms,
                            const char *digest_hex)
{
    static char json[kNowMaxControl];
    long used;
    long settled;

    used = snprintf(json, sizeof json,
                    "{\"type\":\"scene.same\",\"id\":%ld,\"seq\":%ld,"
                    "\"digest\":\"%s\",\"capturedAt\":%.1f,"
                    "\"walkMs\":%ld,",
                    id, scene->seq, digest_hex, scene->captured_at, walk_ms);
    if (used < 0 || used >= (long)sizeof json) {
        scene_fail(id, 0, "the scene.same envelope did not fit");
        return;
    }
    if (now_scene_phase_reporting()) {
        int p;
        long n;

        n = snprintf(json + used, (long)sizeof json - used, "\"phases\":{\"us\":{");
        if (n < 0 || used + n >= (long)sizeof json) {
            scene_fail(id, 0, "the scene.same envelope did not fit");
            return;
        }
        used += n;
        for (p = 0; p < kNowScenePhaseCount; ++p) {
            n = snprintf(json + used, (long)sizeof json - used, "%s\"%s\":%lu",
                         p ? "," : "", now_scene_phase_name(p),
                         now_scene_phase_us(p));
            if (n < 0 || used + n >= (long)sizeof json) {
                scene_fail(id, 0, "the scene.same envelope did not fit");
                return;
            }
            used += n;
        }
        n = snprintf(json + used, (long)sizeof json - used,
                     "},\"clockReads\":%lu,\"clockUs\":%lu,\"faults\":%lu},",
                     now_scene_phase_clock_reads(), now_scene_phase_clock_us(),
                     now_scene_phase_faults());
        if (n < 0 || used + n >= (long)sizeof json) {
            scene_fail(id, 0, "the scene.same envelope did not fit");
            return;
        }
        used += n;
    }
    settled = now_act_encode_settlements(json + used,
                                         (long)sizeof json - used - 1);
    if (settled < 0 || used + settled + 1 >= (long)sizeof json) {
        scene_fail(id, 0, "the scene.same envelope did not fit");
        return;
    }
    /* The trailing comma the settlement encoder expects is written above;
       when it emits nothing, the comma would be trailing garbage - so it
       is stepped back over rather than left in the document. */
    if (settled == 0 && used > 0 && json[used - 1] == ',') {
        used -= 1;
    }
    json[used + settled] = '}';
    json[used + settled + 1] = '\0';
    send_control(json);
}

/* Walks the machine, encodes the current IR, announces scene.begin and arms the
   incremental sender. Returns immediately - the bytes go out from
   service_transfer, exactly as a capture's do. */
/* How long a scene may wait for the anchor plane's arm echo before it
   walks anyway. Ticks, so half a second - a ceiling and not a cost: the
   echo was measured at ~15 ms, and this returns the moment it lands. */
enum { kNowSceneArmSettleTicks = 30 };

static void serve_scene(const char *request)
{
    NowPrefs prefs;
    static char json[kNowMaxControl];
    long id = now_json_find_int(request, "id", 0);
    long stale_ms = now_json_find_int(request, "staleAfterMs", 0);
    Boolean semantics = now_json_find_bool(request, "semantics", true);
    Boolean interaction = now_json_find_bool(request, "interaction", true);
    /* THE ASKER'S BASELINE, quoted as a digest rather than a sequence.
       A sequence says which document the producer THINKS the consumer
       has; a digest says which one it ACTUALLY holds, and those differ
       exactly when a consumer mis-applied a delta - the one failure a
       delta stream has to survive. A `since` this guest does not
       recognise is not an error and is not refused: it is answered with
       a whole document, which is always correct and is therefore the
       recovery path as well as the default. */
    char since[16];
    Boolean want_full = now_json_find_bool(request, "full", false);
    Boolean serve_delta = false;
    NowSceneSpans *spans = NULL;
    unsigned long digest = 0;
    char digest_hex[9];
    Handle delta = NULL;
    long delta_len = 0;
    unsigned long stale_ticks;
    unsigned short xfer;
    long chunk;
    short pace_ms;
    Boolean pack;
    NowScene *scene;
    Handle doc;
    long needed = 0;
    unsigned long t_start = TickCount();
    long walk_ms;

    xfer = next_xfer();
    if (g_stream.active) {
        scene_fail(id, xfer, "a stream owns the transfer lane");
        return;
    }
    if (g_xfer.active) {
        scene_fail(id, xfer, "a transfer is already in flight");
        return;
    }
    /* The scene is ~27 KB of struct - it was ~11 KB before the menubar,
       controls, text and kind planes (scene.h sizes them). A classic Mac
       stack is 24-32 KB and this is called from the event loop with the
       whole wire machine above it, so it goes in the heap - the same
       reason a capture blob does.

       At that size the failure below is a real outcome, not a formality:
       one contiguous 27 KB block out of a small application partition is
       exactly what a fragmented heap cannot serve. It refuses by name
       rather than walking a smaller machine. */
    scene = (NowScene *)NewPtr((Size)sizeof(NowScene));
    if (scene == NULL) {
        scene_fail(id, xfer, "not enough memory to walk the machine");
        return;
    }
    if (stale_ms < 0) {
        stale_ms = 0;
    }
    stale_ticks = (unsigned long)((stale_ms * 60L) / 1000L);
    if (stale_ms > 0 && stale_ticks == 0) {
        stale_ticks = 1;              /* a window shorter than a tick is
                                         still a window, not "disabled" */
    }
    /* ARM THE ANCHOR PLANE BEFORE WALKING, and this line is the whole
       difference between a scene of this machine and a scene of this
       application.
     *
     * The anchor plane captures only while armed. Nothing on the scene
     * path ever armed it - the only arm sites were the Processes page
     * (console face, while shown), the content plane, and act_client,
     * which withdraws again as soon as its op completes. So every scene
     * this guest has ever served walked with the plane dark, the oracle
     * found no anchor for any foreign process, and the answer contained
     * NOW's own window and nothing else. Measured 2026-08-02 against
     * Mirror's agent on one machine: the agent's walk found the front
     * application's window with ten controls, this one found none of it.
     *
     * That read as "NOW's scene is structurally poorer than Mirror's",
     * and it was not - it was unarmed. This side owns only the arm
     * cells, which is exactly what is written here.
     *
     * A capture takes at least one event-loop pass in the target to
     * appear, so the FIRST scene after a cold arm is still thin and the
     * next is not. That is the plane's settle window, not a defect, and
     * it is why this arms rather than arming-and-waiting: a walk that
     * blocked for a foreign process to pump would hold the wire. */
    /* CLAIMED AND HELD, not armed-then-walked. An anchor is captured
       when a process pumps its event loop, so arming immediately before
       the walk can only ever catch the process doing the arming - us.
       Held across requests, every application that pumps between two
       scenes gets one, which is what makes a mirror show the machine
       rather than this application. */
    if (now_mirror_policy_enabled(kMirrorPolicyStructure)) {
        unsigned long requested = (unsigned long)kNowPeekCapAnchors;
        unsigned long optional = (unsigned long)(kNowPeekCapTree
                                                  | kNowPeekTableCapAct);

        if (semantics) requested |= (unsigned long)kNowPeekCapTree;
        if (interaction) requested |= (unsigned long)kNowPeekTableCapAct;
        now_peek_release(kNowPeekOwnerScene, optional & ~requested);
        now_peek_claim(kNowPeekOwnerScene, requested);
        /* And remember it, so ANY later thing this host asks for renews
           the claim rather than only the next scene. See
           renew_scene_planes(). */
        g_scene_plane_caps = requested;
    } else {
        /* Structure-off is not a thin structural request. It is no
           foreign-memory observation at all: withdraw every scene-owned
           claim and let scene_collect report only what Process Manager and
           this application's own context can prove. */
        now_peek_release(kNowPeekOwnerScene,
                         (unsigned long)(kNowPeekCapAnchors
                                         | kNowPeekCapTree
                                         | kNowPeekTableCapAct));
        g_scene_plane_caps = 0;
    }

    /* THEN WAIT FOR THE PLANE, briefly, rather than walking blind.
     *
     * The claim above is a request; the resident echoes it on its next
     * pass, and a walk that starts before the echo reports no-plane for
     * every foreign process - one useless scene per lapse, and it is the
     * scene a person is looking at. Measured 2026-08-06: after a
     * ten-second quiet gap the walk carried NOW's own window alone with a
     * modal open on screen, and the next walk carried all three windows.
     *
     * Bounded, and it does not lie: now_peek_settle returns as soon as
     * the resident echoes (~15 ms) and gives up after half a second, and
     * the walk proceeds either way - a scene that says "not observed" is
     * still the honest answer when the plane genuinely is not armed. The
     * arm handshake is unchanged; this only stops asking before it. */
    if (g_scene_plane_caps != 0) {
        (void)now_peek_settle((unsigned long)kNowPeekCapAnchors,
                              kNowSceneArmSettleTicks);
    }

    /* AND NOTHING MORE, ON THIS PATH. A wake sweep was tried here and
     * REMOVED after it was measured: on a freshly booted machine
     * WakeUpProcess made eight processes eligible, every call returned
     * noErr, and half a second later not one of them had executed a
     * GetNextEvent - `slotScans` did not move. Making a process eligible
     * is not making it pump, and a recurring cost on the scene path with
     * no measured acquisition is exactly the trade this slice was told
     * not to make.
     *
     * What DOES acquire is the process being brought forward, and that
     * visibly disturbs the machine - so it belongs in a control a person
     * or an agent invokes deliberately (`cycle`, anchor_cycle.h) and
     * never on a path that runs whenever a host polls. A scene of a
     * machine nobody has cycled still says "not observed", honestly, for
     * the processes it has never been inside. */

    now_scene_collect(scene, ++g_scene_seq, stale_ticks);
    /* A long scene and cooperative starvation have looked identical in the
       wire log: both surface later as "not scheduled". The scene already
       measures its own phases, so name a slow walk at its source. This is
       diagnostic only; it does not yield while foreign addresses are live or
       invent a cancellation protocol the serial wire does not have. */
    if (scene->latency_ms >= kSlowSceneLogMs) {
        now_log(kLogWarn, "mirror",
                "slow scene %ldms: enum %lums bind %lums windows %lums "
                "controls %lums menu %lums semantics %lums refs %lums",
                scene->latency_ms,
                now_scene_phase_us(kNowScenePhaseEnumerate) / 1000UL,
                now_scene_phase_us(kNowScenePhaseBind) / 1000UL,
                now_scene_phase_us(kNowScenePhaseWindows) / 1000UL,
                now_scene_phase_us(kNowScenePhaseControls) / 1000UL,
                now_scene_phase_us(kNowScenePhaseMenubar) / 1000UL,
                now_scene_phase_us(kNowScenePhaseSemantics) / 1000UL,
                now_scene_phase_us(kNowScenePhaseRefs) / 1000UL);
    }
    /* Correlate subsequent acts with the normal-context observation a
       person actually saw. This is evidence only; resident guards do not
       trust the scene sequence. */
    now_act_note_scene_generation((unsigned long)scene->seq);
    now_act_observe_scene(scene);

    /* Size, then allocate, then encode. One walk, two answers: the
       encoder counts always and writes only while it fits, so asking for
       the size costs a pass and never a second walk.
     *
     * THE SIZING PASS IS WHAT `phases.us.encode` REPORTS, and it has to
     * be: a document cannot state how long it took to write itself. The
     * counting pass does the same work as the writing pass minus the
     * stores, it happens first, and it is therefore the honest thing to
     * name. The consequence is the slack below - the number the write
     * pass emits is longer than the digits the count pass sized for, by
     * at most the width of one microsecond count - and now_scene_encode
     * reports what it ACTUALLY used, so `bytes` stays exact. */
    since[0] = '\0';
    (void)now_json_find_string(request, "since", since, (long)sizeof since);
    now_scene_phase_enter(kNowScenePhaseEncode);
    needed = now_scene_encoded_size(scene);
    now_scene_phase_leave(kNowScenePhaseEncode);
    needed += kSceneEncodePhaseSlack;
    doc = NewHandle((Size)needed);
    if (doc == NULL) {
        DisposePtr((Ptr)scene);
        scene_fail(id, xfer, "not enough memory to encode the scene");
        return;
    }
    /* The span table is heap, not stack: it is ~10 KB and this runs on a
       cooperatively scheduled machine whose stack is not that. A guest
       that cannot afford it serves whole documents, which is what it did
       before this existed - so the allocation failing costs performance
       and never correctness. */
    spans = (NowSceneSpans *)NewPtr((Size)sizeof(NowSceneSpans));
    HLock(doc);
    if (now_scene_encode_spans(scene, *doc, needed, &needed, spans)
        != kNowSceneEncodeOk) {
        HUnlock(doc);
        DisposeHandle(doc);
        if (spans != NULL) DisposePtr((Ptr)spans);
        DisposePtr((Ptr)scene);
        scene_fail(id, xfer, "the scene did not fit its buffer");
        return;
    }
    HUnlock(doc);

    /* WHAT THIS SCENE LOOKS LIKE, as one number over an exactly-specified
       byte range (contract/asyncapi.yaml, SceneBegin.digest). It excludes
       seq, capturedAt and phases on purpose: those move on every walk of
       a machine that did not change, and saying "nothing changed" is the
       whole point. */
    HLock(doc);
    if (spans != NULL) {
        digest = now_scene_body_digest(*doc, spans);
    }
    now_scene_digest_hex(digest, digest_hex);

    if (since[0] != '\0' && !want_full && now_scene_digest_is(digest, since)) {
        /* THE NO-CHANGE ANSWER: a control frame, no transfer, no bulk
           lane held. The test is the digest of the scene JUST WALKED
           against what the host says it holds - not against this guest's
           own baseline, so a guest that has forgotten its baseline can
           still answer "the same" truthfully.
           The run is NOT advanced. A scene.same re-proves the consumer's
           whole body against a freshly walked machine, so it accumulates
           no unverified state for a bound to protect. */
        HUnlock(doc);
        DisposeHandle(doc);
        if (spans != NULL) DisposePtr((Ptr)spans);
        walk_ms = (long)((TickCount() - t_start) * 1000UL / 60UL);
        send_scene_same(id, scene, walk_ms, digest_hex);
        DisposePtr((Ptr)scene);
        return;
    }
    if (spans != NULL && since[0] != '\0' && !want_full
        && g_scene_baseline.held
        && now_scene_digest_is(g_scene_baseline.digest, since)) {
        if (g_scene_baseline.run < kNowSceneDeltaMaxRun) {
            delta_len = now_scene_delta_encode(&g_scene_baseline, *doc, spans,
                                               scene->seq, scene->captured_at,
                                               since, NULL, 0);
            /* ONLY WHEN IT IS SMALLER. There is no case for a delta that
               costs more than the document it replaces, and both numbers
               are already in hand. */
            if (delta_len > 0 && delta_len + 1 < needed) {
                delta = NewHandle((Size)(delta_len + 1));
                if (delta != NULL) {
                    HLock(delta);
                    if (now_scene_delta_encode(&g_scene_baseline, *doc, spans,
                                               scene->seq, scene->captured_at,
                                               since, *delta, delta_len + 1)
                        == delta_len) {
                        serve_delta = true;
                    }
                    HUnlock(delta);
                    if (!serve_delta) {
                        DisposeHandle(delta);
                        delta = NULL;
                    }
                }
            }
        }
    }
    HUnlock(doc);

    /* The baseline becomes THIS scene either way: after a delta the
       consumer holds the new document, and after a whole one it holds it
       too. What differs is the chain length, which only a delta
       advances. */
    if (spans != NULL) {
        unsigned long run = serve_delta ? g_scene_baseline.run + 1 : 0;

        HLock(doc);
        if (now_scene_baseline_adopt(&g_scene_baseline, *doc, spans, digest)) {
            g_scene_baseline.run = run;
        }
        HUnlock(doc);
        DisposePtr((Ptr)spans);
        spans = NULL;
    }
    if (serve_delta) {
        long whole = needed - 1;

        DisposeHandle(doc);
        doc = delta;
        needed = delta_len + 1;
        g_scene_whole_bytes = whole;
    } else {
        g_scene_whole_bytes = 0;
    }
    walk_ms = (long)((TickCount() - t_start) * 1000UL / 60UL);

    now_prefs_load(&prefs);
    tuning_from_json(request, &prefs, &chunk, &pace_ms, &pack);

    /* The terminator is NOT sent: `bytes` is the document, and a JSON
       parser wants a length rather than a C string. needed counts it. */
    {
    long json_used;
    long settlement_used;
    json_used = snprintf(json, sizeof json,
             "{\"type\":\"scene.begin\",\"id\":%ld,\"transfer\":%u,"
             "\"bytes\":%ld,\"irVersion\":%d,\"seq\":%ld,"
             "\"capturedAt\":%.1f,\"source\":\"%s\",\"walkMs\":%ld,"
             "\"digest\":\"%s\",%s",
             id, xfer, needed - 1, NOW_SCENE_IR_VERSION, scene->seq,
             scene->captured_at, scene->source, walk_ms, digest_hex,
             serve_delta ? scene_delta_envelope(since, g_scene_whole_bytes)
                         : "");
    if (json_used < 0 || json_used >= (long)sizeof json) {
        DisposePtr((Ptr)scene);
        DisposeHandle(doc);
        scene_fail(id, xfer, "the scene envelope did not fit");
        return;
    }
    settlement_used = now_act_encode_settlements(
        json + json_used, (long)sizeof json - json_used - 1);
    if (settlement_used < 0
        || json_used + settlement_used + 1 >= (long)sizeof json) {
        DisposePtr((Ptr)scene);
        DisposeHandle(doc);
        scene_fail(id, xfer, "the settlement envelope did not fit");
        return;
    }
    json[json_used + settlement_used] = '}';
    json[json_used + settlement_used + 1] = '\0';
    }
    DisposePtr((Ptr)scene);
    if (!send_control(json)
        || !arm_blob_transfer(id, xfer, doc, needed - 1, chunk, pace_ms,
                              kXferScene)) {
        DisposeHandle(doc);
        scene_fail(id, xfer, "could not start the transfer");
        return;
    }
}

/* "Screenshot App": front the target, then arm the deferred capture. No
   reply yet - the answer is the capture transfer (or a capture.end
   ok:false), correlated by this id, exactly as a plain capture.request. */
static void serve_process_shot(const char *request)
{
    NowPrefs prefs;
    ProcessSerialNumber psn;
    ProcessInfoRec info;
    Str31 name;
    long id = now_json_find_int(request, "id", 0);
    long depth_arg = now_json_find_int(request, "depth", 0);

    if (g_stream.active || g_xfer.active || g_shot.active) {
        now_log(kLogWarn, "proc", "#%ld shot refused: a transfer is in flight",
                id);
        capture_fail(id);             /* one transfer at a time */
        return;
    }
    psn.highLongOfPSN =
        (unsigned long)now_json_find_int(request, "psnHigh", 0);
    psn.lowLongOfPSN =
        (unsigned long)now_json_find_int(request, "psnLow", 0);

    memset(&info, 0, sizeof info);
    info.processInfoLength = sizeof info;
    info.processName = name;
    info.processAppSpec = NULL;
    name[0] = 0;
    if (GetProcessInformation(&psn, &info) != noErr
        || GetCurrentProcess(&g_shot.self) != noErr) {
        now_log(kLogWarn, "proc", "#%ld shot refused: no such process", id);
        capture_fail(id);
        return;
    }
    {
        char cname[32];
        memcpy(cname, name + 1, name[0]);
        cname[name[0]] = '\0';
        now_log(kLogInfo, "proc", "#%ld shot of %.31s begun", id, cname);
    }
    now_prefs_load(&prefs);
    g_shot.target = psn;
    g_shot.id = id;
    g_shot.depth = capture_depth_is_supported((short)depth_arg)
        ? (short)depth_arg : prefs.shot_depth;
    tuning_from_json(request, &prefs, &g_shot.chunk, &g_shot.pace_ms,
                     &g_shot.pack);
    now_proc_bring_to_front(&psn);
    g_shot.active = true;
    /* ~0.75 s for the target to come front and repaint before we read the
       framebuffer - the same beat the Front & Capture page waits. */
    g_shot.deadline = TickCount() + 45;
}

/* Fires the deferred shot once the target has had time to come forward:
   read its front window's fresh bounds, crop the capture to them, restore
   NOW, and deliver over the capture transport. */
static void service_shot(void)
{
    NowPeekWindowList w;
    Rect rect;
    Boolean have_rect = false;
    PixelBlob blob;
    ShotMeta meta;
    int ok;

    if (!g_shot.active || TickCount() < g_shot.deadline) {
        return;
    }
    g_shot.active = false;

    /* Crop to the target's front window when the anchor plane can read its
       bounds. When it cannot - a windowless process, or NOW reading its
       own slot - fall back to the whole screen rather than failing: the
       human asked for a picture of that app, and the app is now front, so
       the screen with it on it is a truthful answer, not an error. */
    if (now_peek_windows_for_psn(&g_shot.target, &w) == kNowPeekReadOk
        && w.count >= 1) {
        SetRect(&rect, w.windows[0].left, w.windows[0].top,
                w.windows[0].right, w.windows[0].bottom);
        have_rect = true;
    }

    memset(&blob, 0, sizeof blob);
    ok = have_rect
        ? gather_shot_rect(g_shot.depth, &rect, g_shot.pack, &blob, &meta)
        : gather_shot(g_shot.depth, g_shot.pack, &blob, &meta);
    /* Pixels grabbed; NOW comes back to the front to send them (it pumps
       the wire either way, but this leaves the human's machine where they
       left it). */
    (void)now_proc_front_confirm(&g_shot.self, 0);
    if (!ok) {
        capture_fail(g_shot.id);
        return;
    }
    arm_transfer(g_shot.id, next_xfer(), &meta, &blob, g_shot.chunk,
                 g_shot.pace_ms, false);
}

/* --- guest-initiated push ----------------------------------------------
   Send to Host is offer/accept: the guest captures FIRST (so the offer
   carries true byte counts and a refusal costs nothing but the capture),
   announces with capture.offer, and only starts the bulk stream when the
   host answers capture.accept. The host can refuse - busy, no landing
   pad - and the refusal reason lands in the panel, at the machine the
   human is actually sitting at. */

enum { kOfferTimeoutTicks = 60 * 15 };

static struct {
    Boolean active;
    PixelBlob blob;
    ShotMeta meta;
    long id;
    long chunk;
    short pace_ms;
    unsigned long deadline;
} g_offer;

static void offer_cleanup(void)
{
    now_pixels_dispose(&g_offer.blob);
    g_offer.active = false;
}

int now_wire_offer_shot(char *err, long cap)
{
    NowPrefs prefs;
    char json[512];
    char line[96];
    char peer[40];

    if (g.phase != kConnConnected) {
        snprintf(err, (size_t)cap, "Not connected");
        return -1;
    }
    if (g_stream.active) {
        snprintf(err, (size_t)cap, "Already streaming");
        return -1;
    }
    if (wire_busy()) {
        snprintf(err, (size_t)cap, "A transfer is already in flight");
        return -1;
    }
    now_prefs_load(&prefs);
    g_offer.chunk = (long)prefs.chunk_kb * 1024;
    if (g_offer.chunk < 1024 || g_offer.chunk > kNowMaxPayload) {
        g_offer.chunk = 8192;
    }
    g_offer.pace_ms = prefs.pace_ms;
    memset(&g_offer.blob, 0, sizeof g_offer.blob);
    if (!gather_shot(prefs.shot_depth, prefs.shot_pack, &g_offer.blob,
                     &g_offer.meta)) {
        snprintf(err, (size_t)cap, "Screen capture failed");
        return -1;
    }
    ++g.offer_seq;
    g_offer.id = g.offer_seq;
    snprintf(json, sizeof json,
             "{\"type\":\"capture.offer\",\"id\":%ld,"
             "\"width\":%d,\"height\":%d,\"depth\":%d,"
             "\"rowBytes\":%d,\"bytes\":%ld,\"paletteBytes\":%ld,"
             "\"encoding\":\"%s\",\"captureMs\":%ld,\"encodeMs\":%ld}",
             g_offer.id, (int)g_offer.meta.width, (int)g_offer.meta.height,
             (int)g_offer.meta.depth, (int)g_offer.meta.row_bytes,
             g_offer.blob.total_bytes, g_offer.blob.palette_bytes,
             g_offer.blob.packed ? "packbits" : "raw",
             g_offer.meta.capture_ms, g_offer.blob.encode_ms);
    if (!send_control(json)) {
        offer_cleanup();
        snprintf(err, (size_t)cap, "Connection lost");
        return -1;
    }
    g_offer.active = true;
    g_offer.deadline = TickCount() + kOfferTimeoutTicks;
    conn_peer_label(peer, sizeof peer);
    snprintf(line, sizeof line, "Offered %ld KB to %s...",
             g_offer.blob.total_bytes / 1024, peer);
    note_shot(line);
    return 0;
}

static void offer_accepted(const char *reply)
{
    if (!g_offer.active || now_json_find_int(reply, "id", -1) != g_offer.id) {
        return;                       /* stale or unsolicited accept */
    }
    g_offer.active = false;
    if (arm_transfer(g_offer.id, next_xfer(), &g_offer.meta, &g_offer.blob,
                     g_offer.chunk, g_offer.pace_ms, true)) {
        {
            char peer[40];
            char line[96];

            conn_peer_label(peer, sizeof peer);
            snprintf(line, sizeof line, "Sending to %s...", peer);
            note_shot(line);
        }
    } else {
        note_shot("Send failed");
    }
}

static void offer_refused(const char *reply)
{
    char reason[64];
    char line[96];
    char peer[40];

    if (!g_offer.active || now_json_find_int(reply, "id", -1) != g_offer.id) {
        return;
    }
    offer_cleanup();
    conn_peer_label(peer, sizeof peer);
    if (now_json_find_string(reply, "reason", reason, sizeof reason)) {
        snprintf(line, sizeof line, "%.39s declined: %.44s", peer, reason);
    } else {
        snprintf(line, sizeof line, "%s declined the screenshot", peer);
    }
    note_shot(line);
}

static void service_offer(void)
{
    if (g_offer.active && TickCount() > g_offer.deadline) {
        offer_cleanup();
        {
            char peer[40];
            char line[96];

            conn_peer_label(peer, sizeof peer);
            snprintf(line, sizeof line, "%s did not answer", peer);
            note_shot(line);
        }
    }
}

/* --- files -------------------------------------------------------------
   Listing is control-plane only, so browsing works even mid-stream. A
   pull is the standard begin -> bulk -> end shape on the shared lane,
   under the same one-at-a-time rule as captures. */

static void file_refuse(long id, const char *code, const char *reason)
{
    char json[256];

    now_log(kLogWarn, "files", "#%ld refused: %s (%.60s)", id, code, reason);

    snprintf(json, sizeof json,
             "{\"type\":\"file.refuse\",\"id\":%ld,\"code\":\"%s\","
             "\"reason\":\"%.120s\"}", id, code, reason);
    send_control(json);
}

/* Once file.begin has been announced, failure is an end rather than a
   refusal. The receiver has already opened its temp and needs the
   transfer-correlated terminal message to clean it immediately. */
static void file_start_failed(long id, unsigned short xfer)
{
    char json[160];

    snprintf(json, sizeof json,
             "{\"type\":\"file.end\",\"id\":%ld,\"transfer\":%u,"
             "\"ok\":false}", id, xfer);
    send_control(json);
}

static void file_refuse_rc(long id, int rc)
{
    switch (rc) {
    case kFilesBadPath:
        file_refuse(id, "bad-path", "path leaves the share");
        break;
    case kFilesNotFound:
        file_refuse(id, "not-found", "no such item in the share");
        break;
    case kFilesNotAFolder:
        file_refuse(id, "bad-path", "not a folder");
        break;
    case kFilesTooBig:
        file_refuse(id, "too-big", "the file cannot be prepared safely");
        break;
    default:
        file_refuse(id, "io-error", "the File Manager refused");
        break;
    }
}

/* --- changing the share -------------------------------------------------
   Every one of these answers with file.result, success or not, because
   the far side is holding an undo stack and a silent failure would
   leave it believing something it can reverse. */

static const char *files_code(int rc)
{
    switch (rc) {
    case kFilesBadPath:   return "bad-path";
    case kFilesNotFound:  return "not-found";
    case kFilesNotAFolder:return "bad-path";
    case kFilesExists:    return "exists";
    default:              return "io-error";
    }
}

static const char *files_reason(int rc)
{
    switch (rc) {
    case kFilesBadPath:   return "that path leaves the shared folder";
    case kFilesNotFound:  return "no such item - it may have been moved "
                                 "or the Trash emptied";
    case kFilesNotAFolder:return "not a folder";
    case kFilesExists:    return "something is already there";
    default:              return "the File Manager refused";
    }
}

static void file_result_fail(long id, int rc)
{
    char json[320];
    char detail[64];

    /* An io-error carries the File Manager's own number: without it the
       far side can only report that something went wrong. */
    detail[0] = '\0';
    if (rc != kFilesBadPath && rc != kFilesNotFound && rc != kFilesExists) {
        snprintf(detail, sizeof detail, " (File Manager error %d)",
                 (int)now_files_last_error());
    }
    snprintf(json, sizeof json,
             "{\"type\":\"file.result\",\"id\":%ld,\"ok\":false,"
             "\"code\":\"%s\",\"reason\":\"%s%s\"}",
             id, files_code(rc), files_reason(rc), detail);
    send_control(json);
}

static void file_result_ok(long id, const char *path, const char *trashed_as)
{
    char json[512];
    char esc[300];
    long pos;

    now_json_escape(path != NULL ? path : "", esc, sizeof esc);
    pos = snprintf(json, sizeof json,
                   "{\"type\":\"file.result\",\"id\":%ld,\"ok\":true,"
                   "\"path\":\"%s\"", id, esc);
    if (trashed_as != NULL && trashed_as[0] != '\0') {
        char esc_name[160];

        now_json_escape(trashed_as, esc_name, sizeof esc_name);
        pos += snprintf(json + pos, sizeof json - (size_t)pos,
                        ",\"trashedAs\":\"%s\"", esc_name);
    }
    snprintf(json + pos, sizeof json - (size_t)pos, "}");
    send_control(json);
}

static void serve_file_move(const char *request)
{
    char from[224], to[224];
    long id = now_json_find_int(request, "id", 0);
    Boolean overwrite = now_json_find_bool(request, "overwrite", false);
    int rc;

    from[0] = to[0] = '\0';
    /* HFS names, not tokens: the host sends them UTF-8, and the File
       Manager wants MacRoman. find_text decodes; find_string would hand
       "café" to FSMakeFSSpec as the wrong bytes. */
    now_json_find_text(request, "path", from, sizeof from);
    now_json_find_text(request, "toPath", to, sizeof to);
    rc = now_files_move(from, to, overwrite);
    if (rc != kFilesOK) {
        file_result_fail(id, rc);
        return;
    }
    file_result_ok(id, to, NULL);
    note_shot("Item moved");
}

static void serve_file_trash(const char *request)
{
    char path[224];
    char landed[64];
    long id = now_json_find_int(request, "id", 0);
    int rc;

    path[0] = '\0';
    now_json_find_text(request, "path", path, sizeof path);
    rc = now_files_trash(path, landed, sizeof landed);
    if (rc != kFilesOK) {
        file_result_fail(id, rc);
        return;
    }
    file_result_ok(id, path, landed);
    note_shot("Item moved to the Trash");
}

static void serve_file_restore(const char *request)
{
    char path[224];
    char trashed_as[64];
    long id = now_json_find_int(request, "id", 0);
    int rc;

    path[0] = trashed_as[0] = '\0';
    now_json_find_text(request, "trashedAs", trashed_as, sizeof trashed_as);
    now_json_find_text(request, "toPath", path, sizeof path);
    rc = now_files_restore(trashed_as, path);
    if (rc != kFilesOK) {
        /* not-found here means the Trash no longer holds it — emptied,
           or dragged out by hand. That is a real answer, not our error. */
        file_result_fail(id, rc);
        return;
    }
    file_result_ok(id, path, NULL);
    note_shot("Item put back");
}

static void serve_file_mkdir(const char *request)
{
    char path[224];
    long id = now_json_find_int(request, "id", 0);
    int rc;

    path[0] = '\0';
    now_json_find_text(request, "path", path, sizeof path);
    rc = now_files_mkdir(path);
    if (rc != kFilesOK) {
        file_result_fail(id, rc);
        return;
    }
    file_result_ok(id, path, NULL);
    note_shot("Folder created");
}

/* --- browsing the OTHER machine's share ----------------------------------
   The mirror of serve_file_list: the same message, asked rather than
   answered. Listings are control-plane, so browsing works while a
   transfer or a stream is in flight - only the ANSWER is one at a
   time, and a second request simply replaces the first. */

enum { kBrowseTimeoutTicks = 60 * 20 };

static struct {
    Boolean pending;
    long id;
    char path[224];
    unsigned long deadline;
} g_browse;

static ConnListing g_listing_hook;

void conn_set_listing(ConnListing fn)
{
    g_listing_hook = fn;
}

int now_wire_list_host(const char *path, long cursor, char *err, long cap)
{
    char json[720];               /* an escaped path can be 6x its bytes */
    char esc[600];

    if (g.phase != kConnConnected) {
        snprintf(err, (size_t)cap, "Not connected");
        return -1;
    }
    if (path == NULL) {
        path = "";
    }
    if (strlen(path) >= sizeof g_browse.path) {
        snprintf(err, (size_t)cap, "That path is too long");
        return -1;
    }
    now_json_escape(path, esc, sizeof esc);
    ++g.offer_seq;
    g_browse.id = g.offer_seq;
    strcpy(g_browse.path, path);
    snprintf(json, sizeof json,
             "{\"type\":\"file.list\",\"id\":%ld,\"path\":\"%s\","
             "\"cursor\":%ld}",
             g_browse.id, esc, cursor > 0 ? cursor : 1);
    if (!send_control(json)) {
        snprintf(err, (size_t)cap, "Connection lost");
        return -1;
    }
    g_browse.pending = true;
    g_browse.deadline = TickCount() + kBrowseTimeoutTicks;
    return 0;
}

/* A listing off the wire. Names are DECODED (UTF-8 to MacRoman) because
   everything here is either drawn or used as a file name, and neither
   can hold anything else. */
static void browse_listing(const char *reply)
{
    FileEntry entries[16];
    char object[320];
    char root[160];
    char kind[16];
    const char *p;
    int n = 0;

    if (!g_browse.pending
        || now_json_find_int(reply, "id", -1) != g_browse.id) {
        return;
    }
    g_browse.pending = false;

    memset(entries, 0, sizeof entries);
    p = now_json_array(reply, "entries");
    while (p != NULL && n < (int)(sizeof entries / sizeof entries[0])) {
        char type[8], creator[8];

        p = now_json_next_object(p, object, sizeof object);
        if (p == NULL) {
            break;
        }
        now_json_find_text(object, "name", entries[n].name,
                           sizeof entries[n].name);
        if (entries[n].name[0] == '\0') {
            continue;                 /* a nameless entry is unusable */
        }
        kind[0] = '\0';
        now_json_find_string(object, "kind", kind, sizeof kind);
        entries[n].folder = (strcmp(kind, "folder") == 0);
        entries[n].data_bytes = now_json_find_int(object, "dataBytes", 0);
        entries[n].rsrc_bytes = now_json_find_int(object, "rsrcBytes", 0);
        /* Unsigned: see now_json_find_u32's header comment. A classic
           date past January 1972 saturates through find_int's signed
           strtol and draws as "--" in the browser. */
        entries[n].modified = now_json_find_u32(object, "modified", 0);
        type[0] = '\0';
        creator[0] = '\0';
        now_json_find_string(object, "fileType", type, sizeof type);
        now_json_find_string(object, "creator", creator, sizeof creator);
        if (strlen(type) == 4) {
            memcpy(&entries[n].file_type, type, 4);
        }
        if (strlen(creator) == 4) {
            memcpy(&entries[n].creator, creator, 4);
        }
        ++n;
    }

    root[0] = '\0';
    now_json_find_text(reply, "root", root, sizeof root);
    if (g_listing_hook != NULL) {
        g_listing_hook(g_browse.path, entries, n,
                       now_json_find_bool(reply, "more", 0) ? true : false,
                       now_json_find_int(reply, "cursor", 1),
                       root[0] != '\0' ? root : NULL, NULL);
    }
}

/* Does this refusal answer OUR question? Browsing and sending both use
   the offer sequence, so the id says which. */
static Boolean browse_refused(const char *reply)
{
    char reason[96];

    if (!g_browse.pending
        || now_json_find_int(reply, "id", -1) != g_browse.id) {
        return false;
    }
    g_browse.pending = false;
    if (!now_json_find_text(reply, "reason", reason, sizeof reason)) {
        strcpy(reason, "the other Mac refused");
    }
    if (g_listing_hook != NULL) {
        g_listing_hook(g_browse.path, NULL, 0, false, 1, NULL, reason);
    }
    return true;
}

static void service_browse(void)
{
    if (g_browse.pending && TickCount() > g_browse.deadline) {
        g_browse.pending = false;
        if (g_listing_hook != NULL) {
            g_listing_hook(g_browse.path, NULL, 0, false, 1, NULL,
                           "no answer");
        }
    }
}

/* --- asking about the other machine's cloud ------------------------------
   The cloud.* family, asked the way a listing is asked: one pending
   question, a deadline, and the reply matched by id. The store that
   PARSES the frames lives in cloud_model.c where the host cc can test
   it; this block only correlates and forwards raw frames.

   A get is its own pending beside the ask, because its success is not
   a cloud frame: the host answers with an ordinary file.offer into
   this machine's share. The offer carries the HOST's id, not ours, so
   it is correlated by arrival — the host only ever offers unprompted
   when a human there pushes, and one doing that mid-get earns a wrong
   status line, not a wrong file. */

enum { kCloudTimeoutTicks = 60 * 15 };

static struct {
    Boolean pending;
    long id;
    int kind;                         /* the CloudAnswerKind expected */
    unsigned long deadline;
} g_cloud;

static struct {
    Boolean pending;
    long id;
    unsigned long deadline;
} g_cloudget;

/* Where a cloud.get's answering offer should LAND, when the person
   chose somewhere other than the share. Guest-side only, and the
   contract is deliberately untouched: the contract's share bound
   governs what the SENDER may reach unbidden, and this delivery is one
   the guest ASKED for — the receiver is sovereign over its own disk,
   exactly as the pull path already is when it lands in Downloads,
   outside the share. Unset means the share root, byte-identical to
   the behavior before this existed. */
static struct {
    Boolean set;
    short vref;
    long dir;
} g_cget_dest;

void now_wire_cloud_get_destination(Boolean use, short vref, long dir)
{
    g_cget_dest.set = use;
    g_cget_dest.vref = vref;
    g_cget_dest.dir = dir;
}

Boolean now_wire_cloud_get_destination_get(short *vref, long *dir)
{
    if (!g_cget_dest.set) {
        return false;
    }
    if (vref != NULL) {
        *vref = g_cget_dest.vref;
    }
    if (dir != NULL) {
        *dir = g_cget_dest.dir;
    }
    return true;
}

/* The last inbound receive's one-line outcome ("Received IMG_1234.jpg",
   or why not), and a sequence number that says a NEW outcome exists —
   the seam that lets the iCloud page replace its "Receiving..." status
   when the transfer ends instead of wearing it forever. One
   implementation serves the placard and the pane: whoever cares reads
   it, nobody is called. */
static char g_rx_outcome[96];
static long g_rx_outcome_seq;

static void rx_outcome(const char *line)
{
    snprintf(g_rx_outcome, sizeof g_rx_outcome, "%.90s", line);
    ++g_rx_outcome_seq;
}

long now_wire_receive_outcome(char *out, long cap)
{
    if (out != NULL && cap > 0) {
        snprintf(out, (size_t)cap, "%s", g_rx_outcome);
    }
    return g_rx_outcome_seq;
}

/* A preview is the third pending beside the ask and the get, and the
   only one whose answer is a bulk transfer (preview.begin / bulk /
   preview.end). It cannot replace itself the way the ask kinds do — a
   replaced ask costs a dropped frame, a replaced transfer would leave
   bulk bytes with no owner — so a second ask while one is in flight is
   refused locally and the view re-asks when the hook settles. */
static struct {
    Boolean pending;                  /* asked; begin not yet seen */
    Boolean receiving;                /* begin seen; bulk landing */
    long id;
    CloudPreviewBegin begin;
    Ptr buf;                          /* NewPtr(begin.bytes) while receiving */
    long received;
    unsigned long deadline;
} g_prev;

static ConnCloudNote g_cloud_hook;
static ConnCloudPreviewNote g_preview_hook;

void conn_set_cloud_note(ConnCloudNote fn)
{
    g_cloud_hook = fn;
}

void conn_set_cloud_preview_note(ConnCloudPreviewNote fn)
{
    g_preview_hook = fn;
}

/* Ends the preview in failure: frees the buffer, clears the state,
   tells the view once. Local only — nothing here touches the wire, so
   it is safe from link_drop_transfers too. */
static void preview_fail(const char *reason)
{
    if (!g_prev.pending && !g_prev.receiving) {
        return;
    }
    if (g_prev.buf != NULL) {
        DisposePtr(g_prev.buf);
        g_prev.buf = NULL;
    }
    g_prev.pending = false;
    g_prev.receiving = false;
    if (g_preview_hook != NULL) {
        g_preview_hook(NULL, reason);
    }
}

static void cloud_note(int kind, const char *reply)
{
    if (g_cloud_hook != NULL) {
        g_cloud_hook(kind, reply);
    }
}

static int cloud_send(const char *json, char *err, long cap)
{
    if (g.phase != kConnConnected) {
        snprintf(err, (size_t)cap, "Not connected");
        return -1;
    }
    if (!send_control(json)) {
        snprintf(err, (size_t)cap, "Connection lost");
        return -1;
    }
    return 0;
}

int now_wire_cloud_services(char *err, long cap)
{
    char json[96];

    ++g.offer_seq;
    snprintf(json, sizeof json,
             "{\"type\":\"cloud.services\",\"id\":%ld}", g.offer_seq);
    if (cloud_send(json, err, cap) != 0) {
        return -1;
    }
    g_cloud.pending = true;
    g_cloud.id = g.offer_seq;
    g_cloud.kind = kCloudAnswerReport;
    g_cloud.deadline = TickCount() + kCloudTimeoutTicks;
    return 0;
}

int now_wire_cloud_list(const char *service, long cursor,
                        char *err, long cap)
{
    char json[160];
    char esc[48];

    now_json_escape(service, esc, sizeof esc);
    ++g.offer_seq;
    snprintf(json, sizeof json,
             "{\"type\":\"cloud.list\",\"id\":%ld,\"service\":\"%s\","
             "\"cursor\":%ld}",
             g.offer_seq, esc, cursor > 0 ? cursor : 1);
    if (cloud_send(json, err, cap) != 0) {
        return -1;
    }
    g_cloud.pending = true;
    g_cloud.id = g.offer_seq;
    g_cloud.kind = kCloudAnswerListing;
    g_cloud.deadline = TickCount() + kCloudTimeoutTicks;
    return 0;
}

Boolean now_wire_cloud_pending(void)
{
    return g_cloud.pending;
}

int now_wire_cloud_detail(const char *service, const char *item,
                          char *err, long cap)
{
    char json[288];
    char esc_service[48];
    char esc_item[144];

    now_json_escape(service, esc_service, sizeof esc_service);
    now_json_escape(item, esc_item, sizeof esc_item);
    ++g.offer_seq;
    snprintf(json, sizeof json,
             "{\"type\":\"cloud.detail\",\"id\":%ld,\"service\":\"%s\","
             "\"item\":\"%s\"}",
             g.offer_seq, esc_service, esc_item);
    if (cloud_send(json, err, cap) != 0) {
        return -1;
    }
    g_cloud.pending = true;
    g_cloud.id = g.offer_seq;
    g_cloud.kind = kCloudAnswerCard;
    g_cloud.deadline = TickCount() + kCloudTimeoutTicks;
    return 0;
}

int now_wire_cloud_get(const char *service, const char *item,
                       const char *size, char *err, long cap)
{
    char json[320];
    char esc_service[48];
    char esc_item[144];

    now_json_escape(service, esc_service, sizeof esc_service);
    now_json_escape(item, esc_item, sizeof esc_item);
    ++g.offer_seq;
    /* Two whole templates, not one spliced one: size is a contract
       enum token (never escaped user text), and an ask with none must
       stay byte-identical to what every guest before the field sent —
       which also keeps both shapes readable by the conformance scan. */
    if (size != NULL && size[0] != '\0') {
        snprintf(json, sizeof json,
                 "{\"type\":\"cloud.get\",\"id\":%ld,\"service\":\"%s\","
                 "\"item\":\"%s\",\"size\":\"%s\"}",
                 g.offer_seq, esc_service, esc_item, size);
    } else {
        snprintf(json, sizeof json,
                 "{\"type\":\"cloud.get\",\"id\":%ld,\"service\":\"%s\","
                 "\"item\":\"%s\"}",
                 g.offer_seq, esc_service, esc_item);
    }
    if (cloud_send(json, err, cap) != 0) {
        return -1;
    }
    g_cloudget.pending = true;
    g_cloudget.id = g.offer_seq;
    g_cloudget.deadline = TickCount() + kCloudTimeoutTicks;
    return 0;
}

int now_wire_cloud_preview(const char *service, const char *item,
                           long max_w, long max_h, long depth,
                           char *err, long cap)
{
    char json[320];
    char esc_service[48];
    char esc_item[144];

    if (g_prev.pending || g_prev.receiving) {
        snprintf(err, (size_t)cap, "A preview is already on its way");
        return -1;
    }
    now_json_escape(service, esc_service, sizeof esc_service);
    now_json_escape(item, esc_item, sizeof esc_item);
    ++g.offer_seq;
    snprintf(json, sizeof json,
             "{\"type\":\"cloud.preview\",\"id\":%ld,\"service\":\"%s\","
             "\"item\":\"%s\",\"maxWidth\":%ld,\"maxHeight\":%ld,"
             "\"depth\":%ld}",
             g.offer_seq, esc_service, esc_item, max_w, max_h, depth);
    if (cloud_send(json, err, cap) != 0) {
        return -1;
    }
    g_prev.pending = true;
    g_prev.id = g.offer_seq;
    g_prev.deadline = TickCount() + kCloudTimeoutTicks;
    return 0;
}

/* preview.begin: allocate exactly what a COHERENT begin announces.
   A begin that fails validation for our id fails the preview; anyone
   else's begin is ignored, and its bulk falls through take_bulk_in's
   "nothing is expecting these" arm. */
static void preview_begin(const char *reply)
{
    CloudPreviewBegin begin;

    if (!g_prev.pending) {
        return;
    }
    if (!cloud_preview_parse_begin(reply, &begin)) {
        if (now_json_find_int(reply, "id", -1) == g_prev.id) {
            preview_fail("The preview arrived malformed");
        }
        return;
    }
    if (begin.id != g_prev.id) {
        return;
    }
    g_prev.buf = NewPtr(begin.bytes);
    if (g_prev.buf == NULL) {
        preview_fail("Not enough memory for the preview");
        return;
    }
    g_prev.pending = false;
    g_prev.receiving = true;
    g_prev.begin = begin;
    g_prev.received = 0;
    g_prev.deadline = TickCount() + kCloudTimeoutTicks;
}

/* preview.end: deliver ONCE, whole or not at all. The buffer stays
   wire-owned across the hook call and is gone when it returns — the
   view's job is one CopyBits into its own GWorld. */
static void preview_end(const char *reply)
{
    if (!g_prev.receiving
        || now_json_find_int(reply, "id", -1) != g_prev.id) {
        return;
    }
    if (!now_json_find_bool(reply, "ok", 0)
        || g_prev.received < g_prev.begin.bytes) {
        preview_fail("The preview did not arrive whole");
        return;
    }
    if (g_preview_hook != NULL) {
        NowCloudPreviewPixels pixels;

        pixels.width = g_prev.begin.width;
        pixels.height = g_prev.begin.height;
        pixels.depth = g_prev.begin.depth;
        pixels.row_bytes = g_prev.begin.row_bytes;
        pixels.bytes = g_prev.begin.bytes;
        pixels.pixels = (const unsigned char *)g_prev.buf;
        g_preview_hook(&pixels, NULL);
    }
    DisposePtr(g_prev.buf);
    g_prev.buf = NULL;
    g_prev.receiving = false;
}

/* The three typed answers share one gate: ours, and the kind we asked
   for. A listing that arrives while a card is pending is stale by
   definition — the ask that wanted it has been replaced. */
static void cloud_answer(int kind, const char *reply)
{
    if (!g_cloud.pending || g_cloud.kind != kind
        || now_json_find_int(reply, "id", -1) != g_cloud.id) {
        return;
    }
    g_cloud.pending = false;
    cloud_note(kind, reply);
}

static Boolean cloud_refused(const char *reply)
{
    char reason[96];
    long id = now_json_find_int(reply, "id", -1);

    if (g_cloud.pending && id == g_cloud.id) {
        g_cloud.pending = false;
    } else if (g_cloudget.pending && id == g_cloudget.id) {
        g_cloudget.pending = false;
    } else if (g_prev.pending && id == g_prev.id) {
        /* The preview's refusal goes to its own hook, and the one code
           a person can act on gets its honest wording HERE, where the
           code is still visible: busy means the lane is carrying a
           download, and the preview will work once it is done. */
        char code[24];

        code[0] = '\0';
        now_json_find_string(reply, "code", code, sizeof code);
        if (strcmp(code, "busy") == 0) {
            strcpy(reason, "Preview after the download");
        } else if (!now_json_find_text(reply, "reason", reason,
                                       sizeof reason)) {
            strcpy(reason, "the other Mac refused the preview");
        }
        preview_fail(reason);
        return true;
    } else {
        return false;
    }
    if (!now_json_find_text(reply, "reason", reason, sizeof reason)) {
        strcpy(reason, "the other Mac refused");
    }
    cloud_note(kCloudAnswerError, reason);
    return true;
}

static void service_cloud(void)
{
    if (g_cloud.pending && TickCount() > g_cloud.deadline) {
        g_cloud.pending = false;
        cloud_note(kCloudAnswerError, "no answer");
    }
    if (g_cloudget.pending && TickCount() > g_cloudget.deadline) {
        g_cloudget.pending = false;
        cloud_note(kCloudAnswerError, "no answer to the fetch");
    }
    if ((g_prev.pending || g_prev.receiving)
        && TickCount() > g_prev.deadline) {
        preview_fail("No answer to the preview");
    }
}

/* --- talking to the other machine's model --------------------------------
   Two pendings with two lifetimes. g_chatask is the cloud shape — one
   bounded question (catalog, or a reset's result), answered or timed
   out in 15 seconds. g_chat is the STREAMING turn: pending survives
   every delta and is cleared only by its chat.result, a rolling quiet
   deadline, or the link going away. The quiet deadline re-arms on
   every delta AND every status — status is what a host sends while its
   model runs a 30-second tool, so silence here means gone, not slow. */

enum {
    kChatAskTimeoutTicks = 60 * 15,   /* catalog / reset: the cloud bound */
    kChatQuietTimeoutTicks = 60 * 60  /* a turn: 60 s of total SILENCE */
};

static struct {
    Boolean pending;
    long id;
    int kind;                         /* the ChatAnswerKind expected */
    unsigned long deadline;
} g_chatask;

static struct {
    Boolean pending;
    long id;
    long next_seq;
    unsigned long quiet_deadline;
} g_chat;

static ConnChatNote g_chat_hook;

ConnChatNote conn_set_chat_note(ConnChatNote fn)
{
    ConnChatNote previous = g_chat_hook;

    g_chat_hook = fn;
    return previous;
}

static void chat_note(int kind, const char *reply)
{
    if (g_chat_hook != NULL) {
        g_chat_hook(kind, reply);
    }
}

Boolean now_wire_chat_turn_active(void)
{
    return g_chat.pending;
}

int now_wire_chat_providers(char *err, long cap)
{
    char json[96];

    ++g.offer_seq;
    snprintf(json, sizeof json,
             "{\"type\":\"chat.models\",\"id\":%ld}", g.offer_seq);
    if (cloud_send(json, err, cap) != 0) {
        return -1;
    }
    g_chatask.pending = true;
    g_chatask.id = g.offer_seq;
    g_chatask.kind = kChatAnswerProviders;
    g_chatask.deadline = TickCount() + kChatAskTimeoutTicks;
    return 0;
}

int now_wire_chat_model_page(const char *provider, long cursor,
                             char *err, long cap)
{
    char json[160];
    char esc_provider[64];

    now_json_escape(provider, esc_provider, sizeof esc_provider);
    ++g.offer_seq;
    /* cursor always written: 0 and absent mean the same start here,
       and one shape keeps this a single snprintf for the conformance
       reader. */
    snprintf(json, sizeof json,
             "{\"type\":\"chat.models\",\"id\":%ld,\"provider\":\"%s\","
             "\"cursor\":%ld}",
             g.offer_seq, esc_provider, cursor);
    if (cloud_send(json, err, cap) != 0) {
        return -1;
    }
    g_chatask.pending = true;
    g_chatask.id = g.offer_seq;
    g_chatask.kind = kChatAnswerModels;
    g_chatask.deadline = TickCount() + kChatAskTimeoutTicks;
    return 0;
}

int now_wire_chat_send(const char *ref, const char *prompt,
                       char *err, long cap)
{
    /* 512 raw escapes to at most 3072 plus envelope — the exec chunk
       arithmetic — so the frame buffer is the control cap itself. The
       cap's one statement is the contract's (ChatSend.prompt); refusing
       locally here costs nothing and saves the round trip. */
    char esc_ref[64];
    /* No pump occurs before both buffers have been consumed, and chat is
       one-in-flight by contract. Keep seven KiB off the event-loop stack. */
    static char json[kNowMaxControl];
    static char esc_prompt[512 * 6 + 1];

    if (g_chat.pending) {
        snprintf(err, (size_t)cap,
                 "an answer is still arriving - chat --stop first");
        return -1;
    }
    if (strlen(prompt) > 512) {
        snprintf(err, (size_t)cap, "prompt is over 512 bytes");
        return -1;
    }
    now_json_escape(ref, esc_ref, sizeof esc_ref);
    now_json_escape(prompt, esc_prompt, sizeof esc_prompt);
    ++g.offer_seq;
    snprintf(json, sizeof json,
             "{\"type\":\"chat.send\",\"id\":%ld,\"ref\":\"%s\","
             "\"prompt\":\"%s\"}",
             g.offer_seq, esc_ref, esc_prompt);
    if (cloud_send(json, err, cap) != 0) {
        return -1;
    }
    g_chat.pending = true;
    g_chat.id = g.offer_seq;
    g_chat.next_seq = 0;
    g_chat.quiet_deadline = TickCount() + kChatQuietTimeoutTicks;
    return 0;
}

int now_wire_chat_cancel(char *err, long cap)
{
    char json[96];

    if (!g_chat.pending) {
        snprintf(err, (size_t)cap, "nothing is streaming");
        return -1;
    }
    /* The turn's own id — cancel has no identity of its own, and the
       promised chat.result is the turn's terminal one. Pending stays
       set until it arrives; the quiet deadline covers a host that
       never answers. */
    snprintf(json, sizeof json,
             "{\"type\":\"chat.cancel\",\"id\":%ld}", g_chat.id);
    return cloud_send(json, err, cap);
}

int now_wire_chat_reset(char *err, long cap)
{
    char json[96];

    if (g_chat.pending) {
        snprintf(err, (size_t)cap,
                 "an answer is still arriving - chat --stop first");
        return -1;
    }
    ++g.offer_seq;
    snprintf(json, sizeof json,
             "{\"type\":\"chat.reset\",\"id\":%ld}", g.offer_seq);
    if (cloud_send(json, err, cap) != 0) {
        return -1;
    }
    g_chatask.pending = true;
    g_chatask.id = g.offer_seq;
    g_chatask.kind = kChatAnswerResult;
    g_chatask.deadline = TickCount() + kChatAskTimeoutTicks;
    return 0;
}

static void chat_catalog_answer(const char *reply)
{
    int kind;

    /* Which shape arrived is decided by what WE asked - the ask's kind
       rode along in the pending, so a providers listing and a models
       page cannot be mistaken for one another. */
    if (!g_chatask.pending
        || (g_chatask.kind != kChatAnswerProviders
            && g_chatask.kind != kChatAnswerModels)
        || now_json_find_int(reply, "id", -1) != g_chatask.id) {
        return;
    }
    kind = g_chatask.kind;
    g_chatask.pending = false;
    chat_note(kind, reply);
}

static void chat_delta_answer(const char *reply)
{
    long seq;

    if (!g_chat.pending
        || now_json_find_int(reply, "id", -1) != g_chat.id) {
        return;                       /* stale by definition */
    }
    g_chat.quiet_deadline = TickCount() + kChatQuietTimeoutTicks;
    seq = now_json_find_int(reply, "seq", -1);
    if (seq != g_chat.next_seq) {
        /* A gap is surfaced, never papered over — but it does not end
           the turn: the text that follows is still worth reading. */
        now_log(kLogWarn, "chat", "delta seq %ld, expected %ld",
                seq, g_chat.next_seq);
        chat_note(kChatAnswerGap, "part of the answer went missing");
        g_chat.next_seq = seq;
    }
    ++g_chat.next_seq;
    chat_note(kChatAnswerDelta, reply);
}

static void chat_status_answer(const char *reply)
{
    if (!g_chat.pending
        || now_json_find_int(reply, "id", -1) != g_chat.id) {
        return;
    }
    g_chat.quiet_deadline = TickCount() + kChatQuietTimeoutTicks;
    chat_note(kChatAnswerStatus, reply);
}

static void chat_result_answer(const char *reply)
{
    long id = now_json_find_int(reply, "id", -1);

    if (g_chat.pending && id == g_chat.id) {
        g_chat.pending = false;
        chat_note(kChatAnswerResult, reply);
        return;
    }
    if (g_chatask.pending && g_chatask.kind == kChatAnswerResult
        && id == g_chatask.id) {
        g_chatask.pending = false;
        chat_note(kChatAnswerResult, reply);
    }
    /* Unmatched: stale by definition, like a cloud answer whose ask
       has been replaced. */
}

static void service_chat(void)
{
    if (g_chatask.pending && TickCount() > g_chatask.deadline) {
        g_chatask.pending = false;
        chat_note(kChatAnswerError, "no answer");
    }
    if (g_chat.pending && TickCount() > g_chat.quiet_deadline) {
        char json[96];

        /* Declared dead for THIS turn after a minute of total silence.
           Best-effort cancel so a host that is merely wedged does not
           keep streaming into a turn nobody is reading. */
        snprintf(json, sizeof json,
                 "{\"type\":\"chat.cancel\",\"id\":%ld}", g_chat.id);
        send_control(json);
        g_chat.pending = false;
        chat_note(kChatAnswerError, "no answer for a minute - gave up");
    }
}

/* A leaving link ends the turn the way it ends a transfer: promptly
   and with the reason, not by letting a 60-second deadline pretend the
   host is thinking. Idle-safe, touches no wire. */
static void chat_drop(void)
{
    if (g_chat.pending) {
        g_chat.pending = false;
        chat_note(kChatAnswerError, "connection lost");
    }
    if (g_chatask.pending) {
        g_chatask.pending = false;
        chat_note(kChatAnswerError, "connection lost");
    }
}

/* --- asking the HOST to show one of its own windows ---------------------
   One direction by definition, the cloud and chat rule: the subject is
   a surface on the modern machine, which this one does not have.

   One ask at a time and no queue. A second press while one is in
   flight is refused locally rather than stacking, because the answer a
   person is waiting for is "did the window come up", and two asks can
   only produce one useful answer. The deadline is short: the host does
   no work worth waiting on — it opens a window and replies — so
   silence past it means a host that predates the family, which is a
   status line rather than an error. */

enum { kHostShowTimeoutTicks = 60 * 8 };

static struct {
    Boolean pending;
    long id;
    unsigned long deadline;
} g_hostshow;

static ConnHostShowNote g_hostshow_hook;

ConnHostShowNote conn_set_host_show_note(ConnHostShowNote fn)
{
    ConnHostShowNote previous = g_hostshow_hook;

    g_hostshow_hook = fn;
    return previous;
}

Boolean now_wire_host_show_pending(void)
{
    return g_hostshow.pending;
}

/* Settles the ask exactly once. Every path out of the family comes
   through here — the answer, the deadline and the dropped link — so
   there is one place that can clear `pending`, and no path that
   forgets to. */
static void host_show_settle(Boolean ok, const char *reason)
{
    if (!g_hostshow.pending) {
        return;
    }
    g_hostshow.pending = false;
    if (g_hostshow_hook != NULL) {
        g_hostshow_hook(ok, reason);
    }
}

static void host_show_drop(void)
{
    host_show_settle(false, "Connection lost.");
}

int now_wire_host_show(const char *surface, char *err, long cap)
{
    char json[128];
    char esc[48];

    if (g_hostshow.pending) {
        snprintf(err, (size_t)cap, "Already asking");
        return -1;
    }
    now_json_escape(surface, esc, sizeof esc);
    ++g.offer_seq;
    snprintf(json, sizeof json,
             "{\"type\":\"host.show\",\"id\":%ld,\"surface\":\"%s\"}",
             g.offer_seq, esc);
    if (cloud_send(json, err, cap) != 0) {
        return -1;
    }
    g_hostshow.pending = true;
    g_hostshow.id = g.offer_seq;
    g_hostshow.deadline = TickCount() + kHostShowTimeoutTicks;
    return 0;
}

/* The host's answer. `reason` is the host's own sentence and is shown
   whichever way `ok` went — a refusal a person cannot read is a button
   that did nothing. */
static void host_shown_answer(const char *reply)
{
    char reason[128];
    Boolean ok;

    if (!g_hostshow.pending
        || now_json_find_int(reply, "id", -1) != g_hostshow.id) {
        return;
    }
    ok = json_find_flag(reply, "ok", 0) != 0;
    if (!now_json_find_string(reply, "reason", reason, sizeof reason)) {
        snprintf(reason, sizeof reason,
                 ok ? "The host showed it." : "The host refused.");
    }
    host_show_settle(ok, reason);
}

static void service_host_show(void)
{
    if (g_hostshow.pending && TickCount() > g_hostshow.deadline) {
        host_show_settle(false, "No answer - that Mac may be too old.");
    }
}

/* --- pulling a file FROM the other machine -------------------------------
   The same bytes as an inbound push, asked for rather than offered, so
   the receiving machinery is the same and only the destination differs:
   a pulled file lands in the downloads folder, outside the share. What
   a person fetches is theirs, not something the other machine can then
   reach back into. */

enum { kGetTimeoutTicks = 60 * 30 };

static struct {
    Boolean pending;                  /* asked; no bytes yet */
    Boolean receiving;                /* file.begin seen; writing */
    long id;
    long expected;
    char name[32];
    char dest_name[64];               /* the folder this pull actually
                                          landed in, resolved once at
                                          get_begin so get_end's outcome
                                          names the same place */
    FileReceive rx;
    unsigned long deadline;
} g_get;

/* Where a pull should land, when the person chose somewhere other than
   the downloads folder. Guest-side only, mirroring g_cget_dest below
   for the OTHER delivery path (a cloud.get's answering offer): unset
   means downloads, byte-identical to every pull before this existed. */
static struct {
    Boolean set;
    short vref;
    long dir;
} g_get_dest;

void now_wire_get_destination(Boolean use, short vref, long dir)
{
    g_get_dest.set = use;
    g_get_dest.vref = vref;
    g_get_dest.dir = dir;
}

Boolean now_wire_get_destination_get(short *vref, long *dir)
{
    if (!g_get_dest.set) {
        return false;
    }
    if (vref != NULL) {
        *vref = g_get_dest.vref;
    }
    if (dir != NULL) {
        *dir = g_get_dest.dir;
    }
    return true;
}

static ConnGetNote g_get_note;

void conn_set_get_note(ConnGetNote fn)
{
    g_get_note = fn;
}

static void get_note(const char *line)
{
    if (g_get_note != NULL) {
        g_get_note(line);
    }
}

static void get_cleanup(Boolean keep_file)
{
    if (g_get.receiving && !keep_file) {
        now_files_receive_abort(&g_get.rx);
    }
    g_get.pending = false;
    g_get.receiving = false;
}

/* Stop the pull in flight, from this side. Two halves, in this order:
   tell the other Mac to stop pushing, then free this side. Local-only
   would leave the host filling a lane one transfer wide with a file
   nobody is writing; wire-only would leave an open temp fork here.

   send_control is best effort on purpose - a stop pressed on a dead
   wire still has to free this side, and get_cleanup(false) is the same
   teardown the timeout, the refusal and a failed file.end already use.
   A pull is never resumable (get_begin passes resume_token NULL), so
   the temp is deleted and nothing appears under the real name. */
int now_wire_get_cancel(char *err, long cap)
{
    char json[64];

    if (!g_get.pending && !g_get.receiving) {
        snprintf(err, (size_t)cap, "Nothing is being transferred");
        return -1;
    }
    /* `transfer`, not `id`: contract/asyncapi.yaml FileCancel requires
       {type, transfer} with additionalProperties false. */
    snprintf(json, sizeof json,
             "{\"type\":\"file.cancel\",\"transfer\":%ld}", g_get.id);
    (void)send_control(json);
    now_log(kLogInfo, "get", "#%ld stopped at %ld bytes by the person",
            g_get.id, g_get.receiving ? g_get.rx.received : 0);
    get_cleanup(false);
    return 0;
}

Boolean now_wire_get_active(long *received, long *expected,
                            WireGetPhase *phase)
{
    if (!g_get.pending && !g_get.receiving) {
        if (phase != NULL) {
            *phase = kWireGetNone;
        }
        return false;
    }
    if (received != NULL) {
        *received = g_get.receiving ? g_get.rx.received : 0;
    }
    if (expected != NULL) {
        *expected = g_get.expected;
    }
    if (phase != NULL) {
        /* The distinction the counts could not carry: pending is a
           question with no answer, receiving is an open file. */
        *phase = g_get.receiving ? kWireGetReceiving : kWireGetAsked;
    }
    return true;
}

int now_wire_get_host(const char *path, const char *name, char *err, long cap)
{
    char json[720];
    char esc[600];

    if (g.phase != kConnConnected) {
        snprintf(err, (size_t)cap, "Not connected");
        return -1;
    }
    if (g_get.pending || g_get.receiving || wire_busy()) {
        snprintf(err, (size_t)cap, "A transfer is already in flight");
        return -1;
    }
    now_json_escape(path, esc, sizeof esc);
    ++g.offer_seq;
    g_get.id = g.offer_seq;
    g_get.expected = 0;
    snprintf(g_get.name, sizeof g_get.name, "%.31s", name != NULL ? name : "");
    snprintf(json, sizeof json,
             "{\"type\":\"file.get\",\"id\":%ld,\"path\":\"%s\"}",
             g_get.id, esc);
    if (!send_control(json)) {
        snprintf(err, (size_t)cap, "Connection lost");
        return -1;
    }
    g_get.pending = true;
    g_get.deadline = TickCount() + kGetTimeoutTicks;
    return 0;
}

/* The answer: bytes are coming. Opening the file here rather than at
   the end means a big file never has to be held in memory - the same
   rule an inbound push already follows. */
static void get_begin(const char *reply)
{
    char container_arg[16];
    char type[8], creator[8];
    short vref;
    long dir;
    FileContainer container = kContainerData;
    OSType file_type = 0, creator_code = 0;
    char name[64];
    char line[128];
    int rc;

    if (!g_get.pending || now_json_find_int(reply, "id", -1) != g_get.id) {
        return;
    }
    g_get.pending = false;
    g_get.expected = now_json_find_int(reply, "bytes", 0);

    /* The sender names the file; it has already made the name one this
       machine can hold. Ours was only a guess from the listing. */
    if (now_json_find_text(reply, "name", name, sizeof name)
        && name[0] != '\0') {
        snprintf(g_get.name, sizeof g_get.name, "%.31s", name);
    }
    if (now_json_find_string(reply, "container", container_arg,
                             sizeof container_arg)
        && strcmp(container_arg, "macbinary") == 0) {
        container = kContainerMacBinary;
    }
    type[0] = '\0';
    creator[0] = '\0';
    now_json_find_string(reply, "fileType", type, sizeof type);
    now_json_find_string(reply, "creator", creator, sizeof creator);
    if (strlen(type) == 4) {
        memcpy(&file_type, type, 4);
    }
    if (strlen(creator) == 4) {
        memcpy(&creator_code, creator, 4);
    }

    if (g_get_dest.set) {
        vref = g_get_dest.vref;
        dir = g_get_dest.dir;
    } else if (now_files_downloads(&vref, &dir) != kFilesOK) {
        get_cleanup(false);
        get_note("Cannot find the downloads folder");
        return;
    }
    /* Resolved once, here, so a later "it landed in Y" cannot disagree
       with where the bytes actually went even if the chooser is used
       again mid-transfer. */
    if (g_get_dest.set) {
        if (!now_files_dir_path(vref, dir, g_get.dest_name,
                                sizeof g_get.dest_name)) {
            strcpy(g_get.dest_name, "the chosen folder");
        } else {
            /* The last named segment, downloads_name's own shape: a
               status line is not the place for a full path. */
            long n = (long)strlen(g_get.dest_name);
            char *last;

            while (n > 0 && g_get.dest_name[n - 1] == ':') {
                g_get.dest_name[--n] = '\0';
            }
            last = strrchr(g_get.dest_name, ':');
            if (last != NULL && last[1] != '\0') {
                memmove(g_get.dest_name, last + 1, strlen(last + 1) + 1);
            }
        }
    } else {
        now_files_downloads_name(g_get.dest_name, sizeof g_get.dest_name);
    }
    /* No resume token on a pull yet: resuming is the sender's protocol
       and this side has never been the sender. A pull starts at zero. */
    /* Unsigned: see now_json_find_u32's header comment. */
    rc = now_files_receive_begin_at(vref, dir, g_get.name, container,
                                    g_get.expected, file_type, creator_code,
                                    now_json_find_u32(
                                        reply, "modified", 0),
                                    false, NULL, 0, &g_get.rx);
    if (rc == kFilesExists) {
        /* Not an error and not a silent overwrite: the file is already
           there, and this machine keeps what it has. */
        get_cleanup(false);
        snprintf(line, sizeof line, "%.31s is already in %.48s",
                 g_get.name, g_get.dest_name);
        get_note(line);
        return;
    }
    if (rc != kFilesOK) {
        get_cleanup(false);
        get_note(rc == kFilesTooBig ? "Not enough room on the disk"
                                    : "Could not create the file");
        return;
    }
    g_get.receiving = true;
    g_get.deadline = TickCount() + kGetTimeoutTicks;
    now_log(kLogInfo, "get", "#%ld %.31s, %ld bytes, into %s", g_get.id,
            g_get.name, g_get.expected, g_get.dest_name);
    snprintf(line, sizeof line, "Receiving %.31s into %.48s...", g_get.name,
             g_get.dest_name);
    get_note(line);
}

/* file.end for a pull: rename into place, or throw away the part. */
static void get_end(const char *reply)
{
    char line[128];

    if (!g_get.receiving || now_json_find_int(reply, "id", -1) != g_get.id) {
        return;
    }
    if (!now_json_find_bool(reply, "ok", 0)) {
        now_log(kLogWarn, "get", "#%ld ended early at %ld of %ld bytes",
                g_get.id, g_get.rx.received, g_get.expected);
        get_cleanup(false);
        get_note("The other Mac stopped sending");
        return;
    }
    if (now_files_receive_finish(&g_get.rx) != kFilesOK) {
        get_cleanup(false);
        get_note("Could not finish writing the file");
        return;
    }
    now_log(kLogInfo, "get", "#%ld %.31s complete, %ld bytes, into %s",
            g_get.id, g_get.name, g_get.rx.received, g_get.dest_name);
    /* dest_name was resolved once at get_begin against whatever the
       destination was at the time; get_cleanup below only touches
       pending/receiving, so it is still the folder these bytes landed
       in. */
    snprintf(line, sizeof line, "Received %.31s - it is in %.48s",
             g_get.name, g_get.dest_name);
    get_cleanup(true);
    get_note(line);
}

static void service_get(void)
{
    if ((g_get.pending || g_get.receiving)
        && TickCount() > g_get.deadline) {
        get_cleanup(false);
        get_note("The other Mac stopped answering");
    }
}

/* --- sending a file to the host -----------------------------------------
   The mirror image of receiving one, and deliberately the same shape:
   we offer, the host answers, and only then do bytes move. The guest
   sends what a human picked in a standard dialog, so the file need not
   be anywhere near the share — sending is not browsing. */

enum { kSendTimeoutTicks = 60 * 20 };

static struct {
    Boolean active;                   /* offered, or sending */
    Boolean sending;                  /* the host said yes; bytes moving */
    /* The host says something is already there. The staged bytes stay
       put while a person decides; wire code cannot ask (pump.h), so it
       raises this and the event loop does the asking. */
    Boolean awaiting_confirm;
    char occupied_by[64];             /* what the host called the clash */
    long id;
    FileStage stage;
    char name[32];                    /* kept past the stage handoff */
    long total;
    long received;                    /* host-confirmed, when it reports */
    Boolean receiving_reports;
    long chunk;
    short pace_ms;
    unsigned long deadline;
} g_send;

static Boolean send_owns_transfer(long id)
{
    return g_send.active && g_send.sending && g_send.id == id;
}

SendPhase now_wire_send_state(long *sent, long *total,
                              char *name, long name_cap)
{
    if (!g_send.active) {
        return kSendNothing;
    }
    if (name != NULL && name_cap > 0) {
        strncpy(name, g_send.name, (size_t)name_cap - 1);
        name[name_cap - 1] = '\0';
    }
    if (total != NULL) {
        *total = g_send.total;
    }
    if (sent != NULL) {
        *sent = g_send.receiving_reports ? g_send.received
            : ((g_send.sending && g_xfer.active && g_xfer.id == g_send.id)
                ? g_xfer.offset : 0);
    }
    return g_send.sending ? kSendSending : kSendOffering;
}

static void send_cleanup(void)
{
    now_files_stage_dispose(&g_send.stage);
    g_send.active = false;
    g_send.sending = false;
    g_send.awaiting_confirm = false;
}

int now_wire_send_file(const FSSpec *spec, char *err, long cap)
{
    NowPrefs prefs;
    FileStage stage;
    char peer[40];
    char line[96];
    int rc;

    if (g.phase != kConnConnected) {
        snprintf(err, (size_t)cap, "Not connected");
        return -1;
    }
    if (wire_busy()) {
        snprintf(err, (size_t)cap, "A transfer is already in flight");
        return -1;
    }
    rc = now_files_stage_spec(spec, kContainerAuto, &stage);
    if (rc == kFilesNotAFolder) {
        snprintf(err, (size_t)cap, "Folders cannot be sent yet");
        return -1;
    }
    if (rc != kFilesOK) {
        snprintf(err, (size_t)cap, "Could not read that file");
        return -1;
    }

    now_prefs_load(&prefs);
    g_send.chunk = (long)prefs.chunk_kb * 1024;
    if (g_send.chunk < 1024 || g_send.chunk > kNowMaxPayload) {
        g_send.chunk = 8192;
    }
    g_send.pace_ms = prefs.pace_ms;
    g_send.stage = stage;
    strncpy(g_send.name, stage.name, sizeof g_send.name - 1);
    g_send.name[sizeof g_send.name - 1] = '\0';
    g_send.total = stage.total_bytes;
    g_send.received = 0;
    g_send.receiving_reports = false;
    g_send.sending = false;
    ++g.offer_seq;
    g_send.id = g.offer_seq;
    if (!send_offer(false)) {
        send_cleanup();
        snprintf(err, (size_t)cap, "Connection lost");
        return -1;
    }
    g_send.active = true;
    g_send.deadline = TickCount() + kSendTimeoutTicks;
    now_log(kLogInfo, "send", "#%ld offering %.31s, %ld bytes", g_send.id,
            stage.name, stage.total_bytes);
    conn_peer_label(peer, sizeof peer);
    snprintf(line, sizeof line, "Asking %.20s to accept %.31s...",
             peer, stage.name);
    note_file(line);
    return 0;
}

/* The offer itself. Sent once to ask, and again with overwrite set if
   the person says to replace what is already there. */
static Boolean send_offer(Boolean overwrite)
{
    char json[512];
    const FileStage stage = g_send.stage;

    {
        char type[8], creator[8];
        char esc_name[200], esc_type[40], esc_creator[40];

        memcpy(type, &stage.file_type, 4);
        type[4] = '\0';
        memcpy(creator, &stage.creator, 4);
        creator[4] = '\0';
        now_json_escape(stage.name, esc_name, sizeof esc_name);
        now_json_escape(type, esc_type, sizeof esc_type);
        now_json_escape(creator, esc_creator, sizeof esc_creator);
        /* path is REQUIRED by the contract — "" means the root of the
           receiver's share. Leaving it out cost a dropped connection:
           the host could not decode the frame at all. */
        snprintf(json, sizeof json,
                 "{\"type\":\"file.offer\",\"id\":%ld,\"name\":\"%s\","
                 "\"path\":\"\",\"container\":\"%s\",\"bytes\":%ld,"
                 "\"fileType\":\"%s\",\"creator\":\"%s\","
                 "\"modified\":%lu%s}",
                 g_send.id, esc_name,
                 stage.container == kContainerMacBinary ? "macbinary" : "data",
                 stage.total_bytes, esc_type, esc_creator, stage.modified,
                 overwrite ? ",\"overwrite\":true" : "");
    }
    return send_control(json);
}

/* The host said yes: announce the transfer, then hand the staged bytes
   to the same machine a pull uses. */
static void send_accepted(const char *reply)
{
    char json[512];
    unsigned short xfer;

    if (!g_send.active || now_json_find_int(reply, "id", -1) != g_send.id) {
        return;
    }
    xfer = next_xfer();
    {
        char esc_name[200];

        /* name and container are REQUIRED here as well; a frame the
           receiver cannot decode costs the whole connection. */
        now_json_escape(g_send.name, esc_name, sizeof esc_name);
        snprintf(json, sizeof json,
                 "{\"type\":\"file.begin\",\"id\":%ld,\"transfer\":%u,"
                 "\"name\":\"%s\",\"container\":\"%s\",\"bytes\":%ld}",
                 g_send.id, xfer, esc_name,
                 g_send.stage.container == kContainerMacBinary
                     ? "macbinary" : "data",
                 g_send.total);
    }
    if (!send_control(json)) {
        send_cleanup();
        return;
    }
    if (!arm_file_transfer(g_send.id, xfer, &g_send.stage,
                           g_send.chunk, g_send.pace_ms)) {
        file_start_failed(g_send.id, xfer);
        send_cleanup();
        note_file("Could not start the transfer");
        return;
    }
    now_files_stage_dispose(&g_send.stage);
    /* active stays true: the send is not over until the host's receipt,
       and until then the panel has something to report. */
    g_send.sending = true;
    {
        char line[96];
        char peer[40];

        conn_peer_label(peer, sizeof peer);
        snprintf(line, sizeof line, "Sending %.31s to %.20s...",
                 g_send.name, peer);
        note_file(line);
    }
}

static void send_refused(const char *reply)
{
    char reason[64];
    char code[32];
    char line[96];
    char peer[40];

    if (!g_send.active || now_json_find_int(reply, "id", -1) != g_send.id) {
        return;
    }
    conn_peer_label(peer, sizeof peer);

    /* "Something is already there" is a question for a person, not a
       failure. The staged bytes stay exactly where they are; the event
       loop asks, and answers by sending the same offer again. */
    code[0] = '\0';
    now_json_find_string(reply, "code", code, sizeof code);
    if (strcmp(code, "exists") == 0 && !g_send.sending) {
        g_send.awaiting_confirm = true;
        snprintf(g_send.occupied_by, sizeof g_send.occupied_by, "%.63s",
                 g_send.name);
        snprintf(line, sizeof line, "%.20s already has %.31s", peer,
                 g_send.name);
        note_file(line);
        return;
    }
    send_cleanup();
    if (now_json_find_string(reply, "reason", reason, sizeof reason)) {
        snprintf(line, sizeof line, "%.30s declined: %.50s", peer, reason);
    } else {
        snprintf(line, sizeof line, "%s declined the file", peer);
    }
    note_file(line);
}

/* The host's receipt. A send is not finished until the file exists at
   the other end, so this — not the last byte — is what we report. */
static void send_done(const char *reply)
{
    char reason[80];
    char line[112];
    char peer[40];

    if (!g_send.active) {
        return;                       /* not ours */
    }
    send_cleanup();
    conn_peer_label(peer, sizeof peer);
    /* "ok" is a BOOLEAN. now_json_find_int is strtol, and strtol on
       "true" is 0 — so reading it as an int reports every successful
       send as a failure, which is exactly what it did. */
    if (now_json_find_bool(reply, "ok", 0)) {
        snprintf(line, sizeof line, "Sent to %s", peer);
    } else if (now_json_find_string(reply, "reason", reason, sizeof reason)) {
        snprintf(line, sizeof line, "%.30s could not save it: %.60s",
                 peer, reason);
    } else {
        snprintf(line, sizeof line, "%s could not save it", peer);
    }
    note_file(line);
}

/* What the event loop needs to know to ask. Returns false when nothing
   is waiting on a person. */
Boolean now_wire_send_pending_replace(char *name, long cap)
{
    if (!g_send.awaiting_confirm) {
        return false;
    }
    if (name != NULL && cap > 0) {
        strncpy(name, g_send.occupied_by, (size_t)cap - 1);
        name[cap - 1] = '\0';
    }
    return true;
}

/* The answer. Replacing re-sends the SAME staged bytes with overwrite
   set, so nothing is read off the disk twice and the file cannot have
   changed underneath the question. */
void now_wire_send_resolve_replace(Boolean replace)
{
    char line[96];
    char peer[40];

    if (!g_send.awaiting_confirm) {
        return;
    }
    g_send.awaiting_confirm = false;
    conn_peer_label(peer, sizeof peer);
    if (!replace) {
        send_cleanup();
        note_file("Not sent");
        return;
    }
    if (!send_offer(true)) {
        send_cleanup();
        note_file("Connection lost");
        return;
    }
    g_send.deadline = TickCount() + kSendTimeoutTicks;
    snprintf(line, sizeof line, "Replacing %.31s on %.20s...",
             g_send.name, peer);
    note_file(line);
}

static void service_send(void)
{
    /* Only the ANSWER is on a clock. Once bytes are moving the transfer
       machine owns the deadline, and a slow file is not a dead host. */
    if (g_send.active && !g_send.sending && !g_send.awaiting_confirm
        && TickCount() > g_send.deadline) {
        char peer[40];
        char line[96];

        send_cleanup();
        conn_peer_label(peer, sizeof peer);
        snprintf(line, sizeof line, "%s did not answer", peer);
        note_file(line);
    }
}

/* --- receiving a put ----------------------------------------------------
   The host offers, the guest answers without prompting anyone, and the
   bytes then stream to disk as they arrive. Nothing is buffered: the
   app partition is smaller than the files people will send. */

static struct {
    Boolean active;                   /* accepted; bytes may arrive */
    long id;
    long reported;                    /* bytes announced with file.progress */
    FileReceive rx;
    /* The offer, kept because file.begin — not file.offer — is what
       finally says where the stream starts. The guest opens optimistically
       at the offset it reported as `have`, and a sender that starts
       somewhere else instead makes it reopen. */
    char path[224];
    char name[64];
    char token[96];
    FileContainer container;
    long bytes;
    OSType file_type, creator;
    unsigned long modified;
    Boolean create_parents;
    Boolean overwrite;
    Boolean from_cloud_get;           /* the offer answered our cloud.get */
    Boolean at_dest;                  /* landing at the chosen folder,
                                         not through the share path */
    Boolean at_candidate;             /* private Development candidate */
    short dest_vref;
    long dest_dir;
    Boolean update;
    NowUpdateComponent update_component;
    NowSHA256 update_sha;
    char update_sha256[65];
    Boolean mirror_drop;
    NowMirrorFileTarget drop_target;
} g_put;

/* A nested target is copied out before flat lookup. Without that boundary,
   mirrorDrop.name and file.offer.name are the same key to this guest's
   allocation-free scanner, and whichever appeared first would silently win. */
static int mirror_file_target(const char *request, const char *key,
                              Boolean source, NowMirrorFileTarget *out)
{
    const char *value = now_json_value(request, key);
    char object[512];
    char kind[40];
    char psn[48];
    char creator[8];
    unsigned long hi, lo;
    char trailing;

    memset(out, 0, sizeof *out);
    if (value == NULL) return 0;
    if (now_json_next_object(value, object, sizeof object) == NULL
        || !now_json_find_string(object, "kind", kind, sizeof kind)) {
        return -1;
    }
    now_json_find_text(object, "name", out->name, sizeof out->name);
    now_json_find_text(object, "path", out->path, sizeof out->path);
    if (source) {
        if (out->name[0] == '\0') return -1;
        if (strcmp(kind, "desktop") == 0) {
            out->kind = kNowMirrorFileDesktop;
        } else if (strcmp(kind, "finder-window") == 0
                   && out->path[0] != '\0') {
            out->kind = kNowMirrorFileFinderWindow;
        } else {
            return -1;
        }
        return 1;
    }
    if (strcmp(kind, "desktop") == 0) {
        out->kind = kNowMirrorFileDesktop;
    } else if (strcmp(kind, "finder-folder") == 0
               && out->path[0] != '\0') {
        out->kind = kNowMirrorFileFinderFolder;
    } else if (strcmp(kind, "application-process") == 0
               && now_json_find_string(object, "psn", psn, sizeof psn)
               && sscanf(psn, "%lu:%lu%c", &hi, &lo, &trailing) == 2) {
        out->kind = kNowMirrorFileApplicationProcess;
        out->psn.highLongOfPSN = (long)hi;
        out->psn.lowLongOfPSN = (unsigned long)lo;
    } else if (strcmp(kind, "application-creator") == 0
               && now_json_find_string(object, "creator", creator,
                                       sizeof creator)
               && strlen(creator) == 4) {
        out->kind = kNowMirrorFileApplicationCreator;
        memcpy(&out->creator, creator, 4);
    } else {
        return -1;
    }
    return 1;
}

static Boolean wire_busy(void)
{
    /* g_prev.receiving counts: the bulk lane is one transfer wide, and
       a preview mid-arrival holds it exactly as a file would. */
    return g_stream.active || g_xfer.active || g_offer.active
        || g_send.active || g_put.active || g_prev.receiving;
}

int now_wire_update_request(NowUpdateComponent component,
                            Boolean allow_unsigned,
                            char *err, long cap)
{
    NowUpdateOffer offer;
    char json[256];

    if (g.phase != kConnConnected) {
        snprintf(err, (size_t)cap, "Connect to the other Mac first");
        return -1;
    }
    if (!now_update_offer_get(component, &offer)) {
        snprintf(err, (size_t)cap, "The other Mac has no %s update",
                 now_update_component_name(component));
        return -1;
    }
    if (!offer.signed_artifact && !allow_unsigned) {
        snprintf(err, (size_t)cap,
                 "Unsigned updates require confirmation in Connections");
        return -1;
    }
    if (g_update.pending || wire_busy()) {
        snprintf(err, (size_t)cap, "Another transfer is in progress");
        return -1;
    }
    ++g.offer_seq;
    g_update.pending = true;
    g_update.id = g.offer_seq;
    g_update.component = component;
    snprintf(g_update.build, sizeof g_update.build, "%s", offer.build);
    snprintf(json, sizeof json,
             "{\"type\":\"update.request\",\"id\":%ld,"
             "\"component\":\"%s\",\"build\":\"%s\","
             "\"sha256\":\"%s\"}",
             g_update.id, now_update_component_name(component), offer.build,
             offer.sha256);
    if (!send_control(json)) {
        g_update.pending = false;
        snprintf(err, (size_t)cap, "Could not send the update request");
        return -1;
    }
    return 0;
}

Boolean now_wire_update_pending(NowUpdateComponent *component)
{
    if (g_update.pending && component != NULL) *component = g_update.component;
    return g_update.pending;
}

Boolean now_wire_update_restart_required(void)
{
    return g_update.restart_required;
}

Boolean now_wire_update_relaunch_required(void)
{
    return g_update.relaunch_required;
}

/* The inbound receive, read-only, for whoever wants to draw it moving
   — now_wire_get_active's shape, one lane over: that one watches a
   pull (file.get), this one watches an offered receive (file.offer),
   which is the lane a cloud.get's answer rides. Every out-parameter is
   optional. `cloud_get` says whether this receive answers our own
   cloud.get (correlated by arrival in serve_file_offer), so a page can
   show ITS download and ignore an unrelated push. */
Boolean now_wire_receive_active(long *received, long *expected,
                                Boolean *cloud_get,
                                char *name, long name_cap)
{
    if (!g_put.active) {
        return false;
    }
    if (received != NULL) {
        *received = g_put.rx.received;
    }
    if (expected != NULL) {
        *expected = g_put.bytes;
    }
    if (cloud_get != NULL) {
        *cloud_get = g_put.from_cloud_get;
    }
    if (name != NULL && name_cap > 0) {
        snprintf(name, (size_t)name_cap, "%s", g_put.name);
    }
    return true;
}

/* A CRC-32 is a 32-bit unsigned value and routinely has its top bit
   set, which now_json_find_int cannot carry: it is strtol into a long,
   and long is 32 bits on this toolchain, so every CRC above 2^31-1
   saturates at LONG_MAX. Left alone, roughly half of all transfers
   would compare a real checksum against 0x7FFFFFFF and be declared
   corrupt. Parsed here as unsigned instead.

   A leading minus is folded rather than rejected: an encoder that
   serialises the value as a signed int32 writes -889275714 for
   0xCAFEBABE, and that is the same 32 bits, not a different format. A
   present-but-unparseable value reads as absent — "unchecked" is the
   honest answer there, and far better than a false "corrupt". */
static unsigned long json_find_u32(const char *json, const char *key,
                                   Boolean *found)
{
    const char *p = now_json_value(json, key);
    unsigned long v = 0;
    Boolean negative = false;

    *found = false;
    if (p == NULL) {
        return 0;
    }
    if (*p == '-') {
        negative = true;
        ++p;
    }
    if (*p < '0' || *p > '9') {
        return 0;
    }
    while (*p >= '0' && *p <= '9') {
        v = (v * 10UL + (unsigned long)(*p - '0')) & 0xFFFFFFFFUL;
        ++p;
    }
    *found = true;
    return negative ? (0UL - v) & 0xFFFFFFFFUL : v;
}

/* How often the guest says where it has got to. The write batch is the
   natural cadence — one report per flush — and on a 2.7 MB file that is
   about 85 control frames across several minutes, which is nothing next
   to the bulk stream they describe. */
/* How often the guest tells the host what it has taken.
 *
 * This is not only a progress bar: the host clocks its sender on these
 * reports and will not run more than a few of them ahead. So the step is
 * flow control, and a coarse one caps how tightly the sender can be
 * bounded — at 32 KB the host could not go below a 64 KB window without
 * deadlocking (it parks, then waits for a report needing bytes it has
 * decided not to send). Matching the host's 8 KB bulk frame means one
 * report per frame, which is what makes a ~24 KB in-flight bound work.
 *
 * Reports stay advisory and are still dropped when the control queue is
 * busy; `received` is cumulative, so a skipped one costs nothing. */
enum { kPutProgressStep = 8 * 1024 };

/* Tells the host what has actually landed. The sender cannot know this:
   its own completion fires when the local socket accepts a chunk, which
   on this link runs minutes ahead of the machine receiving it — the bar
   reached 100% with a third of the file delivered, and the put watchdog
   was being fed by that same lie, so a stalled guest looked healthy.

   Advisory on purpose. The control queue is eight slots deep and shared
   with the messages that carry meaning (pongs, file.done); progress is
   the one thing here that may be dropped, so it yields rather than
   crowding them out, and a skipped report costs the host nothing but a
   coarser bar. */
static void put_report_progress(Boolean force)
{
    char json[128];

    if (!force && g_ctlq.count >= kCtlQueueSlots / 2) {
        return;                       /* real traffic first */
    }
    g_put.reported = g_put.rx.received;
    snprintf(json, sizeof json,
             "{\"type\":\"file.progress\",\"id\":%ld,\"received\":%ld}",
             g_put.id, g_put.rx.received);
    send_control(json);               /* best effort: a drop is not a fault */
}

static void put_drop(void)
{
    if (g_put.active) {
        now_files_receive_abort(&g_put.rx);
        g_put.active = false;
        g_update.pending = false;
        rx_outcome("Connection lost during the transfer");
    }
}

static void put_done(Boolean ok, const char *code, const char *reason,
                     const char *cleanup)
{
    char json[320];

    /* The one-line outcome, recorded at the seam every ending passes
       through — success, cancel, corrupt, io — so the status that said
       "Receiving..." has one place to learn how it went. */
    {
        char outcome[128];

        if (ok) {
            snprintf(outcome, sizeof outcome, "Received %.31s",
                     g_put.name);
        } else {
            snprintf(outcome, sizeof outcome,
                     "Could not receive %.31s: %.60s", g_put.name,
                     reason != NULL ? reason : "failed");
        }
        rx_outcome(outcome);
    }
    if (ok) {
        snprintf(json, sizeof json,
                 "{\"type\":\"file.done\",\"id\":%ld,\"ok\":true,"
                 "\"received\":%ld,\"crc32\":%lu,"
                 "\"finalization\":\"same-folder-rename\","
                 "\"cleanup\":\"temp-renamed\"}",
                 g_put.id, g_put.rx.received, g_put.rx.crc);
    } else {
        snprintf(json, sizeof json,
                 "{\"type\":\"file.done\",\"id\":%ld,\"ok\":false,"
                 "\"code\":\"%s\",\"reason\":\"%.100s\","
                 "\"received\":%ld,\"cleanup\":\"%s\"}",
                 g_put.id, code, reason, g_put.rx.received,
                 cleanup != NULL ? cleanup : "unknown");
    }
    send_control(json);
    g_put.active = false;
}

static void put_abort(const char *code, const char *reason)
{
    Boolean retained;

    if (!g_put.active) {
        return;
    }
    retained = g_put.rx.keep_partial && g_put.rx.received > 0;
    now_files_receive_abort(&g_put.rx);
    put_done(false, code, reason,
             retained ? "partial-retained" : "temp-discarded");
}

/* Called for every inbound bulk frame. */
static void take_bulk_in(const unsigned char *bytes, long len)
{
    int rc;

    /* A pull we asked for. Only one of these can be live at a time -
       the shared lane is one transfer wide - so which one is expecting
       bytes is never ambiguous. */
    if (g_get.receiving) {
        rc = now_files_receive_chunk(&g_get.rx, bytes, len);
        if (rc != kFilesOK) {
            get_cleanup(false);
            get_note("Could not write the file");
        }
        g_get.deadline = TickCount() + kGetTimeoutTicks;
        return;
    }
    /* A preview we asked for: raw indexed rows into the buffer the
       begin sized. Overrun clamps rather than writes — a sender that
       exceeds its own begin has already broken the contract, and the
       end's whole-or-not check will name it. */
    if (g_prev.receiving) {
        long take = len;

        if (take > g_prev.begin.bytes - g_prev.received) {
            take = g_prev.begin.bytes - g_prev.received;
        }
        if (take > 0) {
            memcpy(g_prev.buf + g_prev.received, bytes, (size_t)take);
            g_prev.received += take;
        }
        g_prev.deadline = TickCount() + kCloudTimeoutTicks;
        return;
    }
    if (!g_put.active) {
        return;                       /* nothing is expecting these */
    }
    if (g_put.update) {
        now_sha256_update(&g_put.update_sha, bytes, len);
    }
    rc = now_files_receive_chunk(&g_put.rx, bytes, len);
    if (rc != kFilesOK) {
        put_abort("io-error", "could not write the file");
        return;
    }
    /* The first chunk reports immediately: that is what tells the host
       this guest reports at all, so it can stop trusting its own send
       counter early rather than after the first 32 KB. */
    if (g_put.reported == 0
        || g_put.rx.received - g_put.reported >= kPutProgressStep) {
        put_report_progress(false);
    }
}

static void serve_file_offer(const char *request)
{
    char name[64];
    char path[224];
    char container_arg[16];
    char development_candidate[40];
    char json[320];
    char note[128];
    long id = now_json_find_int(request, "id", 0);
    long bytes = now_json_find_int(request, "bytes", 0);
    /* Unsigned: see now_json_find_u32's header comment. A push offer
       carrying a modern date used to saturate here through find_int's
       signed strtol. */
    unsigned long modified = now_json_find_u32(request, "modified", 0);
    char type_arg[8], creator_arg[8];
    OSType file_type = 0, creator = 0;
    FileContainer container = kContainerData;
    Boolean overwrite;
    Boolean create_parents;
    Boolean cloud_born;
    Boolean update_born = false;
    NowUpdateComponent update_component = kNowUpdateApplication;
    char purpose[32];
    long have;
    NowMirrorFileTarget mirror_drop;
    int mirror_drop_state;
    int rc;

    note[0] = '\0';
    /* A pending cloud.get's success arrives as this offer, correlated
       by arrival (see the cloud block's header comment). Noted before
       anything can refuse it, so the page's status and the outcome
       cannot disagree about whether the host answered. */
    cloud_born = g_cloudget.pending;
    if (g_cloudget.pending) {
        g_cloudget.pending = false;
        cloud_note(kCloudAnswerGetUnderWay, request);
    }
    purpose[0] = '\0';
    now_json_find_string(request, "purpose", purpose, sizeof purpose);
    if (strncmp(purpose, "update.", 7) == 0) {
        update_born = now_update_component_parse(purpose + 7,
                                                 &update_component);
        if (!update_born || !g_update.pending || id != g_update.id
            || update_component != g_update.component) {
            file_refuse(id, "not-requested",
                        "that update was not requested by this guest");
            return;
        }
    }
    if (wire_busy()) {
        file_refuse(id, "busy", "a transfer is already in flight");
        rx_outcome("Not received: a transfer is already in flight");
        return;
    }
    name[0] = '\0';
    path[0] = '\0';
    /* name and path are HFS identifiers the receiver opens; decode
       UTF-8 to MacRoman. container/fileType/creator below are ASCII
       tokens by contract and stay find_string. */
    now_json_find_text(request, "name", name, sizeof name);
    now_json_find_text(request, "path", path, sizeof path);
    if (now_json_find_string(request, "container", container_arg,
                             sizeof container_arg)
        && strcmp(container_arg, "macbinary") == 0) {
        container = kContainerMacBinary;
    }
    if (now_json_find_string(request, "fileType", type_arg, sizeof type_arg)
        && strlen(type_arg) == 4) {
        memcpy(&file_type, type_arg, 4);
    }
    if (now_json_find_string(request, "creator", creator_arg,
                             sizeof creator_arg)
        && strlen(creator_arg) == 4) {
        memcpy(&creator, creator_arg, 4);
    }
    overwrite = now_json_value(request, "overwrite") != NULL
        && *now_json_value(request, "overwrite") == 't';
    create_parents = now_json_value(request, "createParents") == NULL
        || *now_json_value(request, "createParents") == 't';
    development_candidate[0] = '\0';
    now_json_find_string(request, "developmentCandidate",
                         development_candidate,
                         sizeof development_candidate);
    mirror_drop_state = mirror_file_target(
        request, "mirrorDrop", false, &mirror_drop);
    if (mirror_drop_state < 0) {
        file_refuse(id, "bad-target",
                    "the Mirror drop target was incomplete or malformed");
        return;
    }

    memset(&g_put, 0, sizeof g_put);
    g_put.id = id;
    g_put.from_cloud_get = cloud_born;
    now_json_find_string(request, "resumeToken", g_put.token,
                         sizeof g_put.token);

    strncpy(g_put.path, path, sizeof g_put.path - 1);
    strncpy(g_put.name, name, sizeof g_put.name - 1);
    g_put.container = container;
    g_put.bytes = bytes;
    g_put.file_type = file_type;
    g_put.creator = creator;
    g_put.modified = modified;
    g_put.create_parents = create_parents;
    g_put.overwrite = overwrite;
    if (mirror_drop_state > 0) {
        g_put.mirror_drop = true;
        g_put.drop_target = mirror_drop;
    }

    if (update_born) {
        NowUpdateOffer offered;
        const char *leaf = NULL;
        char offered_sha[65];

        offered_sha[0] = '\0';
        now_json_find_string(request, "sha256", offered_sha,
                             sizeof offered_sha);
        if (container != kContainerMacBinary
            || !now_update_offer_get(update_component, &offered)
            || strcmp(offered.sha256, offered_sha) != 0
            || offered.bytes != bytes
            || !now_update_destination(update_component,
                                       &g_put.dest_vref, &g_put.dest_dir,
                                       &leaf, note, sizeof note)) {
            file_refuse(id, "invalid-update",
                        note[0] != '\0' ? note
                                        : "the update identity did not match");
            g_update.pending = false;
            return;
        }
        snprintf(g_put.name, sizeof g_put.name, "%s", leaf);
        g_put.at_dest = true;
        g_put.update = true;
        g_put.update_component = update_component;
        snprintf(g_put.update_sha256, sizeof g_put.update_sha256,
                 "%s", offered_sha);
        now_sha256_init(&g_put.update_sha);
        g_put.token[0] = '\0';
        have = 0;
        rc = now_files_receive_begin_at(
            g_put.dest_vref, g_put.dest_dir, g_put.name, container, bytes,
            file_type, creator, (unsigned long)modified, true, NULL, 0,
            &g_put.rx);
    } else if (development_candidate[0] != '\0') {
        FSSpec candidate;
        long candidate_dir;
        if (cloud_born
            || !dev_candidate_accepting_folder(development_candidate,
                                               &candidate, &candidate_dir)) {
            file_refuse(id, "candidate-unavailable",
                        "the inactive Development candidate is unavailable");
            rx_outcome("Not received: Development candidate unavailable");
            return;
        }
        g_put.at_candidate = true;
        g_put.dest_vref = candidate.vRefNum;
        g_put.dest_dir = candidate_dir;
        g_put.token[0] = '\0';
        have = 0;
        rc = now_files_receive_begin_under(
            g_put.dest_vref, g_put.dest_dir, path, name, container, bytes,
            file_type, creator, (unsigned long)modified, overwrite,
            &g_put.rx);
    } else if (mirror_drop_state > 0) {
        /* A local human released over Mirror. The closed target is resolved
           by the receiver before acceptance; it never becomes a general
           absolute path on the Files surface. */
        g_put.at_dest = true;
        g_put.token[0] = '\0';
        have = 0;
        rc = now_files_mirror_receive_begin(
            &g_put.drop_target, name, container, bytes, file_type, creator,
            (unsigned long)modified, overwrite, &g_put.rx);
    } else if (cloud_born && g_cget_dest.set) {
        /* The person chose where THIS delivery lands. Guest-side only,
           no contract change, and deliberately so: the contract's
           share bound governs what the sender may reach unbidden,
           while this delivery is one the guest ASKED for — the
           receiver is sovereign over its own disk, the same bargain
           that already lands a pull in Downloads, outside the share.
           now_files_receive_begin_at is the pull path's entry point,
           so same-folder temp staging comes with it; resume is skipped
           (token cleared, have 0) because partial lookup is
           share-relative and a redirected partial is not findable
           there — a fresh start costs time, never correctness. When
           the chosen folder IS the share root the view never sets the
           override, so behavior there is byte-identical to today. */
        g_put.at_dest = true;
        g_put.dest_vref = g_cget_dest.vref;
        g_put.dest_dir = g_cget_dest.dir;
        g_put.token[0] = '\0';
        have = 0;
        rc = now_files_receive_begin_at(g_put.dest_vref, g_put.dest_dir,
                                        name, container, bytes,
                                        file_type, creator,
                                        (unsigned long)modified,
                                        overwrite, NULL, 0, &g_put.rx);
    } else {
        /* What we already hold under this token, and therefore where
           the sender should start. Zero for an offer with no token,
           which is every offer an older host makes. */
        have = now_files_partial_bytes(path, g_put.token, bytes);
        rc = now_files_receive_begin(path, name, container, bytes,
                                     file_type, creator,
                                     (unsigned long)modified,
                                     create_parents, overwrite,
                                     g_put.token, have, &g_put.rx);
        if (rc != kFilesOK && have > 0) {
            /* The partial was there a moment ago and is not usable now.
               Losing it costs time, not correctness — start over rather
               than refuse the file. */
            have = 0;
            rc = now_files_receive_begin(path, name, container, bytes,
                                         file_type, creator,
                                         (unsigned long)modified,
                                         create_parents, overwrite,
                                         g_put.token, 0, &g_put.rx);
        }
    }
    if (rc != kFilesOK) {
        const char *why;

        switch (rc) {
        case kFilesExists:
            why = "a file of that name is already there";
            file_refuse(id, "exists", why);
            break;
        case kFilesBadPath:
            why = "that name or folder is not usable";
            file_refuse(id, "bad-path", why);
            break;
        case kFilesTooBig:
            why = "not enough room on that disk";
            file_refuse(id, "too-big", why);
            break;
        default:
            why = "could not create the file";
            file_refuse(id, "io-error", why);
            break;
        }
        {
            char outcome[128];

            snprintf(outcome, sizeof outcome, "Not received: %s", why);
            rx_outcome(outcome);
        }
        return;
    }
    g_put.active = true;
    now_log(kLogInfo, "put", "#%ld %.31s, %ld bytes, into %s", id,
            name, bytes, g_put.at_candidate ? "a Development candidate" :
            (g_put.at_dest ? "the chosen folder" : "the share"));
    /* `have` is omitted rather than sent as 0, so an accept to an old
       host looks exactly as it always did. */
    if (have > 0 && g_put.rx.free_before >= 0) {
        snprintf(json, sizeof json,
                 "{\"type\":\"file.accept\",\"id\":%ld,\"have\":%ld,"
                 "\"freeBytes\":%ld,\"reservedBytes\":%ld,"
                 "\"staging\":\"same-folder-temp\"}",
                 id, have, g_put.rx.free_before, g_put.rx.reserved_bytes);
    } else if (have > 0) {
        snprintf(json, sizeof json,
                 "{\"type\":\"file.accept\",\"id\":%ld,\"have\":%ld,"
                 "\"reservedBytes\":%ld,"
                 "\"staging\":\"same-folder-temp\"}",
                 id, have, g_put.rx.reserved_bytes);
    } else if (g_put.rx.free_before >= 0) {
        snprintf(json, sizeof json,
                 "{\"type\":\"file.accept\",\"id\":%ld,"
                 "\"freeBytes\":%ld,\"reservedBytes\":%ld,"
                 "\"staging\":\"same-folder-temp\"}",
                 id, g_put.rx.free_before, g_put.rx.reserved_bytes);
    } else {
        snprintf(json, sizeof json,
                 "{\"type\":\"file.accept\",\"id\":%ld,"
                 "\"reservedBytes\":%ld,"
                 "\"staging\":\"same-folder-temp\"}",
                 id, g_put.rx.reserved_bytes);
    }
    if (!send_control(json)) {
        now_files_receive_abort(&g_put.rx);
        g_put.active = false;
        rx_outcome("Connection lost during the transfer");
        return;
    }
    if (have > 0) {
        snprintf(note, sizeof note, "Resuming %.31s...", name);
    } else {
        snprintf(note, sizeof note, "Receiving %.31s...", name);
    }
    note_shot(note);
}

/* file.begin is what actually fixes where the stream starts. Usually it
   agrees with the `have` just reported and there is nothing to do; a
   sender is free to start somewhere else, though, and then the file
   opened at the wrong offset has to be reopened at the right one before
   a single byte lands. Getting this wrong writes the tail of a file
   over the middle of it, which no checksum can repair — only detect. */
static void put_begin(const char *request)
{
    long offset;
    int rc;
    Boolean retained;

    if (!g_put.active) {
        return;
    }
    offset = now_json_find_int(request, "offset", 0);
    if (g_put.update && offset != 0) {
        put_abort("invalid-update", "an update cannot resume at an offset");
        g_update.pending = false;
        return;
    }
    if (offset == g_put.rx.received) {
        return;                       /* the sender took our advice */
    }
    if (offset < 0 || offset > g_put.bytes) {
        put_abort("io-error", "the sender named an impossible offset");
        return;
    }
    retained = g_put.rx.keep_partial && g_put.rx.received > 0;
    now_files_receive_abort(&g_put.rx);   /* may keep a resumable partial */
    if (g_put.at_candidate) {
        /* Candidate transfers never resume. A sender that contradicts the
           zero offset we accepted is not allowed to splice bytes into it. */
        if (offset != 0) {
            put_done(false, "io-error", "candidate transfer cannot resume",
                     "temp-discarded");
            return;
        }
        rc = now_files_receive_begin_under(
            g_put.dest_vref, g_put.dest_dir, g_put.path, g_put.name,
            g_put.container, g_put.bytes, g_put.file_type, g_put.creator,
            g_put.modified, g_put.overwrite, &g_put.rx);
    } else if (g_put.at_dest) {
        /* A redirected receive reported have 0, so a conforming sender
           starts at 0 and never reaches here; one that insists on a
           nonzero offset fails below (begin_at requires a token to
           resume) and the transfer ends honestly rather than landing
           bytes at the wrong offset. */
        rc = now_files_receive_begin_at(g_put.dest_vref, g_put.dest_dir,
                                        g_put.name, g_put.container,
                                        g_put.bytes, g_put.file_type,
                                        g_put.creator, g_put.modified,
                                        g_put.overwrite, NULL, offset,
                                        &g_put.rx);
    } else {
        rc = now_files_receive_begin(g_put.path, g_put.name,
                                     g_put.container,
                                     g_put.bytes, g_put.file_type,
                                     g_put.creator, g_put.modified,
                                     g_put.create_parents, g_put.overwrite,
                                     g_put.token, offset,
                                     &g_put.rx);
    }
    if (rc != kFilesOK) {
        put_done(false, "io-error", "could not start at that offset",
                 retained ? "partial-retained" : "temp-discarded");
        note_shot("Incoming file failed");
    }
}

/* The sender's file.end closes the transfer; the guest confirms only
   after the bytes are written and the file is stamped and named. */
static void finish_put(const char *reply)
{
    char note[128];
    unsigned long want_crc;
    Boolean has_crc;
    int rc;

    if (!g_put.active) {
        return;
    }
    if (now_json_value(reply, "ok") != NULL
        && !now_json_find_bool(reply, "ok", 1)) {
        now_log(kLogWarn, "put", "#%ld cancelled at %ld bytes", g_put.id,
                g_put.rx.received);
        put_abort("cancelled", "the sender stopped");
        note_shot("Incoming file cancelled");
        return;
    }
    /* The seam check. A resumed file is stitched from two sessions and
       nothing else looks at the join, so this is the one thing that can
       say the result is the file the sender meant. An absent crc32 is
       "unchecked" — the transfer still completes, it just completes
       without this proof. */
    want_crc = json_find_u32(reply, "crc32", &has_crc);
    if (has_crc && want_crc != g_put.rx.crc) {
        /* Deleted, not kept: bytes that failed their own checksum are
           not a resume candidate, and keeping them would invite the
           same wrong file to be appended to forever. */
        now_log(kLogError, "put", "#%ld checksum failed: wanted %08lX, "
                "got %08lX, %ld bytes discarded", g_put.id, want_crc,
                g_put.rx.crc, g_put.rx.received);
        now_files_receive_discard(&g_put.rx);
        put_done(false, "corrupt", "the checksum did not match",
                 "temp-discarded");
        note_shot("Incoming file was corrupt");
        return;
    }
    if (g_put.update) {
        unsigned char digest[32];
        char got[65];

        now_sha256_final(&g_put.update_sha, digest);
        now_sha256_hex(digest, got);
        if (strcmp(got, g_put.update_sha256) != 0) {
            now_files_receive_discard(&g_put.rx);
            put_done(false, "corrupt", "the SHA-256 did not match",
                     "temp-discarded");
            g_update.pending = false;
            return;
        }
    }
    /* One last report before the confirmation, so the far side sees the
       count reach the total rather than stopping at whatever the 32 KB
       cadence last happened to land on. Forced past the yield rule: it
       is a single frame and it is the one that closes the bar. */
    put_report_progress(true);
    rc = now_files_receive_finish(&g_put.rx);
    if (rc != kFilesOK) {
        put_done(false, rc == kFilesExists ? "exists" : "io-error",
                 rc == kFilesExists
                    ? "a file of that name appeared during the transfer"
                    : "could not finish writing the file",
                 "temp-discarded");
        note_shot("Incoming file failed");
        return;
    }
    if (g_put.mirror_drop
        && now_files_mirror_deliver(&g_put.drop_target,
                                    &g_put.rx.final) != noErr) {
        put_done(false, "target-refused",
                 "the file arrived but the target application did not accept it",
                 "download-retained");
        note_shot("Incoming file retained; application drop failed");
        return;
    }
    if (g_put.update) {
        char install_reason[160];
        char update_reply[512];
        const char *component = now_update_component_name(
            g_put.update_component);
        const char *action = g_put.update_component == kNowUpdateApplication
            ? "relaunch-required" : "restart-required";

        install_reason[0] = '\0';
        if (!now_update_install(g_put.update_component, &g_put.rx.final,
                                install_reason, sizeof install_reason)) {
            char esc[240];
            now_json_escape(install_reason, esc, sizeof esc);
            put_done(false, "install-failed", install_reason,
                     "download-retained");
            snprintf(update_reply, sizeof update_reply,
                     "{\"type\":\"update.result\",\"id\":%ld,"
                     "\"component\":\"%s\",\"ok\":false,"
                     "\"code\":\"install-failed\",\"reason\":\"%s\"}",
                     g_put.id, component, esc);
            send_control(update_reply);
            g_update.pending = false;
            return;
        }
        put_done(true, NULL, NULL, "installed");
        snprintf(update_reply, sizeof update_reply,
                 "{\"type\":\"update.result\",\"id\":%ld,"
                 "\"component\":\"%s\",\"ok\":true,"
                 "\"action\":\"%s\"}", g_put.id, component, action);
        send_control(update_reply);
        if (g_put.update_component == kNowUpdateExtension) {
            g_update.restart_required = true;
        } else {
            g_update.relaunch_required = true;
        }
        g_update.pending = false;
        note_shot(g_put.update_component == kNowUpdateApplication
                  ? "Update installed - quit and relaunch NOW"
                  : "Extension installed - restart this Mac");
        return;
    }
    now_log(kLogInfo, "put", "#%ld complete, %ld bytes%s", g_put.id,
            g_put.rx.received, has_crc ? ", checksum ok" : ", unchecked");
    put_done(true, NULL, NULL, "temp-renamed");
    snprintf(note, sizeof note, "Received %.31s",
             g_put.rx.final.name + 1);
    note_shot(note);
}

/* Answer a census.request for THIS machine's own share. Whoever receives
   the request serves it (contract: censusExchange); the guest is the one
   with the hardware worth asking about. One bounded page per request, so a
   probe never does more than a page of work and the wire never stalls. */
/* --- the exec plane -------------------------------------------------------

   The console plane, opposite the typed command.request path above: a whole
   LINE in, the text this Mac's own Console page would have shown back out.
   Nothing here knows a verb, which is the property being bought - a command
   added to console_model.c is typeable from an unchanged host binary
   against an unchanged contract.

   ONE AT A TIME, like every other bracket on this wire. A second
   exec.request while one runs is refused "exec-busy" rather than queued or
   preempted: the dispatch below is synchronous, so a second one could only
   run by re-entering it, and console_model.c's sink is a single static.

   WHERE CANCEL AND INPUT ACTUALLY REACH. Both arrive as control frames, so
   both are only seen while something PUMPS. A command that runs straight
   through - `ls`, `gestalt` - finishes before either could matter, and a
   cancel for it arrives to find nothing running and is answered
   "not-running", which is true. A command that pumps - capture, or anything
   that calls now_exec_read_input below - sees them. That asymmetry is
   stated rather than hidden because it decides what a person can interrupt:
   nothing that does not pump, however long it takes. */

enum {
    /* Raw text per exec.output frame. kNowMaxControl is 4096 and a MacRoman
       high byte escapes to six bytes, so 512 raw is 3072 escaped plus a
       ~60-byte envelope - inside the cap with room to spare, and large
       enough that ordinary ASCII output is one frame rather than four. */
    kExecChunkRaw = 512,
    /* How long an interpreter may wait for exec.input before giving up.
       Bounded on purpose: this guest is cooperatively scheduled, so an
       unbounded wait is a wedged Mac that needs a power cycle, and the
       host it is waiting on may already be gone. 30 seconds is long enough
       that a human can read a prompt and type, and short enough that a
       forgotten prompt frees the machine while someone is still nearby. */
    kExecInputTicks = 60 * 30
};

static struct {
    Boolean active;
    long    id;
    long    seq;
    Boolean cancelled;
    Boolean failed;        /* a send failed; stop building frames */
    Boolean waiting;       /* an interpreter is blocked on exec.input */
    Boolean have_input;
    char    input[256];
    char    buf[kExecChunkRaw + 1];
    long    len;
} g_exec;

static void exec_flush(void)
{
    /* exec is explicitly one-at-a-time and service_ctl_tx only writes; it
       cannot dispatch back into this function. These buffers used to make
       every flush a seven KiB stack frame. */
    static char out[kNowMaxControl];
    static char esc[kExecChunkRaw * 6 + 1];

    if (g_exec.len <= 0 || g_exec.failed) {
        g_exec.len = 0;
        return;
    }
    g_exec.buf[g_exec.len] = '\0';
    g_exec.len = 0;
    now_json_escape(g_exec.buf, esc, sizeof esc);
    snprintf(out, sizeof out,
             "{\"type\":\"exec.output\",\"id\":%ld,\"seq\":%ld,"
             "\"text\":\"%s\"}",
             g_exec.id, g_exec.seq, esc);
    if (!send_control(out)) {
        g_exec.failed = true;
        return;
    }
    ++g_exec.seq;

    /* DRAIN, or the queue eats the reply. Found on the q800 emulator
       2026-07-28 against the 68K guest, whose queue is four slots deep:
       `help` renders about ten lines, the frames past the fourth were
       dropped, and the one dropped last was the terminal exec.result - so
       the host waited out its whole watchdog for a message the guest had
       built correctly and thrown away. `frobnicate` answered instantly the
       entire time, which is what made it look like exec worked.

       This guest has eight slots rather than four and a 512-byte chunk
       rather than 150, so it takes a much longer command to reach - which
       is exactly why it is fixed here too rather than left as a 68K
       peculiarity. Every other producer on this wire enqueues one or two
       frames and returns to the event loop; exec is the first that emits
       an unbounded number inside a single dispatch, so it is the first
       that has to pay for its own drain.

       service_ctl_tx, NOT now_wire_pump: this pushes queued bytes toward
       Open Transport and READS nothing, so it cannot re-enter the dispatch
       currently on the stack. */
    (void)service_ctl_tx();
}

/* console_model.h's ConsoleEmit. One line at a time from that side; frames
   from this one, because a frame per line would be a control message per
   row of `ls` and this wire pays ~32 ms for each. */
static void exec_emit(void *ctx, const char *text)
{
    long i;
    long n;

    (void)ctx;
    if (g_exec.failed || g_exec.cancelled) {
        return;
    }
    n = (long)strlen(text);
    for (i = 0; i < n; ++i) {
        if (g_exec.len >= kExecChunkRaw) {
            exec_flush();
            if (g_exec.failed) {
                return;
            }
        }
        g_exec.buf[g_exec.len++] = text[i];
    }
    if (g_exec.len >= kExecChunkRaw) {
        exec_flush();
        if (g_exec.failed) {
            return;
        }
    }
    /* CR, matching what the 68K guest's own console appends and what the
       host splits on. The two guests agree about the terminator so the host
       needs only one rule. */
    g_exec.buf[g_exec.len++] = '\r';
}

static void exec_finish(Boolean ok, const char *code, const char *message)
{
    char out[kNowMaxControl];
    char esc[256];

    exec_flush();
    if (ok) {
        snprintf(out, sizeof out,
                 "{\"type\":\"exec.result\",\"id\":%ld,\"ok\":true}",
                 g_exec.id);
    } else {
        now_json_escape(message != NULL ? message : "", esc, sizeof esc);
        snprintf(out, sizeof out,
                 "{\"type\":\"exec.result\",\"id\":%ld,\"ok\":false,"
                 "\"code\":\"%s\",\"message\":\"%s\"}",
                 g_exec.id, code != NULL ? code : "failed", esc);
    }
    (void)send_control(out);
    g_exec.active = false;
    g_exec.waiting = false;
    g_exec.have_input = false;
}

static void serve_exec(const char *request)
{
    char line[256];
    long id = now_json_find_int(request, "id", 0);
    int served;

    if (g_exec.active) {
        char out[256];

        /* Refused, not queued. Same rule as a transfer, and for a harder
           reason: the dispatch is synchronous and its output sink is one
           static, so a second exec could only run by corrupting the first. */
        snprintf(out, sizeof out,
                 "{\"type\":\"exec.result\",\"id\":%ld,\"ok\":false,"
                 "\"code\":\"exec-busy\",\"message\":\"another command is "
                 "already running on this Mac\"}", id);
        (void)send_control(out);
        return;
    }
    if (!now_json_find_string(request, "line", line, sizeof line)) {
        line[0] = '\0';
    }

    g_exec.active = true;
    g_exec.id = id;
    g_exec.seq = 0;
    g_exec.len = 0;
    g_exec.cancelled = false;
    g_exec.failed = false;
    g_exec.waiting = false;
    g_exec.have_input = false;

    served = console_model_exec(line, exec_emit, NULL);

    if (g_exec.cancelled) {
        exec_finish(false, "cancelled", "stopped at the host's request");
    } else if (!served) {
        exec_finish(false, "unknown-command",
                    "this Mac serves no such command");
    } else {
        exec_finish(true, NULL, NULL);
    }
}

/* Always answered, even for an exec this Mac no longer has - the rule
   stream.stop was hardened into, inherited rather than rediscovered. An
   unanswered cancel is a host waiting on a reply that never comes. */
static void serve_exec_cancel(const char *request)
{
    long id = now_json_find_int(request, "id", 0);
    char out[256];

    if (g_exec.active && g_exec.id == id) {
        /* Marked, not acted on. The dispatch below us is synchronous; this
           stops further output immediately and the terminal exec.result is
           sent by serve_exec when the command returns, so exactly one
           result goes out however the race falls. */
        g_exec.cancelled = true;
        g_exec.waiting = false;
        return;
    }
    snprintf(out, sizeof out,
             "{\"type\":\"exec.result\",\"id\":%ld,\"ok\":false,"
             "\"code\":\"not-running\",\"message\":\"nothing by that id is "
             "running on this Mac\"}", id);
    (void)send_control(out);
}

static void serve_exec_input(const char *request)
{
    long id = now_json_find_int(request, "id", 0);

    if (!g_exec.active || g_exec.id != id || !g_exec.waiting) {
        /* Input for an exec that is not asking. Dropped rather than
           buffered: a line typed at a prompt that has already gone would
           otherwise be answered into the NEXT prompt, which is how a
           console ends up executing something nobody meant. */
        return;
    }
    if (!now_json_find_string(request, "text", g_exec.input,
                              sizeof g_exec.input)) {
        g_exec.input[0] = '\0';
    }
    g_exec.have_input = true;
    g_exec.waiting = false;
}

Boolean now_wire_exec_cancelled(void)
{
    return g_exec.active && g_exec.cancelled;
}

int now_exec_read_input(char *out, long cap, const char *prompt)
{
    unsigned long deadline;

    if (out == NULL || cap <= 0) {
        return 0;
    }
    out[0] = '\0';
    /* Only an exec can be asked for input. A person standing at this Mac
       types into the Console page, which never calls this - so an
       interpreter that prompts is answering whoever asked, and there is
       never a prompt on screen with nobody able to answer it. */
    if (!g_exec.active || g_exec.cancelled) {
        return 0;
    }
    if (prompt != NULL && prompt[0] != '\0') {
        exec_emit(NULL, prompt);
    }
    exec_flush();            /* the prompt must LEAVE before we wait on it */

    g_exec.waiting = true;
    g_exec.have_input = false;
    deadline = TickCount() + kExecInputTicks;

    while (g_exec.waiting && !g_exec.cancelled) {
        now_wire_pump();
        if ((unsigned long)TickCount() > deadline) {
            /* The bounded end of a bounded wait. An interpreter gets 0 and
               must cope; it must never be handed a line that never came. */
            g_exec.waiting = false;
            return 0;
        }
    }
    if (g_exec.cancelled || !g_exec.have_input) {
        return 0;
    }
    strncpy(out, g_exec.input, (size_t)cap - 1);
    out[cap - 1] = '\0';
    g_exec.have_input = false;
    return 1;
}

static void serve_census(const char *request)
{
    char probe[24];
    long id = now_json_find_int(request, "id", 0);
    long cursor = now_json_find_int(request, "cursor", 0);
    CensusPage page;
    char out[kNowMaxControl];
    long n;

    if (!now_json_find_string(request, "probe", probe, sizeof probe)) {
        strcpy(probe, "?");
    }
    if (now_census_gather(probe, cursor, &page) != 0) {
        /* Unknown probe: a well-formed refusal, never a protocol error. */
        page.count = 0;
        page.outcome = kCensusRefused;
        page.more = 0;
        page.next_cursor = 0;
        page.total = -1;
        snprintf(page.note, sizeof page.note, "unknown probe \"%.15s\"",
                 probe);
    }
    n = census_report_json(probe, id, &page, out, sizeof out);
    if (n < 0) {
        /* The page overran the frame - a paging bug, never truncate onto
           the wire. Answer a failed report so the asker learns cleanly. */
        page.count = 0;
        page.outcome = kCensusFailed;
        page.more = 0;
        page.total = -1;
        snprintf(page.note, sizeof page.note, "census page too large");
        n = census_report_json(probe, id, &page, out, sizeof out);
    }
    /* An unknown probe or an oversized page is a warn - the asker learned,
       but something went wrong. present/absent/partial are the machine
       answering honestly and log as info. */
    now_log(page.outcome == kCensusRefused || page.outcome == kCensusFailed
                ? kLogWarn : kLogInfo,
            "census", "#%ld %.15s: %s, %d rows%s", id, probe,
            census_outcome_name(page.outcome), page.count,
            page.more ? " (more)" : "");
    if (n > 0) {
        send_control(out);
    }
}

static void serve_file_list(const char *request)
{
    enum { kPage = 16 };              /* control frames cap at 4 KB */
    FileEntry entries[kPage];
    char path[224];
    char json[3584];
    char esc[200];
    long id = now_json_find_int(request, "id", 0);
    long cursor = now_json_find_int(request, "cursor", 1);
    Boolean more = false;
    short next = 1;
    int n, i;
    long pos;
    long free_bytes;

    path[0] = '\0';
    now_json_find_text(request, "path", path, sizeof path);
    if (cursor < 1) {
        cursor = 1;
    }
    n = now_files_list(path, (short)cursor, entries, kPage, &more, &next);
    if (n < 0) {
        file_refuse_rc(id, n);
        return;
    }
    now_json_escape(path, esc, sizeof esc);
    free_bytes = now_files_volume_free(path);
    pos = snprintf(json, sizeof json,
                   "{\"type\":\"file.listing\",\"id\":%ld,"
                   "\"path\":\"%s\",\"entries\":[", id, esc);
    for (i = 0; i < n; ++i) {
        char type[8], creator[8];
        char esc_type[40], esc_creator[40];

        memcpy(type, &entries[i].file_type, 4);
        type[4] = '\0';
        memcpy(creator, &entries[i].creator, 4);
        creator[4] = '\0';
        now_json_escape(entries[i].name, esc, sizeof esc);
        pos += snprintf(json + pos, sizeof json - (size_t)pos,
                        "%s{\"name\":\"%s\",\"kind\":\"%s\"",
                        i > 0 ? "," : "", esc,
                        entries[i].folder ? "folder" : "file");
        if (!entries[i].folder) {
            now_json_escape(type, esc_type, sizeof esc_type);
            now_json_escape(creator, esc_creator, sizeof esc_creator);
            pos += snprintf(json + pos, sizeof json - (size_t)pos,
                            ",\"fileType\":\"%s\",\"creator\":\"%s\","
                            "\"dataBytes\":%ld,\"rsrcBytes\":%ld",
                            esc_type, esc_creator, entries[i].data_bytes,
                            entries[i].rsrc_bytes);
        }
        pos += snprintf(json + pos, sizeof json - (size_t)pos,
                        ",\"modified\":%lu,\"identity\":\"%s\"}",
                        entries[i].modified, entries[i].identity);
    }
    pos += snprintf(json + pos, sizeof json - (size_t)pos,
                    "],\"more\":%s,\"cursor\":%d",
                    more ? "true" : "false", (int)next);
    if (free_bytes >= 0) {
        pos += snprintf(json + pos, sizeof json - (size_t)pos,
                        ",\"freeBytes\":%ld", free_bytes);
    }
    /* Only the root listing carries it: it names the place, and a
       subfolder listing already knows where it is. */
    if (path[0] == '\0') {
        char root[160];
        char esc_root[336];
        char field[352];
        long len;

        now_files_root_name(root, sizeof root);
        now_json_escape(root, esc_root, sizeof esc_root);
        len = snprintf(field, sizeof field, ",\"root\":\"%s\"", esc_root);
        /* A page of long names can leave no room. Dropping the label is
           harmless; half a label would truncate mid-string and cost the
           asker the whole listing. */
        if (len > 0 && pos + len + 2 < (long)sizeof json) {
            memcpy(json + pos, field, (size_t)len);
            pos += len;
        }
    }
    snprintf(json + pos, sizeof json - (size_t)pos, "}");
    send_control(json);
}

/* Serve process.list from this guest's OWN Process Manager - the guest's
   share of the symmetric process family (the host serves its own list
   the same way). Read-only; a process list is no more than the
   Application menu already shows. Paginates: cursor is a 1-based
   position among readable processes, more/cursor continue it. */
static void serve_process_list(const char *request)
{
    enum { kPage = 16 };              /* control frames cap at 4 KB */
    /* One entry's worst case (a 31-char name escaped, two 4CCs, three
       numbers) is ~240 bytes; keep this much free for it plus the tail so
       a row never truncates mid-JSON - a truncated frame decodes to
       nothing and the send silently does nothing. */
    enum { kEntryMargin = 320 };
    char json[kNowMaxControl];
    long id = now_json_find_int(request, "id", 0);
    long cursor = now_json_find_int(request, "cursor", 1);
    /* The roster is the one walk and the one classifier (proc_roster.h).
       isSelf marks the one row that is NOW - the only identity a caller
       can trust for "the process on the other end of this connection".
       serve_process_act already computes it to refuse a self-quit; this
       reports the same fact instead of only acting on it, so a caller can
       name this process without deriving a file name from a version
       string (contract: ProcessListing.isSelf). */
    NowProcRosterIter it;
    NowProcRosterRow proc;
    long pos;
    long index = 0;                   /* readable-process position, 1-based */
    int emitted = 0;
    Boolean more = false;

    if (cursor < 1) {
        cursor = 1;
    }
    pos = snprintf(json, sizeof json,
                   "{\"type\":\"process.listing\",\"id\":%ld,"
                   "\"processes\":[", id);
    now_proc_roster_begin(&it);
    while (now_proc_roster_next(&it, &proc)) {
        char code[8], creator[8];
        char esc_name[64], esc_code[40], esc_creator[40];

        /* Unreadable rows never arrive here at all - the roster skips
           and counts them, so "not a position" stays one rule in one
           place rather than a `continue` every walk has to remember. */
        ++index;
        if (index < cursor) {
            continue;                 /* before this page */
        }
        if (emitted >= kPage
            || pos > (long)sizeof json - kEntryMargin) {
            more = true;              /* this one starts the next page */
            break;
        }
        memcpy(code, &proc.type, 4);
        code[4] = '\0';
        memcpy(creator, &proc.creator, 4);
        creator[4] = '\0';
        now_json_escape(proc.name, esc_name, sizeof esc_name);
        now_json_escape(code, esc_code, sizeof esc_code);
        now_json_escape(creator, esc_creator, sizeof esc_creator);
        /* isSelf only when true: the contract makes it optional and
           absence means false, so 24 rows do not each pay 15 bytes of a
           frame whose page size is derived from its size. */
        pos += snprintf(json + pos, sizeof json - (size_t)pos,
                        "%s{\"name\":\"%s\",\"kind\":\"%s\",\"code\":\"%s\","
                        "\"creator\":\"%s\",\"sizeKB\":%ld,\"front\":%s,"
                        "\"psnHigh\":%lu,\"psnLow\":%lu%s}",
                        emitted > 0 ? "," : "", esc_name,
                        now_proc_kind_name(proc.kind), esc_code,
                        esc_creator, proc.size_kb,
                        proc.is_front ? "true" : "false",
                        (unsigned long)proc.psn.highLongOfPSN,
                        (unsigned long)proc.psn.lowLongOfPSN,
                        proc.is_self ? ",\"isSelf\":true" : "");
        ++emitted;
    }
    snprintf(json + pos, sizeof json - (size_t)pos,
             "],\"more\":%s,\"cursor\":%ld}", more ? "true" : "false",
             cursor + emitted);
    /* One line per refresh, not per page: a refresh that pages is still one
       event, and a list is read often enough that per-page logging would be
       the heartbeat the log is meant to avoid. The first page (cursor 1)
       stands for the whole walk. */
    if (cursor == 1) {
        now_log(kLogInfo, "proc", "#%ld listed %d processes%s", id, emitted,
                more ? " (more)" : "");
    }
    send_control(json);
}

enum { kSoftwareWirePage = 10 };

/* One serial wire request owns this page at a time. The software cache walk
   does not pump the wire, so file scope is both safe and substantially
   cheaper than the former ~5 KiB automatic array on a classic Mac stack. */
static SoftwareEntry g_software_wire_page[kSoftwareWirePage];

/* Serve software.list from this guest's installed-software cache — the
   wire's paged reading of the same data layer the sw command flattens.
   Cursor 1 (re)builds the cache; for "apps" that is the whole blocking
   sweep, ~4 s on the real machine, which the asker's watchdog must
   outlive (the host allows 15 s). Entries carry the full path because
   the path is the launch key: the host launches by path, so the
   name-ambiguity refusal can never fire from a listing. */
static void serve_software_list(const char *request)
{
    /* Worst case per entry: a 31-char name and a 223-char path, both
       escaped (6x), plus the fixed fields and a version — call it 1750
       bytes. The margin below is what must remain BEFORE starting an
       entry, so a worst-case row plus the tail still fits. */
    enum { kEntryMargin = 1900 };
    char json[kNowMaxControl];
    SoftwareEntry *entries = g_software_wire_page;
    char domain[16];
    long id = now_json_find_int(request, "id", 0);
    long cursor = now_json_find_int(request, "cursor", 1);
    Boolean more = false;
    Boolean truncated = false;
    long pos;
    int n, i;
    int emitted = 0;

    domain[0] = '\0';
    if (!now_json_find_string(request, "domain", domain, sizeof domain)
        || domain[0] == '\0') {
        strcpy(domain, "apps");
    }
    if (cursor < 1) {
        cursor = 1;
    }
    n = now_software_page(domain, cursor, entries, kSoftwareWirePage, &more,
                          &truncated);
    if (n < 0) {
        char esc[40];

        now_json_escape(domain, esc, sizeof esc);
        now_log(kLogWarn, "sw", "#%ld software.list refused: no domain "
                "%.15s", id, domain);
        pos = snprintf(json, sizeof json,
                       "{\"type\":\"software.listing\",\"id\":%ld,"
                       "\"domain\":\"%s\",\"entries\":[],\"more\":false,"
                       "\"note\":\"no such domain\"}", id, esc);
        send_control(json);
        return;
    }

    {
        char esc_domain[40];

        now_json_escape(domain, esc_domain, sizeof esc_domain);
        pos = snprintf(json, sizeof json,
                       "{\"type\":\"software.listing\",\"id\":%ld,"
                       "\"domain\":\"%s\",\"entries\":[", id, esc_domain);
    }
    for (i = 0; i < n; ++i) {
        char esc_name[400], esc_path[1400], esc_type[40], esc_creator[40];

        if (pos > (long)sizeof json - kEntryMargin) {
            more = true;              /* this one starts the next page */
            break;
        }
        now_json_escape(entries[i].name, esc_name, sizeof esc_name);
        now_json_escape(entries[i].path, esc_path, sizeof esc_path);
        now_json_escape(entries[i].type, esc_type, sizeof esc_type);
        now_json_escape(entries[i].creator, esc_creator,
                        sizeof esc_creator);
        pos += snprintf(json + pos, sizeof json - (size_t)pos,
                        "%s{\"name\":\"%s\",\"path\":\"%s\","
                        "\"type\":\"%s\",\"creator\":\"%s\","
                        "\"sizeK\":%ld,\"off\":%s,\"running\":%s",
                        emitted > 0 ? "," : "", esc_name, esc_path,
                        esc_type, esc_creator, entries[i].size_k,
                        entries[i].off ? "true" : "false",
                        entries[i].running ? "true" : "false");
        /* Optional on the wire: absence means "no readable 'vers'",
           which the schema spells out. */
        if (entries[i].version[0] != '\0') {
            char esc_ver[100];

            now_json_escape(entries[i].version, esc_ver, sizeof esc_ver);
            pos += snprintf(json + pos, sizeof json - (size_t)pos,
                            ",\"version\":\"%s\"", esc_ver);
        }
        pos += snprintf(json + pos, sizeof json - (size_t)pos, "}");
        ++emitted;
    }
    snprintf(json + pos, sizeof json - (size_t)pos,
             "],\"more\":%s,\"cursor\":%ld%s}",
             more ? "true" : "false", cursor + emitted,
             truncated ? ",\"note\":\"inventory truncated at cache\"" : "");
    /* Cursor 1 stands for the whole refresh, the process.list rule —
       and for "apps" it is also the line that says the sweep ran. */
    if (cursor == 1) {
        now_log(kLogInfo, "sw", "#%ld software.list %.15s: %d served%s%s",
                id, domain, emitted, more ? " (more)" : "",
                truncated ? " (truncated)" : "");
    }
    send_control(json);
}

/* A drive verb: bring a process to front, or ask it to quit. The target
   is the PSN the host echoed from a listing; because that listing may be
   seconds stale, the PSN is re-validated against a live process first and
   a dead one fails closed rather than driving whatever now holds that
   serial. Both verbs answer with the one process.result shape. */
static void serve_process_act(const char *request, Boolean quit)
{
    char json[256];   /* + outcome; the longest reason is 57 bytes */
    long id = now_json_find_int(request, "id", 0);
    ProcessSerialNumber psn;
    ProcessInfoRec info;
    Str31 name;
    OSErr err = noErr;
    const char *reason = NULL;
    /* ActSettlement.status's vocabulary, borrowed rather than invented -
       see ProcessResult.outcome in the contract. Refusals that never
       reached the machine stay "refused"; only the two verbs' own
       terminal states are set below. */
    const char *outcome = "refused";

    psn.highLongOfPSN =
        (unsigned long)now_json_find_int(request, "psnHigh", 0);
    psn.lowLongOfPSN =
        (unsigned long)now_json_find_int(request, "psnLow", 0);

    memset(&info, 0, sizeof info);
    info.processInfoLength = sizeof info;
    info.processName = name;
    info.processAppSpec = NULL;
    name[0] = 0;
    if (GetProcessInformation(&psn, &info) != noErr) {
        reason = "that process is no longer running";
    } else if (quit) {
        ProcessSerialNumber self;
        Boolean is_self = false;
        /* Quitting NOW itself over the wire would sever the connection
           mid-reply - refuse it here, where the current PSN is known,
           rather than trusting the far end never to ask. */
        if (GetCurrentProcess(&self) == noErr) {
            (void)SameProcess(&psn, &self, &is_self);
        }
        if (is_self) {
            reason = "NOW will not ask itself to quit";
        } else {
            err = now_proc_ask_quit(&psn);
            if (err != noErr) {
                reason = "the Mac would not deliver the quit request";
            } else {
                /* QUIT CANNOT BE TOLD MORE THAN THIS, and that is a fact
                   about the platform rather than a gap here: a 'quit'
                   Apple Event is one an application may decline or sit
                   on behind a Save dialog. `ok` says the event was
                   delivered; `outcome` says plainly that delivery is all
                   that was established, so a caller reading `outcome`
                   alone is never misled into thinking it has gone. */
                outcome = "dispatched-but-unconfirmed";
            }
        }
    } else {
        /* THE SAME ASK-AND-CONFIRM the console's `front` and `mach
           activate` make (proc_actions.h). This used to answer ok:true
           on SetFrontProcess returning noErr, which means the switch was
           SCHEDULED and nothing more - so `now_bring_to_front` over MCP,
           which rides this exact path, got the weakest of three claims
           and no way to tell. A verb reports what happened; an accepted
           request that never landed is not a switch. */
        switch (now_proc_front_confirm(&psn,
                                       (unsigned long)kProcFrontWaitSecs
                                       * 60)) {
        case kProcFrontConfirmed:
            outcome = "confirmed";
            break;
        case kProcFrontAccepted:
            /* NEVER OBSERVED. Driven on 2026-08-07 against an emulated
               OS 9.1 guest: fronting a faceless process took the
               refusal branch below instead, and a switch that is
               accepted and then does not land could not be staged
               deliberately. This branch compiles and reads correctly
               and has never run - which is a different thing from
               tested, and the next person should not have to infer
               that from its absence in a log. */
            err = -1;
            outcome = "dispatched-but-unconfirmed";
            reason = "the Mac accepted the request and it is still not "
                     "frontmost";
            break;
        case kProcFrontSetRefused:
            err = -1;
            outcome = "refused";
            reason = "the Mac would not bring it to the front";
            break;
        }
    }

    /* A drive verb changes the machine's state, and its refusal reason
       lives nowhere else once the reply is off the wire - the log is where
       "asked Finder to quit, it declined" survives the window closing. */
    {
        char cname[32];
        const char *verb = quit ? "quit" : "front";

        if (name[0] > 0) {
            memcpy(cname, name + 1, name[0]);
            cname[name[0]] = '\0';
        } else {
            strcpy(cname, "?");
        }
        if (reason == NULL) {
            now_log(kLogInfo, "proc", "#%ld %s %.31s", id, verb, cname);
        } else {
            now_log(kLogWarn, "proc", "#%ld %s refused: %.60s",
                    id, verb, reason);
        }
    }

    if (reason == NULL) {
        snprintf(json, sizeof json,
                 "{\"type\":\"process.result\",\"id\":%ld,\"ok\":true,"
                 "\"outcome\":\"%s\"}", id, outcome);
    } else {
        snprintf(json, sizeof json,
                 "{\"type\":\"process.result\",\"id\":%ld,\"ok\":false,"
                 "\"outcome\":\"%s\",\"reason\":\"%s\"}",
                 id, outcome, reason);
    }
    send_control(json);
}

static void serve_file_get(const char *request)
{
    NowPrefs prefs;
    FileStage stage;
    char path[224];
    char development_project[40];
    char container_arg[16];
    char json[512];
    long id = now_json_find_int(request, "id", 0);
    FileContainer want = kContainerAuto;
    long chunk;
    short pace_ms;
    Boolean pack_unused;
    unsigned short xfer;
    NowMirrorFileTarget mirror_source;
    int mirror_source_state;
    int rc;

    if (wire_busy()) {
        file_refuse(id, "busy", "a transfer is already in flight");
        return;
    }
    path[0] = '\0';
    development_project[0] = '\0';
    now_json_find_text(request, "path", path, sizeof path);
    now_json_find_string(request, "developmentProject", development_project,
                         sizeof development_project);
    mirror_source_state = mirror_file_target(
        request, "mirrorSource", true, &mirror_source);
    if (mirror_source_state < 0) {
        file_refuse(id, "bad-source",
                    "the Mirror drag source was incomplete or malformed");
        return;
    }

    /* Resuming a PULL is not offered yet: the guest does not compute a
       token for its own files, so it can never prove the file it would
       send is the one the partial came from. The contract's answer for
       a token it cannot match is `changed`, and refusing costs a
       restart where the alternative is silent corruption — a whole file
       sent to a host expecting only the tail gets appended to the
       partial it already holds. */
    if (now_json_find_int(request, "offset", 0) > 0) {
        file_refuse(id, "changed",
                    "this Mac cannot prove the file is unchanged; "
                    "ask for it from the beginning");
        return;
    }
    if (now_json_find_string(request, "container", container_arg,
                             sizeof container_arg)) {
        if (strcmp(container_arg, "macbinary") == 0) {
            want = kContainerMacBinary;
        } else if (strcmp(container_arg, "data") == 0) {
            want = kContainerData;
        }
    }
    if (mirror_source_state > 0) {
        rc = now_files_mirror_stage(&mirror_source, want, &stage);
    } else if (development_project[0] != '\0') {
        FSSpec folder;
        long project_dir;
        char hfs_path[224];
        long i;
        if (!dev_active_project_file(development_project, path,
                                     &folder, &project_dir)) {
            file_refuse(id, "project-file-unavailable",
                        "the named source file is not in that active project");
            return;
        }
        snprintf(hfs_path, sizeof hfs_path, "%s", path);
        for (i = 0; hfs_path[i] != '\0'; ++i) {
            if (hfs_path[i] == '/') hfs_path[i] = ':';
        }
        rc = now_files_stage_under(folder.vRefNum, project_dir,
                                   hfs_path, want, &stage);
    } else {
        rc = now_files_stage(path, want, &stage);
    }
    if (rc != kFilesOK) {
        file_refuse_rc(id, rc);
        return;
    }
    now_prefs_load(&prefs);
    tuning_from_json(request, &prefs, &chunk, &pace_ms, &pack_unused);
    xfer = next_xfer();
    {
        char type[8], creator[8];

        memcpy(type, &stage.file_type, 4);
        type[4] = '\0';
        memcpy(creator, &stage.creator, 4);
        creator[4] = '\0';
        char esc_name[200], esc_type[40], esc_creator[40];

        now_json_escape(stage.name, esc_name, sizeof esc_name);
        now_json_escape(type, esc_type, sizeof esc_type);
        now_json_escape(creator, esc_creator, sizeof esc_creator);
        snprintf(json, sizeof json,
                 "{\"type\":\"file.begin\",\"id\":%ld,\"transfer\":%u,"
                 "\"name\":\"%s\",\"container\":\"%s\","
                 "\"bytes\":%ld,\"dataBytes\":%ld,\"rsrcBytes\":%ld,"
                 "\"fileType\":\"%s\",\"creator\":\"%s\","
                 "\"modified\":%lu}",
                 id, xfer, esc_name,
                 stage.container == kContainerMacBinary ? "macbinary" : "data",
                 stage.total_bytes, stage.data_bytes, stage.rsrc_bytes,
                 esc_type, esc_creator, stage.modified);
    }
    if (!send_control(json)) {
        now_files_stage_dispose(&stage);
        return;
    }
    if (!arm_file_transfer(id, xfer, &stage, chunk, pace_ms)) {
        now_files_stage_dispose(&stage);
        file_start_failed(id, xfer);
        return;
    }
}

/* --- live stream ------------------------------------------------------- */

static void stream_pipeline_clear(void)
{
    if (g_stream.cap_active) {
        banded_capture_abort(&g_stream.cap);
        g_stream.cap_active = false;
    }
    if (g_stream.ready) {
        now_pixels_dispose(&g_stream.ready_blob);
        g_stream.ready = false;
    }
    if (g_stream.prev != NULL) {
        DisposePtr(g_stream.prev);
        g_stream.prev = NULL;
    }
}

static void stream_drop(void)
{
    stream_pipeline_clear();
    g_stream.active = false;
    g_stream.stopping = false;
    g_streamreq.pending = false;
}

static void stream_send_stopped(long id, const char *reason)
{
    char json[192];

    if (reason != NULL) {
        snprintf(json, sizeof json,
                 "{\"type\":\"stream.stopped\",\"id\":%ld,"
                 "\"reason\":\"%s\"}", id, reason);
    } else {
        snprintf(json, sizeof json,
                 "{\"type\":\"stream.stopped\",\"id\":%ld}", id);
    }
    send_control(json);
}

static void stream_end(const char *reason)
{
    if (!g_stream.active) {
        return;
    }
    stream_pipeline_clear();
    g_stream.active = false;
    g_stream.stopping = false;
    stream_send_stopped(g_stream.id, reason);
    note_shot("Streaming stopped");
}

/* The frame pump's floor, in ticks between frames.

   minIntervalMs keeps its contract meaning - a MINIMUM interval, the host's
   ceiling on frame rate - but "absent" no longer means "as fast as the wire
   allows". That was only ever a pace because every frame carried bulk
   pixels: an empty frame is a ~150-byte control pair that touches no
   transfer lane at all, so on a static screen with predictive capture on,
   nothing throttled the loop and the guest flooded the wire with thousands
   of control frames a second. Capture on this hardware tops out near 7 fps,
   so a default of ~15 fps is headroom, not a limit. */
enum {
    kStreamDefaultIntervalTicks = 4,  /* ~15 fps when the host says nothing */
    kStreamIdleIntervalTicks = 15     /* ~4 fps once the screen goes still */
};

static long stream_interval_ticks(long min_interval_ms)
{
    long ticks;

    if (min_interval_ms <= 0) {
        return kStreamDefaultIntervalTicks;
    }
    /* Round up: any interval the host asks for is a floor, and truncating
       10 ms to 0 ticks would hand back the unbounded loop. */
    ticks = (min_interval_ms * 60 + 999) / 1000;
    return ticks > 0 ? ticks : 1;
}

static void stream_start(const char *reply)
{
    NowPrefs prefs;
    long depth_arg;
    long id = now_json_find_int(reply, "id", 0);

    if (wire_busy()) {
        stream_send_stopped(id, "busy: a transfer is in flight");
        return;
    }
    now_prefs_load(&prefs);
    depth_arg = now_json_find_int(reply, "depth", 0);

    memset(&g_stream, 0, sizeof g_stream);
    g_stream.id = id;
    g_stream.depth = capture_depth_is_supported((short)depth_arg)
        ? (short)depth_arg : prefs.shot_depth;
    tuning_from_json(reply, &prefs, &g_stream.chunk, &g_stream.pace_ms,
                     &g_stream.pack);
    g_stream.predictive =
        json_find_flag(reply, "predictive", prefs.predictive) != 0;
    g_stream.interlace =
        json_find_flag(reply, "interlace", prefs.interlace) != 0;
    g_stream.min_interval_ticks =
        stream_interval_ticks(now_json_find_int(reply, "minIntervalMs", 0));
    g_stream.next_frame_tick = 0;
    g_stream.est_cap_ticks = 10;      /* ~165 ms until measured */
    g_stream.est_send_ticks = 0;      /* first capture starts at once */
    g_stream.force_key = true;        /* frame one is always whole */
    g_stream.active = true;
    g_streamreq.pending = false;
    {
        char peer[24];
        char line[64];

        conn_peer_label(peer, sizeof peer);
        snprintf(line, sizeof line, "Streaming to %.20s...", peer);
        note_shot(line);
    }
}

static void stream_stop(const char *reply)
{
    long id = now_json_find_int(reply, "id", -1);

    if (!g_stream.active || id != g_stream.id) {
        /* Answer anyway: if the guest lost the stream (reconnect, abort
           whose stream.stopped died with the old socket), an unanswered
           stop would wedge the host's bracket open forever. */
        stream_send_stopped(id, NULL);
        return;
    }
    if (g_xfer.active) {
        xfer_abort();
        if (g_xfer.active) {
            g_stream.stopping = true; /* stream.stopped follows the drain */
            return;
        }
    }
    stream_end(NULL);
}

/* Guest-initiated streaming: the guest can only ASK - the bracket stays
   host-owned (stream.start is the host's word), so both origins share one
   code path and one policy. The host answers stream.start or an error. */

int now_wire_stream_request(char *err, long cap)
{
    NowPrefs prefs;
    char json[96];

    if (g.phase != kConnConnected) {
        snprintf(err, (size_t)cap, "Not connected");
        return -1;
    }
    if (g_stream.active) {
        snprintf(err, (size_t)cap, "Already streaming");
        return -1;
    }
    if (g_xfer.active || g_offer.active || g_streamreq.pending) {
        snprintf(err, (size_t)cap, "A transfer is already in flight");
        return -1;
    }
    now_prefs_load(&prefs);
    snprintf(json, sizeof json,
             "{\"type\":\"stream.request\",\"depth\":%d}",
             (int)prefs.shot_depth);
    if (!send_control(json)) {
        snprintf(err, (size_t)cap, "Connection lost");
        return -1;
    }
    g_streamreq.pending = true;
    g_streamreq.deadline = TickCount() + kStreamReqTimeoutTicks;
    {
        char peer[40];
        char asked[96];

        conn_peer_label(peer, sizeof peer);
        snprintf(asked, sizeof asked, "Asked %s to stream...", peer);
        note_shot(asked);
    }
    return 0;
}

Boolean now_wire_stream_active(void)
{
    return g_stream.active;
}

long now_wire_stream_interval_ms(void)
{
    if (!g_stream.active) {
        return -1;
    }
    /* Ticks back to ms; the rounding-up at arrival means this can read
       a hair over what the host asked, which is the honest direction. */
    return g_stream.min_interval_ticks * 1000L / 60L;
}

/* The panel's Stop: guest ends its own bracket - stream.stopped without a
   reason reads as a clean stop on the host. */
void now_wire_stream_stop(void)
{
    if (!g_stream.active) {
        return;
    }
    if (g_xfer.active) {
        xfer_abort();
        if (g_xfer.active) {
            g_stream.stopping = true; /* stream.stopped follows the drain */
            return;
        }
    }
    stream_end(NULL);
}

enum { kStreamBands = 8 };            /* ~17 ms per event-loop bite */

/* When a send starts, aim the next capture to finish as the send does. */
static void stream_schedule_capture(void)
{
    long lead = g_stream.est_send_ticks - g_stream.est_cap_ticks;

    if (lead < 0) {
        lead = 0;
    }
    g_stream.cap_start_tick = TickCount() + (unsigned long)lead;
}

/* Abandons the frame in hand and makes the next capture a whole-screen
   keyframe. The escape hatch for the one case the exporter cannot serve:
   a key is the only correct frame, but what was captured is a field. */
static void stream_drop_frame(CaptureImage *image, unsigned long began)
{
    capture_image_dispose(image);
    g_stream.ready = false;
    g_stream.force_key = true;        /* next capture reads everything */
    g_stream.n_dirty_hist = 0;
    g_stream.sweep_pos = 0;
    g_stream.est_cap_ticks = (long)(TickCount() - began);
}

/* Finishes a completed banded capture: diff, then export + encode the
   right kind of frame, so it is ready the instant the lane frees.

   Two shapes meet here and must not be confused. The CANVAS is what the
   host paints - full screen height, and what the delta base (prev) always
   holds. The IMAGE is what this capture read: the same height at row_scale
   1, but HALF of it when interlace decimated 2:1 into a half-height
   GWorld. A delta carries rowStep so the host maps field rows back onto
   the canvas; a keyframe carries no such mapping - it replaces the host's
   canvas wholesale. So: a field capture may only ever leave here as a
   delta. Exporting one as a key is what made the host resize its canvas to
   half height and stay there. */
static void stream_finish_capture(unsigned long began)
{
    CaptureImage image = g_stream.cap.image;
    CaptureSpan cap_spans[kCaptureMaxBands];
    short n_cap_spans = g_stream.cap.n_spans;
    unsigned char palette[768];
    long palette_bytes;
    long height, canvas_height, canvas_bytes;
    short scale = g_stream.cap_scale > 1 ? g_stream.cap_scale : 1;
    Boolean field = scale > 1;
    int rc;

    memcpy(cap_spans, g_stream.cap.spans, sizeof cap_spans);
    memset(&g_stream.cap, 0, sizeof g_stream.cap);
    g_stream.cap_active = false;

    memset(&g_stream.ready_meta, 0, sizeof g_stream.ready_meta);
    g_stream.ready_meta.width =
        (short)(image.bounds.right - image.bounds.left);
    g_stream.ready_meta.height =
        (short)(image.bounds.bottom - image.bounds.top);
    g_stream.ready_meta.depth = image.depth;
    g_stream.ready_meta.row_bytes = image.row_bytes;
    g_stream.ready_meta.capture_ms =
        (long)((TickCount() - began) * 1000 / 60);
    height = g_stream.ready_meta.height;
    /* A field holds every other canvas row, so the canvas it diffs against
       is the one prev already describes - not this image's height. Sizing
       the base off the image instead was the second half of the half-screen
       bug: a field capture looked like a shape change, which threw the
       canvas-sized base away and re-made it half height. */
    canvas_height = field ? g_stream.prev_height : height;
    canvas_bytes = (long)image.row_bytes * canvas_height;
    if (field && (g_stream.prev == NULL || canvas_height <= 0)) {
        stream_drop_frame(&image, began);   /* no canvas to patch into */
        return;
    }

    /* A palette change invalidates every delta; so does a base buffer of
       the wrong shape (depth cannot change mid-stream, but composite
       garbage is the worst failure mode - be safe). */
    palette_bytes = now_pixels_palette(&image, palette, sizeof palette);
    if (g_stream.prev != NULL
        && (g_stream.prev_bytes != canvas_bytes
            || g_stream.prev_row_bytes != image.row_bytes
            || g_stream.prev_height != (short)canvas_height
            || palette_bytes != g_stream.prev_palette_bytes
            || memcmp(palette, g_stream.prev_palette,
                      (size_t)palette_bytes) != 0)) {
        g_stream.force_key = true;
        if (g_stream.prev_bytes != canvas_bytes) {
            DisposePtr(g_stream.prev);
            g_stream.prev = NULL;
        }
    }
    /* Whatever invalidated the base, only a whole-screen capture can
       rebuild it. */
    if (field && g_stream.force_key) {
        stream_drop_frame(&image, began);
        return;
    }
    if (g_stream.prev == NULL) {
        g_stream.prev = NewPtr(canvas_bytes);
        if (g_stream.prev == NULL) {
            capture_image_dispose(&image);
            stream_end("capture failed");
            return;
        }
        g_stream.prev_bytes = canvas_bytes;
        g_stream.prev_row_bytes = image.row_bytes;
        g_stream.prev_height = (short)canvas_height;
        g_stream.force_key = true;
    }

    memset(&g_stream.ready_blob, 0, sizeof g_stream.ready_blob);
    if (!g_stream.force_key) {
        long dirty_rows = 0;
        Boolean overflow = false;
        short n = now_pixels_diff(&image, g_stream.prev,
                                  g_stream.cap_full ? NULL : cap_spans,
                                  g_stream.cap_full ? 0 : n_cap_spans,
                                  scale, g_stream.cap_phase,
                                  g_stream.ready_meta.rects,
                                  kPixelMaxRects, &dirty_rows, &overflow);

        if (n < 0) {
            g_stream.force_key = true;
        } else if (overflow) {
            /* Too fragmented to describe: send every captured span whole.
               Correct (all captured), merely coarse. */
            short i;

            n = n_cap_spans;
            for (i = 0; i < n; ++i) {
                g_stream.ready_meta.rects[i].row = cap_spans[i].row;
                g_stream.ready_meta.rects[i].n_rows =
                    cap_spans[i].n_rows;
                g_stream.ready_meta.rects[i].col_off = 0;
                g_stream.ready_meta.rects[i].col_bytes = image.row_bytes;
            }
            g_stream.ready_meta.kind = kFrameDelta;
        } else if (n == 0) {
            g_stream.ready_meta.kind = kFrameEmpty;
        } else if (g_stream.cap_full && !field
                   && dirty_rows * 10 > height * 7) {
            g_stream.force_key = true;   /* mostly new screen: send whole */
        } else {
            g_stream.ready_meta.kind = kFrameDelta;
            g_stream.ready_meta.n_rects = n;
        }
        if (g_stream.ready_meta.kind == kFrameDelta && !g_stream.force_key) {
            short i;

            if (overflow) {
                g_stream.ready_meta.n_rects = n;
            }
            g_stream.ready_meta.row_scale = scale;
            g_stream.ready_meta.row_phase = g_stream.cap_phase;
            /* Remember where the dirt was, in canvas rows, for the next
               frame's prediction. */
            g_stream.n_dirty_hist = g_stream.ready_meta.n_rects;
            for (i = 0; i < g_stream.n_dirty_hist; ++i) {
                g_stream.dirty_hist[i].row = (short)
                    ((long)g_stream.ready_meta.rects[i].row * scale
                     + g_stream.cap_phase);
                g_stream.dirty_hist[i].n_rows = (short)
                    ((long)(g_stream.ready_meta.rects[i].n_rows - 1) * scale
                     + 1);
            }
            rc = now_pixels_export_rects(&image, g_stream.pack,
                                         g_stream.ready_meta.rects,
                                         g_stream.ready_meta.n_rects,
                                         &g_stream.ready_blob);
            if (rc != 0) {
                capture_image_dispose(&image);
                stream_end("capture failed");
                return;
            }
        }
        if (g_stream.ready_meta.kind == kFrameEmpty) {
            g_stream.n_dirty_hist = 0;
        }
        if (g_stream.interlace) {
            g_stream.phase = (short)(g_stream.phase ^ 1);
        }
    }
    /* The invariant, stated once and enforced here: only a whole-screen,
       full-scale capture may leave as a keyframe. force_key is set at plan
       time for a real key (and stream_begin_capture then reads everything),
       but the diff can also raise it AFTER the capture is in hand - and by
       then the capture may be a field. Drop that frame rather than export a
       half-height image as a key; the next capture is whole. */
    if (g_stream.force_key && (field || !g_stream.cap_full)) {
        stream_drop_frame(&image, began);
        return;
    }
    if (g_stream.force_key) {
        g_stream.ready_meta.kind = kFrameKey;
        g_stream.ready_meta.n_rects = 0;
        g_stream.ready_meta.row_scale = 1;
        g_stream.ready_meta.row_phase = 0;
        g_stream.n_dirty_hist = 0;
        g_stream.sweep_pos = 0;
        rc = now_pixels_export(&image, g_stream.pack, &g_stream.ready_blob);
        if (rc != 0 || now_pixels_copy_raw(&image, g_stream.prev) != 0) {
            capture_image_dispose(&image);
            stream_end("capture failed");
            return;
        }
        memcpy(g_stream.prev_palette, palette, (size_t)palette_bytes);
        g_stream.prev_palette_bytes = palette_bytes;
        g_stream.force_key = false;
    }
    capture_image_dispose(&image);
    g_stream.ready = true;
    g_stream.est_cap_ticks = (long)(TickCount() - began);
}

/* An empty frame skips the bulk plane entirely: begin and end go out as
   a control pair (~150 bytes), keeping fps honest on a static screen. */
static void stream_send_empty_frame(void)
{
    char json[256];
    unsigned short xfer = next_xfer();

    snprintf(json, sizeof json,
             "{\"type\":\"capture.begin\",\"id\":%ld,\"transfer\":%u,"
             "\"width\":%d,\"height\":%d,\"depth\":%d,"
             "\"rowBytes\":%d,\"bytes\":0,\"paletteBytes\":0,"
             "\"encoding\":\"raw\",\"captureMs\":%ld,"
             "\"frame\":\"empty\"}",
             g_stream.id, xfer, (int)g_stream.ready_meta.width,
             (int)g_stream.ready_meta.height,
             (int)g_stream.ready_meta.depth,
             (int)g_stream.ready_meta.row_bytes,
             g_stream.ready_meta.capture_ms);
    send_control(json);
    snprintf(json, sizeof json,
             "{\"type\":\"capture.end\",\"id\":%ld,\"transfer\":%u,"
             "\"ok\":true,\"sendMs\":0}", g_stream.id, xfer);
    send_control(json);
}

enum {
    kPredictMarginRows = 8,           /* canvas rows around old dirt */
    kSweepFrames = 8,                 /* whole screen swept every N */
    kSpanMergeGap = 5                 /* keep spans mergeable-safe apart */
};

/* Adds a canvas row range to a span list (canvas coords), merging spans
   closer than kSpanMergeGap so the diff's run-merging never straddles an
   uncaptured gap. */
static short span_add(CaptureSpan *spans, short count, long top,
                      long bottom, long limit)
{
    short i;

    if (top < 0) {
        top = 0;
    }
    if (bottom > limit) {
        bottom = limit;
    }
    if (top >= bottom) {
        return count;
    }
    for (i = 0; i < count; ++i) {
        long s_top = spans[i].row;
        long s_bot = spans[i].row + spans[i].n_rows;

        if (top <= s_bot + kSpanMergeGap && bottom + kSpanMergeGap >= s_top) {
            if (top < s_top) {
                s_top = top;
            }
            if (bottom > s_bot) {
                s_bot = bottom;
            }
            spans[i].row = (short)s_top;
            spans[i].n_rows = (short)(s_bot - s_top);
            return count;
        }
    }
    if (count < kCaptureMaxBands) {
        spans[count].row = (short)top;
        spans[count].n_rows = (short)(bottom - top);
        ++count;
    } else {
        /* Out of spans: widen the first to cover everything. Coarse but
           correct - it only ever costs read time. */
        long s_bot = spans[0].row + spans[0].n_rows;

        if (top < spans[0].row) {
            spans[0].row = (short)top;
        }
        if (bottom > s_bot) {
            s_bot = bottom;
        }
        spans[0].n_rows = (short)(s_bot - spans[0].row);
    }
    return count;
}

/* Chooses what the next capture reads and starts it. Keyframes read the
   whole screen at full scale; otherwise the interlace toggle picks the
   field and the predictive toggle narrows the rows. */
static int stream_begin_capture(void)
{
    CaptureSpan canvas[kCaptureMaxBands];
    CaptureSpan dst[kCaptureMaxBands];
    short n = 0;
    short scale = 1, phase = 0;
    long height = g_stream.prev_height > 0 ? g_stream.prev_height : 0x7FFF;
    short i;

    g_stream.cap_full = false;
    if (g_stream.force_key || g_stream.prev == NULL) {
        g_stream.cap_full = true;
        g_stream.cap_scale = 1;
        g_stream.cap_phase = 0;
        return banded_capture_begin(g_stream.depth, kStreamBands,
                                    &g_stream.cap) == kCaptureOK;
    }
    if (g_stream.interlace) {
        scale = 2;
        phase = g_stream.phase;
    }
    if (!g_stream.predictive) {
        n = span_add(canvas, 0, 0, height, height);
    } else {
        long slice = height / kSweepFrames + 1;

        for (i = 0; i < g_stream.n_dirty_hist; ++i) {
            n = span_add(canvas, n,
                         (long)g_stream.dirty_hist[i].row
                             - kPredictMarginRows,
                         (long)g_stream.dirty_hist[i].row
                             + g_stream.dirty_hist[i].n_rows
                             + kPredictMarginRows, height);
        }
        n = span_add(canvas, n, g_stream.sweep_pos,
                     g_stream.sweep_pos + slice, height);
        g_stream.sweep_pos += slice;
        if (g_stream.sweep_pos >= height) {
            g_stream.sweep_pos = 0;
        }
        if (n == 0) {
            n = span_add(canvas, 0, 0, height, height);
        }
    }
    /* Canvas rows -> destination (field) rows. */
    for (i = 0; i < n; ++i) {
        long top = canvas[i].row;
        long bottom = top + canvas[i].n_rows;
        long d_top = (top - phase + scale - 1) / scale;
        long d_bot = (bottom - phase + scale - 1) / scale;
        long d_limit = (height - phase + scale - 1) / scale;

        if (d_top < 0) {
            d_top = 0;
        }
        if (d_bot > d_limit) {
            d_bot = d_limit;
        }
        if (d_top >= d_limit) {
            d_top = d_limit - 1;
        }
        if (d_bot <= d_top) {
            d_bot = d_top + 1;
        }
        dst[i].row = (short)d_top;
        dst[i].n_rows = (short)(d_bot - d_top);
    }
    g_stream.cap_scale = scale;
    g_stream.cap_phase = phase;
    return banded_capture_begin_spans(g_stream.depth, dst, n, scale, phase,
                                      &g_stream.cap) == kCaptureOK;
}

/* The pipelined frame pump: while frame N sends, frame N+1 is captured a
   band at a time; when both halves are done the frame arms immediately. */
static void service_stream(void)
{
    static unsigned long cap_began;

    if (g_streamreq.pending && TickCount() > g_streamreq.deadline) {
        g_streamreq.pending = false;
        {
            char peer[40];
            char line[96];

            conn_peer_label(peer, sizeof peer);
            snprintf(line, sizeof line, "%s did not start streaming", peer);
            note_shot(line);
        }
    }
    if (!g_stream.active) {
        return;
    }
    if (g_stream.stopping) {
        if (!g_xfer.active) {
            g_stream.stopping = false;
            stream_end(NULL);
        }
        return;                       /* no new frames while stopping */
    }

    /* Arm a ready frame the moment the lane is free. */
    if (g_stream.ready && !g_xfer.active
        && TickCount() >= g_stream.next_frame_tick) {
        long interval = g_stream.min_interval_ticks;

        /* A still screen does not need fifteen updates a second. Back off
           after the second empty frame in a row; any real change snaps the
           pace back on the very next frame. The wait gates the capture too
           (a held frame stops the pump), so this bounds how stale the
           screen can get: a change is seen within one idle interval. */
        if (g_stream.ready_meta.kind == kFrameEmpty) {
            ++g_stream.empty_run;
            if (g_stream.empty_run > 1
                && interval < kStreamIdleIntervalTicks) {
                interval = kStreamIdleIntervalTicks;
            }
        } else {
            g_stream.empty_run = 0;
        }
        g_stream.next_frame_tick = TickCount() + (unsigned long)interval;
        g_stream.ready = false;
        if (g_stream.ready_meta.kind == kFrameEmpty) {
            stream_send_empty_frame();
        } else if (!arm_transfer(g_stream.id, next_xfer(),
                                 &g_stream.ready_meta,
                                 &g_stream.ready_blob, g_stream.chunk,
                                 g_stream.pace_ms, false)) {
            stream_end("transfer failed");
            return;
        }
        ++g_stream.frames;
        stream_schedule_capture();
        return;
    }

    /* Pump the in-progress capture, a small slice per pass: at ~17 ms a
       band, per-pass loop overhead was costing ~1 fps at 1-bit. */
    if (g_stream.cap_active) {
        unsigned long slice_end = TickCount() + 2;
        int rc;

        do {
            rc = banded_capture_step(&g_stream.cap);
        } while (rc == kCaptureMoreBands && TickCount() < slice_end);
        if (rc == kCaptureOK) {
            stream_finish_capture(cap_began);
        } else if (rc != kCaptureMoreBands) {
            g_stream.cap_active = false;
            stream_end("capture failed");
        }
        return;
    }

    /* Begin the next capture once its scheduled moment arrives (or at
       once when nothing is in flight - the first frame, or an estimate
       that ran short). */
    if (!g_stream.ready
        && (!g_xfer.active || TickCount() >= g_stream.cap_start_tick)) {
        if (!stream_begin_capture()) {
            stream_end("capture failed");
            return;
        }
        g_stream.cap_active = true;
        cap_began = TickCount();
    }
}

static int send_continuity_report(const NowContinuityReport *report)
{
    char json[512];
    const char *state = now_continuity_state_name(report->state);
    const char *reason = now_continuity_reason_name(report->exit_reason);

    if (report->id != 0 && reason != NULL) {
        snprintf(json, sizeof json,
                 "{\"type\":\"continuity.report\",\"version\":%u,"
                 "\"id\":%ld,"
                 "\"epoch\":%lu,\"state\":\"%s\",\"acceptedHz\":%lu,"
                 "\"udpPort\":%u,\"reason\":\"%s\","
                 "\"acceptedPackets\":%lu,\"stalePackets\":%lu,"
                 "\"malformedPackets\":%lu,"
                 "\"appliedPositionSequence\":%lu,"
                 "\"appliedButtonGeneration\":%lu}",
                 (unsigned)NOW_CONTINUITY_VERSION,
                 report->id, (unsigned long)report->epoch, state,
                 (unsigned long)report->accepted_hz,
                 (unsigned)now_continuity_udp_port(),
                 reason, (unsigned long)report->accepted_packets,
                 (unsigned long)report->stale_packets,
                 (unsigned long)report->malformed_packets,
                 (unsigned long)report->applied_position_seq,
                 (unsigned long)report->applied_button_generation);
    } else if (report->id != 0) {
        snprintf(json, sizeof json,
                 "{\"type\":\"continuity.report\",\"version\":%u,"
                 "\"id\":%ld,"
                 "\"epoch\":%lu,\"state\":\"%s\",\"acceptedHz\":%lu,"
                 "\"udpPort\":%u,\"acceptedPackets\":%lu,"
                 "\"stalePackets\":%lu,\"malformedPackets\":%lu,"
                 "\"appliedPositionSequence\":%lu,"
                 "\"appliedButtonGeneration\":%lu}",
                 (unsigned)NOW_CONTINUITY_VERSION,
                 report->id, (unsigned long)report->epoch, state,
                 (unsigned long)report->accepted_hz,
                 (unsigned)now_continuity_udp_port(),
                 (unsigned long)report->accepted_packets,
                 (unsigned long)report->stale_packets,
                 (unsigned long)report->malformed_packets,
                 (unsigned long)report->applied_position_seq,
                 (unsigned long)report->applied_button_generation);
    } else {
        snprintf(json, sizeof json,
                 "{\"type\":\"continuity.report\",\"version\":%u,"
                 "\"epoch\":%lu,"
                 "\"state\":\"%s\",\"acceptedHz\":%lu,\"udpPort\":%u,"
                 "\"reason\":\"%s\",\"acceptedPackets\":%lu,"
                 "\"stalePackets\":%lu,\"malformedPackets\":%lu,"
                 "\"appliedPositionSequence\":%lu,"
                 "\"appliedButtonGeneration\":%lu}",
                 (unsigned)NOW_CONTINUITY_VERSION,
                 (unsigned long)report->epoch, state,
                 (unsigned long)report->accepted_hz,
                 (unsigned)now_continuity_udp_port(),
                 reason != NULL ? reason : "disarmed",
                 (unsigned long)report->accepted_packets,
                 (unsigned long)report->stale_packets,
                 (unsigned long)report->malformed_packets,
                 (unsigned long)report->applied_position_seq,
                 (unsigned long)report->applied_button_generation);
    }
    return send_control(json);
}

static int continuity_refuse(long id, unsigned long epoch,
                             const char *reason)
{
    char json[224];
    snprintf(json, sizeof json,
             "{\"type\":\"continuity.report\",\"version\":%u,"
             "\"id\":%ld,"
             "\"epoch\":%lu,\"state\":\"refused\","
             "\"reason\":\"%s\"}",
             (unsigned)NOW_CONTINUITY_VERSION, id, epoch, reason);
    return send_control(json);
}

static void serve_continuity_arm(const char *request)
{
    long id = now_json_find_int(request, "id", 0);
    unsigned long nonce_hi = now_json_find_u32(request, "nonceHi", 0);
    unsigned long nonce_lo = now_json_find_u32(request, "nonceLo", 0);
    unsigned long epoch = now_json_find_u32(request, "epoch", 0);
    unsigned long hz = now_json_find_u32(request, "requestedHz", 0);
    unsigned long lease = now_json_find_u32(request, "leaseTicks", 0);
    int fast_pump = now_json_find_bool(request, "fastPump", 0);
    unsigned long tracking_options = 0;
    unsigned long version = now_json_find_u32(request, "version", 0);
    int result;

    if (version != NOW_CONTINUITY_VERSION) {
        (void)continuity_refuse(id, epoch, "wrong-version");
        return;
    }
    if (id == 0 || epoch == 0 || (nonce_hi == 0 && nonce_lo == 0)
        || (hz != 15 && hz != 30 && hz != 60)) {
        (void)continuity_refuse(id, epoch, "unavailable");
        return;
    }
    if (now_json_find_bool(request, "pinHeldPoint", 0))
        tracking_options |= kNowPeekContinuityTrackingPinHeldPoint;
    if (now_json_find_bool(request, "virtualGetMouse", 0))
        tracking_options |= kNowPeekContinuityTrackingVirtualGetMouse;
    if (now_json_find_bool(request, "settleSyntheticDevice", 0))
        tracking_options |=
            kNowPeekContinuityTrackingSettleSyntheticDevice;
    if (now_json_find_bool(request, "hideGuestCursorWhileDragging", 0))
        tracking_options |= kNowPeekContinuityTrackingHideGuestCursor;
    if (now_json_find_bool(request, "virtualADB", 0))
        tracking_options |= kNowPeekContinuityTrackingVirtualADB;
    if (now_json_find_bool(request, "wideDoubleTime", 0))
        tracking_options |= kNowPeekContinuityTrackingWideDoubleTime;
    if (now_json_find_bool(request, "settleIdleCursor", 0))
        tracking_options |= kNowPeekContinuityTrackingSettleIdleCursor;
    result = now_continuity_arm(id, g.port, nonce_hi, nonce_lo, epoch,
                                hz, lease, fast_pump, tracking_options);
    if (result == kNowContinuityArmUnsupported)
        (void)continuity_refuse(id, epoch, "resident-unavailable");
    else if (result == kNowContinuityArmTransportUnavailable)
        (void)continuity_refuse(id, epoch, "unavailable");
}

static void serve_continuity_disarm(const char *request)
{
    long id = now_json_find_int(request, "id", 0);
    unsigned long epoch = now_json_find_u32(request, "epoch", 0);
    unsigned long version = now_json_find_u32(request, "version", 0);
    if (version != NOW_CONTINUITY_VERSION)
        (void)continuity_refuse(id, epoch, "wrong-version");
    else if (id == 0 || !now_continuity_disarm(id, epoch))
        (void)continuity_refuse(id, epoch, "bad-epoch");
}

static int continuity_key_report(long id, unsigned long epoch,
                                 unsigned long generation,
                                 const char *state, const char *reason)
{
    char json[256];
    if (reason != NULL) {
        snprintf(json, sizeof json,
                 "{\"type\":\"continuity.keyReport\",\"version\":%u,"
                 "\"id\":%ld,\"epoch\":%lu,\"generation\":%lu,"
                 "\"state\":\"%s\",\"reason\":\"%s\"}",
                 (unsigned)NOW_CONTINUITY_VERSION, id, epoch, generation,
                 state, reason);
    } else {
        snprintf(json, sizeof json,
                 "{\"type\":\"continuity.keyReport\",\"version\":%u,"
                 "\"id\":%ld,\"epoch\":%lu,\"generation\":%lu,"
                 "\"state\":\"%s\"}",
                 (unsigned)NOW_CONTINUITY_VERSION, id, epoch, generation,
                 state);
    }
    return send_control(json);
}

static void serve_continuity_key(const char *request)
{
    long id = now_json_find_int(request, "id", 0);
    unsigned long version = now_json_find_u32(request, "version", 0);
    unsigned long epoch = now_json_find_u32(request, "epoch", 0);
    unsigned long generation = now_json_find_u32(request, "generation", 0);
    unsigned long code = now_json_find_u32(request, "code", 256);
    unsigned long character = now_json_find_u32(request, "character", 256);
    unsigned long modifiers = now_json_find_u32(request, "modifiers", 65536);
    unsigned long action = 0;
    char action_name[12];
    int result;

    if (version != NOW_CONTINUITY_VERSION) {
        (void)continuity_key_report(id, epoch, generation, "refused",
                                    "wrong-version");
        return;
    }
    if (now_json_find_string(request, "action", action_name,
                             sizeof action_name)) {
        if (strcmp(action_name, "down") == 0)
            action = kNowPeekContinuityKeyDown;
        else if (strcmp(action_name, "up") == 0)
            action = kNowPeekContinuityKeyUp;
        else if (strcmp(action_name, "repeat") == 0)
            action = kNowPeekContinuityKeyRepeat;
    }
    if (id == 0 || generation == 0 || action == 0
            || code > 127 || character > 255 || modifiers > 65535) {
        (void)continuity_key_report(id, epoch, generation, "refused",
                                    "malformed");
        return;
    }
    result = now_continuity_key(epoch, generation, action, code,
                                character, modifiers);
    if (result == kNowContinuityKeyQueued)
        (void)continuity_key_report(id, epoch, generation, "queued", NULL);
    else if (result == kNowContinuityKeyBadEpoch)
        (void)continuity_key_report(id, epoch, generation, "refused",
                                    "bad-epoch");
    else if (result == kNowContinuityKeyTargetUnavailable)
        (void)continuity_key_report(id, epoch, generation, "refused",
                                    "target-unavailable");
    else if (result == kNowContinuityKeyQueueFull)
        (void)continuity_key_report(id, epoch, generation, "refused",
                                    "queue-full");
    else
        (void)continuity_key_report(id, epoch, generation, "refused",
                                    "malformed");
}

static void service_continuity(void)
{
    NowContinuityReport report;
    if (now_continuity_take_report(&report)
        && !send_continuity_report(&report))
        fail("Connection lost");
}

/* Returns 0 if the connection should be torn down (bye/protocol error). */
static int handle_frame(const char *reply)
{
    if (reply[0] == '\0') {
        return 1;                    /* dropped non-control frame */
    }
    if (g.phase == kConnHandshaking) {
        if (now_json_type_is(reply, "hello")) {
            /* Not unconditionally 1: on_hello gates the contract revision
               and a refused hello tears the connection down here, the
               same way a `refuse` from the host does below. */
            return on_hello(reply);
        }
        if (now_json_type_is(reply, "refuse")) {
            char reason[96];
            if (now_json_find_string(reply, "reason", reason, sizeof reason)) {
                snprintf(g.status, sizeof g.status, "Refused: %s", reason);
            } else {
                {
                char peer[40];

                conn_peer_label(peer, sizeof peer);
                snprintf(g.status, sizeof g.status, "Refused by %s", peer);
            }
            }
            return 0;
        }
        snprintf(g.status, sizeof g.status, "Unexpected reply");
        return 0;
    }
    /* connected */
    if (now_json_type_is(reply, "pong")) {
        g.pings_sent = 0;
        g.last_rtt_ms = (long)((TickCount() - g.ping_sent_tick) * 1000 / 60);
        snprintf(g.status, sizeof g.status, "Connected: %s (v%s) - %ld ms",
                 g.peer_name, g.peer_version, g.last_rtt_ms);
        return 1;
    }
    /* A HOST DOING ANYTHING AT ALL IS A HOST THAT STILL WANTS THE PLANES.
       Below the `pong` return on purpose - our own heartbeat's echo is
       not a consumer asking for something. See renew_scene_planes(). */
    renew_scene_planes();
    if (now_json_type_is(reply, "continuity.arm")) {
        serve_continuity_arm(reply);
        return 1;
    }
    if (now_json_type_is(reply, "continuity.disarm")) {
        serve_continuity_disarm(reply);
        return 1;
    }
    if (now_json_type_is(reply, "continuity.key")) {
        serve_continuity_key(reply);
        return 1;
    }
    if (now_json_type_is(reply, "capture.request")) {
        serve_capture(reply);
        return 1;
    }
    if (now_json_type_is(reply, "capture.cancel")) {
        xfer_abort();
        return 1;
    }
    if (now_json_type_is(reply, "scene.request")) {
        serve_scene(reply);
        return 1;
    }
    if (now_json_type_is(reply, "file.list")) {
        serve_file_list(reply);
        return 1;
    }
    if (now_json_type_is(reply, "process.list")) {
        serve_process_list(reply);
        return 1;
    }
    if (now_json_type_is(reply, "software.list")) {
        serve_software_list(reply);
        return 1;
    }
    if (now_json_type_is(reply, "process.front")) {
        serve_process_act(reply, false);
        return 1;
    }
    if (now_json_type_is(reply, "process.quit")) {
        serve_process_act(reply, true);
        return 1;
    }
    if (now_json_type_is(reply, "process.shot")) {
        serve_process_shot(reply);
        return 1;
    }
    if (now_json_type_is(reply, "file.get")) {
        serve_file_get(reply);
        return 1;
    }
    if (now_json_type_is(reply, "file.cancel")) {
        if (g_put.active) {
            put_abort("cancelled", "the sender stopped");
            note_shot("Incoming file cancelled");
        } else {
            xfer_abort();
        }
        return 1;
    }
    if (now_json_type_is(reply, "file.move")) {
        serve_file_move(reply);
        return 1;
    }
    if (now_json_type_is(reply, "file.trash")) {
        serve_file_trash(reply);
        return 1;
    }
    if (now_json_type_is(reply, "file.restore")) {
        serve_file_restore(reply);
        return 1;
    }
    if (now_json_type_is(reply, "file.mkdir")) {
        serve_file_mkdir(reply);
        return 1;
    }
    if (now_json_type_is(reply, "file.offer")) {
        serve_file_offer(reply);
        return 1;
    }
    if (now_json_type_is(reply, "update.offer")) {
        char component[16];
        NowUpdateComponent which;
        NowUpdateOffer offer;

        memset(&offer, 0, sizeof offer);
        now_json_find_string(reply, "component", component,
                             sizeof component);
        if (!now_update_component_parse(component, &which)) return 1;
        offer.present = 1;
        now_json_find_string(reply, "version", offer.version,
                             sizeof offer.version);
        now_json_find_string(reply, "build", offer.build,
                             sizeof offer.build);
        now_json_find_string(reply, "sha256", offer.sha256,
                             sizeof offer.sha256);
        now_json_find_string(reply, "channel", offer.channel,
                             sizeof offer.channel);
        offer.bytes = now_json_find_int(reply, "bytes", 0);
        /* A peer's boolean is not a signature. Until this guest verifies
           signature bytes against a pinned key, every offer is unsigned and
           must take the local-consent path. */
        offer.signed_artifact = 0;
        offer.requires_restart = now_json_find_bool(
            reply, "requiresRestart", 0);
        if (!now_update_offer_set(which, &offer)) {
            now_log(kLogWarn, "update", "ignored invalid %s offer",
                    component);
        }
        return 1;
    }
    if (now_json_type_is(reply, "file.accept")) {
        send_accepted(reply);
        return 1;
    }
    if (now_json_type_is(reply, "file.listing")) {
        browse_listing(reply);
        return 1;
    }
    if (now_json_type_is(reply, "cloud.report")) {
        cloud_answer(kCloudAnswerReport, reply);
        return 1;
    }
    if (now_json_type_is(reply, "cloud.listing")) {
        cloud_answer(kCloudAnswerListing, reply);
        return 1;
    }
    if (now_json_type_is(reply, "cloud.card")) {
        cloud_answer(kCloudAnswerCard, reply);
        return 1;
    }
    if (now_json_type_is(reply, "cloud.refuse")) {
        cloud_refused(reply);
        return 1;
    }
    if (now_json_type_is(reply, "chat.catalog")) {
        chat_catalog_answer(reply);
        return 1;
    }
    if (now_json_type_is(reply, "chat.delta")) {
        chat_delta_answer(reply);
        return 1;
    }
    if (now_json_type_is(reply, "chat.status")) {
        chat_status_answer(reply);
        return 1;
    }
    if (now_json_type_is(reply, "host.shown")) {
        host_shown_answer(reply);
        return 1;
    }
    if (now_json_type_is(reply, "chat.result")) {
        chat_result_answer(reply);
        return 1;
    }
    if (now_json_type_is(reply, "preview.begin")) {
        preview_begin(reply);
        return 1;
    }
    if (now_json_type_is(reply, "preview.end")) {
        preview_end(reply);
        return 1;
    }
    if (now_json_type_is(reply, "file.refuse")) {
        long refused_id = now_json_find_int(reply, "id", -1);
        if (g_update.pending && refused_id == g_update.id) {
            char reason[96];
            if (!now_json_find_text(reply, "reason", reason, sizeof reason)) {
                strcpy(reason, "the update is no longer available");
            }
            now_log(kLogWarn, "update", "%s", reason);
            g_update.pending = false;
        } else if (g_get.pending && refused_id == g_get.id) {
            char reason[96];

            get_cleanup(false);
            if (!now_json_find_text(reply, "reason", reason, sizeof reason)) {
                strcpy(reason, "the other Mac refused");
            }
            get_note(reason);
        } else if (!browse_refused(reply)) {
            send_refused(reply);
        }
        return 1;
    }
    if (now_json_type_is(reply, "file.progress")) {
        if (g_send.active
            && now_json_find_int(reply, "id", -1) == g_send.id) {
            long received = now_json_find_int(reply, "received", 0);

            if (received >= g_send.received && received <= g_send.total) {
                g_send.received = received;
                g_send.receiving_reports = true;
            }
        }
        return 1;
    }
    if (now_json_type_is(reply, "file.done")) {
        send_done(reply);
        return 1;
    }
    if (now_json_type_is(reply, "file.begin")) {
        /* file.begin now announces two different things: a file we
           ASKED for, and one the other machine offered and we accepted.
           The pending pull decides, and only one can be live because
           the bulk lane is one transfer wide. */
        if (g_get.pending) {
            get_begin(reply);
        } else {
            put_begin(reply);
        }
        return 1;
    }
    if (now_json_type_is(reply, "file.end")) {
        if (g_get.receiving) {
            get_end(reply);
        } else {
            finish_put(reply);
        }
        return 1;
    }
    if (now_json_type_is(reply, "stream.start")) {
        stream_start(reply);
        return 1;
    }
    if (now_json_type_is(reply, "stream.stop")) {
        stream_stop(reply);
        return 1;
    }
    if (now_json_type_is(reply, "stream.refresh")) {
        if (g_stream.active
            && now_json_find_int(reply, "id", -1) == g_stream.id) {
            g_stream.force_key = true;
        }
        return 1;
    }
    if (now_json_type_is(reply, "capture.accept")) {
        offer_accepted(reply);
        return 1;
    }
    if (now_json_type_is(reply, "capture.refuse")) {
        offer_refused(reply);
        return 1;
    }
    if (now_json_type_is(reply, "command.request")) {
        char name[48];
        char result[kNowCommandResultCap];
        long id = now_json_find_int(reply, "id", 0);

        if (!now_json_find_string(reply, "name", name, sizeof name)) {
            strcpy(name, "?");
        }
        now_command_run(name, reply, id, result, sizeof result);
        if (!send_control(result)) {
            fail("Connection lost");
            return 0;
        }
        return 1;
    }
    if (now_json_type_is(reply, "exec.request")) {
        serve_exec(reply);
        return 1;
    }
    if (now_json_type_is(reply, "exec.cancel")) {
        serve_exec_cancel(reply);
        return 1;
    }
    if (now_json_type_is(reply, "exec.input")) {
        serve_exec_input(reply);
        return 1;
    }
    if (now_json_type_is(reply, "census.request")) {
        serve_census(reply);
        return 1;
    }
    if (now_json_type_is(reply, "error")) {
        if (g_streamreq.pending) {
            g_streamreq.pending = false;
            {
                char peer[40];
                char line[96];

                conn_peer_label(peer, sizeof peer);
                snprintf(line, sizeof line, "%s declined the stream", peer);
                note_shot(line);
            }
        }
        return 1;
    }
    if (now_json_type_is(reply, "bye")) {
        char reason[96];
        if (now_json_find_string(reply, "reason", reason, sizeof reason)) {
            {
                char peer[40];

                conn_peer_label(peer, sizeof peer);
                snprintf(g.status, sizeof g.status, "%.39s disconnected: %.60s",
                         peer, reason);
            }
        } else {
            {
                char peer[40];

                conn_peer_label(peer, sizeof peer);
                snprintf(g.status, sizeof g.status, "%s disconnected", peer);
            }
        }
        return 0;
    }
    return 1;                        /* ignore anything else for now */
}

/* Read and drain in turns until nothing more is waiting, bounded by a
   slice so the app stays responsive. One read per event-loop pass was
   enough while everything inbound was a small control message; a file
   arriving needs far more than a bufferful per turn. */
enum { kIoSliceTicks = 3 };           /* ~50 ms */

static void service_connected_io(void)
{
    /* The contract caps a control frame at 4 KB, so the receiver has to
       be able to HOLD 4 KB. This was 1200 for as long as everything
       arriving was a pong or a request; the first listing off the wire
       overflowed it and took the connection down. A buffer smaller than
       the contract allows is a bug waiting for a big enough message. */
    char payload[kNowMaxControl + 4];
    unsigned long slice_end = TickCount() + kIoSliceTicks;
    int rc;

    for (;;) {
        long before = g.rx_len;
        long read_this_pass;

        if (!pump_rx()) {
            fail("Connection lost");
            return;
        }
        read_this_pass = g.rx_len - before;

        for (;;) {
            rc = next_frame(payload, sizeof payload);
            if (rc == 0) {
                break;
            }
            if (rc < 0) {
                fail("Protocol error");
                return;
            }
            if (!handle_frame(payload)) {
                /* Peer said goodbye or we rejected it: orderly release,
                   backoff. handle_frame set g.status to the specific
                   reason — keep it. */
                snprintf(g.last_fail, sizeof g.last_fail, "%s", g.status);
                gNowOT.sndOrderlyDisconnect(g.ep);
                enter_backoff();
                return;
            }
        }
        if (read_this_pass == 0 || TickCount() > slice_end) {
            return;
        }
    }
}

static void service_heartbeat(void)
{
    unsigned long now = TickCount();
    char ping[48];

    /* **Time we were not scheduled is not time the host was silent, and
       this is the one place that used to assume it was.**
       -----------------------------------------------------------------
       Found 2026-08-06, driving plan 012's resident channel end to end
       against the real host. The host had just been taught that a
       starved Macintosh is not a gone one - and the session still died,
       because the GUEST reached the same wrong conclusion from the other
       end. A `guest-wedge spin 110` starved every application for 108 s;
       when this loop next ran, `last_rx_tick` was 110 s old and it
       declared the link dead. The resident's channel had answered for
       the machine throughout, the host had held the session open, and
       the application tore it down anyway.

       The guest's version of the error is the plainer one. The host at
       least observed real silence and had to be told the machine might
       be alive behind it; here nothing was silent at all - we were not
       running to listen, and then blamed the far side for it.

       A pass gap this long is proof of the starvation rather than
       evidence of it, so the interval is FORGIVEN: the dead-link clock
       is advanced past it instead of counting it. What that preserves is
       the thing the timeout is for - a link that is genuinely dead is
       still noticed, one window later, because the clock resumes from
       now rather than being reset to now.

       This deliberately needs no extension. The resident's
       `liveness_ticks` says the same thing more precisely and an
       application that has one could read it, but a rule this important
       must not be optional: the product degrades honestly without a
       resident component (docs/resident-components.md), and "keeps its
       session through a modal" should not be a thing only some machines
       do. */
    if (g.last_pass_tick != 0 && now - g.last_pass_tick > kStarvedPassTicks) {
        unsigned long starved = now - g.last_pass_tick;

        if (now - g.last_rx_tick > starved) {
            g.last_rx_tick += starved;
        } else {
            g.last_rx_tick = now;
        }
        /* The ping is owed from now, not from before the starvation: a
           ping the host would have seen 100 s ago is one we could not
           have sent. */
        if (g.next_ping_tick < now) {
            g.next_ping_tick = now;
        }
        now_log(kLogWarn, "wire",
                "not scheduled for %lus - forgiving the gap rather than "
                "calling the link dead", starved / 60);
    }
    g.last_pass_tick = now;

    if (now - g.last_rx_tick > kDeadTicks) {
        fail("Reconnecting (no answer)");
        return;
    }
    if (now >= g.next_ping_tick) {
        ++g.ping_id;
        snprintf(ping, sizeof ping, "{\"type\":\"ping\",\"id\":%ld}",
                 g.ping_id);
        g.ping_sent_tick = now;
        if (!send_control(ping)) {
            fail("Connection lost");
            return;
        }
        ++g.pings_sent;
        g.next_ping_tick = now + kPingIntervalTicks;
    }
}

/* --- public API --------------------------------------------------------- */

void conn_init(void)
{
    NowPrefs prefs;

    memset(&g, 0, sizeof g);
    now_update_model_reset();
    memset(&g_update, 0, sizeof g_update);
    g.ep = kOTInvalidEndpointRef;
    g.last_rtt_ms = -1;
    loopstat_reset(&g_pass_stat);
    loopstat_reset(&g_wake_stat);
    /* Once, on the main thread. The wake path needs a PSN at interrupt
       time and GetCurrentProcess is not a call to be making there. */
    g_self_psn_known = (GetCurrentProcess(&g_self_psn) == noErr);
    now_prefs_load(&prefs);
    strncpy(g.host, prefs.host, sizeof g.host - 1);
    g.port = prefs.port;
    strcpy(g.status, "Not connected");
    /* The Connection page's "Connect when New Old World opens". Off
       means the target is loaded but nothing dials until asked. */
    if (prefs.auto_connect) {
        g.want_connection = true;
        start_connect();
    }
}

void conn_shutdown(void)
{
    if (g.ep != kOTInvalidEndpointRef) {
        if (g.phase == kConnConnected) {
            unsigned long flush_deadline = TickCount() + 60;

            send_control("{\"type\":\"bye\",\"code\":\"normal\"}");
            while (g_ctlq.count > 0 && TickCount() < flush_deadline) {
                if (!service_ctl_tx()) {
                    break;
                }
            }
        }
        gNowOT.sndOrderlyDisconnect(g.ep);
        ctlq_clear();
        close_endpoint();
    }
    g.want_connection = false;
    g.phase = kConnIdle;
    if (g_connect_notifier != NULL) {
        DisposeOTNotifyUPP(g_connect_notifier);
        g_connect_notifier = NULL;
    }
}

void now_wire_pump(void)
{
    static Boolean pumping = false;

    if (pumping) {
        return;
    }
    pumping = true;
    conn_service();
    pumping = false;
}

static void service_mirror_invalidation(void)
{
    NowMirrorInvalidation hint;
    char json[384];
    const char *quality;
    long pos;

    if (g.phase != kConnConnected
        || !now_transitions_take_invalidation(&hint)) {
        return;
    }
    quality = hint.quality == kNowInvalidationGap ? "gap"
        : hint.quality == kNowInvalidationUnknown ? "unknown" : "sampled";
    pos = snprintf(json, sizeof json,
                   "{\"type\":\"mirror.invalidate\","
                   "\"session\":\"%lu\",\"generation\":%lu,"
                   "\"domains\":{\"structure\":%lu,\"front\":%lu,"
                   "\"menus\":%lu,\"finder\":%lu,\"content\":%lu},",
                   g.connected_tick, (unsigned long)hint.generation,
                   (unsigned long)hint.structure, (unsigned long)hint.front,
                   (unsigned long)hint.menus, (unsigned long)hint.finder,
                   (unsigned long)hint.content);
    if (pos < 0 || pos >= (long)sizeof json) {
        return;
    }
    snprintf(json + pos, sizeof json - (size_t)pos,
             "\"quality\":\"%s\",\"lost\":%lu,"
             "\"source\":\"transitions\"}", quality,
             (unsigned long)hint.lost);
    /* Best effort by contract. A later event carries cumulative generations;
       cadence polling remains the recovery when this queue is full. */
    (void)send_control(json);
}

void conn_service(void)
{
    ++g_service_passes;
    /* Ordinary application context, including nested Toolbox pumps. This is
       the sole drain of the resident P5 cursor; it never runs in the OT
       notifier or resident filter. */
    now_transitions_poll();
    /* The loop's own rhythm, sampled where the loop reaches the wire
       rather than in main.c: every nested Toolbox loop pumps through
       here too (pump.h), so this counts the passes that could have
       served a request, which is the quantity the latency is made of. */
    if (g.phase == kConnConnected || g.phase == kConnHandshaking) {
        UnsignedWide now;

        Microseconds(&now);
        if (g_pass_seen) {
            UnsignedWide then;

            then.hi = g_last_pass_us_hi;
            then.lo = g_last_pass_us_lo;
            loopstat_add(&g_pass_stat, wide_delta_us(&then, &now));
        }
        g_last_pass_us_hi = now.hi;
        g_last_pass_us_lo = now.lo;
        g_pass_seen = true;
    }
    switch (g.phase) {
    case kConnConnecting:
        service_connecting();
        break;
    case kConnHandshaking:
        if (!service_ctl_tx()) {
            fail("Connection lost");
            break;
        }
        service_connected_io();
        if (g.phase == kConnHandshaking && TickCount() > g.phase_deadline) {
            fail("No hello reply (8s)");
        }
        break;
    case kConnConnected:
        if (!service_ctl_tx()) {
            fail("Connection lost");
            break;
        }
        service_connected_io();
        if (g.phase == kConnConnected) {
            service_continuity();
        }
        if (g.phase == kConnConnected) {
            service_offer();
    service_send();
    service_browse();
    service_get();
    service_cloud();
    service_chat();
    service_host_show();
        }
        if (g.phase == kConnConnected) {
            service_stream();
        }
        if (g.phase == kConnConnected) {
            service_shot();
        }
        if (g.phase == kConnConnected) {
            service_transfer();
        }
        if (g.phase == kConnConnected) {
            service_mirror_invalidation();
        }
        if (g.phase == kConnConnected) {
            service_heartbeat();
        }
        break;
    case kConnBackoff:
        if (TickCount() >= g.backoff_until) {
            start_connect();
        } else {
            unsigned long remain =
                (g.backoff_until - TickCount() + 59) / 60;
            if (g.last_fail[0] != '\0') {
                snprintf(g.status, sizeof g.status,
                         "%.100s - retry in %lus", g.last_fail, remain);
            } else {
                snprintf(g.status, sizeof g.status,
                         "Reconnecting in %lus...", remain);
            }
        }
        break;
    default:
        break;
    }
}

void conn_set_target(const char *host, unsigned short port)
{
    strncpy(g.host, host, sizeof g.host - 1);
    g.host[sizeof g.host - 1] = '\0';
    g.port = port;
    g.want_connection = true;
    g.backoff_ticks = 0;
    g.last_rtt_ms = -1;
    start_connect();
}

void conn_disconnect(void)
{
    if (g.ep != kOTInvalidEndpointRef && g.phase == kConnConnected) {
        unsigned long flush_deadline = TickCount() + 60;

        send_control("{\"type\":\"bye\",\"code\":\"normal\"}");
        while (g_ctlq.count > 0 && TickCount() < flush_deadline) {
            if (!service_ctl_tx()) {
                break;
            }
        }
        gNowOT.sndOrderlyDisconnect(g.ep);
    }
    /* After the bye is flushed, not before: the queue drain above is the
       last thing this link is asked to carry. */
    link_drop_transfers();
    close_endpoint();
    g.want_connection = false;
    g_update.pending = false;
    now_update_model_reset();
    g.phase = kConnIdle;
    strcpy(g.status, "Not connected");
}

void conn_connect_now(void)
{
    g.want_connection = true;
    g.backoff_ticks = 0;
    start_connect();
}

long conn_rcv_window(void)
{
    return g_rcv_window;
}

long conn_rcv_peak(void)
{
    return g_rcv_peak;
}

long conn_service_passes(void)
{
    return g_service_passes;
}

void conn_wake_stats(ConnWakeStats *out)
{
    if (out == NULL) {
        return;
    }
    out->pass = g_pass_stat;
    out->wake = g_wake_stat;
    out->data_events = g_data_events;
    out->wake_calls = g_wake_calls;
    out->wake_enabled = g_wake_enabled;
    out->notifier_live = g.notify_data_era;
    out->sleep_ticks = conn_sleep_ticks();
}

void conn_set_wake(Boolean on)
{
    g_wake_enabled = on;
    now_log(kLogInfo, "wire", "wake-on-data %s", on ? "on" : "off");
}

Boolean conn_wake_is_on(void)
{
    return g_wake_enabled;
}

void conn_reset_wake_stats(void)
{
    loopstat_reset(&g_pass_stat);
    loopstat_reset(&g_wake_stat);
    g_pass_seen = false;
    g_data_events = 0;
    g_wake_calls = 0;
}

void conn_peer_label(char *out, long cap)
{
    if (g.peer_name[0] != '\0') {
        snprintf(out, (size_t)cap, "%s", g.peer_name);
    } else {
        snprintf(out, (size_t)cap, "the other Mac");
    }
}

ConnPhase conn_phase(void)
{
    return g.phase;
}

Boolean conn_wants_fast_pump(void)
{
    return g_xfer.active || g_stream.active || g_offer.active
        || g_put.active || g_ctlq.count > 0
        || now_continuity_wants_fast_pump();
}

long conn_sleep_ticks(void)
{
    /* The rule itself is in wire_sleep.c, where a host compiler can run
       it. This supplies the three facts and nothing else. */
    return now_wire_sleep_ticks(conn_wants_fast_pump(), g_data_pending,
                                g_idle_sleep_ticks);
}

void conn_set_idle_sleep(long ticks)
{
    g_idle_sleep_ticks = now_wire_clamp_idle(ticks);
    now_log(kLogInfo, "wire", "idle sleep now %ld tick(s)",
            g_idle_sleep_ticks);
}

long conn_idle_sleep(void)
{
    return g_idle_sleep_ticks;
}

Boolean conn_is_connected(void)
{
    return g.phase == kConnConnected;
}

void conn_status(char *out, long cap)
{
    snprintf(out, cap, "%s", g.status);
}

void conn_snapshot(ConnSnapshot *out)
{
    unsigned long now = TickCount();

    memset(out, 0, sizeof *out);
    out->phase = g.phase;
    strncpy(out->host, g.host, sizeof out->host - 1);
    out->port = g.port;
    strncpy(out->peer_name, g.peer_name, sizeof out->peer_name - 1);
    strncpy(out->peer_version, g.peer_version,
            sizeof out->peer_version - 1);
    strncpy(out->last_fail, g.last_fail, sizeof out->last_fail - 1);
    out->retry_in_secs = -1;
    out->connected_secs = -1;
    out->quiet_secs = -1;
    if (g.phase == kConnBackoff && g.backoff_until > now) {
        out->retry_in_secs = (long)((g.backoff_until - now + 59) / 60);
    }
    if (g.phase == kConnConnected && g.connected_tick != 0) {
        out->connected_secs = (long)((now - g.connected_tick) / 60);
    }
    if (g.last_rx_tick != 0) {
        out->quiet_secs = (long)((now - g.last_rx_tick) / 60);
    }
    out->contract_revision = kNowContractRevision;
    out->transfer_active = conn_wants_fast_pump();
}

long conn_last_rtt_ms(void)
{
    return g.last_rtt_ms;
}
