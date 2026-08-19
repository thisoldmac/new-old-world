#include "chat_project_dialog.h"

#include <string.h>

#include "control_kind.h"
#include "pump.h"

/* Item numbers must match DITL 303 in resources/app.r. */
enum {
    kDialogID = 303,
    kItemCreate = 1,
    kItemCancel = 2,
    kItemName = 3,
    kItemHere = 4,
    kItemThere = 5,
    kItemStatus = 6
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

static void set_radio(DialogRef dialog, short item, Boolean on)
{
    short kind;
    Handle handle;
    Rect box;

    GetDialogItem(dialog, item, &kind, &handle, &box);
    if (handle == NULL) {
        return;
    }
    SetControlValue((ControlRef)handle, on ? 1 : 0);
}

Boolean now_chat_project_new(char *name, long name_cap,
                             char *home, long home_cap)
{
    DialogRef dialog;
    Boolean here = true;
    Boolean created = false;
    Boolean done = false;

    dialog = GetNewDialog(kDialogID, NULL, (WindowRef)-1);
    if (dialog == NULL) {
        return false;
    }
    SetDialogDefaultItem(dialog, kItemCreate);
    SetDialogCancelItem(dialog, kItemCancel);
    set_field(dialog, kItemName, "");
    set_radio(dialog, kItemHere, true);
    set_radio(dialog, kItemThere, false);
    set_field(dialog, kItemStatus, "");
    SelectDialogItemText(dialog, kItemName, 0, 32767);
    ShowWindow(GetDialogWindow(dialog));

    while (!done) {
        short hit = 0;

        ModalDialog(now_pump_modal_filter(), &hit);
        switch (hit) {
        case kItemHere:
        case kItemThere:
            here = hit == kItemHere;
            set_radio(dialog, kItemHere, here);
            set_radio(dialog, kItemThere, !here);
            break;
        case kItemCreate:
            get_field(dialog, kItemName, name, name_cap);
            if (name[0] == '\0') {
                set_field(dialog, kItemStatus,
                          "A project needs a name.");
                break;
            }
            /* The contract's words, not this dialog's: the host reads
               guest-home as authoritative on this Mac. The radios say
               where the project lives AND what builds it — "built here
               with MPW" is guest home, "built there and sent here" is
               host home — but the wire still carries home only; the
               toolchain follows from the home on the host's side. */
            strncpy(home, here ? "guest" : "host", (size_t)(home_cap - 1));
            home[home_cap - 1] = '\0';
            created = true;
            done = true;
            break;
        case kItemCancel:
            done = true;
            break;
        default:
            break;
        }
    }
    now_control_dispose_dialog(dialog);
    return created;
}
