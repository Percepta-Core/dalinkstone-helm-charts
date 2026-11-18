"""Run with `python3 charts/daytona/tests/test_runner_bootstrap.py` (Helm on PATH).

Helm's own YAML parser emits JSON for assertions; no Python dependencies.
All shell commands below use stubs, never the host's Docker or systemctl.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


CHART = Path(__file__).resolve().parents[1]


class RunnerBootstrapTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        cls.chart = Path(cls.temp.name) / "chart"
        shutil.copytree(CHART, cls.chart)
        template = cls.chart / "templates/runner-daemonset.yaml"
        # Exercise the actual template, then let Helm parse its YAML as an object.
        source = template.read_text()
        template.write_text(
            '{{ define "test.runner" }}' + source + '{{ end }}\n'
            '{{ include "test.runner" . | fromYaml | toJson }}\n'
        )

    def render(self, *values):
        command = ["helm", "template", "test", str(self.chart), "--show-only",
                   "templates/runner-daemonset.yaml"]
        for value in values:
            command.extend(["--set", value])
        output = subprocess.check_output(command, text=True)
        document = json.loads("\n".join(
            line for line in output.splitlines()
            if line and not line.startswith(("#", "---"))
        ))
        self.assertNotIn("Error", document)
        return document["spec"]["template"]["spec"]

    def test_installer_finishes_before_runner_and_monitor_start(self):
        pod = self.render("services.runner.registryProxy.enabled=true")
        self.assertEqual([c["name"] for c in pod["initContainers"]], ["docker-installer"])
        self.assertEqual([c["name"] for c in pod["containers"]],
                         ["registry-proxy", "docker-monitor", "runner"])
        installer = pod["initContainers"][0]
        self.assertNotIn("readinessProbe", installer)  # Invalid for ordinary init containers.
        self.assertNotIn("restartPolicy", installer)
        script = installer["args"][0]
        subprocess.run(["sh", "-n"], input=script, text=True, check=True)
        # Execute the real outer script with host setup stubbed. Success must
        # terminate; a failed host setup must prevent init completion.
        stub_dir = Path(self.temp.name) / "bin"
        stub_dir.mkdir(exist_ok=True)
        stub = stub_dir / "nsenter"
        stub.write_text('#!/bin/sh\ncat >/dev/null\nexit "$HOST_SETUP_STATUS"\n')
        stub.chmod(0o755)
        for status in (0, 1):
            with self.subTest(host_setup_status=status):
                result = subprocess.run(
                    ["sh", "-c", script], input="", text=True, capture_output=True,
                    timeout=5, env={**os.environ, "PATH": f"{stub_dir}:{os.environ['PATH']}",
                                    "HOST_SETUP_STATUS": str(status)},
                )
                self.assertEqual(result.returncode, status, result.stderr)

    def test_airgapped_packages_are_extracted_before_installation(self):
        pod = self.render("services.runner.dockerInstaller.airgapped.enabled=true")
        self.assertEqual([c["name"] for c in pod["initContainers"]],
                         ["extract-packages", "docker-installer"])

    def test_external_runtime_has_no_installer_or_monitor(self):
        pod = self.render("services.runner.dockerInstaller.enabled=false",
                          "services.runner.dockerInstaller.airgapped.enabled=true")
        self.assertNotIn("initContainers", pod)
        self.assertEqual([c["name"] for c in pod["containers"]], ["runner"])

    def test_monitor_requires_both_services(self):
        pod = self.render()
        monitor = next(c for c in pod["containers"] if c["name"] == "docker-monitor")
        probe = monitor["readinessProbe"]["exec"]["command"][-1]
        subprocess.run(["sh", "-n"], input=monitor["args"][0], text=True, check=True)
        for failed_service in ("sysbox", "docker", "neither"):
            with self.subTest(failed_service=failed_service):
                result = subprocess.run(
                    ["sh", "-c", 'systemctl() { [ "$3" != "$FAILED_SERVICE" ]; }; ' + probe],
                    env={**os.environ, "FAILED_SERVICE": failed_service},
                )
                self.assertEqual(result.returncode, 0 if failed_service == "neither" else 1)


if __name__ == "__main__":
    unittest.main()
