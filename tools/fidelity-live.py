#!/usr/bin/env python3
"""Watch CONSECUTIVE frames of the host render across a redraw, and put a
number on the flicker.

WHY THIS EXISTS.

Sweep A (2026-08-07) scored STABILITY 3 — zero differing pixels — on
eight panels, and said in its own method section why that score is
nearly empty:

    this instrument renders a *settled capture*, twice. It never draws
    two consecutive live frames, so it cannot see the flicker Michelle
    saw.

Michelle's first complaint was flicker: hatching appearing and
disappearing, Finder content drawing over, under, or absent across
redraws. A sweep that only ever looks at settled state will report
"stable" whether or not the fix worked, which hollows out the A/B the
whole of plan 018 is bracketed by. This is the instrument that closes
that, and it is deliberately built so it can run against the tree BEFORE
the fix as well as after — a measurement that only exists on the B side
proves nothing.

WHAT IT ACTUALLY OBSERVES, and why that is the right thing.

It does not photograph the window. It follows the **scene documents** the
renderer draws from, one by one, over the host's agent socket.

That is not a compromise, it is the sharper measurement, and the reason
is a property of the renderer: `SceneRenderer.draw(in:size:)`
(now-host/Packages/MirrorKit/Sources/MirrorKitUI/SceneRenderer.swift:63) is a
pure function of one immutable `Scene` plus four bits of mirror-local UI
state, and the live view and `RenderShot` share it — one draw path, one
set of pixels. So the sequence of scene documents FULLY DETERMINES the
sequence of frames. A window whose content vanishes and returns in this
trace is a window that hatched and un-hatched on screen.

It also means the flicker can be attributed rather than merely seen: the
trace says WHICH window, WHICH rectangle, and which owner it flipped
between — which is what a fix has to be aimed at.

The honest limits are stated in LIMITS (below), written into every
artifact, and repeated in the tool's own stdout. Read them before
quoting a number from here.

USAGE

    # provoke a redraw through the product's own path and measure it
    tools/fidelity-live.py --outdir /private/tmp/live --label finder-open \\
        --gesture finderOpen --name "Macintosh HD" --in desktop

    # measure a redraw somebody else provokes (a human at the VM, or the
    # sweep's own driver): arm, then act, then it settles and reports
    tools/fidelity-live.py --outdir /private/tmp/live --label manual \\
        --manual --duration 60

    # no provocation at all: does the render sit still when nothing
    # happens? A non-zero flicker number here is the purest form of the
    # defect, because nothing asked for a redraw.
    tools/fidelity-live.py --outdir /private/tmp/live --label idle \\
        --idle --duration 60

The host app must be running with its Mirror open; this tool speaks only
to the agent socket and never binds the wire, so it can run while the
host holds the guest.
"""

import argparse
import hashlib
import json
import os
import sys
import time
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sweeplimits import write_limits                        # noqa: E402

_HERE = os.path.dirname(os.path.abspath(__file__))


def _load_now_agent():
    """`now-agent` has a hyphen and no .py, so it cannot be imported by
    name. Load it rather than copy its socket code: the endpoint is
    DERIVED from TMPDIR and euid, and a second copy of that derivation is
    a second place to be wrong about which host is under test."""
    import importlib.machinery
    import importlib.util
    spec = importlib.util.spec_from_loader(
        "now_agent",
        importlib.machinery.SourceFileLoader("now_agent",
                                             os.path.join(_HERE, "now-agent")))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


now_agent = _load_now_agent()


