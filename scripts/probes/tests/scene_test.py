#!/usr/bin/env python3
"""Cover the scene read's machineless half — scripts/probes/scene.py.

    python3 scripts/probes/tests/scene_test.py     # or via scripts/test-native

Same argument as `tally_test.py`, one plane over. The harnesses cannot run
here, but a scene read has three pieces that are pure and that would each
poison a number silently if they were wrong:

  * **reassembly and the IR gate.** A short document, an unknown IR major, a
    `scene.end ok:false` — each has to refuse rather than hand a caller
    something that parses.
  * **absent vs empty.** A menu bar the producer RETRACTED and a front process
    that genuinely has no menus are different machines. Collapse them and the
    menu cases score trials against a bar nobody ever read.
  * **staleness.** The cached bar is what every menu trial addresses. A rule
    that says "still fresh" when the front process changed underneath aims 20
    trials at another application's menu.

MUTATIONS THIS HAS BEEN SEEN TO FAIL UNDER. Run 2026-07-31 against
scripts/probes/scene.py, one at a time, tree restored from git after each —
upstream's tests/h2-mutations.sh discipline. A test nobody has watched fail is
not a test.

    mutation                                            tests that went red
    --------------------------------------------------  -------------------
 1  menubar_state reads an absent bar as empty          absent/state
      -  if ... scene.get("menubar") is None: ABSENT     absent/menus-raises
      +  bar = (scene or {}).get("menubar") or {}
         return POPULATED if bar.get("menus") else EMPTY

    (A first attempt at this one — routing the absent case through
    plane_state({}, "menus") — SURVIVED, and rightly: it computes the same
    answer by another road. Recorded because a mutation that survives for
    that reason is not a hole in the test.)

 2  menus() returns [] instead of raising on absent     absent/menus-raises
      -  raise PlaneAbsent(...)
      +  return []

 3  the IR gate decodes first and checks the major      ir/unknown-major
    after                                               ir/unknown-major-not-parsed
      -  (major check) ... json.loads(...)
      +  json.loads(...) ... (major check)

 4  a short transfer is accepted                        short/refused
      -  if ... len(self.body) != announced: raise
      +  pass

 5  scene.end ok:false is not marked refused-by-guest   refuse/by-guest
      -  refused_by_guest=True
      +  refused_by_guest=False

 6  stale_reason ignores the front process              stale/front-changed
      -  if front_app is not None and owner != ...       stale/front-changed-reason
      +  if False:

 7  leftmost_menu picks the first in list order         leftmost/unsorted
      -  min(bar, key=... left ...)
      +  bar[0]

 8  a bulk frame for another transfer is folded in      foreign/counted
      -  if ... transfer != self.transfer: count         foreign/body
      +  if False: ...

Mutation 3 is the one worth reading twice: it passes every test about a
well-formed scene, and it means an IR the harness does not describe gets
decoded and measured anyway — which is the failure the version-in-the-envelope
exists to prevent.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import scene as scenemod  # noqa: E402

FAILURES = []


def check(name, got, want):
    if got != want:
        FAILURES.append(f"{name}: got {got!r}, want {want!r}")


def check_raises(name, exc, fn):
    try:
        fn()
    except exc:
        return
    except Exception as other:                                  # noqa: BLE001
        FAILURES.append(f"{name}: raised {type(other).__name__}, "
                        f"want {exc.__name__}")
        return
    FAILURES.append(f"{name}: did not raise {exc.__name__}")


# --- fixtures ----------------------------------------------------------------
#
# Shaped after now-guest-ppc/src/scene/scene_json.c, which is the only producer
# of these bytes. Keys and their absence are copied from that encoder, not
# invented: `menubar` is emitted only when the plane is present, `items` only
# when a menu's item walk completed, `cmd` only when the item has one.

def doc(**over) -> dict:
    d = {"version": 1, "seq": 7, "capturedAt": 1234.5, "source": "peek",
         "screen": {"w": 1024, "h": 768},
         "apps": [{"psn": "0.12345", "name": "Finder", "front": True}],
         "processes": [{"psn": "0.12345", "name": "Finder", "front": True,
                        "signature": "MACS"}],
         "windows": [],
         "meta": {"errors": []}}
    d.update(over)
    return d


FINDER_BAR = {
    "app": "Finder",
    "menus": [
        {"title": "File", "id": 129, "left": 38,
         "items": [{"title": "New Folder", "index": 1, "separator": False,
                    "enabled": True, "mark": False, "cmd": "N"}]},
        # The Apple menu is NOT first in this fixture, and that is the point:
        # the producer emits the bar in its own order and never says which
        # menu is Apple's.
        {"title": "\x14", "id": 128, "left": 10},
        {"title": "Edit", "id": 130, "left": 76, "items": []},
    ],
}


def framed(body: bytes, *, request_id=3, transfer=9, chunk=8, bytes_=None,
           ir=1, ok=True):
    """One whole scene delivery, as a list of (kind, payload) events."""
    events = [("control", {"type": "scene.begin", "id": request_id,
                           "transfer": transfer,
                           "bytes": len(body) if bytes_ is None else bytes_,
                           "irVersion": ir, "seq": 7, "capturedAt": 1234.5,
                           "source": "peek", "walkMs": 41})]
    for i in range(0, len(body), chunk):
        piece = body[i:i + chunk]
        events.append(("bulk", (transfer, piece,
                                i + chunk >= len(body))))
    events.append(("control", {"type": "scene.end", "id": request_id,
                               "transfer": transfer, "ok": ok, "sendMs": 12}))
    return events


def drive(events, request_id=3) -> scenemod.SceneReader:
    r = scenemod.SceneReader(request_id)
    for kind, payload in events:
        if kind == "control":
            r.on_control(payload)
        else:
            r.on_bulk(*payload)
    return r


def body_of(document) -> bytes:
    return json.dumps(document).encode("utf-8")


# --- reassembly --------------------------------------------------------------

def a_whole_scene_reassembles():
    r = drive(framed(body_of(doc(menubar=FINDER_BAR))))
    check("whole/done", r.done, True)
    got = r.result()
    check("whole/app", scenemod.menubar_app(got), "Finder")
    check("whole/menus", len(scenemod.menus(got)), 3)
    check("whole/walkMs", r.envelope()["walkMs"], 41)


def the_terminator_is_scene_end_not_the_flag():
    # A refusal carries NO bulk at all, so a reader that waited for the END
    # flag would wait forever on exactly the answer it most needs.
    r = scenemod.SceneReader(3)
    r.on_control({"type": "scene.end", "id": 3, "transfer": 9, "ok": False,
                  "reason": "not enough memory to walk the machine"})
    check("terminator/done", r.done, True)


def a_refusal_is_the_guests_and_says_so():
    r = scenemod.SceneReader(3)
    r.on_control({"type": "scene.end", "id": 3, "transfer": 9, "ok": False,
                  "reason": "a transfer is already in flight"})
    try:
        r.result()
        FAILURES.append("refuse/by-guest: did not raise")
    except scenemod.SceneUnavailable as exc:
        check("refuse/by-guest", exc.refused_by_guest, True)
        check("refuse/reason", "already in flight" in exc.message, True)


def another_transfers_bulk_is_not_this_scene():
    body = body_of(doc(menubar=FINDER_BAR))
    events = framed(body)
    # Somebody else's chunk, mid-transfer. Folding it in would corrupt the
    # document in a way that then fails to parse and reads as a broken guest.
    events.insert(2, ("bulk", (11, b"XXXXXXXX", False)))
    r = drive(events)
    check("foreign/counted", r.envelope()["foreignBulk"], 1)
    try:
        check("foreign/body", r.result()["seq"], 7)
    except scenemod.SceneUnavailable as exc:
        # Folding the stranger's bytes in makes the document 8 bytes too long
        # and the length check catches it — but as a REFUSAL, which reads like
        # a broken producer. Named here so the mutation's red says what it is.
        FAILURES.append(f"foreign/body: the scene was refused ({exc.message})")


def a_scene_for_another_request_id_is_ignored():
    r = scenemod.SceneReader(3)
    r.on_control({"type": "scene.begin", "id": 4, "transfer": 9, "bytes": 2,
                  "irVersion": 1})
    check("otherid/begin", r.begin, None)


def a_short_document_is_refused():
    body = body_of(doc(menubar=FINDER_BAR))
    r = drive(framed(body, bytes_=len(body) + 40))
    check_raises("short/refused", scenemod.SceneUnavailable, r.result)


def a_cut_stream_is_refused():
    body = body_of(doc())
    events = [e for e in framed(body)]
    # Drop the END flag from the last bulk frame: the transfer was cut.
    for i, (kind, payload) in enumerate(events):
        if kind == "bulk" and payload[2]:
            events[i] = ("bulk", (payload[0], payload[1], False))
    r = drive(events)
    check_raises("cut/refused", scenemod.SceneUnavailable, r.result)


def an_unparseable_document_is_refused():
    r = drive(framed(b"{not json"))
    check_raises("parse/refused", scenemod.SceneUnavailable, r.result)


# --- the IR gate -------------------------------------------------------------

def an_unknown_ir_major_is_refused_before_the_body_is_read():
    # The body here is deliberately UNPARSEABLE. If the refusal happens after
    # the decode, the exception's text is a parse error and the gate has moved
    # behind the parse it exists to guard.
    r = drive(framed(b"\xff\xfe not a document", ir=2))
    try:
        r.result()
        FAILURES.append("ir/unknown-major: did not raise")
    except scenemod.SceneUnavailable as exc:
        check("ir/unknown-major", "IR major" in exc.message, True)
        check("ir/unknown-major-not-parsed", "did not parse" in exc.message,
              False)
        check("ir/unknown-major-local", exc.refused_by_guest, False)


def the_two_places_that_carry_the_version_must_agree():
    r = drive(framed(body_of(doc(version=2))))
    check_raises("ir/two-places", scenemod.SceneUnavailable, r.result)


# --- absent is not empty -----------------------------------------------------

def an_absent_menu_bar_is_absent():
    d = doc()                     # no `menubar` key at all: the plane was
    check("absent/state", scenemod.menubar_state(d), scenemod.ABSENT)
    check("absent/app", scenemod.menubar_app(d), None)
    check_raises("absent/menus-raises", scenemod.PlaneAbsent,
                 lambda: scenemod.menus(d))


def a_present_bar_with_no_menus_is_empty():
    d = doc(menubar={"app": "SomeFacelessThing", "menus": []})
    check("empty/state", scenemod.menubar_state(d), scenemod.EMPTY)
    check("empty/menus", scenemod.menus(d), [])
    check("empty/app", scenemod.menubar_app(d), "SomeFacelessThing")


def a_populated_bar_is_populated():
    d = doc(menubar=FINDER_BAR)
    check("populated/state", scenemod.menubar_state(d), scenemod.POPULATED)


def a_menus_items_keep_the_same_split():
    d = doc(menubar=FINDER_BAR)
    file_menu = scenemod.menu_by_title(d, "File")
    edit = scenemod.menu_by_title(d, "Edit")
    apple = scenemod.menu_by_title(d, "\x14")
    check("items/populated", len(scenemod.menu_items(file_menu)), 1)
    check("items/empty", scenemod.menu_items(edit), [])
    # The Apple menu in the fixture has NO `items` key — its item walk did not
    # complete. That is not "the Apple menu is empty".
    check_raises("items/absent-raises", scenemod.PlaneAbsent,
                 lambda: scenemod.menu_items(apple))


def plane_state_is_one_implementation():
    check("plane/absent", scenemod.plane_state({}, "menus"), scenemod.ABSENT)
    check("plane/null", scenemod.plane_state({"menus": None}, "menus"),
          scenemod.ABSENT)
    check("plane/empty", scenemod.plane_state({"menus": []}, "menus"),
          scenemod.EMPTY)
    check("plane/populated", scenemod.plane_state({"menus": [1]}, "menus"),
          scenemod.POPULATED)


# --- addressing a menu -------------------------------------------------------

def the_menu_id_is_what_menuact_addresses():
    # `menuact` declares `menu` as an INTEGER — the menu's id, "as the scene
    # reports it" (contract/asyncapi.yaml). The scene reports it as a number,
    # so nothing has to be looked up or converted.
    d = doc(menubar=FINDER_BAR)
    m = scenemod.menu_by_title(d, "File")
    check("addr/id", m["id"], 129)
    check("addr/id-is-int", isinstance(m["id"], int), True)
    check("addr/left", m["left"], 38)
    check("addr/missing", scenemod.menu_by_title(d, "Nonesuch"), None)


def the_leftmost_menu_is_picked_by_geometry():
    d = doc(menubar=FINDER_BAR)
    apple = scenemod.leftmost_menu(d)
    # The fixture lists File first. Picking by list order would aim every
    # menu trial's press at the File menu's title and call it the Apple menu.
    check("leftmost/unsorted", apple["id"], 128)
    check("leftmost/corroborated", scenemod.looks_like_apple(apple), True)
    check("leftmost/not-file",
          scenemod.looks_like_apple(scenemod.menu_by_title(d, "File")), False)


def an_empty_bar_has_no_leftmost_menu():
    check("leftmost/empty",
          scenemod.leftmost_menu(doc(menubar={"app": "X", "menus": []})), None)


def the_producers_own_errors_are_readable():
    d = doc(meta={"errors": ["menubar omitted: the front process's menu list "
                            "did not parse"]})
    check("errors/one", len(scenemod.scene_errors(d)), 1)
    check("errors/none", scenemod.scene_errors(doc()), [])


# --- staleness ---------------------------------------------------------------

def an_empty_cache_is_stale():
    c = scenemod.SceneCache()
    check("stale/empty", c.stale_reason(now=100.0, front_app="Finder"),
          "no scene has been read yet")
    check("stale/age-none", c.age(100.0), None)


def a_fresh_cache_for_the_same_front_app_is_not_stale():
    c = scenemod.SceneCache(max_age_s=120.0)
    c.put(doc(menubar=FINDER_BAR), now=100.0)
    check("stale/fresh", c.stale_reason(now=101.5, front_app="Finder"), None)
    check("stale/age", c.age(101.5), 1.5)
    check("stale/fetches", c.fetches, 1)


def a_changed_front_process_makes_the_cached_bar_stale():
    # The one that matters: 20 trials aimed at a bar belonging to another
    # application is not a measurement of anything.
    c = scenemod.SceneCache()
    c.put(doc(menubar=FINDER_BAR), now=100.0)
    why = c.stale_reason(now=101.0, front_app="SimpleText")
    check("stale/front-changed", why is not None, True)
    check("stale/front-changed-reason",
          "Finder" in (why or "") and "SimpleText" in (why or ""), True)


def age_is_the_backstop():
    c = scenemod.SceneCache(max_age_s=60.0)
    c.put(doc(menubar=FINDER_BAR), now=100.0)
    check("stale/under", c.stale_reason(now=159.0, front_app="Finder"), None)
    check("stale/over",
          c.stale_reason(now=161.0, front_app="Finder") is not None, True)


def a_cached_scene_with_no_bar_is_not_reusable():
    # Absent again, one layer up: a cached scene that reports no menu bar
    # cannot serve a menu trial, and saying "fresh" about it would hand the
    # caller a bar-less scene to address menus in.
    c = scenemod.SceneCache()
    c.put(doc(), now=100.0)
    check("absent/cache-unusable",
          c.stale_reason(now=100.5, front_app="Finder") is not None, True)


def an_unknown_front_app_does_not_invalidate_by_itself():
    # `ps` can fail to name a front process. That is not evidence the bar
    # changed, so it is not a reason on its own — age still applies.
    c = scenemod.SceneCache(max_age_s=60.0)
    c.put(doc(menubar=FINDER_BAR), now=100.0)
    check("stale/unknown-front", c.stale_reason(now=101.0, front_app=None),
          None)


TESTS = [v for k, v in sorted(globals().items())
         if callable(v) and not k.startswith("_")
         and k not in ("check", "check_raises", "doc", "framed", "drive",
                       "body_of")
         and getattr(v, "__module__", "") == "__main__"]


def main() -> int:
    for fn in TESTS:
        fn()
    if FAILURES:
        for f in FAILURES:
            print("FAIL " + f)
        print(f"\n{len(FAILURES)} failed of {len(TESTS)} checks")
        return 1
    print(f"scene: {len(TESTS)} checks ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
