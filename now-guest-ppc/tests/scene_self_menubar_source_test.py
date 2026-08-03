#!/usr/bin/env python3
"""NOW's self scene must carry real system menus and popup values."""

import os
from pathlib import Path


DEFAULT = Path(__file__).resolve().parents[1] / "src" / "scene" / "scene_self.c"
SOURCE = Path(os.environ.get("NOW_SCENE_SELF_SOURCE_UNDER_TEST", DEFAULT))
READ = SOURCE.read_text()


def body(signature: str) -> str:
    start = READ.index(signature)
    end = READ.index("\n}\n", start)
    return READ[start:end]


def main() -> None:
    system = body("static void collect_self_system_menus(")
    collect = body("static void collect_self_menubar(")
    controls = body("static void add_control_tree(")

    if "short help_left" not in system:
        raise SystemExit("the self system-menu collector has no guest Help "
                         "coordinate")
    if "GetMenuHandle(kNowSelfHelpMenuID), help_left" not in system:
        raise SystemExit("the Help menu is not emitted at the coordinate the "
                         "guest supplied")
    if "collect_self_system_menus(s, head->last_right)" not in collect:
        raise SystemExit("Help must use MenuList.last_right; zero draws Help "
                         "over the Apple menu in the Mirror")
    if "GetMenuHandle(kNowSelfAppleMenuID), 10" not in system:
        raise SystemExit("the self scene draws an Apple fallback but does not "
                         "carry the guest's actionable Apple menu")
    if "self_scene_has_menu(s, kNowSelfAppleMenuID)" not in system:
        raise SystemExit("the explicit Apple menu must not duplicate one "
                         "already found in the guest MenuList")
    if "kControlPopupButtonMenuHandleTag" not in controls:
        raise SystemExit("popup values must come from the control's owned "
                         "MenuRef, not only the process menu list")
    if "GetMenuHandle(GetControlMinimum(control))" not in controls:
        raise SystemExit("popup extraction must retain the classic menu-list "
                         "fallback")

    print("ok")


if __name__ == "__main__":
    main()
