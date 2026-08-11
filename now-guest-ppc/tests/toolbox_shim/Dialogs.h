#ifndef NOW_TEST_SHIM_DIALOGS_H
#define NOW_TEST_SHIM_DIALOGS_H
#include "Controls.h"
typedef struct OpaqueDialogRef *DialogRef;
WindowRef GetDialogWindow(DialogRef dialog);
void DisposeDialog(DialogRef dialog);
#endif
