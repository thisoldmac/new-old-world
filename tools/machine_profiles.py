"""One vintage machine's facts, in one file, keyed by the id the host
already calls it.

WHY THIS IS NOT `.env.lab`. That file describes ONE DESK — where Retro68
is installed, which SheepShaver profile to open, what codesign identity
to use. Those are properties of this Mac and they are flat keys because
there is only ever one of each.

A machine is not like that. There are two of them on this desk already
(`pb180c`, `pb1400c`), and every fact about one is a fact ABOUT THAT
MACHINE: its address, the FTP account it answers on, the folder builds
land in. Flat keys force those into one namespace, and the namespace can
only hold one machine — so `NOW68K_FTP_HOST` silently means "whichever
Mac the desk file happens to name", and pointing a run at the other one
means editing a shared file or remembering an export.

Worse, flat keys hide that two of them are THE SAME FACT.
`NOW68K_FTP_HOST` and `NOW_METAL_MACHINE` are both "the machine's
address", set separately, and nothing ever checked that they agreed — so
a deploy could go to one machine while the machine-busy guard cleared a
different one. Here `address` is written once and both fall out of it.

The ids are the host's own (`GuestID`, now-host/Sources/Host/
GuestIdentity.swift): the slug a person types at the picker and an agent
types in a tool call. A machine having two names — one for the roster,
one for the deploy script — is the kind of drift this project pays for
later.

Nothing here is committed. `.lab/machines/*.machine` is gitignored the
way `.env.lab` is; `.lab/machines/pb180c.machine.example` is the shape.
"""

import os
import subprocess
from pathlib import Path

#: Directory holding the profiles, relative to a checkout root.
PROFILE_DIR = Path(".lab") / "machines"
SUFFIX = ".machine"

#: Every key a profile may carry, and the environment keys it feeds.
#:
#: Refusing an unknown key rather than ignoring it is deliberate: a typo
#: in `ftp_pas` would otherwise leave the value unset and the run would
#: fall back to whatever a stale `.env.lab` still named — which is the
#: exact failure this whole scheme exists to end, wearing a new hat.
FIELDS = {
    "name":         ("how a message should refer to it", ()),
    "guest":        ("which guest it runs: 68k or ppc", ()),
    "address":      ("its address on the LAN",
                     ("NOW68K_FTP_HOST", "NOW_METAL_MACHINE")),
    "ftp_user":     ("FTP account — NetPresenz or Rumpus",
                     ("NOW68K_FTP_USER",)),
    "ftp_pass":     ("that account's password", ("NOW68K_FTP_PASS",)),
    "ftp_dir":      ("folder builds land in, relative to the FTP root",
                     ("NOW68K_FTP_DIR",)),
    "metal_port":   ("port its metal runs use", ("NOW_METAL_PORT",)),
    "harness_host": ("this Mac's address as THIS machine must dial it, "
                     "when it differs from the desk-wide one",
                     ("NOW68K_HARNESS_HOST",)),
}

GUESTS = ("68k", "ppc")


class ProfileError(Exception):
    """Something a caller must print and stop on. The message is the
    whole interface — it names the file, the key, and what to do."""


class Profile:
    """One machine, as its file describes it."""

    def __init__(self, machine_id, path, values):
        self.id = machine_id
        self.path = path
        self.values = values

    def __getattr__(self, name):
        if name in FIELDS:
            return self.values.get(name)
        raise AttributeError(name)

    @property
    def title(self):
        """`pb180c (PowerBook 180c)`, or just the id when unnamed."""
        name = self.values.get("name")
        return "%s (%s)" % (self.id, name) if name else self.id

    def environment(self):
        """`{env key: value}` this profile asserts. Only keys it actually
        carries — an absent `ftp_dir` must leave the script's own default
        alone rather than blanking it."""
        out = {}
        for key, (_, env_keys) in FIELDS.items():
            value = self.values.get(key)
            if value:
                for env_key in env_keys:
                    out[env_key] = value
        return out


def _parse(text, path, machine_id):
    values = {}
    for number, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ProfileError("%s:%d: not `key = value`: %s"
                               % (path, number, line))
        key, _, value = line.partition("=")
        key, value = key.strip(), value.strip()
        if key not in FIELDS:
            raise ProfileError(
                "%s:%d: no such key `%s`.\n"
                "  A profile may carry: %s\n"
                "  An unknown key is refused rather than ignored — a typo "
                "here would leave the value unset and the run would fall "
                "back to whatever a stale .env.lab still named."
                % (path, number, key, ", ".join(sorted(FIELDS))))
        if key in values:
            raise ProfileError("%s:%d: `%s` is set twice"
                               % (path, number, key))
        values[key] = value

    if not values.get("address"):
        raise ProfileError(
            "%s has no `address`, so it does not describe a machine.\n"
            "  Every other fact here is about the Mac at that address."
            % path)
    guest = values.get("guest")
    if guest and guest not in GUESTS:
        raise ProfileError("%s: `guest` is %r; it must be one of %s"
                           % (path, guest, ", ".join(GUESTS)))
    return Profile(machine_id, path, values)


