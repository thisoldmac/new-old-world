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
    collect = body("static void collect_self_menubar(")
    controls = body("static void add_control_tree(")

    if "LMGetMenuList()" not in collect:
        raise SystemExit("the self scene must read the live MenuList that "
                         "carries guest system-menu geometry")
    if "GetMenuBar()" in collect:
        raise SystemExit("GetMenuBar's copy omitted Apple, Help, and the "
                         "Application menu on the live Mac OS 9 guest")
    if "DisposeHandle(bar)" in collect:
        raise SystemExit("the Menu Manager owns LMGetMenuList's handle")
    for guessed in ("kNowSelfAppleMenuID", "head->last_right"):
        if guessed in collect or guessed in READ:
            raise SystemExit("system menus must come from the live MenuList, "
                             f"not the guessed {guessed} fallback")
    if "kControlPopupButtonMenuHandleTag" not in controls:
        raise SystemExit("popup values must come from the control's owned "
                         "MenuRef, not only the process menu list")
    if "GetMenuHandle(GetControlMinimum(control))" not in controls:
        raise SystemExit("popup extraction must retain the classic menu-list "
                         "fallback")

    print("ok")


if __name__ == "__main__":
    main()
