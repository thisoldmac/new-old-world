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

static const char *const d_update[] = {
    "  With no argument, shows the exact app and extension",
    "  builds the connected Mac has published. application",
    "  installs then relaunches; extension installs separately",
    "  and requires a cold restart. Unsigned development builds",
    "  are named as such before anything is requested.",
    NULL
};

static const char *const d_gestalt[] = {
    "  With no group, prints a short snapshot. Groups:",
    "    --cpu --memory --os --network --hardware",
    "    --full        every group",
    NULL
};

static const char *const d_romdump[] = {
    "  Writes this Mac's complete ROM to New Old World ROM.bin",
    "  in the configured Files share. Other Mac retrieves it",
    "  through the ordinary file stream. On a PowerBook 1400 this",
    "  includes both the 3 MB Toolbox and 1 MB boot sections.",
    NULL
};

static const char *const d_development[] = {
    "  Reports only opaque registration and measured capability facts.",
    "  Toolchain and Projects paths remain on this Mac and are never",
    "  returned to Other Mac.",
    NULL
};

static const char *const d_development_build[] = {
    "  Starts, observes or cancels one declarative ToolServer build.",
    "  Project.ckp supplies the closed build actions; this command never",
    "  accepts MPW text or a path.",
    NULL
};
static const char *const d_development_stage[] = {
    "Prepares, observes or discards one inactive project candidate.",
    "Candidate identities are single-use and files arrive through the",
    "bounded transfer lane outside the generic Files root.", NULL
};
static const char *const d_development_project[] = {
    "catalog lists the active projects, eight to a page, as identity|name;",
    "a project ID measures and pages that project's source manifest.",
    "Staged candidates are not listed here - see development-stage.",
    "The chosen Projects root and HFS path remain private.", NULL
};

static const char *const d_development_run[] = {
    "  Launches only the unchanged product measured by a successful build.",
    "  Build success and launch dispatch remain separate outcomes.",
    NULL
};

static const char *const d_development_open[] = {
    "  Locates and launches CodeKitten, then sends Project.ckp with odoc.",
    "  A launching reply is safe to retry while CodeKitten starts.",
    "  CodeKitten is optional and this command never participates in builds.",
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
    "  same command works from Other Mac's console.",
    "  An area narrows to one subsystem's tag (\"files\",",
    "  \"wire\"); \"before N\" continues an answer at the",
    "  cursor its last line offered, back through all",
    "  2000 held lines.",
    NULL
};

static const char *const d_net[] = {
    "  This Mac's link, its TCP/IP configuration and the",
    "  network ports it has, as four groups of rows.",
    "  The last group says why a connection list is not",
    "  among them: Open Transport publishes no way to ask.",
    NULL
};

static const char *const d_putstat[] = {
    "  Bytes, chunk and write counts, and the milliseconds",
    "  spent inside FSWrite against the whole receive path.",
    "  Measured here, which is the only place the disk can",
    "  be told apart from the wire.",
    NULL
};

static const char *const d_desktop[] = {
    "  What this Mac's desktop is actually drawn from, asked",
    "  of the Appearance Manager rather than read out of a",
    "  resource. The `ppat` in the System file is a shipped",
    "  default the desktop is never chosen from, so it says",
    "  nothing about what is on the screen.",
    "  Reports the theme, the pattern's name and its",
    "  flattened bytes in hex, and - when a picture is set -",
    "  its name and alignment. A picture is drawn OVER the",
    "  pattern, so both are reported and `source` says which",
    "  one a person is looking at.",
    NULL
};

