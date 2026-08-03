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

    if "current_live_menu_list()" not in collect:
        raise SystemExit("the self scene must read the live MenuList that "
                         "carries guest system-menu geometry")
    if "kNowMenuListLowMemoryAddress = 0x0A1C" not in READ:
        raise SystemExit("the classic MenuList low-memory address must be "
                         "explicit and reviewable")
    if "return *(Handle *)kNowMenuListLowMemoryAddress" not in READ:
        raise SystemExit("the live MenuList helper no longer reads the "
                         "platform's measured low-memory global")
    if "GetMenuBar()" in collect:
        raise SystemExit("GetMenuBar's copy omitted Apple, Help, and the "
                         "Application menu on the live Mac OS 9 guest")
    if "DisposeHandle(bar)" in collect:
        raise SystemExit("the Menu Manager owns LMGetMenuList's handle")
    if "AcquireRootMenu()" not in collect or "ReleaseMenu(root)" not in collect:
        raise SystemExit("the system-owned Apple rows must be acquired from "
                         "and released with Carbon's live root menu")
    if "root_items_for(root, entry->menu)" not in collect:
        raise SystemExit("an empty MenuList shell must resolve its root-menu "
                         "submenu by identity")
    root_items = body("static MenuRef root_items_for(")
    if "GetMenuItemHierarchicalMenu" not in root_items:
        raise SystemExit("root-menu rows must come from the attached submenu")
    if "GetMenuID(child) == wanted" not in root_items:
        raise SystemExit("the root submenu must match the measured MenuList "
                         "entry by menu ID, not by title or geometry")
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