LIMITS = {
    "documents-not-pixels": (
        "This traces the SCENE DOCUMENTS the renderer draws from, not "
        "photographs of the window. SceneRenderer.draw is a pure "
        "function of one Scene, and the live view and RenderShot share "
        "it, so a document change IS a frame change. The converse "
        "inference — that every document change was VISIBLE — is not "
        "made here: a flip in a one-pixel rect counts the same as a "
        "flip in a whole window interior, and the report lists rects so "
        "a reader can judge."),
    "sampled-not-streamed": (
        "The agent socket answers one request per connection, so frames "
        "are read by following metadata.snapshotID. Every run reports "
        "`snapshotsMissed`: the count of snapshot IDs that existed and "
        "were never read. A flicker number is a FLOOR when that is "
        "non-zero — states between two reads are invisible to it — and "
        "the report says so per run rather than leaving it to be "
        "assumed."),
    "owner-classes-are-a-proxy": (
        "`owner` here is derived from the projection's own fields "
        "(does a display op ink this rect; does the item carry semantic "
        "kind plus a title or value; neither). The renderer's real "
        "arbitration is SceneRenderer.semanticOwnsDisplay and "
        "friends, which this does not reimplement — deliberately, "
        "because a second copy of that policy would drift. The metric "
        "that matters is CHANGE OVER TIME, and any classifier applied "
        "identically to every frame detects the flip."),
    "projection-is-capped": (
        "The agent protocol caps one message at 64 KB, so a window's "
        "display ops and items are truncated; `itemTotal` and "
        "`displayTotal` are the untruncated counts and this tool uses "
        "THOSE for presence/absence. A rect-level owner map is only as "
        "complete as the items that fit."),
    "three-views-CAN-be-one-instant-here": (
        "Sweep A's three views were three PHASES on one boot, because "
        "the sweep tool and the host app both bind the wire port the "
        "guest dials. This tool binds nothing: it reads the agent "
        "socket while the host holds the wire, and QMP is a third, "
        "independent channel. So the agent surface, the host render and "
        "the guest's own pixels ARE simultaneous in a --qmp run, and "
        "the frame index of each screendump is recorded. What still "
        "cannot join is fidelity-sweep.py's qdtrace capture, which "
        "needs the wire the host is holding."),
    "the-plane-must-have-armed": (
        "This reads the LIVE host, and the live host arms the content "
        "plane itself — so a run against a host that never armed would "
        "report every window stably empty and READ AS A STABILITY "
        "RESULT. Every run therefore states `planeEvidence`, derived "
        "from the artifact rather than from intent: `displayTotal` is "
        "null where the plane never traced a window, 0 where it traced "
        "and the window drew nothing, and above 0 where a drain reached "
        "this trace. Without a drain the run REFUSES unless "
        "--allow-no-drain was given, and that decision is recorded "
        "beside the number."),
    "which-guest-answered": (
        "There is one agent socket per user and this tool binds "
        "nothing, so it reads whichever host owns that socket — "
        "possibly another lane's, holding another lane's VM. Every run "
        "checks the guest build in the host's `session_health` against "
        "this checkout's own products (`--expect-build`, `auto` by "
        "default) before its first frame, and records what it saw in "
        "`rig`."),
    "one-host-one-run": (
        "There is one agent socket per user. If two host copies are "
        "running, this reaches whichever owns the socket. The run "
        "records the guest and session ids it saw; a run whose guest id "
        "changes mid-trace is void, and the tool says so."),
}


# --------------------------------------------------------------------------
# reading frames


class Live:
    def __init__(self, timeout):
        self.timeout = timeout

    def call(self, request):
        request = dict(request)
        request.setdefault("version", now_agent.PROTOCOL_VERSION)
        request.setdefault("requestID", str(uuid.uuid4()).upper())
        return now_agent.call(request, timeout=self.timeout)

    def read(self, intention, **extra):
        mirror = {"intention": intention}
        mirror.update(extra)
        return self.call({"operation": "mirror_read",
                          "mirrorReadRequest": mirror})

    def drive(self, gesture, **extra):
        drive = {"gesture": gesture}
        drive.update({k: v for k, v in extra.items() if v is not None})
        return self.call({"operation": "mirror_drive",
                          "mirrorDriveRequest": drive})

    def snapshot(self):
        reply = self.read("snapshot")
        # A TRANSPORT refusal, which is not an unavailable reading and does
        # not live under `mirrorReadResult`. Surfaced with its own code
        # rather than collapsed into the empty-result path below: without
        # this, `response-too-large` decoded as a result that simply was
        # not there, and every frame would record a bare "unavailable" —
        # a run that swallowed the one thing it needed to report. The
        # closed socket this replaces (sweep C, 2026-08-07) at least
        # crashed the tool honestly.
        if reply.get("error"):
            raise Unavailable(reply["error"].get("code") or "error",
                              reply["error"].get("message") or "")
        result = reply.get("mirrorReadResult") or {}
        if not result.get("available", False):
            bad = result.get("unavailable") or {}
            raise Unavailable(bad.get("code") or "unavailable",
                              bad.get("message") or "")
        return (result.get("value") or {})


