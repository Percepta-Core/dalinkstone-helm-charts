"""Run with `python3 charts/daytona/tests/test_runner_reaper.py` (Helm on PATH).

Renders the real reaper CronJob, then runs its census and reaper scripts with
stub kubectl and psql, so no cluster or database is touched.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


CHART = Path(__file__).resolve().parents[1]
TEMPLATE = "templates/runner-reaper-cronjob.yaml"

GONE = "11111111-1111-1111-1111-111111111111"
STUCK = "22222222-2222-2222-2222-222222222222"
INSTALLING = "33333333-3333-3333-3333-333333333333"
FLAKY = "44444444-4444-4444-4444-444444444444"


class RunnerReaperTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        chart = Path(cls.temp.name) / "chart"
        shutil.copytree(CHART, chart)
        template = chart / TEMPLATE
        # Let Helm parse its own output and hand back only the CronJob as JSON.
        template.write_text(
            '{{ define "test.reaper" }}' + template.read_text() + '{{ end }}\n'
            '{{ range (include "test.reaper" . | splitList "\\n---\\n") }}'
            '{{ $doc := . | fromYaml }}{{ if eq ($doc.kind | toString) "CronJob" }}'
            '{{ $doc | toJson }}{{ end }}{{ end }}\n'
        )
        output = subprocess.check_output(
            ["helm", "template", "test", str(chart), "--show-only", TEMPLATE], text=True
        )
        cronjob = json.loads(next(line for line in output.splitlines() if line.startswith("{")))
        pod = cronjob["spec"]["jobTemplate"]["spec"]["template"]["spec"]
        cls.census = pod["initContainers"][0]["args"][0]
        cls.reaper = pod["containers"][0]["args"][0]

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir)
        self.bin = self.dir / "bin"
        self.bin.mkdir()
        self.shared = self.dir / "shared"
        self.shared.mkdir()

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o755)

    def run_script(self, script):
        script = script.replace("/shared/", f"{self.shared}/")
        env = {**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}", "NAMESPACE": "ns",
               "DB_HOST": "db", "DB_PORT": "5432", "DB_USERNAME": "u", "DB_DATABASE": "d"}
        return subprocess.run(["sh", "-c", script], env=env, text=True, capture_output=True)

    def reap(self, candidates, live_pods, placeholder_nodes, listening_nodes):
        (self.shared / "live-pods.txt").write_text("".join(f"{p}\n" for p in live_pods))
        (self.shared / "placeholder-nodes.txt").write_text(
            "".join(f"{p} {n}\n" for p, n in placeholder_nodes.items()))
        (self.shared / "listening-runner-nodes.txt").write_text(
            "".join(f"{n}\n" for n in listening_nodes))
        (self.dir / "candidates").write_text("\n".join(candidates))
        # SELECTs get the canned candidates; the delete transaction is recorded.
        self.stub("psql", f'sql=$(cat)\ncase "$sql" in *SELECT*) cat {self.dir}/candidates;; '
                          f'*) printf "%s\\n" "$sql" >> {self.dir}/deletes;; esac\n')
        result = self.run_script(self.reaper)
        deletes = self.dir / "deletes"
        return result, deletes.read_text() if deletes.exists() else ""

    def test_reaps_gone_nodes_and_undelivered_keys_only(self):
        result, deletes = self.reap(
            candidates=[
                f"{GONE}|node-placeholder-gone|checked-in",
                f"{STUCK}|node-placeholder-stuck|never-checked-in",
                f"{INSTALLING}|node-placeholder-installing|never-checked-in",
                f"{FLAKY}|node-placeholder-flaky|checked-in",
            ],
            live_pods=["node-placeholder-stuck", "node-placeholder-installing",
                       "node-placeholder-flaky", "daytona-runner-abcde"],
            placeholder_nodes={"node-placeholder-stuck": "node-a",
                               "node-placeholder-installing": "node-b",
                               "node-placeholder-flaky": "node-a"},
            listening_nodes=["node-a"],
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("its key was never delivered", result.stdout)
        delete_line = next(l for l in deletes.splitlines() if "DELETE FROM runner" in l)
        self.assertIn(GONE, delete_line)
        self.assertIn(STUCK, delete_line)
        # Still installing (runner not listening) and once-healthy runners stay.
        self.assertNotIn(INSTALLING, deletes)
        self.assertNotIn(FLAKY, deletes)

    def test_undelivered_key_waits_while_runner_is_not_listening(self):
        result, deletes = self.reap(
            candidates=[f"{INSTALLING}|node-placeholder-installing|never-checked-in"],
            live_pods=["node-placeholder-installing"],
            placeholder_nodes={"node-placeholder-installing": "node-b"},
            listening_nodes=[],
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(deletes, "")

    def test_refuses_to_reap_without_a_census(self):
        result, deletes = self.reap(
            candidates=[f"{GONE}|node-placeholder-gone|checked-in"],
            live_pods=[], placeholder_nodes={}, listening_nodes=[],
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(deletes, "")

    def test_census_lists_only_nodes_whose_runner_is_ready(self):
        self.stub("kubectl", 'case "$*" in\n'
                             '  *app=node-placeholder*) printf "node-placeholder-x node-a\\n";;\n'
                             '  *app=daytona-runner*) printf "node-a true\\nnode-b false\\nnode-c \\n";;\n'
                             '  *) printf "node-placeholder-x\\n";;\n'
                             'esac\n')
        result = self.run_script(self.census)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.shared / "listening-runner-nodes.txt").read_text(), "node-a\n")
        self.assertEqual((self.shared / "placeholder-nodes.txt").read_text(),
                         "node-placeholder-x node-a\n")


if __name__ == "__main__":
    unittest.main()
