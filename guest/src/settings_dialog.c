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
    kItemTest = 3,
    kItemHostField = 4,
    kItemPortField = 5,
    kItemStatus = 6
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

static void run_test(DialogRef dialog)
{
    char host[64];
    char port_text[16];
    char status[160];
    long port;

    get_field(dialog, kItemHostField, host, sizeof host);
    get_field(dialog, kItemPortField, port_text, sizeof port_text);
    port = strtol(port_text, NULL, 10);
    if (port <= 0 || port > 65535) {
        set_field(dialog, kItemStatus, "Port must be 1-65535");
        return;
    }
    set_field(dialog, kItemStatus, "Testing...");
    DrawDialog(dialog);
    now_wire_test(host, (unsigned short)port, status, sizeof status);
    set_field(dialog, kItemStatus, status);
}

void now_settings_dialog_run(void)
{
    DialogRef dialog;
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
    set_field(dialog, kItemStatus, "");
    SelectDialogItemText(dialog, kItemHostField, 0, 32767);
    ShowWindow(GetDialogWindow(dialog));

    while (!done) {
        ModalDialog(NULL, &hit);
        switch (hit) {
        case kItemTest:
            run_test(dialog);
            break;
        case kItemSave: {
            char host[64];
            long port;

            get_field(dialog, kItemHostField, host, sizeof host);
            get_field(dialog, kItemPortField, port_text, sizeof port_text);
            port = strtol(port_text, NULL, 10);
            if (port > 0 && port <= 65535 && host[0] != '\0') {
                strcpy(prefs.host, host);
                prefs.port = (unsigned short)port;
                now_prefs_save(&prefs);
                done = true;
            } else {
                set_field(dialog, kItemStatus,
                          "Enter a host address and a port (1-65535)");
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
    DisposeDialog(dialog);
}
