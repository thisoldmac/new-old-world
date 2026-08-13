from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path
import subprocess

try:
    import yaml
except ModuleNotFoundError:  # Apple ships Python without PyYAML.
    yaml = None


class ReleaseRefusal(ValueError):
    """An input does not satisfy the distribution contract."""


@dataclass(frozen=True)
class DistributionProfile:
    product_version: str
    document: dict

    @classmethod
    def load(cls, root: Path) -> "DistributionProfile":
        path = root / "docs/distribution-profile.yaml"
        document = _load_yaml(path)
        if not isinstance(document, dict) or document.get("schema_version") != 1:
            raise ReleaseRefusal(f"{path}: unsupported distribution profile")
        if document.get("profile_id") != "alpha-distribution":
            raise ReleaseRefusal(f"{path}: expected alpha-distribution")
        outputs = document.get("outputs")
        if not isinstance(outputs, dict):
            raise ReleaseRefusal(f"{path}: outputs must be a mapping")
        required = {
            "macos_dmg", "embedded_app_resources", "generic_classic_image",
            "loose_ppc_application", "loose_ppc_sidecar",
            "loose_now_extension", "loose_extension_sidecar",
            "release_manifest", "release_checksums",
        }
        if set(outputs) != required:
            raise ReleaseRefusal(f"{path}: output contract has drifted")
        if set(document.get("licensed_inputs", {})) != {
            "carbonlib_1_6_installer"
        }:
            raise ReleaseRefusal(f"{path}: licensed-input contract has drifted")
        if set(document.get("excluded_inputs", {})) != {"codekitten"}:
            raise ReleaseRefusal(f"{path}: excluded-input contract has drifted")
        version = _product_version(root / "now-host/NewOldWorld.xcodeproj/project.pbxproj")
        return cls(product_version=version, document=document)

    def filename(self, output_id: str) -> str:
        template = self.document["outputs"][output_id]["filename"]
        return template.replace("${product_version}", self.product_version)


def _product_version(path: Path) -> str:
    values = set()
    for line in path.read_text().splitlines():
        if "MARKETING_VERSION =" in line:
            values.add(line.split("=", 1)[1].strip().rstrip(";"))
    if len(values) != 1:
        raise ReleaseRefusal(f"{path}: expected one MARKETING_VERSION")
    return values.pop()


def _load_yaml(path: Path) -> object:
    if yaml is not None:
        return yaml.safe_load(path.read_text())
    completed = subprocess.run([
        "/usr/bin/ruby", "-ryaml", "-rjson", "-e",
        "puts JSON.generate(YAML.safe_load(File.read(ARGV[0]), aliases: true))",
        str(path),
    ], text=True, capture_output=True)
    if completed.returncode:
        raise ReleaseRefusal(
            f"{path}: cannot parse YAML: {completed.stderr.strip()}")
    return json.loads(completed.stdout)
