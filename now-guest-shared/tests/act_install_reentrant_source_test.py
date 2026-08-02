#!/usr/bin/env python3
"""Installing the act patches twice must be survivable, not fatal.

WHY A SOURCE TEST. `install_patch` calls `NGetTrapAddress` and
`NSetTrapAddress`; no host cc can link them, and the failure it guards
against cannot be caught by running anything here. But the failure is the
worst one this project can ship:

  A second install that saves the incumbent WITHOUT checking would save
  our own shim as the "original". The chain would then point at itself,
  and the first application to call MenuSelect would loop until the
  machine stopped - at boot, in every process, with no way in.

The one-shot `static int installed` used to make that unreachable. It was
removed on 2026-08-02, because installing once meant installing in
whichever process pumped first - always NOW's own Carbon application, the
one serving the wire - and the patch was then not in the dispatch path
inside any other application (`actselftest` answered `act-no-patch`
inside the Finder and SimpleText, twice each, on a boot where NOW's own
application abi-agreed twice).

So the safety now rests entirely on `install_patch` recognising its own
shim and returning before it saves anything. This pins that:

  * the identity check exists, and compares the incumbent to the shim,
  * it returns before `*saved` is written,
  * and it still marks the capability bit, because the patch IS present
    in that table - a second install that reported "no patch" would make
    every op refuse for a machine that is correctly patched.

What this cannot check is whether the trap table is per-context. It does
not need to: the check makes a repeat install correct either way, which
is why the change was safe to make before that question was settled.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.join(HERE, "..", "..", "ext", "src", "now_ext_act.c")

failures = []


def check(ok, what):
    if not ok:
        failures.append(what)


def body_of(text, signature):
    start = text.find(signature)
    if start == -1:
        failures.append("%s is not in the source at all" % signature)
        return ""
    end = text.find("\n}", start)
    return text[start:end if end != -1 else len(text)]


def main():
    with open(SOURCE, "r") as handle:
        text = handle.read()

    install = body_of(text, "static void install_patch(")
    if install:
        guard = re.search(r"if\s*\(\s*old\s*==\s*shim\s*\)", install)
        check(guard is not None,
              "install_patch does not compare the incumbent against its "
              "own shim, so a second install would save OUR shim as the "
              "original and the first MenuSelect would chain to itself "
              "forever - at boot, in every process")
        if guard is not None:
            save = install.find("*saved = old")
            check(save == -1 or guard.start() < save,
                  "install_patch's self-check comes after it saves the "
                  "incumbent, which is the same failure with extra steps")
            tail = install[guard.end():save if save != -1 else len(install)]
            check("*patches |=" in tail,
                  "install_patch returns early when the patch is already "
                  "ours WITHOUT marking the capability bit, so a correctly "
                  "patched table would report no patch and every op would "
                  "refuse on it")

    installer = body_of(text, "static void act_install(")
    if installer:
        check("static int installed" not in installer,
              "act_install is one-shot again. That is not wrong in itself, "
              "but it is what confined the patches to whichever process "
              "pumped first - always the one serving the wire - so if it "
              "is coming back, the measurement in docs/open-issues.md "
              "should be re-read first")

    if failures:
        for line in failures:
            sys.stderr.write("FAIL: %s\n" % line)
        sys.stderr.write("%d failure(s)\n" % len(failures))
        return 1
    print("act_install_reentrant_source: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