def read_expected_build(repo):
    """The build hash READ from this checkout's products rather than
    typed. Deliberately the same derivation `fidelity-sweep.py` uses —
    not a second one, because two spellings of "which build is mine" is
    two places to be wrong about the answer this exists to give."""
    out = os.path.join(os.environ.get("TMPDIR", "/tmp"), "now-guest-builds",
                       hashlib.sha1(repo.encode()).hexdigest()[:12])
    gen = os.path.join(out, "ppc", "build_stamp_gen.h")
    with open(gen) as handle:
        for line in handle:
            if "NOW_SRC_HASH" in line:
                return line.split('"')[1]
    raise SystemExit("no NOW_SRC_HASH in %s — run scripts/build-guests" % gen)


def assert_build(live, expect):
    """WHICH GUEST ANSWERED. The same rule the metal gates carry, arriving
    over the agent socket instead of the wire — and it binds harder here,
    because this tool deliberately binds nothing: it reads whichever host
    owns the one per-user agent socket, and that host may be holding
    another lane's VM. A flicker count taken off a neighbour's build is
    not a weaker measurement, it is a measurement of something else."""
    reply = live.call({"operation": "session_health"})
    health = (reply.get("result") or {}).get("health") or {}
    guest = health.get("guest") or {}
    seen = {"state": health.get("state"), "guest": guest.get("name"),
            "build": guest.get("build"), "version": guest.get("version"),
            "session": (guest.get("reference") or {}).get("sessionID"),
            "listeningPort": health.get("listeningPort")}
    if expect in (None, "-"):
        seen["buildCheck"] = "skipped"
        return seen
    if not guest.get("build"):
        raise SystemExit(
            "the host's session_health reports NO guest build "
            "(state %r). Nothing can be attributed to a build that was "
            "never named; give --expect-build - to proceed anyway and "
            "say so in the report." % health.get("state"))
    if not guest["build"].startswith(expect):
        raise SystemExit(
            "WRONG GUEST. session_health says build %s; this checkout "
            "built %s. The agent socket is one per user, so this is the "
            "host that owns it — probably another lane's. Refusing "
            "rather than measuring somebody else's render."
            % (guest["build"], expect))
    seen["buildCheck"] = "matched %s" % expect
    return seen


def screendump(qmp_path, out_path):
    """The guest's own pixels, on a channel that is neither the wire nor
    the agent socket — which is why a --qmp run can hold all three views
    at one instant where sweep A could only hold two."""
    import socket
    try:
        sock = socket.socket(socket.AF_UNIX)
        sock.settimeout(20)
        sock.connect(qmp_path)
        sock.recv(65536)
        sock.sendall(b'{"execute":"qmp_capabilities"}\n')
        time.sleep(0.3)
        sock.recv(65536)
        sock.sendall((json.dumps({"execute": "screendump",
                                  "arguments": {"filename": out_path}})
                      + "\n").encode())
        time.sleep(1.5)
        sock.recv(65536)
        sock.close()
        return os.path.exists(out_path)
    except Exception as exc:                                # noqa: BLE001
        print("  screendump failed: %s" % exc, flush=True)
        return False


class Unavailable(Exception):
    def __init__(self, code, message):
        super().__init__("%s: %s" % (code, message))
        self.code = code
        self.message = message


# --------------------------------------------------------------------------
# one frame, reduced to the things that can flicker


def rect_key(rect):
    if not rect:
        return None
    if isinstance(rect, dict):
        return "%d,%d,%d,%d" % (rect.get("l", 0), rect.get("t", 0),
                                rect.get("r", 0), rect.get("b", 0))
    return ",".join(str(int(v)) for v in rect)


