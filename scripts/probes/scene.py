"""Reading one scene, as a probe harness has to read it.

This is the machineless half of the scene read: reassembly, the IR gate, the
plane accessors, and the staleness arithmetic that decides when a cached scene
stops describing the machine. It holds no socket and no clock of its own, so
`tests/scene_test.py` can drive all of it, and `nowwire.GuestLink.scene()` is
the thin part that feeds it bytes.

## Why a harness reads a scene at all

Four probe cases — `nohijack-probe.py`'s `menu`, `stale` and `window`, and
`g1-probe.py`'s `menus` — need the front application's menu bar: a menu's
**id** (what `menuact` addresses) and a menu title's **left** (the x the act's
identity check is stated in, and the point the real stimulus is aimed at).

`observe` does not report a menu bar and deliberately will not. The bar is
walked already, by `now_scene_walk_menubar` over `scene.request`, because
docs/streaming-a-scene.md ruled that a tree whose parts mean something only
reassembled is a TRANSFER rather than a bounded control reply. So the harness
needed a scene read; the guest did not need a second walk. The contract says
the same thing from the other end — `menuact.menu` is documented as "The
menu's id, **as the scene reports it**".

## A scene is not a cheap question, and that changes the harness

  * It is a **transfer on the one-wide bulk lane**: `scene.begin`, bulk
    frames, `scene.end`. The guest refuses one outright while any other
    transfer or stream owns the lane, and the host models the same fact
    (`GuestListener.transferLaneHolder`).
  * It is **big**: the producer measured 9,214 bytes for 24 processes and 32
    windows *before* menus existed, ~21,541 with them, against a 4,096-byte
    control cap.
  * It costs **guest time inside the cooperative event loop** — the walk and
    the encode both run there, and `scene.begin` reports `walkMs` precisely
    because that time is worth watching.

Upstream's probes could ask for the menu bar cheaply: Mirror's `observe`
returned it in a bounded reply, so a trial re-read it whenever it liked. This
port cannot, and pretending otherwise inside a tight trial loop would put a
20-KB transfer and an unbounded guest-side walk *in the middle of a
measurement whose whole subject is what happens during a ~5 s armed window*.

### Where the fetch therefore sits: once per case, cached, re-read on a stated staleness rule

Not once per trial, and not once per run. The rule is in `SceneCache`:

  * **once per case**, in the case's setup, while the wire is free and
    nothing is armed — the same place the hop and drag calibration already
    happens, for the same reason;
  * **re-read before a trial arms** when, and only when, `stale_reason()`
    says the cached bar no longer describes this machine: the front process
    changed out from under it, its own `menubar.app` disagrees with the front
    process, or it has aged past `max_age_s`;
  * **never inside the armed window.** A re-read happens before the request
    is sent, or not in that trial at all.

What that choice means for the number, said plainly because it is the part
that could be got wrong invisibly: the cached bar is a claim about *layout*
(which menus exist, where their titles sit), and layout is exactly the fact
that does not change between trials of one case unless the front process
changes — which the trial already checks, every trial, on a `ps` round trip it
was making anyway. Caching a fact that cannot have changed is not an
approximation; re-reading it 20 times would be a different experiment, one
where a 20-KB transfer runs a second before every arm.

**No trial is scored or dropped on account of the scene.** `tally.py` is
untouched by any of this: the fetch happens outside the armed window and
outside the stimulus, so the denominator is still trials-minus-dropped with
the same drop reasons upstream had. A staleness re-read costs a trial time and
changes nothing it records except the bookkeeping fields (`sceneSeq`,
`sceneRefetched`) that exist so a reader can see when it happened.

## Absent is not empty

The three plane states are distinct and this module refuses to collapse them:

    absent      this producer does not report this plane. NOBODY LOOKED.
    empty       it looked and there are none.
    populated   it looked and here they are.

`menubar` absent means the scene reports no menu bar — a front process whose
menu list did not parse (the producer retracts the whole plane rather than
ship a short one, and says so in `meta.errors`). `menubar` present with an
empty `menus` means the front process genuinely has none, which a faceless
background application does. A harness that read the first as the second would
report a machine as having no menus when nothing had looked, and would then
score trials against it.

So `menus()` RAISES on absent and returns `[]` on empty; the same split holds
for a menu's `items`.
"""

from __future__ import annotations

import json

