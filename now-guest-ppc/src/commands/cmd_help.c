#include "cmd_help.h"

#include <string.h>

/* Detail lines. Pre-wrapped to fit this Mac's console column (the host
   renders them in a proportional-width monospace and is the wider of the
   two surfaces, so wrapping for the narrow one serves both). */

static const char *const d_help[] = {
    "  Lists what THIS Mac serves, which is the point: the",
    "  other side keeps no command list of its own, so a",
    "  machine that implements three commands says three.",
    NULL
};

static const char *const d_gestalt[] = {
    "  With no group, prints a short snapshot. Groups:",
    "    --cpu --memory --os --network --hardware",
    "    --full        every group",
    NULL
};

static const char *const d_screenshot[] = {
    "  Captures the whole screen as a packed PICT. Depth",
    "  defaults to the Screenshots panel setting; --no-save",
    "  measures capture+encode without writing a file.",
    "  --bands N (2..32) captures in N banded CopyBits",
    "  calls and reports the per-band cost spread.",
    NULL
};

static const char *const d_ls[] = {
    "  Paths are relative to the share root, with",
    "  colons between folders: \"Lab:Code\". No path",
    "  lists the root itself. The root is chosen in",
    "  File > File Sharing... and defaults to the",
    "  startup volume; nothing outside it is reachable.",
    NULL
};

static const char *const d_tail[] = {
    "  The log is a file per launch in a \"now-logs\"",
    "  folder beside this application, so what happened",
    "  survives a crash that takes everything else. The",
    "  same command works from the other Mac's console.",
    NULL
};

static const char *const d_putstat[] = {
    "  Bytes, chunk and write counts, and the milliseconds",
    "  spent inside FSWrite against the whole receive path.",
    "  Measured here, which is the only place the disk can",
    "  be told apart from the wire.",
    NULL
};

static const char *const d_vprobe[] = {
    "  Times raw framebuffer reads (8/16/32/64-bit) against",
    "  the CopyBits baseline, checks reread caching, partial-",
    "  read scaling, and pixel fidelity. Takes ~3 seconds;",
    "  the screen should be still during the run.",
    NULL
};

static const char *const d_ps[] = {
    "  One line per process: its name, then kind",
    "  (application / background / finder), size, and",
    "  whether it is frontmost. A reading only; the",
    "  Processes page is where they are driven.",
    NULL
};

static const char *const d_census[] = {
    "  Probes:",
    "    overview identity selectors video volumes",
    "    drives drivers adb ata pccard pram power",
    "    pci scsi",
    "  Passive reads of tables the OS keeps. Absence is",
    "  an answer, not an error (no PCI slots = absent).",
    NULL
};

static const char *const d_catsearch[] = {
    "  Sweeps the startup volume's catalog for applications",
    "  with PBCatSearch, in short slices, cold then warm.",
    "  Measures whether a full application index is",
    "  affordable on this disk. Seconds-long; read-only.",
    NULL
};

static const char *const d_sw[] = {
    "  Domains: apps extensions cdevs startup apple",
    "  No domain shows counts. Items disabled by the",
    "  Extensions Manager are listed too, tagged (off).",
    "  \"sw apps\" sweeps the whole startup disk (a few",
    "  seconds) and shows one page of applications.",
    NULL
};

static const char *const d_launch[] = {
    "  The name is the whole rest of the line - spaces",
    "  need no quotes. If several apps share it, the",
    "  first launches and the reply names its version.",
    "  To force one: -v (\"launch -v 1.1.1 SimpleText\"),",
    "  a full path, or \"vers <name>\" then \"launch #2\".",
    NULL
};

static const char *const d_quit[] = {
    "  The name is the whole rest of the line, so any",
    "  flag comes FIRST. Names it by what \"ps\" shows.",
    "  A 'quit' Apple Event is a REQUEST: an app with an",
    "  unsaved document stops to ask and stays running.",
    "  So this waits (6 s, --wait N up to 20) and re-reads",
    "  the process list, then says \"is gone\" or \"is STILL",
    "  RUNNING\" - never the first when it means the second.",
    "  Several processes of one name refuse unless --all.",
    "  --no-wait sends and reports it unconfirmed.",
    NULL
};

/* --- the act plane (P4) ------------------------------------------------
   Six commands, one mechanism, and one rule that shapes all of them:
   every act names ONE element by an opaque reference this Mac minted,
   revalidated here against a live element before anything is
   dispatched, and none of them can express "whatever is frontmost".
   That refusal is a measurement rather than taste - a sibling project's
   request that merely disarmed after one use rode a real user's press
   18 times in 20, while the variant that had to name its exact target
   rode it 0 times in 20.

   And what they do not claim: an ok reply means the event was handed to
   the application's own path. Never that the window moved or the text
   changed. Read it back to learn that. */
