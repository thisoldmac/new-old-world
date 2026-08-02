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

/* Mirror's own port, named once here and read from Mirror's sources rather
   than remembered:

     mirror/guest/app/src/main.c   kDefaultPort 1420, and the range
                                   read_port() will accept from the file,
                                   1024 through 65535. A number outside it
                                   is ignored and the default taken.
     mirror/tools/stage-agent.py   GUEST_PORT 1420, the number its stager
                                   writes into mirror.port.

   NOW does not bind any of this. The page shows the number so that a
   person can compare it against the port their host is dialling, which is
   the one comparison nothing else on either machine makes. */
enum {
    kMirrorAgentPort = 1420,
    kMirrorPortLow = 1024,
    kMirrorPortHigh = 65535
};

enum {
    kMirrorExtCount = 3,       /* AXPeek, QDPeek, Portal */
    kMirrorAgentRows = 4,      /* state, port, program, signature */
    kMirrorNoteLines = 3,      /* the last action's outcome, in words */
    /* Characters a note line will hold. A budget in CHARACTERS because
       this file has no port to measure a string in; the module still
       passes every drawn line through TruncString, so a narrow window
       shortens rather than overflows. 84 fits the narrowest pane the
       Workshop allows at the small system font, with room to spare. */
    kMirrorNoteChars = 84,
    /* Sized so the lines can always say the whole note - three budgets
       less what a greedy word wrap pushes onto the next line, which for
       the longest word any of these messages uses is under twenty
       characters a line. Silently clipping the last clause of a failure
       message is the one truncation this page cannot afford, and the
       native test asserts a buffer-filling note loses nothing. */
    kMirrorNoteMax = 200,
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

/* RUNNING AND SERVING ARE DIFFERENT FACTS, and this page conflated them
   until 2026-08-02. Mirror's agent learns which TCP port to bind from a
   text file called `mirror.port` sitting beside it, read once at launch.
   A guest whose file named a stale port had a live agent, a page saying
   "Running", and a host whose every connection was reset by a forward
   with nothing behind it. The process existed; the status was true; the
   status was useless.

   So the port file is a fact of its own, separate from the process, and
   the page reports both. What it CANNOT report is the port the running
   process actually bound: that was read at ITS launch, and this file can
   only be read now. The two agree on a machine nobody has restaged
   underneath, and the row says where its number came from so that the one
   case where they differ is legible rather than invisible. */
typedef enum {
    kMirrorPortUnknown = 0,    /* never looked - no folder to look in */
    kMirrorPortAbsent,         /* looked, and there is no mirror.port */
    kMirrorPortUnusable,       /* a file, naming no port the agent takes */
    kMirrorPortNamed           /* a file, and it names a usable port */
} MirrorPortState;

typedef struct MirrorFacts {
    MirrorExtState ext_state[kMirrorExtCount];
    /* The version the block declares. Only meaningful when the state is
       resident or other-version; zero otherwise, and never rendered as a
       version in that case. */
    unsigned long ext_version[kMirrorExtCount];

    MirrorAgentState agent;
    char agent_path[kMirrorPathMax];   /* where we looked, always */
    char agent_sig[kMirrorSigMax];     /* the running process's creator */

    MirrorPortState port_state;
    /* What mirror.port says, and only then. Zero for every other state,
       and never rendered as a port in one - a page that printed 0 here
       would be inventing a listener. */
    long port;

    /* What happened the last time somebody pressed a button, or the empty
       string. Set by the module, rendered here. A failure that is not in
       these words is a failure nobody saw. */
    char note[kMirrorNoteMax];
} MirrorFacts;

#endif /* NOW_MIRROR_FACTS_H */