def _valid_id(text):
    """The host's `GuestID` grammar, so a machine has ONE name across the
    roster, the tool calls and this directory."""
    return (text and len(text) <= 40
            and all(c.isascii() and (c.isalnum() or c == "-") for c in text)
            and text == text.lower()
            and text[0].isalnum() and text[-1].isalnum())


def profile_dir(repo):
    """Where this checkout's profiles are, or None.

    A worktree is not a fresh clone — it is the same desk and the same
    machines — so the MAIN worktree's directory is used when this one has
    none. `scripts/build-guests` learnt that the hard way with `.env.lab`:
    a lane told to copy the file copied it into its own worktree, where it
    died with the worktree, and the gate had already read green once.
    """
    here = Path(repo) / PROFILE_DIR
    if here.is_dir():
        return here
    try:
        out = subprocess.run(
            ["git", "-C", str(repo), "rev-parse", "--path-format=absolute",
             "--git-common-dir"],
            capture_output=True, text=True, timeout=10)
    except Exception:
        return None
    if out.returncode != 0 or not out.stdout.strip():
        return None
    main = Path(out.stdout.strip()).parent / PROFILE_DIR
    return main if main.is_dir() else None


def discover(repo):
    """Every profile this checkout can see, by id.

    `.machine.example` is deliberately not a `.machine`, so the committed
    example can sit in the same directory without ever being selected as
    a real machine."""
    directory = profile_dir(repo)
    if directory is None:
        return {}
    found = {}
    for path in sorted(directory.glob("*" + SUFFIX)):
        machine_id = path.name[:-len(SUFFIX)]
        if not _valid_id(machine_id):
            raise ProfileError(
                "%s is not a usable machine id.\n"
                "  Ids are the host's own (GuestID): lowercase letters, "
                "digits and hyphens, starting and ending alphanumeric — "
                "`pb180c`, `pb1400c`. The same slug a person types at the "
                "picker and an agent types in a tool call." % path)
        found[machine_id] = _parse(path.read_text(encoding="utf-8"),
                                   path, machine_id)
    return found


def select(profiles, wanted, why="this run"):
    """The machine to act on, or a refusal that NAMES THE CHOICES.

    With one profile there is no question to ask. With several there is,
    and this refuses rather than picking the first — a deploy that went to
    a machine nobody chose is the whole failure class here."""
    if wanted:
        if wanted in profiles:
            return profiles[wanted]
        known = ", ".join(sorted(profiles)) or "(none)"
        raise ProfileError(
            "no machine profile `%s`.\n"
            "  Profiles here: %s\n"
            "  One file per machine in %s, named <id>%s."
            % (wanted, known, PROFILE_DIR, SUFFIX))
    if not profiles:
        return None
    if len(profiles) == 1:
        return next(iter(profiles.values()))
    listing = "\n".join(
        "    --machine %-10s %s%s"
        % (p.id, p.address, " — runs the %s guest" % p.guest if p.guest else "")
        for p in sorted(profiles.values(), key=lambda p: p.id))
    raise ProfileError(
        "this desk has %d machine profiles, so %s must say which:\n%s"
        % (len(profiles), why, listing))


def apply(profile, explicit, log=None):
    """Put `profile`'s facts in the environment, under an EXPLICIT
    environment variable and over `.env.lab`.

    `explicit` is the process environment as it was BEFORE `.env.lab` was
    read — that is the only way to tell a one-off `NOW68K_FTP_HOST=… ` on
    the command line, which must win, from a desk file's stale copy of the
    same key, which must not. The repo convention is that an explicit
    variable beats a file; a profile is a file.
    """
    if profile is None:
        return
    for env_key, value in sorted(profile.environment().items()):
        if env_key in explicit:
            if log and explicit[env_key] != value:
                log("== %s=%s from the environment, over %s's %s"
                    % (env_key, explicit[env_key], profile.id, value))
            continue
        os.environ[env_key] = value


def note_shadowed(profile, env_lab_values, log):
    """Say so when `.env.lab` still carries a machine key the profile now
    answers, AND disagrees about it.

    Silence here would be the same trap one layer down: the desk file
    keeps a plausible old address, the profile wins, and nothing ever
    tells the person reading `.env.lab` that the file is lying to them."""
    if profile is None:
        return
    mine = profile.environment()
    stale = sorted(key for key, value in env_lab_values.items()
                   if key in mine and value != mine[key])
    if not stale:
        return
    log("== .env.lab still sets %s; %s's profile wins (%s). Delete those "
        "keys from .env.lab — machine facts live in %s now."
        % (", ".join(stale), profile.id, profile.path, PROFILE_DIR))
