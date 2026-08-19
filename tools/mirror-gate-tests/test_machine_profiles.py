#!/usr/bin/env python3
"""Machine profiles: which Mac a deploy chose, and who won when two
places named one.

These are the questions a flat `.env.lab` could not be asked. With one
namespace for machine facts, "which machine is `NOW68K_FTP_HOST`?" had
one answer — whichever the desk file last named — and a second Mac on the
desk could only be reached by editing a shared file or remembering an
export. Both of those are the shape of the failure this project already
paid for: a deploy that silently went somewhere, and a test run
afterwards that measured a build which never moved.

So the cases here are mostly REFUSALS, and each one is checked to name
the thing the reader must act on: the machines to choose between, the key
that is missing, the file it is missing from. A refusal that does not
name its subject sends somebody to edit the wrong file.

`scripts/deploy-68k --which` resolves and stops, so every deploy-side
case runs here without a network, without a version bump, and without
touching a Macintosh.
"""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import machine_profiles as mp  # noqa: E402

DEPLOY = ROOT / "scripts" / "deploy-68k"

FULL = """
name = PowerBook 180c
guest = 68k
address = 192.0.2.180
ftp_user = lab
ftp_pass = secret
ftp_dir = Lab/now-68k
"""


class Fixture(unittest.TestCase):
    """A throwaway checkout carrying only what these tools read."""

    def setUp(self):
        self.work = tempfile.mkdtemp(prefix="machprof-", dir="/private/tmp")
        self.addCleanup(shutil.rmtree, self.work, ignore_errors=True)
        self.repo = Path(self.work) / "repo"
        (self.repo / "scripts").mkdir(parents=True)
        (self.repo / "tools").mkdir()
        shutil.copy(DEPLOY, self.repo / "scripts" / "deploy-68k")
        shutil.copy(ROOT / "tools" / "machine_profiles.py",
                    self.repo / "tools" / "machine_profiles.py")
        shutil.copy(ROOT / "tools" / "lab-machine",
                    self.repo / "tools" / "lab-machine")

    def profile(self, machine_id, text=FULL, repo=None):
        directory = (repo or self.repo) / mp.PROFILE_DIR
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / (machine_id + mp.SUFFIX)
        path.write_text(text, encoding="utf-8")
        return path

    def env_lab(self, text, repo=None):
        ((repo or self.repo) / ".env.lab").write_text(text, encoding="utf-8")

    def which(self, *args, env=None):
        """`deploy-68k --which`, with a clean environment.

        `env=None` means a bare one on purpose: this process may itself
        have been started with NOW68K_* exported, and inheriting it would
        make an explicit-beats-profile test pass for the wrong reason.
        """
        base = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                "HOME": self.work}
        base.update(env or {})
        out = subprocess.run(
            [sys.executable, str(self.repo / "scripts" / "deploy-68k"),
             "--which", *args],
            capture_output=True, text=True, timeout=120, env=base,
            cwd=str(self.repo))
        return out.returncode, out.stdout + out.stderr


