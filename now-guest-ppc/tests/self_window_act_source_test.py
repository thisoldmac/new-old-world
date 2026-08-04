#!/usr/bin/env python3
"""Pin the optional-extension boundary for NOW's own window acts."""

import os
from pathlib import Path


DEFAULT_SOURCE = (Path(__file__).resolve().parents[1] / "src" / "act"
                  / "act_cmds.c")
SOURCE = Path(os.environ.get("NOW_ACT_CMDS_SOURCE", DEFAULT_SOURCE)).read_text()


def require(value, message):
    if not value:
        raise SystemExit("FAIL: " + message)


resolver = SOURCE.split("static int resolve_for_act", 1)[1]
resolver = resolver.split("/* ---- where `elements` went", 1)[0]
direct = resolver.find("self_direct && act_target_is_self")
plane = resolver.find("now_act_ready()")
require(direct >= 0, "resolve_for_act lost the direct-self decision")
require(plane >= 0, "resolve_for_act lost the foreign act-plane gate")
require(direct < plane,
        "the optional resident plane is checked before the self-window path")

winact = SOURCE.split("void now_act_run_winact", 1)[1]
winact = winact.split("/* ---- textget", 1)[0]
require("&handle, ref, 1)" in winact,
        "winact no longer opts its self window into direct Window Manager acts")

self_act = SOURCE.split("static void self_window_act", 1)[1]
self_act = self_act.split("void now_act_run_winact", 1)[0]
require('row_add(&rows, "Dispatch", "dispatched")' in self_act,
        "direct self-window acts must use the shared dispatched vocabulary")
require('row_add(&rows, "Dispatch", "performed")' not in self_act,
        "the host cannot interpret the private performed dispatch value")
require("g_self_window_close_handler(window)" in self_act,
        "self close must enter the owning application's close path")
require("HideWindow(window)" not in self_act,
        "self close cannot leave an application-owned hidden window behind")

ctlact = SOURCE.split("void now_act_run_ctlact", 1)[1]
ctlact = ctlact.split("/* ---- ditemact", 1)[0]
require("&handle, ref, 0)" in ctlact,
        "control acts must still require the application's event-path plane")

print("PASS: self window acts precede the optional resident-plane gate")