# now-guest-ppc/src/scene/scene.h :: NOW_SCENE_IR_VERSION. Restated here for
# the same reason nowwire.py restates the frame constants: a probe is not part
# of the build, and one that silently followed a changed constant would report
# numbers from an IR it did not describe.
SUPPORTED_IR_MAJOR = 1

# Plane states. Strings rather than an enum so they land in a run's JSON as
# themselves.
ABSENT = "absent"
EMPTY = "empty"
POPULATED = "populated"

# How old a cached scene may be before it is re-read even though nothing
# observable changed. Not a correctness bound — a backstop, for the case this
# harness cannot see: an application that rebuilt its own menu bar without the
# front process changing. Two minutes is far longer than a trial and far
# shorter than a 20-trial case.
DEFAULT_MAX_AGE_S = 120.0


class SceneUnavailable(Exception):
    """No scene could be had, and this says which side decided that.

    `refused_by_guest` is the same distinction the host draws
    (`GuestListener.SceneFailure`): the guest was asked, it answered, and the
    answer was no — which is itself evidence that the scene plane is there and
    talking. Everything else (silence, a short transfer, an IR major this
    harness does not read) is this side's decision and says nothing about the
    other machine.
    """

    def __init__(self, message: str, *, refused_by_guest: bool = False):
        super().__init__(message)
        self.message = message
        self.refused_by_guest = refused_by_guest


class PlaneAbsent(Exception):
    """A plane this scene does not report. NOT "there are none of these".

    Raised rather than returning `[]` on purpose; see the module docstring.
    The caller's precondition then fails with a reason a person can act on,
    instead of the case measuring a machine it never looked at.
    """

    def __init__(self, plane: str, detail: str = ""):
        self.plane = plane
        msg = (f"this scene does not report {plane} — the key is ABSENT, "
               f"which means nothing walked it, not that there are none")
        if detail:
            msg += f". {detail}"
        super().__init__(msg)


# --- reassembly ---------------------------------------------------------------

