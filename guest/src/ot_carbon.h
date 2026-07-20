#ifndef NOW_OT_CARBON_H
#define NOW_OT_CARBON_H

#include <Carbon.h>
#include <OpenTransport.h>
#include <OpenTptInternet.h>

/* Carbon OT on OS 9 lives in CarbonLib's "Apple;Carbon;Networking" CFM
   sub-fragment (CarbonLib 1.4+; NOW requires 1.6). We resolve it at runtime
   instead of link time on purpose: a strong import would abort launch on
   stock CarbonLib 1.2 with an opaque system dialog, while runtime lookup
   lets the app launch anywhere and explain the prerequisite in its own UI.
   Metal- and emu-verified 2026-07-19 (finding carbon-ot-needs-carbonlib-16). */

typedef struct {
    OSStatus (*initOT)(OTInitializationFlags flags, OTClientContextPtr *ctx);
    void (*closeOT)(OTClientContextPtr ctx);
    EndpointRef (*openEndpoint)(OTConfigurationRef cfg, OTOpenFlags flags,
                                TEndpointInfo *info, OSStatus *err,
                                OTClientContextPtr ctx);
    OSStatus (*closeProvider)(ProviderRef ref);
    OSStatus (*setNonBlocking)(ProviderRef ref);
    OSStatus (*bind)(EndpointRef ref, TBind *req, TBind *ret);
    OSStatus (*connect)(EndpointRef ref, TCall *sndCall, TCall *rcvCall);
    OSStatus (*rcvConnect)(EndpointRef ref, TCall *call);
    OTResult (*look)(EndpointRef ref);
    OTResult (*snd)(EndpointRef ref, void *buf, OTByteCount nbytes,
                    OTFlags flags);
    OTResult (*rcv)(EndpointRef ref, void *buf, OTByteCount nbytes,
                    OTFlags *flags);
    OSStatus (*sndOrderlyDisconnect)(EndpointRef ref);
    OSStatus (*rcvOrderlyDisconnect)(EndpointRef ref);
    OSStatus (*rcvDisconnect)(EndpointRef ref, TDiscon *discon);
    OSStatus (*unbind)(EndpointRef ref);
    OSStatus (*optionManagement)(EndpointRef ref, TOptMgmt *req,
                                 TOptMgmt *ret);
} NowOTTable;

/* Resolves the table once (idempotent). Returns noErr, or an error when the
   Networking fragment is absent — i.e. CarbonLib < 1.4 — which callers must
   surface as "install CarbonLib 1.6", never swallow. */
OSStatus now_ot_resolve(void);

/* Valid only after now_ot_resolve() returned noErr. */
extern NowOTTable gNowOT;
extern OTClientContextPtr gNowOTContext;

/* InitOpenTransportInContext, run once lazily; noErr when OT is up. */
OSStatus now_ot_ensure_inited(void);

#endif
