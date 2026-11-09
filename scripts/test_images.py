"""Regression tests for the version-driven local and CI image inventory."""

import argparse
import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import yaml

import images_from_versions as images
import trivy_images as scans


ROOT = Path(__file__).resolve().parent.parent


class ImageTests(unittest.TestCase):
    def setUp(self):
        self.config = images.load_versions(ROOT / "versions.yml")
        self.resolver = images.ImageResolver(ROOT)

    def test_every_live_track_is_built_once(self):
        with patch.object(images, "run_command") as run:
            images.docker_build_base(self.resolver, self.config["base-tracks"], "docker", "test", True)
            images.docker_build_tools(self.resolver, self.config, "docker", "test", "", False, True)
        commands = [call.args[0] for call in run.call_args_list]
        expected = self.resolver.tags(self.config, "test")
        self.assertEqual([command[command.index("-t") + 1] for command in commands], expected)
        self.assertEqual(len(expected), 10)
        self.assertEqual(len(set(expected)), len(expected))
        for command in commands:
            self.assertIn("--pull", command)
            self.assertIn("--no-cache", command)
        self.assertEqual(self.config["tool-tracks"], [])
        self.assertFalse((ROOT / "init-tools.dockerfile").exists())

    def test_eol_tracks_are_skipped(self):
        self.config["base-tracks"][0]["status"] = "eol"
        with patch.object(images, "run_command") as run:
            images.docker_build_base(self.resolver, self.config["base-tracks"], "docker", "test", True)
        self.assertEqual(run.call_count, 9)
        self.assertEqual(len(self.resolver.tags(self.config, "test")), 9)

    def test_alpine_tags_include_upstream_and_release_versions(self):
        tracks = {
            track["suffix"]: track
            for track in images.live_tracks(self.config["base-tracks"])
        }
        for suffix, upstream in (("alpine322", "3.22"), ("alpine324", "3.24")):
            with self.subTest(track=suffix):
                self.assertTrue(tracks[suffix]["build-arg"].startswith(f"ALPINE_VERSION={upstream}."))
                self.assertEqual(
                    self.resolver.base_tag(tracks[suffix], "1.2.3"),
                    f"sg-alpine:{tracks[suffix]['image-version']}-cis1.2.3",
                )

    def test_tags_use_upstream_version_and_manifest_cis_version(self):
        tracks = {track["suffix"]: track for track in self.config["base-tracks"]}
        self.assertEqual(
            self.resolver.base_tag(tracks["rocky9"], "v1.0.1"),
            "sg-rockylinux:9.8-cis1.0.1",
        )
        self.assertEqual(
            self.resolver.base_tag(tracks["rocky10"], "v1.0.1"),
            "sg-rockylinux:10.2-cis1.0.1",
        )
        self.assertEqual(
            self.resolver.base_tag(tracks["jenkins-lts-alpine-jdk25"], "v1.0.1"),
            "sg-jenkins:2.589-alpine-jdk25-cis1.0.1",
        )
        for track in images.live_tracks(self.config["base-tracks"]):
            with self.subTest(track=track["suffix"]):
                self.assertEqual(
                    self.resolver.base_tag(track, "1.2.3"),
                    f"{self.resolver.title(track['dockerfile'])}:{track['image-version']}-cis1.2.3",
                )

    def test_cli_defaults_to_manifest_version(self):
        with (
            patch("sys.argv", ["images", "images"]),
            contextlib.redirect_stdout(io.StringIO()) as output,
            contextlib.chdir(ROOT),
        ):
            self.assertEqual(images.main(), 0)
        self.assertEqual(
            output.getvalue().splitlines(),
            self.resolver.tags(self.config, self.config["version"]),
        )
        make_output = subprocess.run(
            ["make", "-s", "list-images", f"PYTHON={sys.executable}"],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertEqual(make_output.stdout.splitlines(), output.getvalue().splitlines())

    def test_jenkins_make_target_uses_track_tag(self):
        for track in images.live_tracks(self.config["base-tracks"]):
            if track["dockerfile"] != "jenkins.dockerfile":
                continue
            with self.subTest(track=track["suffix"]):
                expected = self.resolver.base_tag(track, "1.2.3")
                result = subprocess.run(
                    [
                        "make", "-n", "test-jenkins", f"PYTHON={sys.executable}",
                        "VERSION=1.2.3", f"JENKINS_TRACK={track['suffix']}",
                    ],
                    cwd=ROOT, check=True, capture_output=True, text=True,
                )
                self.assertIn(f'-t "{expected}"', result.stdout)
                self.assertIn(f'bash scripts/test-jenkins.sh "{expected}"', result.stdout)

    def test_jenkins_build_and_release_scan_use_inventory_name(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/release.yml").read_text())
        gate = next(
            step for step in workflow["jobs"]["validate-jenkins"]["steps"]
            if step.get("name") == "Gate Jenkins image vulnerabilities"
        )
        for track in images.live_tracks(self.config["base-tracks"]):
            if track["dockerfile"] != "jenkins.dockerfile":
                continue
            with self.subTest(track=track["suffix"]):
                expected = self.resolver.base_tag(track, "1.2.3")
                scan_ref = gate["with"]["image-ref"].replace(
                    "${{ needs.prepare.outputs.version_no_v }}", "1.2.3",
                ).replace("${{ matrix.image_version }}", track["image-version"]).replace(
                    "${{ needs.prepare.outputs.tag_suffix }}", "",
                )
                self.assertEqual(scan_ref, expected)

    def test_release_matrices_include_every_live_track(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/release.yml").read_text())
        step = next(
            step for step in workflow["jobs"]["generate-matrix"]["steps"]
            if step.get("id") == "gen"
        )
        script = step["run"].split("\n", 1)[1].rsplit("PYEOF", 1)[0]
        with tempfile.NamedTemporaryFile() as output, patch.dict(
            os.environ, {"GITHUB_OUTPUT": output.name},
        ), contextlib.chdir(ROOT):
            exec(compile(script, "release.yml", "exec"), {})
            values = dict(line.split("=", 1) for line in Path(output.name).read_text().splitlines())
        base_matrix = json.loads(values["base-matrix"])["include"]
        scan_matrix = json.loads(values["scan-matrix"])["include"]
        live_tracks = images.live_tracks(self.config["base-tracks"])
        self.assertEqual(
            [track["track"] for track in base_matrix],
            [track["suffix"] for track in live_tracks],
        )
        self.assertEqual(
            [track["track"] for track in scan_matrix],
            [track["suffix"] for track in live_tracks],
        )
        for entry, track in zip(base_matrix, live_tracks):
            self.assertEqual(entry["image_version"], track["image-version"])
        for entry, track in zip(scan_matrix, live_tracks):
            self.assertEqual(entry["image_version"], track["image-version"])

    def test_release_metadata_uses_manifest_version_and_checks_pushed_tag(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/release.yml").read_text())
        prepare = workflow["jobs"]["prepare"]["steps"]
        step = next(step for step in prepare if step.get("name") == "Compute release metadata")
        script = step["run"].split("python3 - <<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]

        with tempfile.NamedTemporaryFile() as output, patch.dict(
            os.environ,
            {
                "GITHUB_EVENT_NAME": "push",
                "GITHUB_REF_TYPE": "tag",
                "GITHUB_REF_NAME": f"v{self.config['version']}",
                "GITHUB_REPOSITORY_OWNER": "Sarins-Lab",
                "GITHUB_OUTPUT": output.name,
            },
        ), contextlib.chdir(ROOT):
            exec(compile(script, "release.yml", "exec"), {})
            values = dict(line.split("=", 1) for line in Path(output.name).read_text().splitlines())
        self.assertEqual(values["version"], f"v{self.config['version']}")
        self.assertEqual(values["version_no_v"], self.config["version"])
        self.assertEqual(values["tag_suffix"], "")
        self.assertEqual(values["owner_lower"], "sarins-lab")

        with tempfile.NamedTemporaryFile() as output, patch.dict(
            os.environ,
            {
                "GITHUB_EVENT_NAME": "push",
                "GITHUB_REF_TYPE": "branch",
                "GITHUB_REF_NAME": "main",
                "GITHUB_REPOSITORY_OWNER": "Sarins-Lab",
                "GITHUB_OUTPUT": output.name,
            },
        ), contextlib.chdir(ROOT):
            exec(compile(script, "release.yml", "exec"), {})
            values = dict(line.split("=", 1) for line in Path(output.name).read_text().splitlines())
        self.assertEqual(values["tag_suffix"], "-dev")
        self.assertEqual(
            self.resolver.base_tag(
                next(track for track in self.config["base-tracks"] if track["suffix"] == "rocky9"),
                f"{values['version_no_v']}{values['tag_suffix']}",
            ),
            "sg-rockylinux:9.8-cis1.0.0-dev",
        )

        with tempfile.NamedTemporaryFile() as output, patch.dict(
            os.environ,
            {
                "GITHUB_EVENT_NAME": "pull_request",
                "GITHUB_REF_TYPE": "branch",
                "GITHUB_REF_NAME": "123/merge",
                "GITHUB_REPOSITORY_OWNER": "Sarins-Lab",
                "GITHUB_OUTPUT": output.name,
            },
        ), contextlib.chdir(ROOT):
            exec(compile(script, "release.yml", "exec"), {})
            values = dict(line.split("=", 1) for line in Path(output.name).read_text().splitlines())
        self.assertEqual(values["tag_suffix"], "")
        self.assertEqual(workflow["jobs"]["publish-base"]["if"], "github.event_name != 'pull_request'")

        with tempfile.NamedTemporaryFile() as output, patch.dict(
            os.environ,
            {
                "GITHUB_EVENT_NAME": "push",
                "GITHUB_REF_TYPE": "tag",
                "GITHUB_REF_NAME": "v9.9.9",
                "GITHUB_REPOSITORY_OWNER": "Sarins-Lab",
                "GITHUB_OUTPUT": output.name,
            },
        ), contextlib.chdir(ROOT), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            exec(compile(script, "release.yml", "exec"), {})

    def test_build_all_respects_flag_override(self):
        with (
            patch("sys.argv", ["images", "build-all", "--build-flags="]),
            patch.object(images, "run_command") as run,
            contextlib.chdir(ROOT),
        ):
            self.assertEqual(images.main(), 0)
        self.assertEqual(run.call_count, 10)
        for call in run.call_args_list:
            self.assertNotIn("--no-cache", call.args[0])
            self.assertNotIn("--pull", call.args[0])

    def test_workflow_matrices_match_local_inventory(self):
        for workflow, job, output_key in (
            ("release.yml", "generate-matrix", "scan-matrix"),
            ("security.yml", "generate-docker-matrix", "docker-matrix"),
        ):
            with self.subTest(workflow=workflow):
                config = yaml.safe_load((ROOT / ".github/workflows" / workflow).read_text())
                step = next(step for step in config["jobs"][job]["steps"] if step.get("id") == "gen")
                script = step["run"].split("\n", 1)[1].rsplit("PYEOF", 1)[0]
                with (
                    tempfile.NamedTemporaryFile() as output,
                    patch.dict(os.environ, {"GITHUB_OUTPUT": output.name}),
                    contextlib.chdir(ROOT),
                ):
                    exec(compile(script, workflow, "exec"), {})
                    values = dict(line.split("=", 1) for line in Path(output.name).read_text().splitlines())
                matrix = json.loads(values[output_key])["include"]
                expected_tracks = images.live_tracks(self.config["base-tracks"])
                self.assertEqual(
                    [entry["track"] for entry in matrix],
                    [entry["suffix"] for entry in expected_tracks],
                )
                if workflow == "release.yml":
                    self.assertEqual(values["has-tools"], "false")
                    self.assertEqual(json.loads(values["tools-matrix"])["include"], [])
                    jobs = config["jobs"]
                    self.assertIn("has-tools == 'true'", jobs["publish-tools"]["if"])
                    self.assertIn("has-tools == 'true'", jobs["validate-tools-pr"]["if"])
                    self.assertIn("needs.publish-tools.result == 'skipped'", jobs["scan"]["if"])
                    self.assertIn("always()", jobs["scan"]["if"])


class ScanTests(unittest.TestCase):
    def test_workflow_trivy_version_and_gates(self):
        for workflow, expected_scans in (("release.yml", 3), ("security.yml", 3)):
            with self.subTest(workflow=workflow):
                config = yaml.safe_load((ROOT / ".github/workflows" / workflow).read_text())
                steps = [
                    step
                    for job in config["jobs"].values()
                    for step in job.get("steps", [])
                    if step.get("uses", "").startswith("aquasecurity/trivy-action@")
                ]
                self.assertEqual(len(steps), expected_scans)
                for step in steps:
                    inputs = step["with"]
                    self.assertEqual(inputs["version"], "v0.76.2")
                    self.assertEqual(inputs["severity"], "HIGH,CRITICAL")
                    self.assertTrue(inputs["ignore-unfixed"])
                    self.assertEqual(inputs["trivyignores"], ".trivyignore")
                    if inputs.get("format") == "table":
                        self.assertEqual(inputs["exit-code"], "1")

    def test_inventory_defaults(self):
        with patch("sys.argv", ["trivy"]):
            args = scans.parse_args()
        self.assertIsNone(args.version)
        self.assertFalse(args.ignore_unfixed)
        self.assertEqual(args.ignore_file, "/dev/null")
        self.assertEqual(set(args.severity), set(scans.SEVERITY_ORDER))

    def test_makefile_boolean_arguments(self):
        for value, expected in (("false", False), ("true", True)):
            with patch("sys.argv", ["trivy", "--ignore-unfixed", value]):
                self.assertIs(scans.parse_args().ignore_unfixed, expected)
        with patch("sys.argv", ["trivy", "--ignore-unfixed"]):
            self.assertTrue(scans.parse_args().ignore_unfixed)
        with patch("sys.argv", ["trivy", "--include-unfixed"]):
            self.assertFalse(scans.parse_args().ignore_unfixed)
        with self.assertRaises(argparse.ArgumentTypeError):
            scans.parse_bool("invalid")

    def test_scan_command_does_not_hide_findings(self):
        with patch("sys.argv", ["trivy"]):
            args = scans.parse_args()
        result = unittest.mock.Mock(returncode=0, stderr="", stdout='{"Results": []}')
        with patch.object(scans.subprocess, "run", return_value=result) as run, contextlib.redirect_stdout(io.StringIO()):
            scans.run_trivy(args, "test:tag", scans.csv(args.severity), "vuln")
        command = run.call_args.args[0]
        self.assertNotIn("--ignore-unfixed", command)
        self.assertEqual(command[command.index("--ignorefile") + 1], "/dev/null")


if __name__ == "__main__":
    unittest.main()
