"""Capture adapters. They own emulator differences, not case policy."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import subprocess
from typing import Callable


Run = Callable[..., subprocess.CompletedProcess[str]]


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _run(command: list[str], *, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, text=True, capture_output=True, check=True, env=env)


@dataclass
class SheepShaverBackend:
    repo: Path
    vm: Path | None = None
    run: Run = _run
    name: str = "sheepshaver-86"
    extension: str = ".bmp"

    def _env(self) -> dict[str, str]:
        env = os.environ.copy()
        if self.vm is not None:
            env["NOW_SHEEPSHAVER_VM"] = str(self.vm)
        return env

    @property
    def harness(self) -> Path:
        return self.repo / "scripts" / "emulator"

    def capture(self, destination: Path) -> None:
        self.run([str(self.harness), "sheepshaver-86", "capture", str(destination)], env=self._env())

    def input(self, actions: list[str]) -> None:
        # The emulator dispatches every action in one request, then the harness
        # settles once. The cooperative guest can therefore miss intermediate
        # button/position states if a gesture is batched. One receipt per
        # transition is the measured boundary: dispatch, guest settlement,
        # then the next state.
        for action in actions:
            self.run([str(self.harness), "sheepshaver-86", "input", action], env=self._env())

    def cleanup_input(self) -> None:
        # Cleanup changes emulator ADB state rather than describing a gesture;
        # batch every release and do not spend one settlement interval apiece.
        env = self._env()
        env["NOW_SHEEPSHAVER_INPUT_SETTLE"] = "0"
        self.run([str(self.harness), "sheepshaver-86", "input",
            "up 0", "up 1", "up 2",
            "keyup 55", "keyup 56", "keyup 57", "keyup 58", "keyup 59",
        ], env=env)

    def provenance(self) -> dict:
        doctor = self.run([str(self.harness), "sheepshaver-86", "doctor"], env=self._env()).stdout
        profile_line = next((line for line in doctor.splitlines()
                             if line.startswith("Mac OS 8.6 profile: ")), None)
        profile = Path(profile_line.split(": ", 1)[1]) if profile_line else self.vm
        result: dict = {"doctor": doctor.splitlines(), "profile": str(profile) if profile else None}
        if profile:
            for filename, key in (("Oracle Parent.rig", "parentRig"),
                                  ("prefs", "prefs"), ("Installed Apps.rig", "installedAppsRig")):
                path = profile / filename
                if path.is_file():
                    result[key] = {"path": str(path), "sha256": _sha256(path)}
                    if filename.endswith(".rig"):
                        result[key]["lines"] = path.read_text(errors="replace").splitlines()
        return result


@dataclass
class QMPBackend:
    repo: Path
    socket: Path
    run: Run = _run
    name: str = "qemu-ppc"
    extension: str = ".ppm"

    def capture(self, destination: Path) -> None:
        payload = json.dumps({"filename": str(destination)})
        self.run(["python3", str(self.repo / "tools" / "qmp"), str(self.socket),
                  "screendump", payload])

    def input(self, actions: list[str]) -> None:
        if actions:
            raise ValueError("QEMU case input is not implemented; drive it through its semantic harness")

    def cleanup_input(self) -> None:
        return

    def provenance(self) -> dict:
        return {"qmpSocket": str(self.socket)}
