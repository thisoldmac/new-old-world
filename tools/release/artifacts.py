from __future__ import annotations

import hashlib
import json
import os
import shutil
from dataclasses import dataclass
from pathlib import Path

from .profile import ReleaseRefusal


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def copy_exact(source: Path, destination: Path) -> None:
    try:
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
        source_digest = sha256(source)
        destination_digest = sha256(destination)
    except OSError as exc:
        raise ReleaseRefusal(f"could not copy {source}: {exc}") from exc
    if source_digest != destination_digest:
        raise ReleaseRefusal(f"copy changed bytes: {source}")


def load_json_object(path: Path, label: str) -> dict:
    try:
        document = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise ReleaseRefusal(f"{path}: {label}: {exc}") from exc
    if not isinstance(document, dict):
        raise ReleaseRefusal(f"{path}: {label}: top level must be an object")
    return document


@dataclass(frozen=True)
class ComponentArtifact:
    component: str
    path: Path
    sidecar_path: Path
    metadata: dict

    @classmethod
    def load(cls, path: Path, component: str, version: str,
             source_revision: str) -> "ComponentArtifact":
        path = path.resolve()
        sidecar = path.with_name(path.name + ".now-update.json")
        metadata = load_json_object(sidecar, "missing or invalid sidecar")
        expected_keys = {
            "schema", "component", "version", "build", "sha256", "bytes",
            "channel", "signed",
        }
        optional_keys = {
            "compatibility", "displayVersion", "lifecycle", "lifecycleNumber",
            "releaseTag", "sourceRevision",
        }
        unknown = set(metadata) - expected_keys - optional_keys
        if unknown:
            raise ReleaseRefusal(f"{sidecar}: unknown fields: {sorted(unknown)}")
        if metadata.get("schema") != 1 or metadata.get("component") != component:
            raise ReleaseRefusal(f"{sidecar}: component contract mismatch")
        if metadata.get("version") != version:
            raise ReleaseRefusal(f"{sidecar}: version does not match product {version}")
        digest = sha256(path)
        if metadata.get("sha256") != digest or metadata.get("bytes") != path.stat().st_size:
            raise ReleaseRefusal(f"{sidecar}: stale artifact identity")
        build = metadata.get("build")
        if not isinstance(build, str) or len(build) != 64 or any(
            char not in "0123456789abcdef" for char in build
        ):
            raise ReleaseRefusal(f"{sidecar}: build must be a lowercase SHA-256")
        recorded_revision = metadata.get("sourceRevision")
        if recorded_revision != source_revision:
            raise ReleaseRefusal(f"{sidecar}: source revision does not match HEAD")
        return cls(component=component, path=path, sidecar_path=sidecar,
                   metadata=metadata)

    def manifest_row(self) -> dict:
        row = {
            "classification": "repository-build",
            "component": self.component,
            "filename": self.path.name,
            "version": self.metadata["version"],
            "build": self.metadata["build"],
            "bytes": self.path.stat().st_size,
            "sha256": sha256(self.path),
            "sidecarSHA256": sha256(self.sidecar_path),
        }
        for key in (
            "compatibility", "displayVersion", "lifecycle", "lifecycleNumber",
            "releaseTag",
        ):
            if key in self.metadata:
                row[key] = self.metadata[key]
        return row


@dataclass(frozen=True)
class LicensedInput:
    artifact: Path
    descriptor_path: Path
    license_files: tuple[Path, ...]
    metadata: dict

    @classmethod
    def load(cls, descriptor_path: Path) -> "LicensedInput":
        descriptor_path = descriptor_path.resolve()
        document = load_json_object(descriptor_path, "invalid descriptor")
        required = {
            "schema", "id", "artifact", "sha256", "provenance",
            "licenseFiles", "licenseAcceptance",
        }
        if set(document) != required:
            raise ReleaseRefusal(
                f"{descriptor_path}: fields must be exactly {sorted(required)}")
        if document["schema"] != 1 or document["id"] != "carbonlib_1_6_installer":
            raise ReleaseRefusal(f"{descriptor_path}: not the approved CarbonLib input")
        if document["licenseAcceptance"] != "user":
            raise ReleaseRefusal(f"{descriptor_path}: installer license must be user-accepted")
        provenance = document["provenance"]
        if not isinstance(provenance, dict) or set(provenance) != {"url", "retrievedAt"}:
            raise ReleaseRefusal(f"{descriptor_path}: provenance must name URL and retrieval date")
        if not str(provenance["url"]).startswith(("https://", "http://")):
            raise ReleaseRefusal(f"{descriptor_path}: provenance URL is invalid")
        artifact = _relative_input(descriptor_path, document["artifact"])
        if not artifact.is_file() or sha256(artifact) != document["sha256"]:
            raise ReleaseRefusal(f"{descriptor_path}: CarbonLib checksum mismatch")
        raw_licenses = document["licenseFiles"]
        if not isinstance(raw_licenses, list) or not raw_licenses:
            raise ReleaseRefusal(f"{descriptor_path}: license material is required")
        licenses = tuple(_relative_input(descriptor_path, item) for item in raw_licenses)
        if any(not item.is_file() for item in licenses):
            raise ReleaseRefusal(f"{descriptor_path}: license material is missing")
        return cls(artifact=artifact, descriptor_path=descriptor_path,
                   license_files=licenses, metadata=document)

    def manifest_row(self) -> dict:
        return {
            "classification": "approved-external-installer",
            "id": self.metadata["id"],
            "filename": self.artifact.name,
            "bytes": self.artifact.stat().st_size,
            "sha256": sha256(self.artifact),
            "provenance": self.metadata["provenance"],
            "licenseAcceptance": "user",
            "licenseFiles": [
                {"filename": path.name, "sha256": sha256(path)}
                for path in self.license_files
            ],
        }


def _relative_input(descriptor: Path, value: object) -> Path:
    if not isinstance(value, str) or not value:
        raise ReleaseRefusal(f"{descriptor}: input path must be a string")
    path = Path(os.path.expanduser(value))
    if not path.is_absolute():
        path = descriptor.parent / path
    return path.resolve()