def _inked(rect, ops):
    """Did any display op put ink in this rect? Geometry only, and
    intersection rather than containment, because the flicker being
    hunted is a rect losing its content entirely."""
    if not rect or not ops:
        return False
    left, top = rect.get("l", 0), rect.get("t", 0)
    right, bottom = rect.get("r", 0), rect.get("b", 0)
    for op in ops:
        box = op.get("rect") or op.get("dst")
        if not box or len(box) < 4:
            continue
        if box[0] < right and box[2] > left and box[1] < bottom and box[3] > top:
            return True
    return False


def owner_of(item, ops):
    """The proxy described in LIMITS. Three classes, and the ORDER is the
    renderer's: a typed control with something to say silences the
    drawing stream under it, ink beats nothing, and nothing is a hatch."""
    kind = item.get("kind")
    semantic = item.get("semantic") or {}
    if not kind and isinstance(semantic, dict):
        kind = semantic.get("kind")
    title = item.get("title") or semantic.get("title")
    value = item.get("value") or semantic.get("value")
    if kind and (title or value):
        return "semantic"
    if _inked(item.get("rect"), ops):
        return "ink"
    return "unknown"


def reduce_frame(value, seen_at):
    """Everything about this instant that could differ from the next.

    Presence/absence uses the UNtruncated totals (`displayTotal`,
    `itemTotal`), because the capped list is a property of the message
    and not of the machine."""
    snap = value.get("snapshot") or {}
    meta = snap.get("metadata") or value.get("current") or {}
    frame = {
        "at": seen_at,
        "snapshotID": meta.get("snapshotID"),
        "sequence": meta.get("sequence"),
        "digest": meta.get("digest"),
        "baseComplete": meta.get("baseComplete"),
        "sceneGeneration": meta.get("sceneGeneration"),
        "contentGeneration": meta.get("contentGeneration"),
        "guest": meta.get("guest"),
        "session": meta.get("session"),
        "coverage": {},
        "windows": {},
    }
    for claim in snap.get("coverage") or []:
        key = "%s/%s" % (claim.get("scope"), claim.get("owner") or "-")
        frame["coverage"][key] = claim.get("status")
    for surface in snap.get("surfaces") or []:
        ops = surface.get("display") or []
        display_total = surface.get("displayTotal")
        item_total = surface.get("itemTotal")
        owners = {}
        for item in surface.get("items") or []:
            key = rect_key(item.get("rect"))
            if key:
                owners[key] = owner_of(item, ops)
        frame["windows"][surface.get("entityID")] = {
            "title": surface.get("title"),
            "rect": rect_key(surface.get("rect")),
            "visible": surface.get("visible"),
            "front": surface.get("front"),
            "z": surface.get("z"),
            "displayTotal": display_total,
            "itemTotal": item_total,
            # The whole-window hatch: SceneRenderer.drawWindow paints
            # "Guest content not reported" when a window reports no
            # display, no text, no dialog items and no items at all.
            "wouldHatch": not (display_total or item_total
                               or surface.get("text")),
            "owners": owners,
        }
    return frame


def state_vector(frame):
    """What must be equal for two frames to draw the same. Deliberately
    NOT the digest: the digest covers the whole projection including
    fields that cannot reach a pixel, so it over-reports change. Both
    are recorded; this one is what settle is measured against."""
    return json.dumps({
        "coverage": frame["coverage"],
        "windows": {k: {kk: vv for kk, vv in v.items() if kk != "title"}
                    for k, v in frame["windows"].items()},
    }, sort_keys=True)


# --------------------------------------------------------------------------
# the analysis: what a flicker IS


def transitions(seq):
    """Collapse a per-frame value series into its changes."""
    out = []
    last = object()
    for index, (at, value) in enumerate(seq):
        if value != last:
            out.append({"i": index, "at": at, "value": value})
            last = value
    return out


def _returns(changes):
    """A → B → A. The signature of a flicker, as opposed to a change:
    something was one way, became another, and came back. A one-way
    change is the machine doing what it was asked."""
    events = []
    for i in range(2, len(changes)):
        if changes[i]["value"] == changes[i - 2]["value"]:
            events.append({
                "from": changes[i - 2]["value"],
                "via": changes[i - 1]["value"],
                "back": changes[i]["value"],
                "atVia": changes[i - 1]["at"],
                "atBack": changes[i]["at"],
                "ms": int((changes[i]["at"] - changes[i - 2]["at"]) * 1000),
            })
    return events


