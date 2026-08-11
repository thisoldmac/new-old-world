#!/usr/bin/env python3
"""Write the sidecar the host requires before it advertises an update.

The artifact and its metadata are one publication unit.  A copied .bin with
no sidecar remains available to the onboarding portal, but is never offered
to an already-running guest as an update.  The SHA-256 is recomputed by the
host before every offer, so a stale sidecar fails closed.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path


def define(path: Path, name: str) -> str:
    match = re.search(
        rf"^\s*#define\s+{re.escape(name)}\s+[\"]?([^\"\s]+)",
        path.read_text(),
        re.MULTILINE,
    )
    if not match:
        raise SystemExit(f"{path}: no {name} definition")
    return match.group(1).removesuffix("UL")


def git(root: Path, *args: str) -> str:
    result = subprocess.run(("git", "-C", str(root), *args), text=True,
                            capture_output=True)
    if result.returncode:
        raise SystemExit(result.stderr.strip() or "git command failed")
    return result.stdout.strip()


def release_fields(root: Path, component: str, tag_version: str, build: str,
                   digest: str,
                   candidate_number: int | None = None) -> dict[str, str | int]:
    tag = (f"now-product-v{tag_version}" if component == "application"
           else f"now-extension-v{tag_version}")
    if candidate_number is not None:
        tag += f"-rc.{candidate_number}"
    ref = f"refs/tags/{tag}"
    try:
        kind = git(root, "cat-file", "-t", ref)
    except SystemExit:
        kind = ""
    if kind != "tag":
        raise SystemExit(f"release requires annotated tag {tag}")
    if git(root, "rev-parse", "HEAD") != git(root, "rev-parse", f"{ref}^{{}}"):
        raise SystemExit(f"release tag {tag} does not point at HEAD")
    if git(root, "status", "--porcelain", "--untracked-files=no"):
        raise SystemExit("release publication requires a clean tracked tree")
    annotation = git(root, "for-each-ref", "--format=%(contents)", ref)
    required = (
        f"NOW-Component: {component}",
        f"NOW-Build: {build}",
        f"NOW-SHA256: {digest}",
    )
    missing = [line for line in required if line not in annotation.splitlines()]
    if missing:
        raise SystemExit(
            f"release tag {tag} does not pin this artifact: " + ", ".join(missing))
    fields: dict[str, str | int] = {
        "releaseTag": tag,
        "sourceRevision": git(root, "rev-parse", "HEAD"),
    }
    if candidate_number is not None:
        fields["releaseCandidate"] = candidate_number
    return fields


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifact", required=True, type=Path)
    parser.add_argument("--component", required=True,
                        choices=("application", "extension"))
    parser.add_argument("--version-header", required=True, type=Path)
    parser.add_argument("--version-major", required=True)
    parser.add_argument("--version-minor")
    parser.add_argument("--version-patch")
    parser.add_argument("--lifecycle-define")
    parser.add_argument("--lifecycle-number-define")
    parser.add_argument("--identity-header", required=True, type=Path)
    parser.add_argument("--identity-define")
    parser.add_argument("--identity-word-prefix")
    parser.add_argument("--channel", default="development",
                        choices=("development", "candidate", "release"))
    parser.add_argument("--candidate-number", type=int)
    parser.add_argument("--repo-root", type=Path)
    args = parser.parse_args()

    parts = [define(args.version_header, args.version_major)]
    if args.version_minor:
        parts.append(define(args.version_header, args.version_minor))
    if args.version_patch:
        parts.append(define(args.version_header, args.version_patch))
    version = ".".join(str(int(part, 0)) for part in parts)
    display_version = version
    lifecycle: str | None = None
    lifecycle_number: int | None = None
    if args.component == "application":
        if not args.lifecycle_define or not args.lifecycle_number_define:
            raise SystemExit(
                "application manifest requires lifecycle define and number")
        lifecycle = define(args.version_header, args.lifecycle_define)
        lifecycle_number = int(
            define(args.version_header, args.lifecycle_number_define), 0)
        if lifecycle not in ("prealpha", "alpha", "beta", "release"):
            raise SystemExit(f"unknown product lifecycle {lifecycle}")
        if lifecycle == "release":
            if lifecycle_number != 0:
                raise SystemExit("release lifecycle number must be 0")
        elif not 1 <= lifecycle_number <= 255:
            raise SystemExit(
                "non-release lifecycle number must be 1 through 255")
        if lifecycle != "release":
            display_version = f"{version}-{lifecycle}.{lifecycle_number}"
    elif args.lifecycle_define or args.lifecycle_number_define:
        raise SystemExit("Extension lifecycle is independently versioned")

    if args.identity_define:
        build = define(args.identity_header, args.identity_define)
    elif args.identity_word_prefix:
        build = "".join(
            f"{int(define(args.identity_header, args.identity_word_prefix + str(i)), 0):08x}"
            for i in range(5)
        )
    else:
        raise SystemExit("name --identity-define or --identity-word-prefix")
    if not re.fullmatch(r"[0-9a-f]{64}", build):
        raise SystemExit("build identity must be a full lowercase SHA-256")

    artifact = args.artifact.resolve()
    digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
    document = {
        "schema": 1,
        "component": args.component,
        "version": version,
        "build": build,
        "sha256": digest,
        "bytes": artifact.stat().st_size,
        "channel": args.channel,
        # There is no release key yet.  This explicit false prevents an
        # integrity digest from being presented as an artifact signature.
        "signed": False,
    }
    if lifecycle is not None and lifecycle_number is not None:
        document.update({
            "displayVersion": display_version,
            "lifecycle": lifecycle,
            "lifecycleNumber": lifecycle_number,
        })
    if args.channel == "candidate":
        if args.candidate_number is None or args.candidate_number < 1:
            raise SystemExit(
                "candidate channel requires a positive --candidate-number")
    elif args.candidate_number is not None:
        raise SystemExit("--candidate-number is valid only for candidate channel")

    if args.channel in ("candidate", "release"):
        if args.repo_root is None:
            raise SystemExit(f"{args.channel} channel requires --repo-root")
        document.update(release_fields(args.repo_root.resolve(),
                                       args.component, display_version, build, digest,
                                       args.candidate_number))
    out = artifact.with_name(artifact.name + ".now-update.json")
    out.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
