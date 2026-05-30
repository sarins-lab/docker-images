#!/usr/bin/env python
"""Resolve and build local image tags from versions.yml.

versions.yml is the source of truth. Schema consumed here:

  tracks:        # OS base images; each track has a builds[] sublist.
    - suffix: alpine322
      status: active|beta|maintained|deprecated|eol
      builds:
        - type: oci            # only 'oci' builds are handled here (packer is
          dockerfile: alpine.dockerfile   # built by the Makefile packer targets)
          build-arg: ALPINE_VERSION=3.22.4
          platforms: [linux/amd64, ...]

  tool-tracks:   # tool images extending a base by base-suffix
    - track: init-tools
      dockerfile: init-tools.dockerfile
      base-image: hardened-alpine-base
      base-suffix: alpine322
      platforms: [linux/amd64, ...]
      status: active

  agent-tracks:  # Jenkins agent images; same shape as tool-tracks
    - track: runner
      dockerfile: runner.dockerfile
      base-image: hardened-ubuntu-base
      base-suffix: ubuntu24
      platforms: [linux/amd64, ...]
      status: active

Base image names are read from each dockerfile's org.opencontainers.image.title
label, so tool/agent `base-image` values must match those titles.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

try:
    import yaml
except ModuleNotFoundError:  # pragma: no cover - exercised by environment setup
    print(
        "ERROR: PyYAML is required to read versions.yml. "
        "Install it with: python -m pip install pyyaml",
        file=sys.stderr,
    )
    raise SystemExit(127)


VALID_STATUSES = {"beta", "active", "maintained", "deprecated", "eol"}

# Sections of versions.yml consumed by this script.
BASE_SECTION = "tracks"
TOOL_SECTION = "tool-tracks"
AGENT_SECTION = "agent-tracks"
EXTENDER_SECTIONS = (TOOL_SECTION, AGENT_SECTION)


def load_versions(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        data = yaml.safe_load(handle)

    if not isinstance(data, dict):
        raise ValueError(f"{path} must contain a YAML mapping")

    if BASE_SECTION not in data or not isinstance(data[BASE_SECTION], list):
        raise ValueError(f"{path} is missing required list section: {BASE_SECTION}")
    # tool-tracks is required; agent-tracks is optional (default to empty).
    if TOOL_SECTION not in data or not isinstance(data[TOOL_SECTION], list):
        raise ValueError(f"{path} is missing required list section: {TOOL_SECTION}")
    data.setdefault(AGENT_SECTION, [])
    if not isinstance(data[AGENT_SECTION], list):
        raise ValueError(f"{path}:{AGENT_SECTION} must be a YAML list")

    validate_base_tracks(data[BASE_SECTION])
    for section in EXTENDER_SECTIONS:
        validate_extender_tracks(
            data[section],
            section,
            ("track", "dockerfile", "base-image", "base-suffix", "platforms", "status"),
        )
    validate_extender_references(data)
    return data


def _check_status(section: str, index: int, status: Any) -> None:
    if str(status) not in VALID_STATUSES:
        raise ValueError(
            f"{section}[{index}] has invalid status {status!r}; "
            f"expected one of {sorted(VALID_STATUSES)}"
        )


def validate_base_tracks(tracks: list[dict[str, Any]]) -> None:
    for index, track in enumerate(tracks):
        if not isinstance(track, dict):
            raise ValueError(f"{BASE_SECTION}[{index}] must be a YAML mapping")
        for key in ("suffix", "status", "builds"):
            if key not in track:
                raise ValueError(f"{BASE_SECTION}[{index}] is missing required key: {key}")
        _check_status(BASE_SECTION, index, track["status"])
        if not isinstance(track["builds"], list):
            raise ValueError(f"{BASE_SECTION}[{index}]:builds must be a YAML list")
        # An OCI build, when present, must carry the build fields we rely on.
        oci = oci_build(track)
        if oci is not None:
            for key in ("dockerfile", "build-arg", "platforms"):
                if key not in oci:
                    raise ValueError(
                        f"{BASE_SECTION}[{index}] oci build is missing required key: {key}"
                    )


def validate_extender_tracks(tracks: list[dict[str, Any]], section: str, required: tuple[str, ...]) -> None:
    for index, track in enumerate(tracks):
        if not isinstance(track, dict):
            raise ValueError(f"{section}[{index}] must be a YAML mapping")
        for key in required:
            if key not in track:
                raise ValueError(f"{section}[{index}] is missing required key: {key}")
        _check_status(section, index, track["status"])


def oci_build(track: dict[str, Any]) -> dict[str, Any] | None:
    """Return the track's OCI build sublist entry, or None (e.g. packer-only tracks)."""
    for build in track.get("builds", []):
        if isinstance(build, dict) and build.get("type") == "oci":
            return build
    return None