def plane_evidence(frames):
    """**Did the content plane write a drain into THIS trace?**

    AGENTS.md: an instrument that reads a live machine must assert that
    the plane armed, and the assertion is about the ARTIFACT, not the
    intent — "I armed it" is not the assertion; "the artifact carries
    it" is. `fidelity-live.py` did not implement it, and the failure it
    is missing is specific and it has happened: this tool reads the live
    host, which arms P3 itself, so a run against a host that never armed
    reports every window stably empty and READS AS A STABILITY RESULT.
    Zero flicker and no content look identical from the number alone.

    The projection makes the distinction for us and it costs one field.
    `AgentIntegrationMirrorSurface.displayTotal` is:

        None  the plane was never traced for this window
        0     traced, and proven to have drawn nothing
        > 0   traced, and it carries ops — a DRAIN reached this artifact

    So `windowsWithOps` is the assertion. `windowsTraced` is kept beside
    it because the two failures are different repairs: nothing traced at
    all is a host that never armed, while traced-everywhere-and-empty is
    a guest that drew nothing (or a plane that armed and lost its
    records), and a run that collapsed them would send the reader to the
    wrong half of the system."""
    traced, with_ops, frames_with_ops = set(), set(), 0
    max_total = 0
    for frame in frames:
        any_here = False
        for wid, win in (frame.get("windows") or {}).items():
            total = win.get("displayTotal")
            if total is None:
                continue
            traced.add(wid)
            if total > 0:
                with_ops.add(wid)
                any_here = True
                max_total = max(max_total, total)
        if any_here:
            frames_with_ops += 1
    return {
        "windowsTraced": len(traced),
        "windowsWithOps": len(with_ops),
        "framesCarryingOps": frames_with_ops,
        "maxDisplayTotal": max_total,
        # The one boolean a reader is allowed to quote.
        "drainInArtifact": bool(with_ops),
    }


