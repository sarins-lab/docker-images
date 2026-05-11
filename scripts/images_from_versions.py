#!/usr/bin/env python
"""Resolve and build local image tags from versions.yml."""

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


VALID_STATUSES = {"active", "maintained", "deprecated", "eol"}


def load_versions(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        data = yaml.safe_load(handle)

    if not isinstance(data, dict):
        raise ValueError(f"{path} must contain a YAML mapping")

    for section in ("base-tracks", "tool-tracks"):
        if section not in data:
            raise ValueError(f"{path} is missing required section: {section}")
        if not isinstance(data[section], list):
            raise ValueError(f"{path}:{section} must be a YAML list")

    validate_tracks(data["base-tracks"], "base-tracks", ("suffix", "dockerfile", "build-arg", "platforms", "status"))
    validate_tracks(
        data["tool-tracks"],
        "tool-tracks",
        ("track", "dockerfile", "base-image", "base-suffix", "platforms", "status"),
    )
    validate_tool_references(data)
    return data


def validate_tracks(tracks: list[dict[str, Any]], section: str, required: tuple[str, ...]) -> None:
    for index, track in enumerate(tracks):
        if not isinstance(track, dict):
            raise ValueError(f"{section}[{index}] must be a YAML mapping")
        for key in required:
            if key not in track:
                raise ValueError(f"{section}[{index}] is missing required key: {key}")
        status = str(track["status"])
        if status not in VALID_STATUSES:
            raise ValueError(
                f"{section}[{index}] has invalid status {status!r}; "
                f"expected one of {sorted(VALID_STATUSES)}"
            )


def live_tracks(tracks: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [track for track in tracks if track["status"] != "eol"]


def csv_set(value: str) -> set[str]:
    return {part.strip() for part in value.split(",") if part.strip()}


def validate_tool_references(config: dict[str, Any]) -> None:
    live_bases = {track["suffix"]: track for track in live_tracks(config["base-tracks"])}

    for track in live_tracks(config["tool-tracks"]):
        base_suffix = track["base-suffix"]
        if base_suffix not in live_bases:
            raise ValueError(
                f"tool track {track['track']!r} references base-suffix {base_suffix!r}, "
                f"which is not a live base track"
            )

        unsupported = sorted(csv_set(track["platforms"]) - csv_set(live_bases[base_suffix]["platforms"]))
        if unsupported:
            raise ValueError(
                f"tool track {track['track']!r} requests platforms not published by "
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
        return f"{self.title(track['dockerfile'])}:{version}-{track['suffix']}"

    def tool_tag(self, track: dict[str, Any], version: str) -> str:
        suffix = str(track.get("tag-suffix", "")).strip()
        tag = f"{version}-{suffix}" if suffix else version
        return f"{self.title(track['dockerfile'])}:{tag}"

    def tags(self, config: dict[str, Any], version: str, git_sha: str = "", include_git_sha_tag: bool = False) -> list[str]:
        images: list[str] = []
        for track in live_tracks(config["base-tracks"]):
            images.append(self.base_tag(track, version))
        for track in live_tracks(config["tool-tracks"]):
            images.append(self.tool_tag(track, version))
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
    for track in live_tracks(tracks):
        run_command(
            [
                docker,
                "build",
                "--build-arg",
                track["build-arg"],
                "-f",
                track["dockerfile"],
                "-t",
                resolver.base_tag(track, version),
                ".",
            ],
            dry_run,
        )


def docker_build_tools(
    resolver: ImageResolver,
    config: dict[str, Any],
    docker: str,
    version: str,
    git_sha: str,
    build_dependencies: bool,
    dry_run: bool,
) -> None:
    base_by_suffix = {track["suffix"]: track for track in live_tracks(config["base-tracks"])}

    if build_dependencies:
        suffixes = {track["base-suffix"] for track in live_tracks(config["tool-tracks"])}
        docker_build_base(resolver, [base_by_suffix[suffix] for suffix in sorted(suffixes)], docker, version, dry_run)

    for track in live_tracks(config["tool-tracks"]):
        tag_args = ["-t", resolver.tool_tag(track, version)]
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
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("images", "build-base", "build-tools", "build-all"))
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
        docker_build_base(resolver, config["base-tracks"], args.docker, args.version, args.dry_run)
        return 0

    if args.command == "build-tools":
        docker_build_tools(
            resolver,
            config,
            args.docker,
            args.version,
            args.git_sha,
            args.build_dependencies,
            args.dry_run,
        )
        return 0

    docker_build_base(resolver, config["base-tracks"], args.docker, args.version, args.dry_run)
    docker_build_tools(resolver, config, args.docker, args.version, args.git_sha, False, args.dry_run)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