static const char *const d_wirestat[] = {
    "  How long this Mac takes to NOTICE a request, as two",
    "  histograms: the interval between wire service passes,",
    "  and the delay from Open Transport announcing data to",
    "  this loop reading it. A round trip cannot tell those",
    "  apart from the work; only this Mac can.",
    "  `sleep N` sets the idle WaitNextEvent sleep in ticks,",
    "  `wake on|off` the Open Transport wake, `reset` clears",
    "  the counts. None of the three is saved.",
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
   Seven commands, one mechanism, and one rule that shapes all of them:
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
    "  Mints the references the other six take. Nothing else can:",
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
static const char *const d_cursoract[] = {
    "  Places the drawn cursor at one point inside an observed window.",
    "  It clicks nothing and changes no front order or selection.",
    "  The window reference binds the point to one process and A5 world.",
    "  NOT TYPEABLE usefully - the reference comes from observation.",
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
    "  Part 0 answers NOTHING: the press is still posted and the",
    "  application's own tracking decides, which is how a tab switches",
    "  and a list row selects.",
    "  h and v are global screen coordinates and must be inside the",
    "  control. Omit both to press its centre.",
    NULL
};
static const char *const d_dragpress[] = {
    "  Presses the mouse button on the element and LEAVES IT DOWN,",
    "  handing the gesture to the resident's drag vehicle. Returns a",
    "  session nonce that dragmove and dragrelease must name.",
    "  The resident carries its own deadline and will release the",
    "  button whether or not anyone asks - idle and cap set how long,",
    "  in ticks, and it clamps both, so neither can switch it off.",
    NULL
};
static const char *const d_dragmove[] = {
    "  Publishes a new pointer position for a held drag. The resident's",
    "  Time Manager task applies it; the application being dragged in is",
    "  inside its own tracking loop and is not reading events at all.",
    "  Also relays that the caller is still alive, which is what holds",
    "  the resident's idle deadline open.",
    NULL
};
static const char *const d_dragrelease[] = {
    "  Asks the resident to release a held drag. It reports that it",
    "  ASKED, never that it released: the resident performs it on its",
    "  next tick through the same path its deadline uses, and that",
    "  deadline may already have got there first. Read the ended row.",
    NULL
};
static const char *const d_ditemact[] = {
    "  Selects one 1-based DITL item through the application's own",
    "  dialog event path. The item number and observation-minted",
    "  control reference must still name the same backing object.",
    "  This is not TrackControl: the Dialog Manager owns the action.",
    NULL
};
static const char *const d_menuact[] = {
    "  Answers the application's own MenuSelect, so a menu item with no",
    "  keyboard shortcut becomes reachable. No menu is drawn.",
    "  Application-menu items 1 and 2 instead use the Process Manager's",
    "  keyboard equivalents in the exact target process context.",
    "  titleLeft is where the press will land, and it is this act's",
    "  identity check: a menu carries no handle to name, so a press",
    "  anywhere else is somebody else's and chains through.",
    NULL
};

/* --- the machine's own state, folded in from timbottu/mirror ----------- */
static const char *const d_activate[] = {
    "  Not a second \"front\". front takes a NAME and refuses when",
    "  several match; this takes the identity an observation minted,",
    "  which is what a driver has. Both reach the one SetFrontProcess",
    "  on this Mac.",
    "  The reply says whether the switch is OBSERVABLE, never merely",
    "  that it was accepted: a cooperative switch lands when this",
    "  application yields, and the two readings keep separate words.",
    NULL
};
static const char *const d_actselftest[] = {
    "  Proves the act plane's trap calling convention from inside this",
    "  machine, which no other instrument can: every other one reads",
    "  OUR side of the call, and a patch whose result lands in the",
    "  wrong slot does not crash - it LIES. Each counter reports",
    "  success while the application reads a value we never wrote and",
    "  takes the other branch.",
    "  Side-effect free by construction: the point tested is outside",
    "  the menu bar, so an unanswered call returns at once having",
    "  drawn and tracked nothing.",
    "  No serial means the front process.",
    NULL
};

/* --- the input plane ---------------------------------------------------
   Four different kinds of thing behind one heading: a read that every
   hop calibration closes its loop against, one keystroke, one
   AppleScript, and one of four core Apple Events. See
   src/input/input_cmds.h. */
static const char *const d_mouseloc[] = {
    "  Where the pointer IS, which is not where anything asked it to",
    "  go: an emulator's relative mouse is acceleration-distorted, so",
    "  a driver positions by reading this and correcting.",
    "  A read, and it stays a read - there is deliberately no",
    "  move-the-mouse verb beside it.",
    NULL
};
static const char *const d_key[] = {
    "  One keystroke into this Mac's event queue - the mechanism",
    "  textset is not. textset writes an element's text directly and",
    "  never reaches Return, Escape, or a dialog that answers only",
    "  keys; this posts the event a keyboard would.",
    "  Name a key (return, escape, tab, space, delete, enter, help,",
    "  home, end, pageup, pagedown, fwddelete, left, right, up,",
    "  down), or give char, or give code, or both.",
    "  NO MODIFIERS, and mods is REFUSED rather than dropped. An",
    "  event's modifiers live on the Event Manager's queue element;",
    "  the only call that hands that element back is PPostEvent,",
    "  which CarbonLib does not have, and this application is",
    "  Carbon. For a menu command use menuact - it needs no",
    "  modifier and draws no menu.",
    NULL
};
static const char *const d_script[] = {
    "  One AppleScript through this Mac's own OSA component. Source",
    "  is at most 2048 bytes and the result at most 1024, because the",
    "  reply is assembled in a 3072-byte buffer and an answer that",
    "  did not fit would be cut silently.",
    "  A whole-disk Finder search (\"entire contents\") is REFUSED:",
    "  it wedged a real machine for twelve minutes, and there is no",
    "  error path that could report that after the fact.",
    "  timeoutMs is clamped to 500..60000; this Mac answers serially,",
    "  so a script's timeout is every other caller's wait.",
    NULL
};
static const char *const d_aesend[] = {
    "  A CLOSED vocabulary of four - quit, oapp, odoc, pdoc - and not",
    "  a class/id pipe. Each has an effect statable in one line,",
    "  which is the test a fifth would have to pass.",
    "  odoc and pdoc need a path; all four need a whole serial.",
    "  Addressing this Mac's own NOW is refused rather than sent:",
    "  a quit to ourselves takes the guest down mid-reply, and the",
    "  caller would see a dropped connection instead of an answer.",
    NULL
};

/* --- the content plane's reader ---------------------------------------- */
static const char *const d_qdtrace[] = {
    "  What is DRAWING on this Mac, read from the ring the NOW",
    "  Extension's resident half fills at draw time.",
    "  op status (the default) counts without moving one record;",
    "  start arms ONE A5 world for a bounded time in count, record",
    "  or probe mode (probe also chases a window blit back to the",
    "  offscreen GWorld that sourced it, and records what is drawn",
    "  THERE); stop disarms; drain reads records from a cursor.",
    "  A short drain always says WHY it is short - more, resync,",
    "  torn or busy - because fewer records than expected quietly",
    "  covering an overrun is the whole failure this plane guards.",
    "  start answers requested, never armed: nothing is hooked until",
    "  the extension agrees inside the target process, and status is",
    "  where that shows.",
    "  In probe mode the plane also patches the QDExtensions trap in",
    "  the target's own context, so a world created and disposed",
    "  inside one event pass is hooked at BIRTH rather than chased",
    "  and missed; status's qdext object counts what that patch saw.",
    NULL
};

/* --- the transition plane's reader -------------------------------------
   Same shape as qdtrace above, and the claim it makes is the one thing
   worth reading twice: this is a SAMPLER. */
static const char *const d_transitions[] = {
    "  What CHANGED between two of this Mac's own event passes, read",
    "  from the ring the NOW Extension's resident half fills inside",
    "  an armed process.",
    "  op status (the default) counts without moving one record;",
    "  start arms ONE process for a bounded time; stop disarms;",
    "  drain reads records from a cursor and says more when short.",
    "  \"transitions start\" arms the FRONT process - typed here, that",
    "  is NOW itself. \"transitions start Finder\" names another one,",
    "  and a name is the only target a console line can carry: nothing",
    "  this guest prints carries a ProcessSerialNumber.",
    "  IT SAMPLES, IT DOES NOT TAIL. It catches what a 2.2 s poll",
    "  misses because the event loop runs at ~60 Hz; something raised",
    "  and dismissed BETWEEN two passes is still missed.",
    "  start answers requested, never armed: nothing records until the",
    "  extension agrees inside the target, and status's passes count",
    "  is where that shows - a live request beside a still passes is",
    "  an arm that named the wrong world.",
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
static const char *const d_mirrorlog[] = {
    "  The mirror log area's DEBUG TIER, on a session switch that is off",
    "  each launch. Off, the ring keeps the product's story: arm/disarm,",
    "  epoch begin, selection and grant lines, and every warning and",
    "  error. On, the per-epoch counter dumps and per-event traces",
    "  return - the plane's own diagnostics, ~25 lines per disarm.",
    "",
    "  Not saved on purpose: a diagnostic that survives a relaunch is a",
    "  configuration nobody chose, and this one can bury every later",
    "  log. The toggle logs its own transitions, so the log names who",
    "  turned it on. Bare or unrecognised reports without changing",
    "  anything.",
    NULL
};

static const char *const d_mirror[] = {
    "  What this Mac can prove about the one NOW Extension: lifecycle,",
    "  exact resident build, and P1-P4 support, request, active, format,",
    "  freshness, generation, refusal and degradation facts.",
    "",
    "  Residency is a Gestalt answer and only this Mac can give it. The",
    "  command distinguishes absent, restart-required, wrong-version,",
    "  active and degraded instead of inferring residence from a file.",
    "",
    "  Plane policy belongs to the host. This command and the Workshop",
    "  page are read-only views over the same guest-observed facts.",
    NULL
};
static const char *const d_cycle[] = {
    "  Brings each application forward in turn, with the anchor plane",
    "  armed, so it pumps its event loop once and the plane captures it.",
    "  The application that was front is restored afterwards.",
    "",
    "  THIS DISTURBS THE MACHINE ON PURPOSE. Windows come forward and",
    "  flash past. It is never automatic; run it once on a fresh boot,",
    "  or when what the Mirror shows has gone stale.",
    "",
    "  Why it is needed: the plane captures a process only while THAT",
    "  process is executing GetNextEvent, and on a Mac nobody has driven",
    "  nothing else is ever scheduled inside an armed window. Processes",
    "  it can reach without fronting them are woken invisibly first.",
    "",
    "  Faceless background processes have no window to bring forward and",
    "  are reported as background-only rather than as failures. They are",
    "  outside what this can reach.",
    "",
    "  Believe the counters, not the flashing: passes rising without",
    "  scans rising means it fronted things and captured nothing.",
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

static const char *const d_hide[] = {
    "  What the Application menu does, through the Process",
    "  Manager call that menu ends up in. The name is the",
    "  rest of the line; --show puts it back, --status only",
    "  reads. Flags LEAD, because names have spaces.",
    "  It reads the flag back before answering, so it says",
    "  \"is now hidden\" only when it saw that - never",
    "  \"asked and assume\". Nothing by that name is a",
    "  FAILURE, like \"front\" and unlike \"quit\".",
    "  NOW itself is a fair target; a hidden application is",
    "  still scheduled, so the wire keeps being served.",
    "  Needs CarbonLib 1.5 or later and says so if not.",
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

static const char *const d_cancel[] = {
    "  Stops whatever file is moving, in whichever",
    "  direction - a file arriving from Other Mac or",
    "  one this Mac asked for. It needs no name: the lane",
    "  is one transfer wide, so there is only ever one",
    "  thing to stop. A file this Mac is SENDING cannot be",
    "  stopped from here yet, and says so rather than",
    "  reporting a quiet machine.",
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

static const char *const d_offer[] = {
    "  The file the person at the Mac is holding out over the shared",
    "  edge - a bare call reports it (name, kind, type/creator, size),",
    "  and what became of the last drag of it. No name and no path:",
    "  this verb reaches nothing the host has not published by a",
    "  person's own gesture.",
    "    --take       file it in the downloads folder",
    "    --drag       pick it up as a real drag; it lands where you",
    "                 drop it. Arms only - the drag starts when the",
    "                 button is down, and says so if it never is.",
    "    --stop       end a drag that is armed or under way",
    NULL
};

static const char *const d_chat[] = {
    "  Talks to a model through Other Mac's harness.",
    "  The conversation lives over there, one turn at a",
    "  time. Two steps to pick a model, by name not id:",
    "    --models     list Other Mac's providers",
    "    --models P   list provider P's models, numbered",
    "    --model N    choose number N from that listing",
    "    --new        start a fresh conversation",
    "    --stop       end the answer that is streaming",
    "  Conversations are saved over there and outlive the",
    "  link, both machines' in one list:",
    "    --chats [C]  list saved chats from cursor C",
    "    --open N     continue number N from that listing",
    "    --history[C] page what was said, newest first",
    "    --projects   list projects, numbered",
    "    --project N  work in number N",
    "    --project none        work in no project",
    "    --project new <name> here|there",
    "                 make one; here keeps its code on",
    "                 this Mac, there on the modern one",
    "    --mode M     chat looks, plan writes a plan,",
    "                 build may change things",
    "  Skills are instructions the other Mac keeps - the",
    "  classic Mac ones ship with it. Type them as text:",
    "    chat /skills            list them",
    "    chat /<name>            load one for this chat",
    "    chat /<name> <question> load it and ask at once",
    "  chat -- <text> forces text that starts with a dash.",
    "  While an answer streams this console waits for it;",
    "  the Chat page is the face that stays interactive.",
    NULL
};

/* Order is display order on both consoles. */
const NowCommandDoc kNowCommandDocs[] = {
    { "update", 1, "updates published by the connected Mac",
      "update [application | extension]", d_update },
    { "development", 1, "registered Projects and build environment",
      "development", d_development },
    { "development-build", 1, "build one project through MPW ToolServer",
      "development-build <status | cancel | start projectID>",
      d_development_build },
    { "development-stage", 1, "manage one inactive project candidate",
      "development-stage <prepare | status | discard>",
      d_development_stage },
    { "development-project", 1, "list or measure active projects",
      "development-project <catalog [cursor] | projectID>", d_development_project },
    { "development-run", 1, "launch the exact last built product",
      "development-run <productRef>", d_development_run },
    { "development-test", 1, "test the exact product by the closed plan",
      "development-test <productRef>", d_development_run },
    { "development-open", 1, "open one active Project.ckp in CodeKitten",
      "development-open <projectID>", d_development_open },
    { "gestalt", 1, "report this Mac: system, model, RAM, CarbonLib",
      "gestalt [group] [--full]", d_gestalt },
    { "romdump", 1, "save this Mac's complete ROM in the Files share",
      "romdump", d_romdump },
    { "screenshot", 1, "capture this Mac's screen to its desktop",
      "screenshot [--depth {1,2,4,8,16,32}] [--bands N] [--no-save]",
      d_screenshot },
    { "ls", 1, "list a folder in the shared files",
      "ls [path]", d_ls },
    { "put", 0, "send a file to Other Mac",
      "put <full path>", d_put },
    { "tail", 1, "lines of this launch's log, pageable",
      "tail [lines] [area] [before N]   (default 20, most 40 a page)",
      d_tail },
    { "net", 1, "this Mac's link, address and network hardware",
      "net", d_net },
    { "putstat", 1, "where the last file received spent its time",
      "putstat", d_putstat },
    { "wirestat", 1, "how long this Mac takes to notice a request",
      "wirestat [reset | sleep N | wake on|off]", d_wirestat },
    { "desktop", 1, "what this Mac's desktop is actually drawn from",
      "desktop", d_desktop },
    { "cancel", 0, "stop the file transfer in flight",
      "cancel   (no arguments)", d_cancel },
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
    { "chat", 0, "talk to a model through Other Mac",
      "chat <text> | --models [p] | --model <n> | --chats | --open <n> | "
      "--history | --projects | --project <n>|none|new <name> here|there | "
      "--mode <m> | --new | --stop",
      d_chat },
    { "sw", 1, "what is installed on this Mac",
      "sw [domain]", d_sw },
    { "launch", 1, "open an application on this Mac",
      "launch [-v VERSION] <name | path | #n>", d_launch },
    { "quit", 1, "ask an application on this Mac to quit",
      "quit [--all] [--wait N | --no-wait] <name>", d_quit },
    { "front", 1, "bring an application on this Mac forward",
      "front <name>", d_front },
    { "hide", 1, "hide or show an application on this Mac",
      "hide [--show | --status] <name>", d_hide },
    { "reveal", 1, "show an item in this Mac's Finder",
      "reveal <name | full path | #n>", d_reveal },
    { "vers", 1, "one file's version resources",
      "vers <name | full path | #n>", d_vers },
    { "elements", 1, "name this Mac's on-screen elements, so they can "
      "be acted on",
      "elements [serialHi serialLo]", d_elements },
    { "winact", 1, "move, resize, zoom or close one window",
      "winact <window> <action> [geometry]", d_winact },
    { "cursoract", 1, "place the cursor inside one observed window",
      "cursoract <window> <h> <v>", d_cursoract },
    { "textget", 1, "read one text element's contents",
      "textget <element>", d_textget },
    { "textset", 1, "replace one text element's contents",
      "textset <element> <text>", d_textset },
    { "ctlact", 1, "act on one control",
      "ctlact <element> <part> [h v]", d_ctlact },
    { "dragpress", 1, "press and hold the mouse button on an element",
      "dragpress <element> [idle] [cap]", d_dragpress },
    { "dragmove", 1, "move a held drag to a point",
      "dragmove <session> <h> <v>", d_dragmove },
    { "dragrelease", 1, "ask the resident to release a held drag",
      "dragrelease <session>", d_dragrelease },
    { "ditemact", 1, "select one Dialog Manager item",
      "ditemact <element> <item>", d_ditemact },
    { "menuact", 1, "perform one menu command",
      "menuact <menu> <item> <titleLeft>", d_menuact },
    { "activate", 1, "bring one process forward, by serial number",
      "activate <serialHi> <serialLo>", d_activate },
    { "actselftest", 1, "prove the act plane's trap ABI in one process",
      "actselftest [serialHi serialLo]", d_actselftest },
    { "mouseloc", 1, "where this Mac's pointer actually is",
      "mouseloc", d_mouseloc },
    { "key", 1, "post one keystroke, with no modifiers",
      "key <name | char N | code N>", d_key },
    { "script", 1, "run one AppleScript on this Mac",
      "script <source>", d_script },
    { "aesend", 1, "send one core Apple Event to a process on this Mac",
      "aesend <event> <serialHi> <serialLo> [path]", d_aesend },
    { "qdtrace", 1, "what is drawing on this Mac",
      "qdtrace [op] ...   (op = status | start | stop | drain)", d_qdtrace },
    { "transitions", 1, "what changed between two of this Mac's event passes",
      "transitions [op] [name]   (op = status | start | stop | drain)",
      d_transitions },
    { "observe", 1, "walk this Mac's elements and mint a reference for each",
      "observe [scope]", d_observe },
    { "handle", 1, "take one reference back to a live element",
      "handle <ref>", d_handle },
    { "axtree", 1, "the same walk, to look at rather than to act on",
      "axtree [scope]", d_axtree },
    { "axsnap", 1, "who is front, and how many references are live",
      "axsnap", d_axsnap },
    { "mirror", 1, "NOW Extension lifecycle and P1-P4 plane facts",
      "mirror", d_mirror },
    { "mirrorlog", 1, "mirror debug diagnostics in the log, on or off",
      "mirrorlog [on|off]", d_mirrorlog },
    { "offer", 1, "the file held out over the shared edge: take or drag it",
      "offer [--take|--drag|--stop]", d_offer },
    { "cycle", 1, "bring each application forward once so the Mirror can "
      "see it", "cycle", d_cycle },
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