class SceneReader:
    """The `scene.begin` → bulk → `scene.end` state machine, without a socket.

    Fed by `nowwire.GuestLink.scene()`, which does nothing but read frames and
    hand them here. Everything that could be got wrong about a transfer —
    correlating the id, correlating the transfer, refusing a short document,
    the IR gate's ORDER — is here, where a test can drive it.
    """

    def __init__(self, request_id: int):
        self.request_id = request_id
        self.begin: dict | None = None
        self.end: dict | None = None
        self.transfer: int | None = None
        self.body = bytearray()
        self.saw_end_flag = False
        # Bulk that arrived while this reader was live but belonged to another
        # transfer, or to none yet. Counted rather than silently dropped: a
        # scene assembled while somebody else's bytes were interleaved is a
        # fact about the run worth carrying into the record.
        self.foreign_bulk = 0

    # -- feeding --------------------------------------------------------

    def on_control(self, msg: dict) -> None:
        """One control message. Anything not this scene's is ignored."""
        kind = msg.get("type")
        if kind not in ("scene.begin", "scene.end"):
            return
        if msg.get("id") != self.request_id:
            return
        if kind == "scene.begin":
            if self.begin is not None:
                raise SceneUnavailable(
                    "two scene.begin messages for one request id")
            self.begin = msg
            self.transfer = msg.get("transfer")
            return
        self.end = msg

    def on_bulk(self, transfer: int, payload: bytes, end_flag: bool) -> None:
        if self.transfer is None or transfer != self.transfer:
            self.foreign_bulk += 1
            return
        self.body.extend(payload)
        if end_flag:
            self.saw_end_flag = True

    @property
    def done(self) -> bool:
        """`scene.end` is the terminator, and it is the ONLY terminator.

        Not the END flag on the last bulk frame: a failed scene is
        `scene.end ok:false` with NO bulk at all, so a reader that waited for
        the flag would wait forever on exactly the answer it most needs to
        report.
        """
        return self.end is not None

    # -- the answer -----------------------------------------------------

    def result(self) -> dict:
        """The decoded IR document, or an exception saying why there is none.

        The order here is the consumer duty IR-V1.md states and the contract
        repeats: **read the version, refuse an unknown major, THEN decode.**
        It is written out step by step rather than tidied, because tidying it
        is precisely how a gate ends up behind the parse it was meant to
        guard.
        """
        if self.end is None:
            raise SceneUnavailable("no scene.end arrived")
        if not self.end.get("ok"):
            raise SceneUnavailable(
                self.end.get("reason") or "the guest refused the scene",
                refused_by_guest=True)
        if self.begin is None:
            raise SceneUnavailable(
                "scene.end ok:true with no scene.begin — nothing announced "
                "the transfer this document was supposed to arrive on")

        # 1. the version, from the ENVELOPE.
        major = self.begin.get("irVersion")
        if major != SUPPORTED_IR_MAJOR:
            # 2. refuse an unknown major, WITHOUT decoding the body. The whole
            # reason irVersion rides in scene.begin is so this decision can be
            # made before a transfer's bytes are interpreted.
            raise SceneUnavailable(
                f"scene IR major {major!r}, this harness reads "
                f"{SUPPORTED_IR_MAJOR}. Refusing before decoding: a document "
                "from an IR this probe does not describe would produce "
                "numbers attributed to a shape nobody checked")

        announced = self.begin.get("bytes")
        if isinstance(announced, int) and len(self.body) != announced:
            # A short document is the failure a scene exists to make
            # impossible in the other direction ("a partial walk must never
            # arrive as a complete scene"). The reading side owes the same
            # refusal, and half a JSON document does not even parse — which
            # would surface as a parse error and read as a broken producer.
            raise SceneUnavailable(
                f"scene.begin announced {announced} bytes and "
                f"{len(self.body)} arrived; refusing a partial document")
        if not self.saw_end_flag and announced:
            raise SceneUnavailable(
                "the bulk stream never carried its END flag; the transfer was "
                "cut rather than finished")

        # 3. now decode.
        try:
            doc = json.loads(self.body.decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as exc:
            raise SceneUnavailable(f"the scene document did not parse: {exc}")
        if not isinstance(doc, dict):
            raise SceneUnavailable("the scene document is not an object")

        # "One number, two places" (IR-V1.md): the body carries the same major
        # the envelope announced, and the guest copies both from one constant.
        # A disagreement is not a thing to pick a winner in.
        body_version = doc.get("version")
        if body_version != major:
            raise SceneUnavailable(
                f"the envelope says IR {major} and the document says "
                f"{body_version!r}; one number is carried in two places and "
                "they disagree")
        return doc

    def envelope(self) -> dict:
        """What `scene.begin` said about the walk, for a run's record."""
        b = self.begin or {}
        return {"seq": b.get("seq"), "capturedAt": b.get("capturedAt"),
                "source": b.get("source"), "walkMs": b.get("walkMs"),
                "bytes": b.get("bytes"), "irVersion": b.get("irVersion"),
                "foreignBulk": self.foreign_bulk}


# --- the planes ---------------------------------------------------------------

def plane_state(container, key: str) -> str:
    """ABSENT / EMPTY / POPULATED for one list-valued key.

    The one place the three-state rule is implemented, so every caller gets
    the same answer and a reader has one function to check.
    """
    if not isinstance(container, dict) or key not in container:
        return ABSENT
    value = container[key]
    if value is None:
        return ABSENT
    return POPULATED if len(value) else EMPTY


def menubar_state(scene: dict) -> str:
    """The menu-bar plane's state, in the words the producer means.

    `menubar` absent -> ABSENT: no menu bar is reported. `menubar` present
    with an empty `menus` -> EMPTY: the front process genuinely has none.
    """
    if not isinstance(scene, dict) or scene.get("menubar") is None:
        return ABSENT
    return plane_state(scene["menubar"], "menus")


def menubar_app(scene: dict):
    """Whose bar this is, or None when no bar is reported.

    The scene walks the FRONT process's menu bar and names it. That name is
    what makes a cached bar checkable against a later `ps`.
    """
    bar = (scene or {}).get("menubar")
    if not isinstance(bar, dict):
        return None
    return bar.get("app")


def menus(scene: dict) -> list:
    """The bar's menus. RAISES when the plane is absent; `[]` when empty."""
    if menubar_state(scene) == ABSENT:
        raise PlaneAbsent(
            "a menu bar",
            "The producer retracts the whole plane rather than ship a short "
            "one; meta.errors says why. Look there before concluding this "
            "machine has no menus")
    return list(scene["menubar"].get("menus") or [])


def menu_items(menu: dict) -> list:
    """One menu's items. Same split: absent raises, empty is `[]`.

    A menu's `items` is absent when its item walk did not complete — the
    producer's per-owner retraction. Reading that as "this menu is empty" is
    how a harness reports a Finder with a File menu that has nothing in it.
    """
    if plane_state(menu, "items") == ABSENT:
        raise PlaneAbsent(f"the items of menu {(menu or {}).get('title')!r}",
                          "its item walk did not complete")
    return list(menu.get("items") or [])


def menu_by_title(scene: dict, title: str):
    """The menu with this exact title, or None. Raises if there is no bar."""
    for m in menus(scene):
        if m.get("title") == title:
            return m
    return None


def leftmost_menu(scene: dict):
    """The menu whose title sits furthest left — on this OS, the Apple menu.

    Stated as the inference it is. IR v1 has a `menus[].apple` field and this
    producer DELIBERATELY DOES NOT EMIT IT: nothing the walk reads says which
    menu is the Apple menu, and a title byte or a menu id could be made to
    look like evidence. So the harness picks by geometry — the leftmost title
    in the bar is the Apple menu on every Mac OS this project targets — and
    `looks_like_apple` records the corroboration separately rather than
    letting it masquerade as the test.
    """
    bar = menus(scene)
    if not bar:
        return None
    return min(bar, key=lambda m: (int(m.get("left", 0)), m.get("title") or ""))


def looks_like_apple(menu: dict) -> bool:
    """Corroboration only, never a gate.

    The Apple menu's title is the single MacRoman character 0x14, which the
    guest's escaper emits as `\\u0014`. A bar whose leftmost menu carries it
    agrees with the geometric pick; one that does not is worth recording and
    is not by itself evidence the pick was wrong (a machine with a menu-bar
    extension, or a non-US system, can differ).
    """
    return (menu or {}).get("title") == "\x14"


def scene_errors(scene: dict) -> list:
    """`meta.errors` — what the walk could not do, in the producer's words."""
    meta = (scene or {}).get("meta")
    if not isinstance(meta, dict):
        return []
    return list(meta.get("errors") or [])


# --- staleness ----------------------------------------------------------------

class SceneCache:
    """One case's scene, and the rule for when it stops describing the machine.

    Pure: it is TOLD the time and the front process rather than reading
    either, so the rule can be driven from a test. `nohijack-probe.py` passes
    `time.time()` and the `ps` read it was already making.
    """

    def __init__(self, max_age_s: float = DEFAULT_MAX_AGE_S):
        self.max_age_s = max_age_s
        self.scene: dict | None = None
        self.envelope: dict = {}
        self.fetched_at: float | None = None
        self.fetches = 0
        self.forced: str | None = None

    def put(self, scene: dict, *, now: float, envelope: dict | None = None):
        self.scene = scene
        self.envelope = envelope or {}
        self.fetched_at = now
        self.fetches += 1
        self.forced = None
        return scene

    def invalidate(self, reason: str) -> None:
        """The caller saw something this cache cannot see.

        There is one such thing and it is not hypothetical. A trial brings the
        Finder to the front before it does anything; by the time the front
        process is read it is "Finder" again, so comparing names can never
        reveal that something ELSE owned the menu bar in between — and coming
        back to the front is exactly when an application rebuilds its bar. The
        caller knows it had to switch; this is how it says so.
        """
        self.forced = reason

    def stale_reason(self, *, now: float, front_app):
        """None when the cached scene still describes this machine.

        Otherwise a sentence saying what changed, which the caller records on
        the trial and prints. Four reasons, in the order they are worth
        knowing:

          1. nothing cached yet;
          2. the caller invalidated it — see `invalidate`;
          3. the bar belongs to another application than the one that is
             frontmost now, which the scene and `ps` can be compared on;
          4. age, the backstop for a change none of those can see.
        """
        if self.scene is None or self.fetched_at is None:
            return "no scene has been read yet"
        if self.forced:
            return self.forced
        owner = menubar_app(self.scene)
        if owner is None:
            return ("the cached scene reports no menu bar at all, so there is "
                    "nothing in it to reuse")
        if front_app is not None and owner != front_app:
            return (f"the cached menu bar is {owner!r} and the front process "
                    f"is {front_app!r}")
        age = now - self.fetched_at
        if age >= self.max_age_s:
            return (f"the cached scene is {age:.0f}s old "
                    f"(bound {self.max_age_s:.0f}s)")
        return None

    def age(self, now: float):
        if self.fetched_at is None:
            return None
        return now - self.fetched_at