class Selection(Fixture):

    def test_one_profile_needs_no_argument(self):
        self.profile("pb180c")
        code, text = self.which()
        self.assertEqual(code, 0, text)
        self.assertIn("192.0.2.180", text)
        self.assertIn("pb180c", text)

    def test_two_profiles_refuse_and_name_both(self):
        """The whole reason `--machine` exists. Picking the first would
        be a deploy to a machine nobody chose."""
        self.profile("pb180c")
        self.profile("pb1400c", FULL.replace("192.0.2.180", "192.0.2.140")
                     .replace("guest = 68k", "guest = 68k"))
        code, text = self.which()
        self.assertEqual(code, 1, text)
        self.assertIn("pb180c", text)
        self.assertIn("pb1400c", text)
        self.assertIn("--machine", text,
                      "a refusal must say how to answer it")

    def test_named_machine_is_used(self):
        self.profile("pb180c")
        self.profile("pb1400c", FULL.replace("192.0.2.180", "192.0.2.140"))
        code, text = self.which("--machine", "pb1400c")
        self.assertEqual(code, 0, text)
        self.assertIn("192.0.2.140", text)
        self.assertNotIn("192.0.2.180", text)

    def test_an_unknown_machine_names_the_ones_there_are(self):
        self.profile("pb180c")
        code, text = self.which("--machine", "pb190c")
        self.assertEqual(code, 1, text)
        self.assertIn("pb190c", text)
        self.assertIn("pb180c", text, "name what this desk does have")

    def test_the_committed_example_is_not_a_machine(self):
        """`.machine.example` sits in the same directory and must never
        be selected — a desk that has copied nothing has no machines."""
        directory = self.repo / mp.PROFILE_DIR
        directory.mkdir(parents=True)
        shutil.copy(ROOT / ".lab" / "machines" / "pb180c.machine.example",
                    directory / "pb180c.machine.example")
        self.assertEqual(mp.discover(self.repo), {})

    def test_a_worktree_reads_the_main_worktrees_profiles(self):
        """Same argument as `.env.lab` in test_build_guests_env.py: a
        worktree is the same desk and the same machines, and a profile
        copied into one dies with it."""
        subprocess.run(["git", "init", "-q", "-b", "main", str(self.repo)],
                       check=True, capture_output=True)
        for args in (("config", "user.email", "t@t"),
                     ("config", "user.name", "t"),
                     ("add", "-A"), ("commit", "-qm", "scaffold")):
            subprocess.run(["git", "-C", str(self.repo), *args], check=True,
                           capture_output=True)
        self.profile("pb180c")
        tree = Path(self.work) / "wt"
        subprocess.run(["git", "-C", str(self.repo), "worktree", "add", "-q",
                        "--detach", str(tree), "HEAD"],
                       check=True, capture_output=True)
        found = mp.discover(tree)
        self.assertEqual(sorted(found), ["pb180c"],
                         "a worktree with no profiles of its own must find "
                         "the main worktree's")

    def test_a_worktree_reads_the_main_worktrees_env_lab_too(self):
        """Profiles and the desk file follow ONE rule. A worktree that
        found its machine but not its toolchain would be a confusing
        half-answer, and `scripts/build-guests` already resolves
        `.env.lab` this way."""
        subprocess.run(["git", "init", "-q", "-b", "main", str(self.repo)],
                       check=True, capture_output=True)
        for args in (("config", "user.email", "t@t"),
                     ("config", "user.name", "t"),
                     ("add", "-A"), ("commit", "-qm", "scaffold")):
            subprocess.run(["git", "-C", str(self.repo), *args], check=True,
                           capture_output=True)
        self.env_lab("NOW68K_FTP_HOST=192.0.2.99\nNOW68K_FTP_USER=lab\n"
                     "NOW68K_FTP_PASS=secret\n")
        tree = Path(self.work) / "wt"
        subprocess.run(["git", "-C", str(self.repo), "worktree", "add", "-q",
                        "--detach", str(tree), "HEAD"],
                       check=True, capture_output=True)
        self.assertEqual(mp.desk_file(tree), self.repo / ".env.lab")

    def test_a_worktrees_own_profiles_still_win(self):
        subprocess.run(["git", "init", "-q", "-b", "main", str(self.repo)],
                       check=True, capture_output=True)
        for args in (("config", "user.email", "t@t"),
                     ("config", "user.name", "t"),
                     ("add", "-A"), ("commit", "-qm", "scaffold")):
            subprocess.run(["git", "-C", str(self.repo), *args], check=True,
                           capture_output=True)
        self.profile("pb180c")
        tree = Path(self.work) / "wt"
        subprocess.run(["git", "-C", str(self.repo), "worktree", "add", "-q",
                        "--detach", str(tree), "HEAD"],
                       check=True, capture_output=True)
        self.profile("q950", FULL.replace("192.0.2.180", "192.0.2.95"),
                     repo=tree)
        self.assertEqual(sorted(mp.discover(tree)), ["q950"])


class Precedence(Fixture):

    def test_explicit_environment_beats_the_profile(self):
        """The repo convention, and what lets a one-off run point
        somewhere else without editing a file."""
        self.profile("pb180c")
        code, text = self.which(env={"NOW68K_FTP_HOST": "192.0.2.44"})
        self.assertEqual(code, 0, text)
        self.assertIn("192.0.2.44", text)

    def test_the_profile_beats_env_lab(self):
        """A desk mid-migration has both. The profile is the newer, more
        specific statement and must win — otherwise writing one changes
        nothing and the reason is invisible."""
        self.profile("pb180c")
        self.env_lab("NOW68K_FTP_HOST=192.0.2.99\n")
        code, text = self.which()
        self.assertEqual(code, 0, text)
        self.assertIn("192.0.2.180", text)
        self.assertNotIn("would deploy to ftp://lab@192.0.2.99", text)

    def test_a_shadowed_env_lab_key_is_named_out_loud(self):
        """Silence here is the same trap one layer down: `.env.lab` keeps
        a plausible old address and nothing tells the person reading it
        that the file is lying to them."""
        self.profile("pb180c")
        self.env_lab("NOW68K_FTP_HOST=192.0.2.99\n")
        _, text = self.which()
        self.assertIn("NOW68K_FTP_HOST", text)
        self.assertIn(".env.lab", text)

    def test_env_lab_alone_still_deploys(self):
        """A desk that has written no profile keeps working, or this
        change breaks the only machine anybody is using today."""
        self.env_lab("NOW68K_FTP_HOST=192.0.2.99\n"
                     "NOW68K_FTP_USER=lab\nNOW68K_FTP_PASS=secret\n")
        code, text = self.which()
        self.assertEqual(code, 0, text)
        self.assertIn("192.0.2.99", text)

    def test_one_address_feeds_both_the_deploy_and_the_metal_guard(self):
        """They were two keys that nothing checked agreed, so a deploy
        could go to one machine while the machine-busy guard cleared
        another."""
        profile = mp._parse(FULL, "x", "pb180c")
        environment = profile.environment()
        self.assertEqual(environment["NOW68K_FTP_HOST"], "192.0.2.180")
        self.assertEqual(environment["NOW_METAL_MACHINE"], "192.0.2.180")


