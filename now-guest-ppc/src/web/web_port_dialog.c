#include "web_port_dialog.h"

#include <stdio.h>
#include <string.h>

#include "conn_fields.h"
#include "control_kind.h"
#include "pump.h"

enum {
    kDialogID = 302,
    kItemSave = 1,
    kItemCancel = 2,
    kItemPort = 3,
    kItemStatus = 4
};

static void set_field(DialogRef dialog, short item, const char *value)
{
    short kind;
    Handle handle;
    Rect box;
    Str255 text;

    GetDialogItem(dialog, item, &kind, &handle, &box);
    if (handle == NULL) return;
    CopyCStringToPascal(value, text);
    SetDialogItemText(handle, text);
}

static void get_field(DialogRef dialog, short item, char *out, long cap)
{
    short kind;
    Handle handle;
    Rect box;
    Str255 text;
    long n;

    out[0] = '\0';
    GetDialogItem(dialog, item, &kind, &handle, &box);
    if (handle == NULL) return;
    GetDialogItemText(handle, text);
    n = text[0];
    if (n > cap - 1) n = cap - 1;
    memcpy(out, text + 1, (size_t)n);
    out[n] = '\0';
}

Boolean now_web_edit_port(unsigned short *port)
{
    DialogRef dialog;
    char text[16];
    Boolean saved = false;
    Boolean done = false;

    if (port == NULL) return false;
    dialog = GetNewDialog(kDialogID, NULL, (WindowRef)-1);
    if (dialog == NULL) return false;
    SetDialogDefaultItem(dialog, kItemSave);
    SetDialogCancelItem(dialog, kItemCancel);
    snprintf(text, sizeof text, "%u", *port);
    set_field(dialog, kItemPort, text);
    set_field(dialog, kItemStatus, "");
    SelectDialogItemText(dialog, kItemPort, 0, 32767);
    ShowWindow(GetDialogWindow(dialog));

    while (!done) {
        short hit = 0;
        ModalDialog(now_pump_modal_filter(), &hit);
        if (hit == kItemSave) {
            long parsed;
            get_field(dialog, kItemPort, text, sizeof text);
            parsed = now_conn_port_parse(text);
            if (parsed < 0) {
                set_field(dialog, kItemStatus,
                          "Enter a port from 1 through 65535.");
            } else {
                *port = (unsigned short)parsed;
                saved = true;
                done = true;
            }
        } else if (hit == kItemCancel) {
            done = true;
        }
    }
    now_control_dispose_dialog(dialog);
    return saved;
}
