#!/usr/bin/env python3
"""NOW's self scene must carry the Menu Manager's Help coordinate."""

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

    if "short help_left" not in system:
        raise SystemExit("the self system-menu collector has no guest Help "
                         "coordinate")
    if "GetMenuHandle(kNowSelfHelpMenuID), help_left" not in system:
        raise SystemExit("the Help menu is not emitted at the coordinate the "
                         "guest supplied")
    if "collect_self_system_menus(s, head->last_right)" not in collect:
        raise SystemExit("Help must use MenuList.last_right; zero draws Help "
                         "over the Apple menu in the Mirror")

    print("ok")


if __name__ == "__main__":
    main()