def analyse(frames, provoked_at, settle_quiet):
    if not frames:
        return {"error": "no frames read"}

    ids = [f["snapshotID"] for f in frames if f["snapshotID"] is not None]
    missed = 0
    if len(ids) >= 2:
        missed = max(0, (max(ids) - min(ids) + 1) - len(set(ids)))

    guests = sorted({f.get("guest") for f in frames if f.get("guest")})
    sessions = sorted({f.get("session") for f in frames if f.get("session")})

    vectors = [(f["at"], state_vector(f)) for f in frames]
    changes = transitions(vectors)

    # SETTLE. The first moment after the provocation from which the state
    # vector never changes again for `settle_quiet` seconds. Reported as
    # `null` — never as the run length — when it never happens, because
    # "settled at 45 s" and "never settled in 45 s" are opposite results
    # and this repository has already paid for a `-` that was written 0.
    last_change = changes[-1]["at"] if changes else frames[0]["at"]
    quiet_for = frames[-1]["at"] - last_change
    settled = quiet_for >= settle_quiet
    after = [c for c in changes if provoked_at is None or c["at"] >= provoked_at]

    # DISTINCT INTERMEDIATE STATES: the states between the provocation
    # and the settled one. If the render went straight from the old
    # picture to the new one, this is 0 and there was no flicker to see.
    tail_states = [c["value"] for c in after]
    intermediate = max(0, len(tail_states) - 1)
    distinct_states = len(set(tail_states))

    # THE FLICKER EVENTS, four families, each an A → B → A return.
    coverage_flips = []
    keys = set()
    for frame in frames:
        keys |= set(frame["coverage"])
    for key in sorted(keys):
        series = [(f["at"], f["coverage"].get(key)) for f in frames]
        for event in _returns(transitions(series)):
            coverage_flips.append(dict(event, scope=key))

    window_ids = set()
    for frame in frames:
        window_ids |= set(frame["windows"])

    hatch_flips, content_dropouts, owner_flips, presence_flips = [], [], [], []
    for wid in sorted(window_ids):
        title = None
        for frame in frames:
            if wid in frame["windows"]:
                title = frame["windows"][wid].get("title")
                break

        def series(field):
            return [(f["at"], (f["windows"].get(wid) or {}).get(field))
                    for f in frames]

        for event in _returns(transitions(series("wouldHatch"))):
            hatch_flips.append(dict(event, window=wid, title=title))
        # Content that was there, went, and came back — Michelle's
        # "content draws over, under, or absent across redraws", named
        # per window.
        present = [(at, bool(v)) for at, v in series("displayTotal")]
        for event in _returns(transitions(present)):
            content_dropouts.append(dict(event, window=wid, title=title,
                                         measure="displayTotal>0"))
        seen = [(at, wid in f["windows"]) for (at, _), f in zip(series("z"),
                                                               frames)]
        for event in _returns(transitions(seen)):
            presence_flips.append(dict(event, window=wid, title=title))

        rects = set()
        for frame in frames:
            rects |= set((frame["windows"].get(wid) or {}).get("owners") or {})
        for rect in sorted(rects):
            owner_series = [
                (f["at"],
                 ((f["windows"].get(wid) or {}).get("owners") or {}).get(rect))
                for f in frames]
            for event in _returns(transitions(owner_series)):
                owner_flips.append(dict(event, window=wid, title=title,
                                        rect=rect))

    total = (len(coverage_flips) + len(hatch_flips) + len(content_dropouts)
             + len(owner_flips) + len(presence_flips))

    gens = [(f["sceneGeneration"], f["contentGeneration"]) for f in frames]
    return {
        "framesRead": len(frames),
        "planeEvidence": plane_evidence(frames),
        "snapshotIDs": {"first": min(ids) if ids else None,
                        "last": max(ids) if ids else None,
                        "missed": missed},
        "guest": guests,
        "session": sessions,
        "voidReason": ("guest identity changed mid-trace"
                       if len(guests) > 1 else
                       ("session changed mid-trace"
                        if len(sessions) > 1 else None)),
        "settled": settled,
        "quietForSeconds": round(quiet_for, 2),
        "msToSettle": (int((last_change - provoked_at) * 1000)
                       if settled and provoked_at is not None else None),
        "framesToSettle": len(after) if settled else None,
        "distinctStatesAfterProvocation": distinct_states,
        "intermediateStates": intermediate,
        "stateChanges": len(changes),
        # THE FLICKER NUMBER.
        "flickerEvents": total,
        "flickerBreakdown": {
            "coverageStatusFlips": len(coverage_flips),
            "windowHatchFlips": len(hatch_flips),
            "windowContentDropouts": len(content_dropouts),
            "rectOwnerFlips": len(owner_flips),
            "windowPresenceFlips": len(presence_flips),
        },
        "flickerDetail": {
            "coverageStatusFlips": coverage_flips[:60],
            "windowHatchFlips": hatch_flips[:60],
            "windowContentDropouts": content_dropouts[:60],
            "rectOwnerFlips": owner_flips[:120],
            "windowPresenceFlips": presence_flips[:60],
        },
        "generations": {
            "sceneFirstLast": [gens[0][0], gens[-1][0]] if gens else None,
            "contentFirstLast": [gens[0][1], gens[-1][1]] if gens else None,
            "baseCompleteEver": any(f["baseComplete"] for f in frames),
            "baseCompleteAlways": all(f["baseComplete"] for f in frames),
        },
    }


