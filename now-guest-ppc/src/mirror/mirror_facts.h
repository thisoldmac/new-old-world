#ifndef NOW_MIRROR_FACTS_H
#define NOW_MIRROR_FACTS_H

/* What this Mac can say about Mirror, as a value.
   ------------------------------------------------------------------
   Mirror is a SEPARATE application that happens to run on the same
   Macintosh: three resident 68K extensions and one faceless PowerPC
   agent, none of them NOW's. This page is a reader of them and a switch
   for the one piece that has a switch. It installs nothing, patches
   nothing, and speaks none of Mirror's wire.

   Toolbox-free by construction, so the same file compiles under the
   host's cc for now-guest-ppc/tests/mirror_layout_test.c - the pattern
   net_facts.c and diag_layout.c set. Everything that needs a Macintosh
   (Gestalt, the Process Manager, LaunchApplication, the quit Apple
   Event) lives in mirror_probe.c; everything about what a state MEANS
   lives beside this header, where a test can reach it.

   THE HONESTY THIS PAGE EXISTS FOR. An extension is loaded by the system
   at startup and by nothing else. There is no runtime switch for one, so
   this page does not draw one: the three extension rows are read-only
   and say why. A switch that silently does nothing is the defect class
   this project keeps paying for, and it is cheaper to write the sentence
   than to explain the switch afterwards. */

#if TARGET_API_MAC_CARBON
#include <MacTypes.h>
#else
typedef struct Rect {
    short top;
    short left;
    short bottom;
    short right;
} Rect;
typedef unsigned char Boolean;
#endif

enum {
    kMirrorExtCount = 3,       /* AXPeek, QDPeek, Portal */
    kMirrorAgentRows = 3,      /* state, program, signature */
    kMirrorNoteLines = 2,      /* the last action's outcome, in words */
    kMirrorNoteMax = 220,
    kMirrorPathMax = 128,
    kMirrorSigMax = 8          /* four characters and room to escape one */
};

/* Which resident, in the order the page draws them. The order is Mirror's
   own dependency order: AXPeek is what a scene is built from, QDPeek is
   what a drawing trace comes from, Portal is what a click goes through. */
typedef enum {
    kMirrorExtAX = 0,
    kMirrorExtQD,
    kMirrorExtPortal
} MirrorExt;

/* Three states, and the third is the one worth having. "Answered, but not
   a version this build knows" is not the same as absent: the extension IS
   loaded, and saying "not installed" about a machine that plainly has it
   sends someone to reinstall a file that is already there. */
typedef enum {
    kMirrorExtAbsent = 0,      /* Gestalt silent: not installed, or no boot */
    kMirrorExtResident,        /* published, and the block is one we know */
    kMirrorExtOtherVersion     /* published, and it is not */
} MirrorExtState;

typedef enum {
    kMirrorAgentNoFile = 0,    /* nothing where Mirror stages it */
    kMirrorAgentStopped,
    kMirrorAgentRunning
} MirrorAgentState;

typedef struct MirrorFacts {
    MirrorExtState ext_state[kMirrorExtCount];
    /* The version the block declares. Only meaningful when the state is
       resident or other-version; zero otherwise, and never rendered as a
       version in that case. */
    unsigned long ext_version[kMirrorExtCount];

    MirrorAgentState agent;
    char agent_path[kMirrorPathMax];   /* where we looked, always */
    char agent_sig[kMirrorSigMax];     /* the running process's creator */

    /* What happened the last time somebody pressed a button, or the empty
       string. Set by the module, rendered here. A failure that is not in
       these words is a failure nobody saw. */
    char note[kMirrorNoteMax];
} MirrorFacts;

#endif /* NOW_MIRROR_FACTS_H */
