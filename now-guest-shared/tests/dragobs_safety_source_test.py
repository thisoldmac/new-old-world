#!/usr/bin/env python3
"""V14 drag observer source guard.

This plane patches the trap every Drag Manager call in the machine goes
through, so the properties that keep a Macintosh alive are properties of
the SOURCE, not of any run: a shim that could decline would change what a
drag does, a missing re-entrancy guard would recurse until the stack was
gone, and an allocation in the entry path would be a Memory Manager call
in a foreign application at the worst possible moment.

Each check below names the mutation it catches. Every one of them has
been watched failing against exactly that mutation - see the mutation log
in the commit that added this file.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONTRACT = (ROOT / "contract/peek_table.h").read_text()
CORE = (ROOT / "ext/src/now_ext.c").read_text()
OBS = (ROOT / "ext/src/now_ext_dragobs.c").read_text()
SHIM = (ROOT / "ext/src/now_ext_dragobs_patch.S").read_text()
DRAIN = (ROOT / "now-guest-ppc/src/input/continuity_service.c").read_text()
NET = (ROOT / "ext/src/now_liveness_net.c").read_text()
LIVENESS = (ROOT / "ext/src/now_liveness.c").read_text()
WIRE = (ROOT / "now-guest-ppc/src/core/wire.c").read_text()

failures = []


def check(condition: bool, message: str) -> None:
    if not condition:
        failures.append(message)


def body(source: str, start_name: str, end_name: str) -> str:
    start = source.index(start_name)
    end = source.index(end_name, start)
    return source[start:end]


def strip_comments(source: str) -> str:
    import re

    return re.sub(r"/\*.*?\*/", "", source, flags=re.S)


OBS_CODE = strip_comments(OBS)
SHIM_CODE = "\n".join(
    line.split("/*")[0] for line in SHIM.splitlines()
    if not line.strip().startswith("*")
)

# ---------------------------------------------------------------- contract
check("kNowPeekContinuityFormatV14" in CONTRACT
      and "kNowPeekContinuityFormatV15" in CONTRACT
      and "NOW_CONTINUITY_FORMAT_CURRENT 15u" in CONTRACT,
      "both observer formats must be explicit and V15 must be current")
check("_Static_assert(offsetof(NowPeekContinuityCell, drag_observe) == 4452"
      in CONTRACT,
      "the V14 block moved without its offset assert following it")
# The four counters that let this instrument report a negative honestly.
# Collapsing any pair of them makes 'patched and never called' read the
# same as 'never patched', which is the exact failure the act plane's
# 'active with full capabilities while every act refused' already was.
for field in ("install_state", "dispatches", "trackdrag_entries",
              "begin_seq"):
    check(f"NowPeekU32 {field};" in CONTRACT,
          f"the V14 block lost the counter that separates absence "
          f"from defect: {field}")

# ------------------------------------------------------------ the shim
# THE CHAIN IS UNCONDITIONAL. Slice 1 observes; a shim with a path that
# skips the incumbent is a shim that can change what a drag does.
check(SHIM_CODE.count("jmp (%a0)") == 2
      and SHIM_CODE.count("movea.l gNowDragObsOldDispatch,%a0") == 2,
      "the drag shim grew a path that does not chain to the incumbent")
# D0 carries the selector into the incumbent dispatcher. It is in the
# saved set and nothing may touch it after the restore.
check(SHIM_CODE.count("movem.l %d0-%d2/%a0-%a1,-(%sp)") == 2
      and SHIM_CODE.count("movem.l (%sp)+,%d0-%d2/%a0-%a1") == 3,
      "the drag shim stopped preserving the selector register")
# The result word is READ in place and never written back.
check("move.w 20(%sp),%d2" in SHIM_CODE
      and "move.w %d0,(%sp)" not in SHIM_CODE
      and "move.w #" not in SHIM_CODE,
      "the drag shim writes into a caller's result slot")

# --------------------------------------------------- the re-entrancy guard
# Every Drag Manager call is the same trap, so the observer's own calls
# come back through the shim that made them. Without the guard the first
# drag on the machine recurses until the stack is gone.
enter = body(OBS, "int now_dragobs_enter(", "/* TrackDrag returned.")
enter_code = strip_comments(enter)
check("if (gInside) {" in enter_code
      and enter_code.index("if (gInside) {")
          < enter_code.index("block->dispatches++"),
      "the re-entrancy guard no longer runs before the observer works")
check(OBS_CODE.count("gInside = 1;") == OBS_CODE.count("gInside = 0;")
      and OBS_CODE.count("gInside = 1;") == 6,
      "a Drag Manager call escaped the re-entrancy guard's brackets")
# Every Drag Manager entry point this file uses, and where it may appear.
# `leave` runs from the return thunk with NO bracket around it, so a Drag
# Manager call added there would re-enter the shim unguarded.
DRAG_CALLS = ("CountDragItems(", "GetFlavorData(", "GetFlavorDataSize(",
              "GetDragItemReferenceNumber(", "GetDragMouse(",
              "GetDragAttributes(", "GetDragModifiers(", "GetDragOrigin(")
leave = strip_comments(OBS[OBS.index("/* TrackDrag returned."):])
for call in DRAG_CALLS:
    check(call in OBS_CODE,
          f"the observer stopped reading the drag through {call}")
    check(call not in leave,
          f"the unbracketed return path re-enters the Drag Manager: {call}")

# ---------------------------------------------------- allocation and I/O
# TrackDrag entry is task time in a FOREIGN application. Nothing here may
# allocate, move memory, wait, or touch the File Manager.
for token in ("NewPtr", "DisposePtr", "NewHandle", "DisposeHandle",
              "SetHandleSize", "now_log", "PBOpen", "FSpOpenDF",
              "WaitNextEvent", "GetNextEvent", "SysBeep",
              "GetFrontProcess", "SetFrontProcess"):
    check(token not in OBS_CODE,
          f"the drag observer reaches unsafe work in a foreign context: "
          f"{token}")

# --------------------------------------------------------- observe-only
# Nothing in this plane may set a drag's state. The Drag Manager's
# mutators are the ones that would turn slice 1 into slice 3 by accident.
for token in ("SetDragMouse", "SetDropLocation", "SetDragItemBounds",
              "ChangeDragBehaviors", "SetDragImage", "SetDragInputProc",
              "SetDragSendProc"):
    check(token not in OBS_CODE,
          f"the observe-only plane gained a Drag Manager mutator: {token}")
# And nothing in the resident reads the block back: it is evidence, and a
# decision that consulted it would be slice 2 arriving early.
RESIDENT_OTHERS = "".join(
    (ROOT / "ext/src" / name).read_text()
    for name in ("now_ext.c", "now_ext_act.c", "now_ext_continuity.c",
                 "now_ext_drag.c", "now_ext_cursor.c",
                 "now_ext_continuity_keyboard.c")
)
check("drag_observe" not in RESIDENT_OTHERS,
      "a second resident file now reads or writes the observer's block")

# ------------------------------------------------------- the name copy
# A fixed-width Pascal copy, bounded by BOTH the length byte and the
# field, because it is read from a foreign heap that may be gone.
check("if (len > 62)" in OBS_CODE
      and "out_name[0] = (unsigned char)len;" in OBS_CODE,
      "the dragged file's name is copied without both its bounds")
check("flavor.fileSpec.name" in OBS_CODE
      and "= flavor.fileSpec.name" not in OBS_CODE.replace(
          "out_name[i + 1] = flavor.fileSpec.name[i + 1];", ""),
      "the observer kept a pointer into a foreign heap instead of a copy")

# -------------------------------------------------------- honest status
# A promise is not an FSSpec. Reporting one as the other is precisely the
# guess this block exists not to make.
check("kNowPeekDragObsItemPromise" in OBS_CODE
      and "flavorTypePromiseHFS" in OBS_CODE,
      "a promised HFS flavor would now be reported as a real file")
check("*out_count = (NowPeekU32)count;" in OBS_CODE,
      "the item count stopped being the count the Drag Manager gave")

# ------------------------------------------------------------- the control
# `dispatches == 0` has two opposite meanings and only the control tells
# them apart. It must be OUTSIDE the re-entrancy guard - a control that
# our own guard swallowed would report Blind on a working shim - and it
# must be able to fail three different ways.
selftest = body(OBS, "static void dragobs_selftest(",
                "/* WHICH ARM SWITCHES THIS ON")
check("NewDrag(&probe)" in selftest and "DisposeDrag(probe)" in selftest,
      "the control stopped being a Drag Manager call of our own")
check("gInside" not in strip_comments(selftest),
      "the control went inside the guard, so it can only report Blind")
for outcome in ("kNowPeekDragObsSelftestSeen",
                "kNowPeekDragObsSelftestBlind",
                "kNowPeekDragObsSelftestRefused"):
    check(outcome in selftest,
          f"the control lost an outcome it must be able to report: {outcome}")
check("block->selftest_state != (NowPeekU32)kNowPeekDragObsSelftestUntried"
      in selftest,
      "the control stopped being once-per-boot")

# ================================================ V15, the registration route
handler = body(OBS, "static pascal OSErr now_dragobs_tracking(DragTrackingMessage",
               "/* ---- the control")
handler_code = strip_comments(handler)

# THE UPP IS NEVER A CAST ON THIS RUNTIME. A 68K handler reached by a
# PowerPC Drag Manager goes through Mixed Mode and needs a descriptor
# that says so; a cast produces a jump into the middle of one.
check("BUILD_ROUTINE_DESCRIPTOR(" in OBS_CODE
      and "uppDragTrackingHandlerProcInfo" in OBS_CODE,
      "the tracking handler UPP became a cast")
check("(DragTrackingHandlerUPP)now_dragobs_tracking" not in OBS_CODE,
      "the handler is passed to the Drag Manager as a bare cast")
# NOTHING IS ALLOCATED. NewDragTrackingHandlerUPP allocates, and it would
# allocate in the FOREIGN application's heap from a hook.
check("NewDragTrackingHandlerUPP" not in OBS_CODE
      and "NewRoutineDescriptor" not in OBS_CODE,
      "the handler descriptor is allocated in a foreign application's heap")
# ...and it is built from a LOCAL initializer, because this INIT is
# relocated at load and a procedure address in static data is either
# fixed up or a jump into nowhere.
check("RoutineDescriptor built = BUILD_ROUTINE_DESCRIPTOR(" in OBS_CODE,
      "the descriptor went back to static initialisation across a relocation")

# INSTALL/REMOVE PAIRING. A registration is per-application and can only
# be given back from the application that took it. A handler left behind
# after the arm ends is worse than a leaked patch: the Drag Manager keeps
# calling a plane that has been told to stand down.
check("RemoveTrackingHandler(" in OBS_CODE,
      "the plane can register a handler and never give it back")
arm_pass = body(OBS, "void now_ext_dragobs_gne(NowPeekTable *table,",
                "/* ---- reading a drag")
# Stated as the exact guard rather than as mere presence: a call to
# track_remove behind a condition that is never true reads identical to
# one that runs, and the ordering check alone let that through.
check("""        if (gTrackContextCount != 0)
            track_remove(&cell->drag_observe,
                         (NowPeekU32)LMGetCurrentA5());
        return;""" in arm_pass,
      "the disarm path no longer un-registers whenever a context holds one")
check(arm_pass.index("track_remove") < arm_pass.index("track_install"),
      "un-registration moved after the arm branch it is supposed to precede")
check("gTrackContexts[gTrackContextCount++] = a5;" in OBS_CODE
      and "gTrackContextCount--;" in OBS_CODE,
      "the context table stopped tracking what must be un-registered")
check("kNowPeekDragObsHandlerNoRoom" in OBS_CODE,
      "a registration that would not fit is dropped instead of recorded, "
      "and a dropped one can never be removed")

# THE HANDLER IS OBSERVE-ONLY AND MUST NOT REFUSE. Its result is
# consulted by the Drag Manager.
check(handler_code.count("return noErr;") >= 2
      and "return err" not in handler_code
      and "return userCanceledErr" not in handler_code,
      "the tracking handler can answer the Drag Manager with a refusal")
for token in ("SetDragMouse", "SetDropLocation", "SetDragImage"):
    check(token not in handler_code,
          f"the tracking handler gained a Drag Manager mutator: {token}")
# Its Drag Manager reads go back out through our own trap shim, so they
# are inside the same guard as everything else here.
check("block->handler_reentries++" in handler_code,
      "the handler stopped counting its own re-entries")

# The two routes are counted SEPARATELY. Collapsing them destroys the
# only comparison that matters.
check("handler_calls" in CONTRACT and "handler_installs" in CONTRACT
      and "dispatches" in CONTRACT and "trackdrag_entries" in CONTRACT,
      "the trap route and the registration route share a counter")
check("hitem_status" in CONTRACT and "item_status" in CONTRACT,
      "the two routes stopped reading identity into separate fields")

hdrain = body(DRAIN, "    /* ---- V15, the registration route",
              "    if (end_seq != gLastDragEndSeq")
check("drag handler state=" in hdrain and "drag track n=" in hdrain
      and "drag handler item seq=" in hdrain,
      "the registration route lost one of its three always-on lines")
# The NAME gets its own line. kLogLineMax is 120 and the first emulator
# round of this route printed a correct identity and cut it off two
# characters into the creator code.
check("drag handler file seq=" in hdrain and "name=%s" in hdrain,
      "the dragged file's name went back on a line that truncates it")
check("now_mirror_debug_on()" not in hdrain,
      "the targeting stream went behind the debug gate - it is the whole "
      "reason the route was tried")

# ------------------------------------------------------ install per pass
# Once-per-boot is the act plane's measured mistake: the install lands in
# NOW's own context and no foreign application ever calls it.
gne = body(OBS, "void now_ext_dragobs_gne(NowPeekTable *table,",
           "/* ---- reading a drag")
check("dragobs_install(&cell->drag_observe);" in gne
      and "static int" not in gne and "installed" not in gne,
      "the drag shim install became one-shot again")
check("now_ext_dragobs_gne(table, request);" in CORE,
      "the core stopped running the observer's armed pass")
install = body(OBS, "static void dragobs_install(",
               "void now_ext_dragobs_gne(")
check("if (old == (void *)now_dragobs_patch)" in install,
      "a second install would chain the shim to itself and hang")
check("NGetTrapAddress(_Unimplemented, ToolTrap)" in install,
      "a machine with no Drag Manager would read as a broken patch")
check("NSetTrapAddress" not in strip_comments(OBS).replace(
          strip_comments(install), ""),
      "the trap table is written outside the single install function")

# ---------------------------------------------------------- the drain
drain = body(DRAIN, "static void drain_drag_observe(",
             "/* V11 deep click probe drain.")
# The drain runs on the Mirror's slow idle, not inside the Continuity
# service: the observer is armed by the act plane too, and the first
# emulator round drained NOTHING because the service only runs while an
# epoch runs. That is the mistake this pin exists to keep from returning.
IDLE = (ROOT / "now-guest-ppc/src/mirror/mirror_log.c").read_text()
check("now_continuity_drag_observe_idle();" in IDLE,
      "the drag drain left the Mirror's idle observer")
check("drain_drag_observe(cell);" not in DRAIN,
      "the drag drain went back inside the epoch-gated Continuity service")
check("now_log_memory" not in drain and "now_log(" in drain,
      "the drag observer drain fell back to the never-uploaded memory log")
# The lifecycle is ALWAYS ON and only the per-look ring is gated. Stated
# as four separate properties, because the counters line now MENTIONS the
# gate - extra Drag Manager traffic beyond the first is debug tier -
# while not being behind it, and a pin that only checked ordering read
# that as the lifecycle going dark.
check("if (!now_mirror_debug_on())" not in drain,
      "the whole drain went behind the debug gate")
check(drain.index("obs->install_state != gLastDragInstall")
      < drain.index("now_mirror_debug_on()"),
      "the counters line no longer has an ungated reason to print")
check(drain.index("drag begin seq=")
      < drain.index("if (now_mirror_debug_on()"),
      "a drag beginning went behind the debug gate")
check("drag look n=" in drain.split("if (now_mirror_debug_on()")[1],
      "the per-look ring came out from behind the debug gate")

# ============================================ V16, the resident's own send
#
# The identity has always been read in time and published too late: the
# application that publishes it gets no task time until the Finder's drag
# loop ends, so the drag-sourced generation reached the host 462 ticks
# after the drag began and 14 ticks after it ENDED (2026-08-16). The
# resident now says it itself, over its own channel, from the tracking
# handler. That is a SEND from inside a foreign application's drag loop,
# and every property that makes it safe is a property of this source.
NET_CODE = strip_comments(NET)
send = body(NET, "int now_liveness_net_send_drag(", "\n}\n")
send_code = strip_comments(send)

# WHERE IT IS CALLED FROM. Task time in the handler, and nowhere else.
# The pump is INTERRUPT time; a drag frame built from there would be the
# context error six PowerBook wedges were bought with.
check("now_liveness_net_send_drag(" in handler_code,
      "the drag identity is no longer sent from the tracking handler, so "
      "it can only reach the host after the drag it describes has ended")
pump = body(NET, "void now_liveness_net_pump(", "/* ------------------")
check("now_liveness_net_send_drag" not in strip_comments(pump)
      and "now_liveness_net_send_drag" not in strip_comments(LIVENESS),
      "the drag send is reachable from the interrupt-time pump")

# AFTER THE COMMIT WORD. The application's drain lifts the record on the
# strength of an even handler_begin_seq; a send that preceded it would
# be a host holding a fact the machine's own table does not yet admit.
check(handler_code.index("block->handler_begin_seq++;\n        break;") <
      handler_code.index("now_liveness_net_send_drag(")
      if "block->handler_begin_seq++;\n        break;" in handler_code
      else handler_code.rindex("handler_begin_seq++")
           < handler_code.index("now_liveness_net_send_drag("),
      "the drag frame is sent before the record is committed")
# ONLY AN HFS FIRST ITEM, AND ONLY UNDER AN EPOCH. A promise names no
# file this side could serve, and a drag with no epoch is a person using
# their own Macintosh rather than a consent.
check("kNowPeekDragObsItemHFS" in handler_code
      and handler_code.index("kNowPeekDragObsItemHFS")
          < handler_code.index("now_liveness_net_send_drag("),
      "a promise or a text drag would now be sent as a file")
check("cell->epoch != 0" in handler_code,
      "a drag seen with no Continuity epoch running is sent anyway")

# ITS OWN PARAM BLOCK. gCtlPB belongs to the interrupt-time pump's
# one-call-at-a-time state machine; a task-time caller filling it in
# while an interrupt reaps it is a corruption, not a race to argue over.
check("gDragPB" in send_code and "gCtlPB" not in send_code,
      "the drag send writes the pump's own param block")
check("static TCPiopb gDragPB;" in NET_CODE
      and "static wdsEntry gDragWDS[2];" in NET_CODE,
      "the drag send lost the param block and WDS that keep it clear of "
      "the pump")

# FIRE AND FORGET. Async, nil completion, no wait, no retry - the Finder
# is inside TrackDrag with this call on its stack.
check("PBControlAsync((ParmBlkPtr)&gDragPB)" in send_code
      and "PBControlSync" not in send_code,
      "the drag send blocks the Finder's drag loop")
check("gDragPB.ioCompletion = NULL;" in send_code,
      "the drag send grew a completion routine whose ABI is not settled")
check("while" not in send_code and "for (" not in send_code,
      "the drag send waits or retries inside the Finder's drag loop")

# NOTHING IS QUEUED, AND EVERY WAY IT DOES NOT GO OUT IS COUNTED.
# A queue here would be a resident holding somebody's file identity for
# an unbounded time; a single 'not sent' counter would make 'the host was
# never up' and 'two drags in one send' the same reading.
for counter in ("drag_send_sends", "drag_send_dropped",
                "drag_send_unconnected", "drag_send_busy",
                "drag_send_last_seq"):
    check(f"NowPeekU32 {counter};" in CONTRACT and counter in send_code,
          f"the drag send lost the counter that names one of its "
          f"outcomes: {counter}")
check("_Static_assert(sizeof(NowPeekTable)\n                   == offsetof("
      "NowPeekTable, drag_send_format) + 24," in CONTRACT,
      "the drag-send counters moved without their tail assert following")

# THE RESIDENT DOES NOT LOG, AND DOES NOT REACH THE FILE MANAGER. The
# frame carries what a live DragRef already knew and nothing that would
# need a call this context may not make.
for token in ("now_log", "NewPtr", "NewHandle", "FSpGetFInfo", "PBGetCatInfo",
              "FSpOpenDF", "GetVInfo", "WaitNextEvent"):
    check(token not in NET_CODE,
          f"the resident's channel reaches work its context forbids: {token}")

# THE JOIN KEY IS ON BOTH ACCOUNTS OF THE GESTURE. The resident's frame
# and the application's own continuity.selection must carry the same
# dragSeq, or a host has to decide by timing whether two frames are one
# drag - and timing is precisely what is unreliable here.
builder = body(NET, "static unsigned long build_drag_begin(",
               "/* Reap our own previous frame")
builder_code = strip_comments(builder)
check(r',\"dragSeq\":' in builder_code
      and r'\"continuity.dragBegin\"' in builder_code,
      "the resident's frame stopped naming the drag it describes")
# NO SIZES, NO DATES, NO FOLDERNESS: all three need the File Manager and
# this context may not call it. A frame that carried them would either be
# lying or be a charter breach, and both are worse than their absence.
for absent in ("dataSize", "resourceSize", "modifiedAt", "isFolder"):
    check(absent not in builder_code,
          f"the drag frame claims a field only the File Manager could "
          f"answer: {absent}")
check('\\"dragSeq\\":%lu' in WIRE
      and "table->item.drag_seq" in WIRE,
      "the application's selection stopped carrying the join key")

if failures:
    for message in failures:
        print(f"FAIL: {message}")
    raise SystemExit(1)
print("dragobs_safety_source_test: ok")
