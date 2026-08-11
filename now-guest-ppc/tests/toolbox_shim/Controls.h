/* A Toolbox stand-in, for ONE purpose: compiling workshop/control_kind.c
   with the host cc so its registry can be tested without a Macintosh.

   It declares only what that file touches. The procID values are copied
   from the real Universal Interfaces rather than invented, but nothing
   rests on the copy staying right: control_kind.c maps NAMES to roles, so
   the native test asserts name-to-role and the numbers only have to be
   distinct. Two of them colliding would be a duplicate `case` and the
   real cross-build would refuse to compile it, which is a better gate
   than anything this file could carry.

   Nothing else in this tree may include it: it is on the include path of
   exactly one native test. */
#ifndef NOW_TEST_SHIM_CONTROLS_H
#define NOW_TEST_SHIM_CONTROLS_H

#ifndef NULL
#define NULL ((void *)0)
#endif
#define true 1
#define false 0

typedef unsigned char Boolean;
typedef unsigned char Str255[256];
typedef const unsigned char *ConstStr255Param;

typedef struct { short top, left, bottom, right; } Rect;

typedef struct OpaqueControlRef *ControlRef;
typedef struct OpaqueWindowRef *WindowRef;

enum {
    pushButProc                   = 0,
    checkBoxProc                  = 1,
    radioButProc                  = 2,
    scrollBarProc                 = 16,
    popupMenuProc                 = 1008
};

/* The fake Toolbox the test links against; the test defines these. */
ControlRef NewControl(WindowRef window, const Rect *bounds,
                      ConstStr255Param title, Boolean visible,
                      short value, short min, short max,
                      short procID, long refCon);
void DisposeControl(ControlRef control);

#endif