# --------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(
        description="Trace consecutive live frames of the host render and "
                    "put a number on the flicker.")
    parser.add_argument("--outdir", required=True)
    parser.add_argument("--label", default="live")
    parser.add_argument("--duration", type=float, default=45.0,
                        help="seconds to observe after the provocation")
    parser.add_argument("--pre", type=float, default=8.0,
                        help="seconds to observe BEFORE provoking, so the "
                             "run can say whether the render was already "
                             "still when it started")
    parser.add_argument("--settle-quiet", type=float, default=5.0,
                        help="unchanged for this long counts as settled")
    parser.add_argument("--interval", type=float, default=0.10,
                        help="floor between reads; the socket's own round "
                             "trip usually dominates")
    parser.add_argument("--timeout", type=float, default=20.0)
    parser.add_argument("--idle", action="store_true",
                        help="provoke nothing. A non-zero flicker number "
                             "here is the purest form of the defect.")
    parser.add_argument("--manual", action="store_true",
                        help="somebody else provokes the redraw; this arms, "
                             "prints a line, and keeps reading")
    parser.add_argument("--gesture",
                        help="mirror_drive gesture to provoke the redraw")
    parser.add_argument("--entity")
    parser.add_argument("--name")
    parser.add_argument("--in", dest="container")
    parser.add_argument("--menu", type=int)
    parser.add_argument("--item", type=int)
    parser.add_argument("--qmp",
                        help="QMP socket. With it, a guest screendump is "
                             "taken at the provocation and at settle, and "
                             "the frame index of each is recorded — which "
                             "is what makes the three views one instant "
                             "here where sweep A had three phases.")
    parser.add_argument("--allow-no-drain", action="store_true",
                        help="accept a trace in which the content plane "
                             "never wrote a drain. The default is to "
                             "REFUSE, because such a run reports every "
                             "window stably empty and reads as a "
                             "stability result — see plane_evidence().")
    parser.add_argument("--expect-build", default="auto",
                        help="refuse a guest whose build is not this "
                             "checkout's. `auto` reads NOW_SRC_HASH out "
                             "of the products scripts/build-guests just "
                             "wrote; `-` skips the check and says so in "
                             "the report.")
    parser.add_argument("--repeat", type=int, default=1,
                        help="issue the provocation N times; each is "
                             "measured and the run reports the worst and "
                             "the mean")
    args = parser.parse_args()
    os.makedirs(args.outdir, exist_ok=True)

    print("LIMITS OF THIS MEASUREMENT (also written to %s/LIMITS.md):"
          % args.outdir)
    for key, text in LIMITS.items():
        print("  * %s: %s" % (key, text))
    print("")

    live = Live(args.timeout)
    expect = args.expect_build
    if expect == "auto":
        expect = read_expected_build(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        print("expecting guest build %s" % expect, flush=True)
    rig = assert_build(live, expect)
    print("rig: %s\n" % json.dumps(rig), flush=True)

    frames = []
    shots = []
    seen_ids = set()

    def shoot(tag):
        if not args.qmp:
            return
        out = os.path.join(args.outdir, "%s-%s-guest.ppm" % (args.label, tag))
        ok = screendump(args.qmp, out)
        shots.append({"tag": tag, "frameIndex": len(frames),
                      "at": time.time(), "path": out if ok else None})
    path = os.path.join(args.outdir, "%s-frames.jsonl" % args.label)
    stream = open(path, "w")

    def pump(seconds, note):
        end = time.time() + seconds
        while time.time() < end:
            started = time.time()
            try:
                value = live.snapshot()
            except Unavailable as exc:
                # Not fatal and not silent: `now-mirror-snapshot-
                # unavailable` is what the socket answers until the
                # Mirror window is open, and a run that swallowed it
                # would report a perfectly stable render of nothing.
                frames.append({"at": started, "unavailable": exc.code,
                               "snapshotID": None, "coverage": {},
                               "windows": {}, "baseComplete": False,
                               "sceneGeneration": None,
                               "contentGeneration": None,
                               "digest": None, "sequence": None,
                               "guest": None, "session": None})
                stream.write(json.dumps(frames[-1]) + "\n")
                time.sleep(max(args.interval, 0.5))
                continue
            frame = reduce_frame(value, started)
            frame["phase"] = note
            if frame["snapshotID"] not in seen_ids or not frames:
                seen_ids.add(frame["snapshotID"])
            frames.append(frame)
            stream.write(json.dumps(frame) + "\n")
            slept = args.interval - (time.time() - started)
            if slept > 0:
                time.sleep(slept)

    print("[pre] observing %.0fs before provoking" % args.pre, flush=True)
    pump(args.pre, "pre")
    pre_changes = len(transitions([(f["at"], state_vector(f))
                                   for f in frames if "unavailable" not in f]))
    print("[pre] %d frames, %d state changes while nothing was asked"
          % (len(frames), max(0, pre_changes - 1)), flush=True)

    provoked_at = None
    provocations = []
    if args.idle:
        print("[idle] provoking nothing", flush=True)
        shoot("idle-start")
        pump(args.duration, "idle")
        shoot("idle-end")
    else:
        for pass_index in range(max(1, args.repeat)):
            if args.manual:
                provoked_at = time.time()
                print("[provoke] ARMED — act now (pass %d)" % (pass_index + 1),
                      flush=True)
                provocations.append({"pass": pass_index + 1,
                                     "at": provoked_at, "how": "manual"})
            elif args.gesture:
                provoked_at = time.time()
                reply = live.drive(args.gesture, entityID=args.entity,
                                   itemName=args.name,
                                   container=args.container,
                                   menuID=args.menu, itemIndex=args.item)
                drive = reply.get("mirrorDriveResult") or {}
                print("[provoke] %s -> %s" % (args.gesture,
                                              json.dumps(drive)[:220]),
                      flush=True)
                provocations.append({"pass": pass_index + 1,
                                     "at": provoked_at,
                                     "how": args.gesture,
                                     "result": drive})
            else:
                raise SystemExit("give --gesture, or --manual, or --idle; "
                                 "a run with no stated provocation cannot "
                                 "say what its number is a number OF")
            shoot("provoke-%d" % (pass_index + 1))
            pump(args.duration, "observe-%d" % (pass_index + 1))
            shoot("settle-%d" % (pass_index + 1))

    stream.close()
    usable = [f for f in frames if "unavailable" not in f]
    unavailable = len(frames) - len(usable)
    report = analyse(usable, provoked_at, args.settle_quiet)
    report.update({
        "label": args.label,
        "rig": rig,
        "provocations": provocations,
        "idle": bool(args.idle),
        "preChanges": max(0, pre_changes - 1),
        "unavailableReads": unavailable,
        "framesFile": path,
        "screendumps": shots,
        "limits": LIMITS,
    })
    if unavailable:
        report["unavailableNote"] = (
            "%d reads answered unavailable — usually the Mirror window is "
            "not open. Those instants are absent from the trace and the "
            "flicker number is a floor." % unavailable)
    out = os.path.join(args.outdir, "%s-flicker.json" % args.label)
    with open(out, "w") as handle:
        json.dump(report, handle, indent=1)
    write_limits(args.outdir, "fidelity-live (%s)" % args.label, LIMITS)

    print("\n=== %s ===" % args.label)
    for key in ("framesRead", "snapshotIDs", "settled", "msToSettle",
                "framesToSettle", "distinctStatesAfterProvocation",
                "intermediateStates", "flickerEvents", "flickerBreakdown",
                "planeEvidence", "generations", "voidReason"):
        print("  %-32s %s" % (key, json.dumps(report.get(key))))
    if report.get("voidReason"):
        print("\n!! VOID: %s" % report["voidReason"])
        return 2

    # THE ARTIFACT ASSERTION, last because it is the one that decides
    # whether the numbers above mean anything. It is written into the
    # report either way — a run allowed through without a drain must
    # carry that fact wherever its number is quoted.
    evidence = report.get("planeEvidence") or {}
    if not evidence.get("drainInArtifact"):
        report["planeEvidence"]["verdict"] = (
            "allowed by --allow-no-drain" if args.allow_no_drain
            else "REFUSED: no drain in the artifact")
        with open(out, "w") as handle:
            json.dump(report, handle, indent=1)
        message = (
            "NO DRAIN IN THIS ARTIFACT. %d windows were traced by the "
            "content plane and %d of them carry ops, so this trace cannot "
            "tell a stable render from a plane that never armed — every "
            "window would read stably empty and the flicker number would "
            "read as a stability result."
            % (evidence.get("windowsTraced", 0),
               evidence.get("windowsWithOps", 0)))
        if args.allow_no_drain:
            print("\n!! %s\n   Allowed by --allow-no-drain; the report "
                  "carries it." % message)
        else:
            print("\n!! %s\n   Open the Mirror, front a window with content, "
                  "and run again — or pass --allow-no-drain if absence is "
                  "what you meant to measure." % message)
            return 3
    print("\nwrote %s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
