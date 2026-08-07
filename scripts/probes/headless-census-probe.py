#!/usr/bin/env python3
"""Does the machine agree that these processes are faceless — and does the
visibility census have anything to say about them?

    scripts/probes/headless-census-probe.py --port 5380

Two claims are under test, and neither is safe to assume.

1. **THE DECLARATION IS REALLY SET.** `apps[].backgroundOnly` is the
   process's own `modeOnlyBackground` bit. That the field exists in the
   encoder proves nothing about whether Control Strip Extension actually
   sets it on a real Mac OS 9.1 boot. This asks the guest and prints the
   roster.

2. **THE APPLICATION MENU'S MEMBERSHIP IS THE SAME BIT.** The claim in
   docs/scene-producer.md is that the Process Manager populates the
   Application menu from `modeOnlyBackground`, so the switcher is not a
   second, independent signal to corroborate the declaration against. If
   that is right, the set of application-menu rows and the set of
   non-`backgroundOnly` processes coincide. If it is wrong, this prints
   the disagreement — and a disagreement would be the more interesting
   result, because it would mean there IS a second signal.

   The Application menu is the guest's own, id -16489, and its rows below
   the separator are the running applications. It is read from the FRONT
   process's menu bar, so a run with NOW itself in front reads NOW's copy;
   the roster is the Menu Manager's either way.

3. **WHAT THE CENSUS COULD EVER COVER.** The host's visibility census asks
   the Finder for `every application process`. This prints how many
   processes the roster has, how many declare themselves faceless, and
   therefore what the denominator would have to be for
   `process-visibility` to be able to read `complete` at all.

It changes nothing on the machine and takes no arguments beyond the link.
"""
import argparse
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import nowwire                                          # noqa: E402

# HitTester.applicationMenuID / ObjectResolver — the system's own id.
APPLICATION_MENU_ID = -16489


def application_menu_rows(scene):
    """Names the guest's Application menu is offering, or None when the
    scene carries no menu bar to read (which is an ABSENT signal, not an
    empty one — the difference this whole probe is about)."""
    menus = (scene.get("menubar") or {}).get("menus")
    if not menus:
        return None
    for menu in menus:
        if menu.get("id") != APPLICATION_MENU_ID:
            continue
        items = menu.get("items") or []
        # Hide <app> / Hide Others / Show All, a separator, then the
        # applications. Everything after the LAST separator is the roster.
        cut = max((i for i, it in enumerate(items)
                   if it.get("separator")), default=-1)
        return [it.get("title", "") for it in items[cut + 1:]
                if not it.get("separator")]
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    nowwire.add_link_args(ap)
    ap.add_argument("--json", action="store_true",
                    help="machine-readable, for a report")
    args = ap.parse_args()

    link = nowwire.link_from_args(args)
    # WHICH GUEST ANSWERED. Every QEMU guest on this Mac reaches the host
    # as 10.0.2.2, so any session's VM running any branch's build can dial
    # this listener — and here that would be silently wrong rather than
    # loud: a build without `backgroundOnly` emits no such key, and this
    # probe would report "0 declared faceless" as a MEASUREMENT of the
    # machine instead of a fact about the binary. The stamp is printed
    # beside every number for that reason.
    print(f"guest: {link.hello.get('name')!r} "
          f"version {link.hello.get('version')} "
          f"build {link.hello.get('build')}")
    print()
    scene, _envelope = link.scene()

    apps = scene.get("apps") or []
    windows = scene.get("windows") or []
    per_psn = {}
    for w in windows:
        per_psn[w.get("psn")] = per_psn.get(w.get("psn"), 0) + 1

    rows = []
    for a in apps:
        rows.append({
            "name": a.get("name"),
            "psn": a.get("psn"),
            "front": bool(a.get("front")),
            # Absent is NOT false — printed as null so a reader can see
            # which of the two they are looking at.
            "backgroundOnly": a.get("backgroundOnly"),
            "error": a.get("error"),
            "windows": per_psn.get(a.get("psn"), 0),
        })

    headless = [r for r in rows if r["backgroundOnly"] is True]
    undeclared = [r for r in rows if r["backgroundOnly"] is None]
    faced = [r for r in rows if r["backgroundOnly"] is not True]
    not_found = [r for r in rows if r["error"] == "ax_oracle_not_found"]

    switcher = application_menu_rows(scene)
    agreement = None
    if switcher is not None:
        in_menu = set(switcher)
        faced_names = {r["name"] for r in faced}
        agreement = {
            "menuRows": sorted(in_menu),
            "facedButNotInMenu": sorted(faced_names - in_menu),
            "inMenuButHeadless": sorted(
                in_menu & {r["name"] for r in headless}),
        }

    report = {
        "processes": len(rows),
        "headlessDeclared": len(headless),
        "undeclared": len(undeclared),
        "coverableByTheCensus": len(faced),
        "stillReportingNotFound": [r["name"] for r in not_found],
        "rows": rows,
        "applicationMenu": agreement,
    }

    if args.json:
        print(json.dumps(report, indent=1))
        return 0

    print(f"{len(rows)} processes in the scene")
    for r in rows:
        mark = ("headless" if r["backgroundOnly"] is True
                else "faced" if r["backgroundOnly"] is False
                else "UNDECLARED")
        print(f"  {r['name']:<32} {mark:<11} windows={r['windows']:<3}"
              f" {'front' if r['front'] else '     '}"
              f" {r['error'] or ''}")
    print()
    print(f"declared faceless : {len(headless)}")
    print(f"undeclared        : {len(undeclared)}"
          "   (absent is not false — an older guest, or a read that failed)")
    print(f"census could cover: {len(faced)} of {len(rows)}"
          "   <- the only denominator process-visibility can ever fill")
    if not_found:
        print(f"still ax_oracle_not_found: "
              f"{', '.join(r['name'] for r in not_found)}"
              "   (each one has a FACE and could not be read — a real gap)")
    else:
        print("no process reports ax_oracle_not_found")
    print()
    if switcher is None:
        print("Application menu: NOT IN THIS SCENE — no corroboration either "
              "way (absent, not empty)")
    else:
        print(f"Application menu offers {len(agreement['menuRows'])}: "
              f"{', '.join(agreement['menuRows'])}")
        if agreement["inMenuButHeadless"]:
            print("  DISAGREEMENT — the menu offers a process that declared "
                  "itself faceless: "
                  + ", ".join(agreement["inMenuButHeadless"]))
        if agreement["facedButNotInMenu"]:
            print("  DISAGREEMENT — a process with a face the menu does not "
                  "offer: " + ", ".join(agreement["facedButNotInMenu"]))
        if not agreement["inMenuButHeadless"] \
                and not agreement["facedButNotInMenu"]:
            print("  the menu's membership and the declaration coincide "
                  "exactly, which is what 'the same bit one remove away' "
                  "predicts — and therefore NOT independent corroboration")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