static const char *const d_elements[] = {
    "  Mints the references the other five take. Nothing else can:",
    "  a reference is short-lived, opaque, and only ever one this Mac",
    "  made for something it saw.",
    "  Defaults to the frontmost application; serialHi/serialLo name",
    "  another. NOT TYPEABLE in any useful way - the output is",
    "  references no human has.",
    NULL
};
static const char *const d_winact[] = {
    "  Answers the owning application's own FindWindow, so it does what",
    "  it would have done had a person dragged the window. No mouse is",
    "  simulated and no emulator is involved.",
    "  move and resize carry their own geometry; zoom and close carry",
    "  none. close is DESTRUCTIVE and does not promise the window",
    "  closes - it promises the application was asked, exactly as a",
    "  user clicking the close box asks. An unsaved document answers",
    "  with a save dialog and the window stays open. That is correct.",
    NULL
};
static const char *const d_textget[] = {
    "  The only third of the act plane that changes nothing, which is",
    "  why it is its own command: a Mac whose owner agreed to be read",
    "  can serve this while refusing the two that drive it.",
    "  Says whether the element held more than the reply could carry.",
    NULL
};
static const char *const d_textset[] = {
    "  A replacement, not an edit: no offset and no append form,",
    "  because an offset into text the caller has not read is a write",
    "  it cannot predict.",
    NULL
};
static const char *const d_ctlact[] = {
    "  Answers the application's own TrackControl with the part code",
    "  you name, so the application runs its real mouse-down handler.",
    "  Button parts are 10 and 11; a scroll bar's are 20 up, 21 down,",
    "  22 page-up, 23 page-down, and 129 is the indicator.",
    NULL
};
static const char *const d_menuact[] = {
    "  Answers the application's own MenuSelect, so a menu item with no",
    "  keyboard shortcut becomes reachable. No menu is drawn.",
    "  titleLeft is where the press will land, and it is this act's",
    "  identity check: a menu carries no handle to name, so a press",
    "  anywhere else is somebody else's and chains through.",
    NULL
};

/* --- the reference layer -----------------------------------------------
   The half that MINTS what the act plane takes. `elements` above is the
   same walk aimed by a process rather than by a scope: there is exactly
   one thing on this Mac that creates a reference, and these are doors
   onto it rather than second opinions about it. */
static const char *const d_observe[] = {
    "  Walks and MINTS a reference for every window and control seen.",
    "  The only thing here that creates one - which is what makes",
    "  \"observation-minted\" a fact about the mechanism rather than a",
    "  wish. A token carries no identity: it is a key into a table only",
    "  a walk writes, hashed over a secret this session made and no",
    "  caller sees.",
    "  scope front (the default) or all.",
    "  NOW itself is NOT observable: it is a Carbon application and its",
    "  own window records are not where a classic walk reads.",
    NULL
};
static const char *const d_handle[] = {
    "  One reference back to a live element, or a named refusal.",
    "  ok stays true for every verdict including the four that resolve",
    "  to nothing: \"your reference is stale\" is an ANSWER, and an error",
    "  would invite a retry of the same reference. What is never true",
    "  is resolved.",
    "  Staleness is refused, never repaired - a window that closed and",
    "  reopened is a different window wearing the same title.",
    NULL
};
static const char *const d_axtree[] = {
    "  The read surface over observe's walk: the same emitter, so the",
    "  two can never describe this Mac differently. It mints too -",
    "  there is no read-only spelling of this tree, and pretending",
    "  otherwise would be a second, quieter minter.",
    NULL
};
static const char *const d_axsnap[] = {
    "  Who is front, whether the reference layer can see it, and how",
    "  many references are live. No walk, so no minting - the one call",
    "  on this surface that is safe to poll.",
    NULL
};

static const char *const d_front[] = {
    "  The name is the whole rest of the line and there",
    "  are no flags. Names it by what \"ps\" shows.",
    "  The switch is cooperative, so this yields for 2 s",
    "  and re-reads which process is frontmost - it says",
    "  \"is frontmost\" or \"is NOT frontmost\", never the",
    "  first when it means the second.",
    "  Nothing by that name is a FAILURE here, unlike",
    "  \"quit\": you cannot front what is not running.",
    "  NOW itself is a fair target - fronting it severs",
    "  nothing, where quitting it would cut the reply.",
    NULL
};

static const char *const d_reveal[] = {
    "  Selects the item in its Finder window and brings",
    "  the Finder forward. Opens nothing, so any item",
    "  reveals - an extension or control panel by path,",
    "  an app by name (the first copy if several share",
    "  it), or \"#n\" from the last vers/launch list.",
    NULL
};

static const char *const d_vers[] = {
    "  Reads that file's 'vers' resources. A bare name",
    "  searches applications and shows EVERY match as",
    "  a numbered list, full paths and all - then",
    "  \"vers #2\" or \"launch #2\" picks one. A full",
    "  path reads any file, so extensions want their",
    "  path. Never loops a whole folder.",
    NULL
};

/* --- console-local verbs (wire = 0) ------------------------------------- */

static const char *const d_put[] = {
    "  \"Macintosh HD:Notes:Read Me\". The path is a full",
    "  HFS path, not a share-relative one: sending is not",
    "  browsing, so the file need not be in the share. The",
    "  host saves it in whatever folder it shares.",
    NULL
};

