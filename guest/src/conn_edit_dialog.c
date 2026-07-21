#include "conn_edit_dialog.h"

#include <stdio.h>
#include <string.h>

#include "conn_fields.h"
#include "pump.h"

/* Item numbers must match DITL 301 in resources/app.r. */
enum {
    kDialogID = 301,
    kItemSave = 1,
    kItemCancel = 2,
    kItemAddr = 3,
    kItemPort = 4,
    kItemStatus = 5
};

static void get_field(DialogRef dialog, short item, char *out, long cap)
{
    short kind;
    Handle handle;
    Rect box;
    Str255 text;
    long n;

    out[0] = '\0';
    GetDialogItem(dialog, item, &kind, &handle, &box);
    if (handle == NULL) {
        return;
    }
    GetDialogItemText(handle, text);
    n = text[0];
    if (n > cap - 1) {
        n = cap - 1;
    }
    memcpy(out, text + 1, (size_t)n);
    out[n] = '\0';
}

static void set_field(DialogRef dialog, short item, const char *s)
{
    short kind;
    Handle handle;
    Rect box;
    Str255 text;

    GetDialogItem(dialog, item, &kind, &handle, &box);
    if (handle == NULL) {
        return;
    }
    CopyCStringToPascal(s, text);
    SetDialogItemText(handle, text);
}

Boolean now_conn_edit(char *host, long host_cap, unsigned short *port)
{
    DialogRef dialog;
    char port_text[16];
    Boolean saved = false;
    Boolean done = false;

    dialog = GetNewDialog(kDialogID, NULL, (WindowRef)-1);
    if (dialog == NULL) {
        return false;
    }
    SetDialogDefaultItem(dialog, kItemSave);
    SetDialogCancelItem(dialog, kItemCancel);
    set_field(dialog, kItemAddr, host);
    snprintf(port_text, sizeof port_text, "%u", *port);
    set_field(dialog, kItemPort, port_text);
    set_field(dialog, kItemStatus, "");
    /* Select the whole address so typing replaces it - the person
       usually wants a different machine, not to edit one octet. */
    SelectDialogItemText(dialog, kItemAddr, 0, 32767);
    ShowWindow(GetDialogWindow(dialog));

    while (!done) {
        short hit = 0;

        /* now_pump_modal_filter services the wire on every pass and
           chains the standard filter, so Return commits Save and
           Escape/Cmd-. commits Cancel. */
        ModalDialog(now_pump_modal_filter(), &hit);
        if (hit == kItemSave) {
            char new_host[64];
            char new_port[16];
            long parsed;

            get_field(dialog, kItemAddr, new_host, sizeof new_host);
            get_field(dialog, kItemPort, new_port, sizeof new_port);
            if (!now_conn_ipv4_valid(new_host)) {
                set_field(dialog, kItemStatus,
                          "The address must be dotted IPv4, like "
                          "10.91.5.20.");
            } else if ((parsed = now_conn_port_parse(new_port)) < 0) {
                set_field(dialog, kItemStatus,
                          "The port must be a number from 1 through "
                          "65535.");
            } else {
                strncpy(host, new_host, (size_t)(host_cap - 1));
                host[host_cap - 1] = '\0';
                *port = (unsigned short)parsed;
                saved = true;
                done = true;
            }
        } else if (hit == kItemCancel) {
            done = true;
        }
    }

    DisposeDialog(dialog);
    return saved;
}
