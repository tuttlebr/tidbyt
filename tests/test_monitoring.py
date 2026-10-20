"""Regression tests: loopback Prometheus fixtures and a fake Tidbyt uploader."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "prometheus-monitoring"
PIXLET = os.environ.get("PIXLET_BIN") or shutil.which("pixlet")


def vector(power="369.277", temperature="50", count="5"):
    return {
        "status": "success",
        "data": {
            "resultType": "vector",
            "result": [
                {"metric": {"kind": kind}, "value": [1700000000, value]}
                for kind, value in [
                    ("power", power), ("temperature", temperature), ("count", count)
                ]
                if value is not None
            ],
        },
    }


@unittest.skipUnless(PIXLET, "Set PIXLET_BIN or install Pixlet for renderer tests")
class RendererTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                cls.requests.append(self.path)
                self.send_response(cls.status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(cls.body)))
                self.end_headers()
                self.wfile.write(cls.body)

            def log_message(self, *args):
                pass

        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        type(self).requests = []

    def render(self, payload=None, status=200, raw=None, **config):
        type(self).status = status
        type(self).body = raw if raw is not None else json.dumps(payload).encode()
        output = Path(self.tmp.name) / "frame.webp"
        result = subprocess.run(
            [PIXLET, "render", str(APP / "prometheus-monitoring.star"),
             f"prometheus_url=http://127.0.0.1:{self.server.server_port}",
             *[f"{key}={value}" for key, value in config.items()],
             "--output", str(output)],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreater(output.stat().st_size, 0)
        return result.stdout, output.read_bytes()

    def test_healthy_uses_one_query_and_rounds_watts(self):
        log, _ = self.render(vector())
        self.assertIn("watts=369 temperature=50", log)
        self.assertEqual(len(self.requests), 1)

    def test_zero_watts_is_valid(self):
        log, _ = self.render(vector(power="0"))
        self.assertIn("watts=0", log)
        self.assertNotIn("unavailable", log)

    def test_missing_or_invalid_temperature_preserves_power(self):
        for value in [None, "NaN", "+Inf", "1e999", "bad", [], True]:
            with self.subTest(value=value):
                log, _ = self.render(vector(temperature=value))
                self.assertIn("watts=369 temperature=None", log)
        _, gray = self.render(vector(temperature=None))
        _, green = self.render(vector())
        self.assertNotEqual(gray, green)

    def test_invalid_power_renders_offline_image(self):
        _, offline = self.render(offline="true")
        for value in [None, "NaN", "+Inf", "-Inf", "1e999", "bad", "-1", [], True]:
            with self.subTest(value=value):
                log, image = self.render(vector(power=value))
                self.assertIn("telemetry unavailable", log)
                self.assertEqual(image, offline)

    def test_bad_responses_render_offline_image(self):
        _, offline = self.render(offline="true")
        for payload in [
            {}, [], None, {"status": "error"}, {"status": "success", "data": []},
            {"status": "success", "data": {"resultType": "vector", "result": []}},
            {"status": "success", "data": {"resultType": "vector", "result": [None]}},
        ]:
            with self.subTest(payload=payload):
                _, image = self.render(payload)
                self.assertEqual(image, offline)
        for status, raw in [(200, b"not json"), (503, b"unavailable")]:
            with self.subTest(status=status):
                _, image = self.render(status=status, raw=raw)
                self.assertEqual(image, offline)

    def test_expected_gpu_count_is_optional(self):
        log, _ = self.render(vector(count="4"))
        self.assertIn("watts=369", log)
        for count in ["4", "6"]:
            log, _ = self.render(vector(count=count), expected_gpu_count="5")
            self.assertIn("telemetry incomplete", log)
        log, _ = self.render(vector(), expected_gpu_count="5")
        self.assertIn("watts=369", log)

    def test_offline_render_does_not_query_prometheus(self):
        log, _ = self.render(offline="true")
        self.assertIn("telemetry unavailable", log)
        self.assertEqual(self.requests, [])


FAKE_PIXLET = r'''
import json, os, pathlib, sys, time
args = sys.argv[1:]
events = pathlib.Path(os.environ["TEST_EVENTS"])
def record(event):
    with events.open("a") as stream:
        stream.write(json.dumps(event) + "\n")
if args[0] == "render":
    offline = "offline=true" in args
    record({"command": "render", "offline": offline})
    output = pathlib.Path(args[args.index("--output") + 1])
    mode = os.environ.get("FAKE_RENDER_MODE", "")
    if mode == "hang_online" and not offline:
        time.sleep(60)
    if mode == "fail_all" or (mode == "fail_online" and not offline):
        output.write_text("partial-failed-render")
        sys.exit(1)
    if mode != "empty":
        output.write_text("offline" if offline else "fresh")
elif args[0] == "push":
    record({"command": "push", "image": pathlib.Path(args[2]).read_text()})
    mode = os.environ.get("FAKE_PUSH_MODE", "")
    if mode == "hang":
        time.sleep(60)
    if mode == "fail":
        sys.exit(1)
'''


class DaemonTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.script = self.root / "daemonize-push.sh"
        shutil.copy2(APP / "daemonize-push.sh", self.script)
        shutil.copy2(APP / "prometheus-monitoring.star", self.root)
        (self.root / "prometheus-monitoring.webp").write_text("stale")
        fake = self.root / "pixlet"
        fake.write_text(f"#!{sys.executable}\n" + FAKE_PIXLET)
        fake.chmod(0o755)
        self.events_path = self.root / "events.jsonl"
        self.log_path = self.root / "daemon.log"
        self.marker = self.root / "status" / "last-success"
        self.env = {
            "PATH": f"{self.root}:{os.defpath}",
            "DEVICE_ID": "dummy-device", "TIDBYT_API_TOKEN": "dummy-token",
            "TEST_EVENTS": str(self.events_path), "STATUS_DIR": str(self.marker.parent),
            "POLL_INTERVAL_SECONDS": "1", "RETRY_INTERVAL_SECONDS": "1",
            "COMMAND_TIMEOUT_SECONDS": "1",
        }
        self.process = None
        self.addCleanup(self.stop)

    def events(self):
        if not self.events_path.exists():
            return []
        rows = []
        for line in self.events_path.read_text().splitlines():
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                pass  # A child may still be writing the final line.
        return rows

    def logs(self):
        return self.log_path.read_text()

    def start(self, **overrides):
        self.env.update(overrides)
        self.log_stream = self.log_path.open("w")
        self.process = subprocess.Popen(
            [str(self.script)], env=self.env, stdout=self.log_stream,
            stderr=subprocess.STDOUT, start_new_session=True,
        )

    def stop(self):
        if self.process:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            finally:
                if self.process.poll() is None:
                    self.process.kill()
                    self.process.wait()
                self.log_stream.close()
            self.process = None

    def wait_for(self, predicate):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if predicate():
                return
            if self.process.poll() is not None:
                self.fail(f"Daemon exited early: {self.logs()}")
            time.sleep(0.02)
        self.fail(f"Timed out: {self.logs()}")

    def health(self):
        return subprocess.run(
            [str(self.script), "healthcheck"], env=self.env,
            capture_output=True, timeout=3,
        ).returncode

    def test_success_uploads_fresh_image_and_records_health(self):
        self.start()
        self.wait_for(self.marker.exists)
        self.stop()
        pushes = [e["image"] for e in self.events() if e["command"] == "push"]
        self.assertEqual(pushes, ["fresh"])
        self.assertEqual(self.health(), 0)
        for value in ["1", "invalid", str(int(time.time()) + 3600)]:
            self.marker.write_text(value + "\n")
            self.assertNotEqual(self.health(), 0)

    def test_failed_render_uploads_only_new_offline_frame(self):
        self.start(FAKE_RENDER_MODE="fail_online")
        self.wait_for(self.marker.exists)
        self.stop()
        pushes = [e["image"] for e in self.events() if e["command"] == "push"]
        self.assertEqual(pushes, ["offline"])

    def test_failed_fallback_never_uploads_old_or_partial_output(self):
        self.start(FAKE_RENDER_MODE="fail_all")
        self.wait_for(lambda: "No new frame available" in self.logs())
        self.stop()
        self.assertFalse(any(e["command"] == "push" for e in self.events()))
        self.assertFalse(self.marker.exists())

    def test_empty_successful_render_is_not_uploaded(self):
        self.start(FAKE_RENDER_MODE="empty")
        self.wait_for(lambda: "Render produced no image" in self.logs())
        self.stop()
        self.assertFalse(any(e["command"] == "push" for e in self.events()))

    def test_failed_push_retries_with_new_render_and_does_not_record_health(self):
        self.start(FAKE_PUSH_MODE="fail")
        self.wait_for(lambda: sum(e["command"] == "push" for e in self.events()) >= 2)
        self.stop()
        commands = [e["command"] for e in self.events()]
        self.assertEqual(commands[:4], ["render", "push", "render", "push"])
        self.assertFalse(self.marker.exists())
        self.assertNotEqual(self.health(), 0)

    def test_push_timeout_returns_control_to_loop(self):
        self.start(FAKE_PUSH_MODE="hang")
        self.wait_for(lambda: "upload failed or timed out" in self.logs())
        self.stop()
        self.assertFalse(self.marker.exists())

    def test_render_timeout_uses_offline_fallback(self):
        self.start(FAKE_RENDER_MODE="hang_online")
        self.wait_for(self.marker.exists)
        self.stop()
        pushes = [e["image"] for e in self.events() if e["command"] == "push"]
        self.assertEqual(pushes, ["offline"])

    def test_missing_credentials_and_invalid_intervals_fail_at_startup(self):
        for overrides in [
            {"DEVICE_ID": ""}, {"TIDBYT_API_TOKEN": ""},
            {"POLL_INTERVAL_SECONDS": "0"}, {"COMMAND_TIMEOUT_SECONDS": "bad"},
        ]:
            with self.subTest(overrides=overrides):
                result = subprocess.run(
                    [str(self.script)], env={**self.env, **overrides},
                    capture_output=True, text=True, timeout=3,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Configuration error", result.stdout)

    def test_sigterm_interrupts_sleep(self):
        self.start(POLL_INTERVAL_SECONDS="60")
        self.wait_for(lambda: "upload succeeded" in self.logs())
        start = time.monotonic()
        self.stop()
        self.assertLess(time.monotonic() - start, 2)


if __name__ == "__main__":
    unittest.main()
