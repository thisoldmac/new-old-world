#include "db_hilite.h"

typedef OSStatus (*HiliteStyleProc)(ControlRef,
                                    DataBrowserTableViewHiliteStyle);

void now_browser_fill_hilite(ControlRef browser)
{
    static HiliteStyleProc proc;
    static Boolean looked;

    if (!looked) {
        CFragConnectionID conn;
        Ptr main_addr;
        Str255 err_name;
        CFragSymbolClass cls;

        looked = true;
        /* The compile-time constant is free; only the CALL needs the
           export to exist. FindSymbol hands back a TVector, which IS a
           CFM function pointer — the same bargain ot_carbon.c strikes
           for the optional Open Transport entry points. */
        if (GetSharedLibrary((ConstStr255Param)"\pCarbonLib",
                             kPowerPCCFragArch, kFindCFrag, &conn,
                             &main_addr, err_name) == noErr) {
            if (FindSymbol(conn,
                           (ConstStr255Param)
                           "\pSetDataBrowserTableViewHiliteStyle",
                           (Ptr *)&proc, &cls) != noErr) {
                proc = NULL;
            }
        }
    }
    if (proc != NULL && browser != NULL) {
        (*proc)(browser, kDataBrowserTableViewFillHilite);
    }
}