static const char *const d_mv[] = {
    "  Both paths are relative to the share root. The",
    "  second is the whole destination including the new",
    "  name, so a rename is \"mv Notes Notes Old\". The",
    "  destination folder must already exist, and an",
    "  existing item is never replaced.",
    NULL
};

static const char *const d_trash[] = {
    "  The item goes to this volume's Trash, so it can be",
    "  dragged back out until the Trash is emptied. It is",
    "  not erased. Reports the name it landed under, which",
    "  differs if the Trash already held that name.",
    NULL
};

static const char *const d_untrash[] = {
    "  The first is what trash reported the item is",
    "  called in the Trash; the second is where in the",
    "  share to put it back, including its name.",
    NULL
};

static const char *const d_mkdir[] = {
    "  The enclosing folder must already exist. Names are",
    "  at most 31 characters and cannot contain a colon.",
    NULL
};

/* Order is display order on both consoles. */
const NowCommandDoc kNowCommandDocs[] = {
    { "gestalt", 1, "report this Mac: system, model, RAM, CarbonLib",
      "gestalt [group] [--full]", d_gestalt },
    { "screenshot", 1, "capture this Mac's screen to its desktop",
      "screenshot [--depth {1,2,4,8,16,32}] [--bands N] [--no-save]",
      d_screenshot },
    { "ls", 1, "list a folder in the shared files",
      "ls [path]", d_ls },
    { "put", 0, "send a file to the other Mac",
      "put <full path>", d_put },
    { "tail", 1, "the last lines of this launch's log",
      "tail [lines]   (default 20, most 40)", d_tail },
    { "putstat", 1, "where the last file received spent its time",
      "putstat", d_putstat },
    { "mv", 0, "move or rename something in the shared files",
      "mv <path> <new path>", d_mv },
    { "trash", 0, "move something to the Trash",
      "trash <path>", d_trash },
    { "untrash", 0, "put something back from the Trash",
      "untrash <trash name> <path>", d_untrash },
    { "mkdir", 0, "make a folder in the shared files",
      "mkdir <path>", d_mkdir },
    { "vprobe", 1, "measure this Mac's VRAM read cost by method",
      "vprobe", d_vprobe },
    { "ps", 1, "the processes running on this Mac",
      "ps", d_ps },
    { "census", 1, "run one hardware-census probe",
      "census [probe]   (no probe = overview)", d_census },
    { "catsearch", 1, "time a whole-disk application search",
      "catsearch", d_catsearch },
    { "sw", 1, "what is installed on this Mac",
      "sw [domain]", d_sw },
    { "launch", 1, "open an application on this Mac",
      "launch [-v VERSION] <name | path | #n>", d_launch },
    { "quit", 1, "ask an application on this Mac to quit",
      "quit [--all] [--wait N | --no-wait] <name>", d_quit },
    { "front", 1, "bring an application on this Mac forward",
      "front <name>", d_front },
    { "reveal", 1, "show an item in this Mac's Finder",
      "reveal <name | full path | #n>", d_reveal },
    { "vers", 1, "one file's version resources",
      "vers <name | full path | #n>", d_vers },
    { "elements", 1, "name this Mac's on-screen elements, so they can "
      "be acted on",
      "elements [serialHi serialLo]", d_elements },
    { "winact", 1, "move, resize, zoom or close one window",
      "winact <window> <action> [geometry]", d_winact },
    { "textget", 1, "read one text element's contents",
      "textget <element>", d_textget },
    { "textset", 1, "replace one text element's contents",
      "textset <element> <text>", d_textset },
    { "ctlact", 1, "act on one control",
      "ctlact <element> <part>", d_ctlact },
    { "menuact", 1, "perform one menu command",
      "menuact <menu> <item> <titleLeft>", d_menuact },
    { "observe", 1, "walk this Mac's elements and mint a reference for each",
      "observe [scope]", d_observe },
    { "handle", 1, "take one reference back to a live element",
      "handle <ref>", d_handle },
    { "axtree", 1, "the same walk, to look at rather than to act on",
      "axtree [scope]", d_axtree },
    { "axsnap", 1, "who is front, and how many references are live",
      "axsnap", d_axsnap },
    { "help", 1, "list commands (\"help <cmd>\" for one)",
      "help [command]", d_help },
    { "clear", 0, "clear the console scrollback",
      "clear", NULL },
    { NULL, 0, NULL, NULL, NULL }
};

const NowCommandDoc *now_command_doc(const char *name)
{
    int i;

    if (name == NULL) {
        return NULL;
    }
    for (i = 0; kNowCommandDocs[i].name != NULL; ++i) {
        if (strcmp(kNowCommandDocs[i].name, name) == 0) {
            return &kNowCommandDocs[i];
        }
    }
    return NULL;
}

int now_command_doc_count(void)
{
    int i = 0;

    while (kNowCommandDocs[i].name != NULL) {
        ++i;
    }
    return i;
}
