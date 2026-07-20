#include "settings_dialog.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "prefs.h"
#include "wire.h"

enum {
    kSettingsDialogID = 300,
    kItemSave = 1,
    kItemCancel = 2,
    kItemConnect = 3,
    kItemHostField = 4,
    kItemPortField = 5,
    kItemStatus = 6,
    kItemRetryField = 9
};

static void get_field(DialogRef dialog, short item, char *out, long cap)
{
    Handle handle;
    short kind;
    Rect box;
    Str255 text;
    long n;

    GetDialogItem(dialog, item, &kind, &handle, &box);
    GetDialogItemText(handle, text);
    n = text[0] < cap - 1 ? text[0] : cap - 1;
    memcpy(out, text + 1, n);
    out[n] = '\0';
}

static void set_field(DialogRef dialog, short item, const char *value)
{
    Handle handle;
    short kind;
    Rect box;
    Str255 text;

    GetDialogItem(dialog, item, &kind, &handle, &box);
    CopyCStringToPascal(value, text);
    SetDialogItemText(handle, text);
}

/* The action button reads the current state: Disconnect while connected,
   Connect otherwise. */
static void set_button_title(DialogRef dialog, short item, const char *value)
{
    Handle handle;
    short kind;
    Rect box;
    Str255 text;

    GetDialogItem(dialog, item, &kind, &handle, &box);
    if (handle != NULL) {
        CopyCStringToPascal(value, text);
        SetControlTitle((ControlRef)handle, text);
    }
}

/* Reflect the live connection status into the dialog's status field, but only
   when it actually changes — SetDialogItemText redraws, and doing it every
   filter tick would flicker. */
static Boolean g_last_connected;
static Boolean g_button_primed;

static void refresh_status(DialogRef dialog, char *last, long cap)
{
    char now[128];
    Boolean connected = conn_is_connected();

    conn_status(now, sizeof now);
    if (strcmp(now, last) != 0) {
        strncpy(last, now, cap - 1);
        last[cap - 1] = '\0';
        set_field(dialog, kItemStatus, now);
    }
    if (!g_button_primed || connected != g_last_connected) {
        set_button_title(dialog, kItemConnect,
                         connected ? "Disconnect" : "Connect");
        g_last_connected = connected;
        g_button_primed = true;
    }
}

/* The connection is serviced from the main event loop, but that loop is
   suspended while ModalDialog runs. This filter keeps it pumping (and the
   status live) so a connection attempt started from the dialog completes
   while the dialog is open. */
static char g_last_status[128];
static DialogRef g_filter_dialog;

static pascal Boolean settings_filter(DialogRef dialog, EventRecord *event,
                                      short *item)
{
    ModalFilterUPP std_proc = NULL;

    if (dialog == g_filter_dialog) {
        conn_service();
        refresh_status(dialog, g_last_status, sizeof g_last_status);
    }
    /* Chain the standard filter so Return maps to Save and Escape/Cmd-. to
       Cancel; without this our filter would swallow the keyboard. */
    if (GetStdFilterProc(&std_proc) == noErr && std_proc != NULL) {
        return InvokeModalFilterUPP(dialog, event, item, std_proc);
    }
    return false;
}

static void apply_and_connect(DialogRef dialog)
{
    char host[64];
    char port_text[16];
    long port;

    get_field(dialog, kItemHostField, host, sizeof host);
    get_field(dialog, kItemPortField, port_text, sizeof port_text);
    port = strtol(port_text, NULL, 10);
    if (port <= 0 || port > 65535 || host[0] == '\0') {
        set_field(dialog, kItemStatus, "Enter a host and a port (1-65535)");
        g_last_status[0] = '\0';
        return;
    }
    conn_set_target(host, (unsigned short)port);
    g_last_status[0] = '\0';         /* force the next refresh to paint */
}

void now_settings_dialog_run(void)
{
    DialogRef dialog;
    ModalFilterUPP filter;
    short hit;
    NowPrefs prefs;
    char port_text[16];
    Boolean done = false;

    now_prefs_load(&prefs);
    dialog = GetNewDialog(kSettingsDialogID, NULL, (WindowRef)-1);
    if (dialog == NULL) {
        return;
    }
    SetDialogDefaultItem(dialog, kItemSave);
    SetDialogCancelItem(dialog, kItemCancel);
    set_field(dialog, kItemHostField, prefs.host);
    snprintf(port_text, sizeof port_text, "%u", prefs.port);
    set_field(dialog, kItemPortField, port_text);
    snprintf(port_text, sizeof port_text, "%d", (int)prefs.retry_secs);
    set_field(dialog, kItemRetryField, port_text);
    g_last_status[0] = '\0';
    g_button_primed = false;
    refresh_status(dialog, g_last_status, sizeof g_last_status);
    SelectDialogItemText(dialog, kItemHostField, 0, 32767);
    ShowWindow(GetDialogWindow(dialog));

    g_filter_dialog = dialog;
    filter = NewModalFilterUPP(settings_filter);

    while (!done) {
        ModalDialog(filter, &hit);
        switch (hit) {
        case kItemConnect:
            /* Same button, dual role: Disconnect when connected, else apply
               the fields and (re)connect. */
            if (conn_is_connected()) {
                conn_disconnect();
                g_last_status[0] = '\0';
            } else {
                apply_and_connect(dialog);
            }
            g_button_primed = false;
            break;
        case kItemSave: {
            char host[64];
            long port;

            get_field(dialog, kItemHostField, host, sizeof host);
            get_field(dialog, kItemPortField, port_text, sizeof port_text);
            port = strtol(port_text, NULL, 10);
            if (port > 0 && port <= 65535 && host[0] != '\0') {
                char retry_text[16];
                long retry;

                get_field(dialog, kItemRetryField, retry_text,
                          sizeof retry_text);
                retry = strtol(retry_text, NULL, 10);
                if (retry >= 0 && retry <= 300) {
                    prefs.retry_secs = (short)retry;
                }
                strcpy(prefs.host, host);
                prefs.port = (unsigned short)port;
                now_prefs_save(&prefs);
                conn_set_target(host, (unsigned short)port);
                done = true;
            } else {
                set_field(dialog, kItemStatus,
                          "Enter a host and a port (1-65535)");
                g_last_status[0] = '\0';
            }
            break;
        }
        case kItemCancel:
            done = true;
            break;
        default:
            break;
        }
    }
    DisposeModalFilterUPP(filter);
    g_filter_dialog = NULL;
    DisposeDialog(dialog);
}
