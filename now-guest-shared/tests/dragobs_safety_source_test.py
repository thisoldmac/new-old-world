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
      and "NOW_CONTINUITY_FORMAT_CURRENT 14u" in CONTRACT,
      "V14 must have an explicit format number and be the current one")
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
      and OBS_CODE.count("gInside = 1;") == 2,
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
      and "block->file_name[0] = (unsigned char)len;" in OBS_CODE,
      "the dragged file's name is copied without both its bounds")
check("flavor.fileSpec.name" in OBS_CODE
      and "= flavor.fileSpec.name" not in OBS_CODE.replace(
          "block->file_name[i + 1] = flavor.fileSpec.name[i + 1];", ""),
      "the observer kept a pointer into a foreign heap instead of a copy")

# -------------------------------------------------------- honest status
# A promise is not an FSSpec. Reporting one as the other is precisely the
# guess this block exists not to make.
check("kNowPeekDragObsItemPromise" in OBS_CODE
      and "flavorTypePromiseHFS" in OBS_CODE,
      "a promised HFS flavor would now be reported as a real file")
check("block->item_count = (NowPeekU32)count;" in OBS_CODE,
      "the item count stopped being the count the Drag Manager gave")

# ------------------------------------------------------ install per pass
# Once-per-boot is the act plane's measured mistake: the install lands in
# NOW's own context and no foreign application ever calls it.
gne = body(OBS, "void now_ext_dragobs_gne(", "/* ---- reading a drag")
check("dragobs_install(&cell->drag_observe);" in gne
      and "static int" not in gne and "installed" not in gne,
      "the drag shim install became one-shot again")
check("now_ext_dragobs_gne(table);" in CORE,
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
check("now_log_memory" not in drain and "now_log(" in drain,
      "the drag observer drain fell back to the never-uploaded memory log")
# The lifecycle is always on; only the per-look ring is gated. A gate on
# the counters line would hide the negative this slice exists to report.
check(drain.index("drag obs install=") < drain.index("now_mirror_debug_on()")
      and drain.index("drag begin seq=") < drain.index("now_mirror_debug_on()")
      and "drag look n=" in drain.split("now_mirror_debug_on()")[1],
      "the drag lifecycle went behind the debug gate, or the ring came out")

if failures:
    for message in failures:
        print(f"FAIL: {message}")
    raise SystemExit(1)
print("dragobs_safety_source_test: ok")
