#include "ot_carbon.h"

#include <string.h>

NowOTTable gNowOT;
OTClientContextPtr gNowOTContext = NULL;

static Boolean g_resolved = false;
static Boolean g_inited = false;

typedef struct {
    const char *name;
    void **slot;
} SymbolSpec;

OSStatus now_ot_resolve(void)
{
    CFragConnectionID conn = 0;
    Ptr mainAddr = NULL;
    Str255 errName;
    Str255 pname;
    CFragSymbolClass cls;
    OSErr err;
    int i;
    SymbolSpec specs[] = {
        { "InitOpenTransportInContext", (void **)&gNowOT.initOT },
        { "CloseOpenTransportInContext", (void **)&gNowOT.closeOT },
        { "OTOpenEndpointInContext", (void **)&gNowOT.openEndpoint },
        { "OTCloseProvider", (void **)&gNowOT.closeProvider },
        { "OTInstallNotifier", (void **)&gNowOT.installNotifier },
        { "OTRemoveNotifier", (void **)&gNowOT.removeNotifier },
        { "OTSetAsynchronous", (void **)&gNowOT.setAsynchronous },
        { "OTSetSynchronous", (void **)&gNowOT.setSynchronous },
        { "OTSetNonBlocking", (void **)&gNowOT.setNonBlocking },
        { "OTBind", (void **)&gNowOT.bind },
        { "OTListen", (void **)&gNowOT.listen },
        { "OTAccept", (void **)&gNowOT.accept },
        { "OTGetEndpointState", (void **)&gNowOT.getEndpointState },
        { "OTConnect", (void **)&gNowOT.connect },
        { "OTRcvConnect", (void **)&gNowOT.rcvConnect },
        { "OTLook", (void **)&gNowOT.look },
        { "OTSnd", (void **)&gNowOT.snd },
        { "OTRcv", (void **)&gNowOT.rcv },
        { "OTSndOrderlyDisconnect", (void **)&gNowOT.sndOrderlyDisconnect },
        { "OTSndDisconnect", (void **)&gNowOT.sndDisconnect },
        { "OTRcvOrderlyDisconnect", (void **)&gNowOT.rcvOrderlyDisconnect },
        { "OTRcvDisconnect", (void **)&gNowOT.rcvDisconnect },
        { "OTUnbind", (void **)&gNowOT.unbind },
        { "OTOptionManagement", (void **)&gNowOT.optionManagement },
        { "OTSndUData", (void **)&gNowOT.sndUData },
        { "OTRcvUData", (void **)&gNowOT.rcvUData },
        { "OTRcvUDErr", (void **)&gNowOT.rcvUDErr },
    };
    /* Resolved separately because a miss here must NOT be fatal. Every
       symbol above is load-bearing, so the loop treats absence as a
       failed resolve — which takes the whole wire down. A diagnostic
       counter has no business doing that: put it in the list above and a
       guest whose CarbonLib does not export it simply never dials in,
       looking for all the world like a hang. */
    SymbolSpec optional_specs[] = {
        { "OTCountDataBytes", (void **)&gNowOT.countDataBytes },
    };

    if (g_resolved) {
        return noErr;
    }
    err = GetSharedLibrary((ConstStr255Param)"\pApple;Carbon;Networking",
                           kPowerPCCFragArch,
                           kReferenceCFrag, &conn, &mainAddr, errName);
    if (err != noErr) {
        return err;
    }
    for (i = 0; i < (int)(sizeof specs / sizeof specs[0]); ++i) {
        pname[0] = (unsigned char)strlen(specs[i].name);
        memcpy(pname + 1, specs[i].name, pname[0]);
        err = FindSymbol(conn, pname, (Ptr *)specs[i].slot, &cls);
        if (err != noErr || *specs[i].slot == NULL) {
            return err != noErr ? err : cfragNoSymbolErr;
        }
    }
    for (i = 0; i < (int)(sizeof optional_specs / sizeof optional_specs[0]);
         ++i) {
        pname[0] = (unsigned char)strlen(optional_specs[i].name);
        memcpy(pname + 1, optional_specs[i].name, pname[0]);
        if (FindSymbol(conn, pname, (Ptr *)optional_specs[i].slot, &cls)
            != noErr) {
            *optional_specs[i].slot = NULL;   /* callers null-check */
        }
    }
    g_resolved = true;
    return noErr;
}

OSStatus now_ot_ensure_inited(void)
{
    OSStatus err;

    if (!g_resolved) {
        err = now_ot_resolve();
        if (err != noErr) {
            return err;
        }
    }
    if (g_inited) {
        return noErr;
    }
    err = gNowOT.initOT(kInitOTForApplicationMask, &gNowOTContext);
    if (err == noErr) {
        g_inited = true;
    }
    return err;
}
