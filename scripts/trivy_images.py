#!/usr/bin/env python
"""Run local Trivy image scans and write human-readable Markdown reports."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from collections import Counter
from datetime import date, datetime
from pathlib import Path
from typing import Any

from images_from_versions import ImageResolver, load_versions


SEVERITY_ORDER = {"UNKNOWN": 0, "LOW": 1, "MEDIUM": 2, "HIGH": 3, "CRITICAL": 4}
TRIVYIGNORE_ENTRY_PATTERN = re.compile(r"^\s*(CVE-\d{4}-\d+)\b")
TRIVYIGNORE_EXPIRES_PATTERN = re.compile(r"\bexpires:\s*(\d{4}-\d{2}-\d{2})\b")


def parse_bool(value: str | bool) -> bool:
    if isinstance(value, bool):
        return value
    return value.strip().lower() in {"1", "true", "yes", "y", "on"}


def csv(value: list[str] | str) -> str:
    parts: list[str] = []
    values = value if isinstance(value, list) else [value]
    for item in values:
        for part in item.replace(",", " ").split():
            if part.strip():
                parts.append(part.strip())
    return ",".join(parts)


def safe_filename(value: str) -> str:
    return "".join(char if char.isalnum() or char in "._-" else "_" for char in value)


def markdown_cell(value: Any) -> str:
    if value is None:
        return "-"
    text = str(value).strip()
    if not text:
        return "-"
    return text.replace("\r", " ").replace("\n", " ").replace("|", "\\|")


def markdown_link(text: Any, url: Any) -> str:
    label = markdown_cell(text)
    if not url:
        return label
    return f"[{label}]({str(url).strip().replace(')', '%29')})"


def validate_trivyignore(ignore_file: str, today: date) -> None:
    path = Path(ignore_file)
    if not ignore_file or not path.exists():
        return

    errors: list[str] = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue

        entry = TRIVYIGNORE_ENTRY_PATTERN.match(stripped)
        if not entry:
            continue

        cve = entry.group(1)
        expires = TRIVYIGNORE_EXPIRES_PATTERN.search(line)
        if not expires:
            errors.append(f"{path}:{line_number}: {cve} is missing expires: YYYY-MM-DD")
            continue

        expires_text = expires.group(1)
        try:
            expires_on = date.fromisoformat(expires_text)
        except ValueError:
            errors.append(f"{path}:{line_number}: {cve} has invalid expiration date {expires_text!r}")
            continue

        if expires_on < today:
            errors.append(f"{path}:{line_number}: {cve} expired on {expires_on.isoformat()}")

    if errors:
        details = "\n".join(f"  - {error}" for error in errors)
        raise ValueError(f"Trivy ignore file has expired or invalid entries:\n{details}")


def finding_rows(scan: dict[str, Any], image: str) -> list[dict[str, Any]]:
    findings: list[dict[str, Any]] = []
    for result in scan.get("Results", []) or []:
        target = result.get("Target")
        result_type = result.get("Type")
        for vulnerability in result.get("Vulnerabilities", []) or []:
            severity = str(vulnerability.get("Severity") or "UNKNOWN").upper()
            findings.append(
                {
                    "Image": image,
                    "Target": target,
                    "Type": result_type,
                    "VulnerabilityID": vulnerability.get("VulnerabilityID"),
                    "Severity": severity,
                    "Package": vulnerability.get("PkgName"),
                    "InstalledVersion": vulnerability.get("InstalledVersion"),
                    "FixedVersion": vulnerability.get("FixedVersion"),
                    "Status": vulnerability.get("Status"),
                    "Title": vulnerability.get("Title"),
                    "PrimaryURL": vulnerability.get("PrimaryURL"),
                }
            )
    return findings


def severity_counts(findings: list[dict[str, Any]]) -> dict[str, int]:
    counter = Counter(finding.get("Severity") or "UNKNOWN" for finding in findings)
    return {severity: counter.get(severity, 0) for severity in ("CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN")}


def unique_cve_count(findings: list[dict[str, Any]]) -> int:
    return len({finding["VulnerabilityID"] for finding in findings if finding.get("VulnerabilityID")})


def sorted_findings(findings: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return sorted(
        findings,
        key=lambda finding: (
            finding["Image"],
            -SEVERITY_ORDER.get(finding["Severity"], 0),
            finding.get("VulnerabilityID") or "",
            finding.get("Package") or "",
            finding.get("Target") or "",
        ),
    )


def image_markdown(
    image: str,
    findings: list[dict[str, Any]],
    json_file: Path,
    severity: str,
    scanners: str,
    ignore_unfixed: bool,
    ignore_file: str,
    generated_at: str,
) -> str:
    counts = severity_counts(findings)
    lines = [
        "# Trivy CVE Report",
        "",
        f"- Image: `{image}`",
        f"- Generated: `{generated_at}`",
        f"- Severity filter: `{severity}`",
        f"- Scanners: `{scanners}`",
        f"- Unfixed findings: `{'excluded' if ignore_unfixed else 'included'}`",
        f"- Ignore file: `{ignore_file}`",
        f"- Raw JSON: `{json_file}`",
        "",
        "## Summary",
        "",
        "| Total findings | Unique CVEs | Critical | High | Medium | Low | Unknown |",
        "| ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
        (
            f"| {len(findings)} | {unique_cve_count(findings)} | {counts['CRITICAL']} | "
            f"{counts['HIGH']} | {counts['MEDIUM']} | {counts['LOW']} | {counts['UNKNOWN']} |"
        ),
        "",
    ]

    if not findings:
        lines.append("No vulnerabilities were reported.")
        return "\n".join(lines) + "\n"

    lines.extend(
        [
            "## Findings",
            "",
            "| Severity | CVE | Package | Installed | Fixed | Status | Target | Title |",
            "| --- | --- | --- | --- | --- | --- | --- | --- |",
        ]
    )
    for finding in sorted_findings(findings):
        lines.append(
            "| "
            f"{markdown_cell(finding['Severity'])} | "
            f"{markdown_link(finding['VulnerabilityID'], finding['PrimaryURL'])} | "
            f"{markdown_cell(finding['Package'])} | "
            f"{markdown_cell(finding['InstalledVersion'])} | "
            f"{markdown_cell(finding['FixedVersion'])} | "
            f"{markdown_cell(finding['Status'])} | "
            f"{markdown_cell(finding['Target'])} | "
            f"{markdown_cell(finding['Title'])} |"
        )
    return "\n".join(lines) + "\n"


def aggregate_markdown(
    images: list[str],
    findings: list[dict[str, Any]],
    severity: str,
    scanners: str,
    ignore_unfixed: bool,
    ignore_file: str,
    generated_at: str,
) -> str:
    counts = severity_counts(findings)
    lines = [
        "# Local Trivy CVE Report",
        "",
        f"- Generated: `{generated_at}`",
        f"- Images scanned: {len(images)}",
        f"- Severity filter: `{severity}`",
        f"- Scanners: `{scanners}`",
        f"- Unfixed findings: `{'excluded' if ignore_unfixed else 'included'}`",
        f"- Ignore file: `{ignore_file}`",
        "",
        "## Summary",
        "",
        "| Total findings | Unique CVEs | Critical | High | Medium | Low | Unknown |",
        "| ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
        (
            f"| {len(findings)} | {unique_cve_count(findings)} | {counts['CRITICAL']} | "
            f"{counts['HIGH']} | {counts['MEDIUM']} | {counts['LOW']} | {counts['UNKNOWN']} |"
        ),
        "",
        "## Images",
        "",
        "| Image | Total | Unique CVEs | Critical | High | Medium | Low | Unknown |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]

    for image in images:
        image_findings = [finding for finding in findings if finding["Image"] == image]
        image_counts = severity_counts(image_findings)
        lines.append(
            f"| `{markdown_cell(image)}` | {len(image_findings)} | {unique_cve_count(image_findings)} | "
            f"{image_counts['CRITICAL']} | {image_counts['HIGH']} | {image_counts['MEDIUM']} | "
            f"{image_counts['LOW']} | {image_counts['UNKNOWN']} |"
        )

    lines.append("")
    if not findings:
        lines.append("No vulnerabilities were reported.")
        return "\n".join(lines) + "\n"

    lines.extend(
        [
            "## All Findings",
            "",
            "| Image | Severity | CVE | Package | Installed | Fixed | Status | Target | Title |",
            "| --- | --- | --- | --- | --- | --- | --- | --- | --- |",
        ]
    )
    for finding in sorted_findings(findings):
        lines.append(
            "| "
            f"`{markdown_cell(finding['Image'])}` | "
            f"{markdown_cell(finding['Severity'])} | "
            f"{markdown_link(finding['VulnerabilityID'], finding['PrimaryURL'])} | "
            f"{markdown_cell(finding['Package'])} | "
            f"{markdown_cell(finding['InstalledVersion'])} | "
            f"{markdown_cell(finding['FixedVersion'])} | "
            f"{markdown_cell(finding['Status'])} | "
            f"{markdown_cell(finding['Target'])} | "
            f"{markdown_cell(finding['Title'])} |"
        )
    return "\n".join(lines) + "\n"


def run_trivy(args: argparse.Namespace, image: str, severity: str, scanners: str) -> dict[str, Any]:
    command = [
        args.trivy,
        "image",
        "--cache-dir",
        args.cache_dir,
        "--no-progress",
        "--skip-version-check",
        "--scanners",
        scanners,
        "--severity",
        severity,
        "--exit-code",
        "0",
        "--format",
        "json",
    ]
    if args.ignore_file:
        if Path(args.ignore_file).exists():
            command.extend(["--ignorefile", args.ignore_file])
        else:
            print(f"WARN: ignore file not found: {args.ignore_file}", file=sys.stderr)
    if args.ignore_unfixed:
        command.append("--ignore-unfixed")
    command.append(image)

    print(f"Scanning {image}")
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.stderr:
        print(result.stderr, file=sys.stderr, end="")
    if result.returncode != 0:
        raise RuntimeError(f"Trivy scan failed for {image} with exit code {result.returncode}")
    return json.loads(result.stdout or "{}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--versions-file", default="versions.yml")
    parser.add_argument("--version", default="1.0.0")
    parser.add_argument("--git-sha", default=os.environ.get("GIT_SHA", ""))
    parser.add_argument("--images", nargs="*")
    parser.add_argument("--trivy", default="trivy")
    parser.add_argument("--cache-dir", default=".trivy-cache")
    parser.add_argument("--results-dir", default=".trivy/results")
    parser.add_argument("--ignore-file", default=".trivyignore")
    parser.add_argument("--severity", nargs="*", default=["UNKNOWN", "LOW", "MEDIUM", "HIGH", "CRITICAL"])
    parser.add_argument("--scanners", nargs="*", default=["vuln"])
    parser.add_argument("--ignore-unfixed", dest="ignore_unfixed", action="store_true", default=True)
    parser.add_argument("--include-unfixed", dest="ignore_unfixed", action="store_false")
    parser.add_argument("--exit-code", type=int, default=0)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    severity = csv(args.severity)
    scanners = csv(args.scanners)
    if not severity:
        raise ValueError("No Trivy severities were provided")
    if not scanners:
        raise ValueError("No Trivy scanners were provided")

    now = datetime.now().astimezone()
    validate_trivyignore(args.ignore_file, now.date())

    if args.images:
        images = args.images
    else:
        config = load_versions(Path(args.versions_file))
        images = ImageResolver(Path.cwd()).tags(config, args.version, args.git_sha, False)

    if not images:
        raise ValueError("No images were provided for Trivy scanning")

    results_dir = Path(args.results_dir)
    results_dir.mkdir(parents=True, exist_ok=True)
    generated_at = now.strftime("%Y-%m-%d %H:%M:%S %z")

    all_findings: list[dict[str, Any]] = []
    for image in images:
        scan = run_trivy(args, image, severity, scanners)
        report_name = safe_filename(image)
        json_file = results_dir / f"{report_name}.raw.json"
        markdown_file = results_dir / f"{report_name}.md"
        json_file.write_text(json.dumps(scan, indent=2, sort_keys=True) + "\n", encoding="utf-8")

        findings = finding_rows(scan, image)
        all_findings.extend(findings)
        markdown_file.write_text(
            image_markdown(
                image,
                findings,
                json_file,
                severity,
                scanners,
                args.ignore_unfixed,
                args.ignore_file,
                generated_at,
            ),
            encoding="utf-8",
        )

        print(f"  {'clean' if not findings else f'findings: {len(findings)}'} -> {markdown_file}")

    aggregate_file = results_dir / "all-cves.md"
    aggregate_file.write_text(
        aggregate_markdown(images, all_findings, severity, scanners, args.ignore_unfixed, args.ignore_file, generated_at),
        encoding="utf-8",
    )
    print(f"Trivy Markdown reports written to {results_dir}")
    print(f"Aggregate CVE report -> {aggregate_file}")

    if all_findings and args.exit_code:
        return args.exit_code
    return 0


if __name__ == "__main__":
    try:
        exit_code = main()
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
    raise SystemExit(exit_code)