class Refusals(Fixture):

    def test_an_unknown_key_is_refused_by_name(self):
        """Ignoring it would leave the value unset and the run would fall
        back to a stale flat key — this scheme's own failure, rewrapped."""
        with self.assertRaises(mp.ProfileError) as caught:
            mp._parse("address = 1.2.3.4\nftp_pas = oops\n", "p", "m")
        self.assertIn("ftp_pas", str(caught.exception))
        self.assertIn("ftp_pass", str(caught.exception),
                      "name the keys there are, so a typo is visibly one")

    def test_a_profile_without_an_address_is_not_a_machine(self):
        with self.assertRaises(mp.ProfileError) as caught:
            mp._parse("name = nothing\n", "p", "m")
        self.assertIn("address", str(caught.exception))

    def test_a_duplicate_key_is_refused(self):
        with self.assertRaises(mp.ProfileError):
            mp._parse("address = 1.2.3.4\naddress = 5.6.7.8\n", "p", "m")

    def test_a_bad_guest_value_is_refused(self):
        with self.assertRaises(mp.ProfileError) as caught:
            mp._parse("address = 1.2.3.4\nguest = powerpc\n", "p", "m")
        self.assertIn("powerpc", str(caught.exception))

    def test_a_file_name_that_is_not_a_guest_id_is_refused(self):
        """One machine, one name — the host's roster, the tool calls and
        this directory."""
        self.profile("PB_180c")
        with self.assertRaises(mp.ProfileError) as caught:
            mp.discover(self.repo)
        self.assertIn("PB_180c", str(caught.exception))

    def test_deploying_68k_to_a_ppc_machine_is_refused(self):
        self.profile("pb1400c", FULL.replace("guest = 68k", "guest = ppc"))
        code, text = self.which()
        self.assertEqual(code, 1, text)
        self.assertIn("ppc", text)
        self.assertIn("pb1400c", text)

    def test_a_missing_key_names_the_profile_and_not_env_lab(self):
        """The message decides which file somebody opens. Naming
        `.env.lab` while a profile is in play sends them to edit a file
        where the change would do nothing."""
        self.profile("pb180c", "address = 192.0.2.180\nftp_user = lab\n")
        code, text = self.which()
        self.assertEqual(code, 1, text)
        self.assertIn("ftp_pass", text)
        self.assertIn(".machine", text)
        self.assertNotIn("cp .env.lab.example", text)

    def test_with_no_profile_a_missing_key_points_at_the_new_home(self):
        code, text = self.which()
        self.assertEqual(code, 1, text)
        self.assertIn("NOW68K_FTP_HOST", text)
        self.assertIn(".lab/machines", text,
                      "a desk with nothing set should be sent to profiles, "
                      "not taught the flat keys again")


class Committed(unittest.TestCase):
    """What the repository itself must keep true."""

    def test_the_example_profile_parses(self):
        path = ROOT / ".lab" / "machines" / "pb180c.machine.example"
        profile = mp._parse(path.read_text(encoding="utf-8"), path, "pb180c")
        self.assertEqual(profile.guest, "68k")
        self.assertTrue(profile.address)

    def test_no_real_profile_is_tracked(self):
        """Machine addresses and FTP passwords must never reach a commit."""
        out = subprocess.run(
            ["git", "-C", str(ROOT), "ls-files", ".lab/"],
            capture_output=True, text=True, timeout=60)
        tracked = [line for line in out.stdout.split() if line]
        self.assertEqual(
            [t for t in tracked if t.endswith(mp.SUFFIX)], [],
            "a *.machine file is tracked; .gitignore should have kept it out")

    def test_the_gitignore_rule_actually_ignores_one(self):
        """Watched to fail: without the rule, `git check-ignore` says no."""
        out = subprocess.run(
            ["git", "-C", str(ROOT), "check-ignore",
             ".lab/machines/pb180c.machine"],
            capture_output=True, text=True, timeout=60)
        self.assertEqual(out.returncode, 0,
                         "'.lab/machines/*.machine' is not ignored")


if __name__ == "__main__":
    unittest.main(verbosity=2)