def live_tracks(tracks: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [track for track in tracks if track["status"] != "eol"]


def live_oci_bases(tracks: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Live base tracks that actually produce an OCI image (have an oci build)."""
    return [track for track in live_tracks(tracks) if oci_build(track) is not None]


def as_platform_set(value: Any) -> set[str]:
    """platforms is a YAML list in versions.yml; tolerate a CSV string too."""
    if isinstance(value, (list, tuple)):
        return {str(part).strip() for part in value if str(part).strip()}
    return {part.strip() for part in str(value).split(",") if part.strip()}


def validate_extender_references(config: dict[str, Any]) -> None:
    live_bases = {track["suffix"]: track for track in live_oci_bases(config[BASE_SECTION])}

    for section in EXTENDER_SECTIONS:
        for track in live_tracks(config[section]):
            base_suffix = track["base-suffix"]
            if base_suffix not in live_bases:
                raise ValueError(
                    f"{section} {track['track']!r} references base-suffix {base_suffix!r}, "
                    f"which is not a live OCI base track"
                )
            base_platforms = as_platform_set(oci_build(live_bases[base_suffix])["platforms"])
            unsupported = sorted(as_platform_set(track["platforms"]) - base_platforms)
            if unsupported:
                raise ValueError(
                    f"{section} {track['track']!r} requests platforms not published by "
                    f"base-suffix {base_suffix!r}: {unsupported}"
                )


def image_name_from_file(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    match = re.search(r'org\.opencontainers\.image\.title\s*=\s*"([^"]+)"', text)
    if not match:
        raise ValueError(f"No org.opencontainers.image.title label found in {path}")
    return re.sub(r"[^a-z0-9._-]", "-", match.group(1).lower())


class ImageResolver:
    def __init__(self, root: Path) -> None:
        self.root = root
        self._title_cache: dict[str, str] = {}

    def title(self, dockerfile: str) -> str:
        if dockerfile not in self._title_cache:
            self._title_cache[dockerfile] = image_name_from_file(self.root / dockerfile)
        return self._title_cache[dockerfile]

    def base_tag(self, track: dict[str, Any], version: str) -> str:
        dockerfile = oci_build(track)["dockerfile"]
        return f"{self.title(dockerfile)}:{version}-{track['suffix']}"

    def extender_tag(self, track: dict[str, Any], version: str) -> str:
        suffix = str(track.get("tag-suffix", "")).strip()
        tag = f"{version}-{suffix}" if suffix else version
        return f"{self.title(track['dockerfile'])}:{tag}"

    def tags(self, config: dict[str, Any], version: str, git_sha: str = "", include_git_sha_tag: bool = False) -> list[str]:
        images: list[str] = []
        for track in live_oci_bases(config[BASE_SECTION]):
            images.append(self.base_tag(track, version))
        for section in EXTENDER_SECTIONS:
            for track in live_tracks(config[section]):
                images.append(self.extender_tag(track, version))
                if include_git_sha_tag and git_sha:
                    images.append(f"{self.title(track['dockerfile'])}:sha-{git_sha}")
        return images


def run_command(command: list[str], dry_run: bool) -> None:
    print(" ".join(command))
    if dry_run:
        return
    subprocess.run(command, check=True)


def docker_build_base(
    resolver: ImageResolver,
    tracks: list[dict[str, Any]],
    docker: str,
    version: str,
    dry_run: bool,
) -> None:
    for track in live_oci_bases(tracks):
        build = oci_build(track)
        run_command(
            [
                docker,
                "build",
                "--build-arg",
                build["build-arg"],
                "-f",
                build["dockerfile"],
                "-t",
                resolver.base_tag(track, version),
                ".",
            ],
            dry_run,
        )


def docker_build_extenders(
    resolver: ImageResolver,
    config: dict[str, Any],
    section: str,
    docker: str,
    version: str,
    git_sha: str,
    build_dependencies: bool,
    dry_run: bool,
) -> None:
    base_by_suffix = {track["suffix"]: track for track in live_oci_bases(config[BASE_SECTION])}

    if build_dependencies:
        suffixes = {track["base-suffix"] for track in live_tracks(config[section])}
        docker_build_base(
            resolver,
            [base_by_suffix[suffix] for suffix in sorted(suffixes)],
            docker,
            version,
            dry_run,
        )

    for track in live_tracks(config[section]):
        tag_args = ["-t", resolver.extender_tag(track, version)]
        if git_sha:
            tag_args.extend(["-t", f"{resolver.title(track['dockerfile'])}:sha-{git_sha}"])

        run_command(
            [
                docker,
                "build",
                "--build-arg",
                f"BASE_IMAGE={track['base-image']}:{version}-{track['base-suffix']}",
                "-f",
                track["dockerfile"],
                *tag_args,
                ".",
            ],
            dry_run,
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Resolve/build image tags from versions.yml")
    parser.add_argument(
        "command",
        choices=("images", "build-base", "build-tools", "build-agents", "build-all"),
    )
    parser.add_argument("--versions-file", default="versions.yml")
    parser.add_argument("--version", default="1.0.0")
    parser.add_argument("--docker", default="docker")
    parser.add_argument("--git-sha", default=os.environ.get("GIT_SHA", ""))
    parser.add_argument("--include-git-sha-tag", action="store_true")
    parser.add_argument("--build-dependencies", action="store_true")
    parser.add_argument("--as-argument-string", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = Path.cwd()
    config = load_versions(root / args.versions_file)
    resolver = ImageResolver(root)

    if args.command == "images":
        images = resolver.tags(config, args.version, args.git_sha, args.include_git_sha_tag)
        print((" ".join(images)) if args.as_argument_string else "\n".join(images))
        return 0

    if args.command == "build-base":
        docker_build_base(resolver, config[BASE_SECTION], args.docker, args.version, args.dry_run)
        return 0

    if args.command == "build-tools":
        docker_build_extenders(
            resolver, config, TOOL_SECTION, args.docker, args.version,
            args.git_sha, args.build_dependencies, args.dry_run,
        )
        return 0

    if args.command == "build-agents":
        docker_build_extenders(
            resolver, config, AGENT_SECTION, args.docker, args.version,
            args.git_sha, args.build_dependencies, args.dry_run,
        )
        return 0

    # build-all: bases, then tools, then agents (dependencies already covered by bases).
    docker_build_base(resolver, config[BASE_SECTION], args.docker, args.version, args.dry_run)
    docker_build_extenders(resolver, config, TOOL_SECTION, args.docker, args.version, args.git_sha, False, args.dry_run)
    docker_build_extenders(resolver, config, AGENT_SECTION, args.docker, args.version, args.git_sha, False, args.dry_run)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
