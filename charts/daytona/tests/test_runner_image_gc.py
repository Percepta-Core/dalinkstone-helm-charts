"""Run with `python3 charts/daytona/tests/test_runner_image_gc.py` (Helm on PATH).

Renders the real image-GC DaemonSet, then runs one pass of its script against
a stub docker that records what it was asked to remove.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


CHART = Path(__file__).resolve().parents[1]
TEMPLATE = "templates/runner-image-gc-daemonset.yaml"
REG = "harbor.example/library"
REF_A = f"{REG}/daytona-{'a' * 64}:daytona"
REF_C = f"{REG}/daytona-{'c' * 64}:daytona"


def render(*set_args):
    with tempfile.TemporaryDirectory() as temp:
        chart = Path(temp) / "chart"
        shutil.copytree(CHART, chart)
        template = chart / TEMPLATE
        # Let Helm parse its own output and hand back only the DaemonSet as JSON.
        template.write_text(
            '{{ define "test.gc" }}' + template.read_text() + '{{ end }}\n'
            '{{ range (include "test.gc" . | splitList "\\n---\\n") }}'
            '{{ $doc := . | fromYaml }}{{ if eq ($doc.kind | toString) "DaemonSet" }}'
            '{{ $doc | toJson }}{{ end }}{{ end }}\n'
        )
        args = ["helm", "template", "test", str(chart), "--show-only", TEMPLATE]
        for s in set_args:
            args += ["--set", s]
        result = subprocess.run(args, text=True, capture_output=True)
        lines = [l for l in result.stdout.splitlines() if l.startswith("{")]
        return json.loads(lines[0]) if lines else None


class RunnerImageGcTest(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir)
        self.bin = self.dir / "bin"
        self.bin.mkdir()
        self.calls = self.dir / "calls"

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o755)

    def run_once(self, images):
        (self.dir / "images").write_text("".join(f"{i}\n" for i in images))
        self.stub("docker", f'case "$1" in images) cat {self.dir}/images;; '
                            f'*) echo "$@" >> {self.calls};; esac\n')
        # The loop never exits on its own; end it at its first sleep.
        self.stub("sleep", "kill $PPID\n")
        script = render()["spec"]["template"]["spec"]["containers"][0]["args"][0]
        env = {**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}"}
        subprocess.run(["sh", "-c", script], env=env, timeout=30)
        return self.calls.read_text().splitlines() if self.calls.exists() else []

    def test_untags_only_sources_of_finished_snapshots(self):
        calls = self.run_once([
            f"aaa {REF_A}",
            f"aaa {REG}/nexus-sandbox-agent:1",       # snapshot done: untag
            f"aaa {REG}/nexus-sandbox-agent:1-alias",  # every source tag goes
            f"bbb {REG}/nexus-sandbox-agent:2",       # pull in flight: keep
            f"ccc {REF_C}",                           # sandbox image: keep
            "ddd <none>:<none>",
            "eee docker.io/library/busybox:1.37",
        ])
        rmi = [c for c in calls if c.startswith("rmi ")]
        self.assertEqual(len(rmi), 1)
        self.assertEqual(
            sorted(rmi[0].split()[1:]),
            [f"{REG}/nexus-sandbox-agent:1", f"{REG}/nexus-sandbox-agent:1-alias"],
        )
        self.assertIn("image prune -f", calls)

    def test_nothing_to_untag_runs_no_rmi(self):
        calls = self.run_once([f"ccc {REF_C}", f"bbb {REG}/nexus-sandbox-agent:2"])
        self.assertEqual([c for c in calls if c.startswith("rmi")], [])

    def test_skipped_without_docker_runtime(self):
        self.assertIsNone(render("services.runner.env.CONTAINER_RUNTIME=containerd"))
        self.assertIsNone(render("services.runnerImageGc.enabled=false"))


if __name__ == "__main__":
    unittest.main()
