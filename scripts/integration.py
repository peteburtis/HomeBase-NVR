#!/usr/bin/env python3
"""Unprivileged, real subprocess/socket tests. Usage: python3 scripts/integration.py /path/to/hbnvr"""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest

BINARY = os.path.abspath(sys.argv.pop(1))

class Integration(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="hn-", dir="/tmp")
        self.root = Path(self.temp.name)
        self.children = []

    def tearDown(self):
        for child in self.children:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=3)
            if child.stderr:
                child.stderr.close()
        self.temp.cleanup()

    def cli(self, *args):
        return subprocess.run([BINARY, *map(str, args)], capture_output=True, text=True, timeout=8)

    def agent(self, name="run"):
        directory = self.root / name
        process = subprocess.Popen([BINARY, "agent", "--runtime-dir", str(directory)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.children.append(process)
        end = time.monotonic() + 4
        while time.monotonic() < end:
            if process.poll() is not None:
                self.fail(process.stderr.read().decode())
            if (directory / "control.sock").exists():
                status = self.cli("status", "--runtime-dir", directory, "--json")
                if status.returncode == 0 and json.loads(status.stdout)["status"]["pid"] == process.pid:
                    return directory, process
            time.sleep(.02)
        self.fail("Agent failed to become ready")

    def connect(self, directory):
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(7)
        client.connect(str(directory / "control.sock"))
        return client

    def request(self, directory, data):
        with self.connect(directory) as client:
            client.sendall(data)
            response = b""
            while b"\n" not in response:
                part = client.recv(4096)
                if not part:
                    break
                response += part
            return json.loads(response)

    def test_status_and_shutdown(self):
        directory, process = self.agent()
        result = self.cli("status", "--runtime-dir", directory, "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        response = json.loads(result.stdout)
        self.assertTrue(response["status"]["ready"])
        self.assertEqual(response["status"]["pid"], process.pid)
        self.assertIn("hbnvr ready", self.cli("status", "--runtime-dir", directory).stdout)
        process.send_signal(signal.SIGINT)
        self.assertEqual(process.wait(timeout=3), 0)
        self.assertFalse((directory / "control.sock").exists())
        self.assertEqual(self.cli("status", "--runtime-dir", directory).returncode, 3)

    def test_duplicate_and_independent_agents(self):
        directory, process = self.agent()
        duplicate = self.cli("agent", "--runtime-dir", directory)
        self.assertNotEqual(duplicate.returncode, 0)
        self.assertIn("already holds", duplicate.stderr)
        second, other = self.agent("other")
        for path, expected in [(directory, process), (second, other)]:
            self.assertEqual(json.loads(self.cli("status", "--runtime-dir", path, "--json").stdout)["status"]["pid"], expected.pid)

    def test_stale_socket_recovered_after_crash(self):
        directory, process = self.agent()
        process.kill(); process.wait(timeout=3)
        self.assertTrue((directory / "control.sock").exists())
        _, replacement = self.agent()
        self.assertEqual(self.cli("status", "--runtime-dir", directory).returncode, 0)
        self.assertNotEqual(process.pid, replacement.pid)

    def test_protocol_validation(self):
        directory, _ = self.agent()
        cases = [(b"garbage\n", 7), (b'{"protocolVersion":2,"operation":"status"}\n', 5), (b'{"protocolVersion":1,"operation":"nope"}\n', 7), (b"x" * 65537 + b"\n", 7)]
        for data, code in cases:
            self.assertEqual(self.request(directory, data)["code"], code)
        self.assertEqual(self.cli("status", "--runtime-dir", directory).returncode, 0)

    def test_idle_client_deadline_and_shutdown(self):
        directory, process = self.agent()
        with self.connect(directory) as client:
            start = time.monotonic()
            self.assertEqual(json.loads(client.recv(4096))["code"], 6)
            self.assertLess(time.monotonic() - start, 6)
        with self.connect(directory):
            process.terminate()
            self.assertEqual(process.wait(timeout=2), 0)

    def test_client_deadline_against_unresponsive_server(self):
        directory = self.root / "fake"; directory.mkdir()
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
            listener.bind(str(directory / "control.sock")); listener.listen(1)
            start = time.monotonic()
            result = self.cli("status", "--runtime-dir", directory)
            self.assertEqual(result.returncode, 6, result.stderr)
            self.assertLess(time.monotonic() - start, 6)

    def test_cli_validation_and_privilege_requirements(self):
        self.assertIn("hbnvr", self.cli("--help").stdout)
        for command in ["install", "uninstall", "start", "stop"]:
            self.assertEqual(self.cli(command).returncode, 4)
            self.assertNotEqual(self.cli(command, "--runtime-dir", self.root).returncode, 0)
        self.assertNotEqual(self.cli("agent", "--system", "--runtime-dir", self.root).returncode, 0)
        self.assertEqual(self.cli("agent", "--system").returncode in (1, 4), True)

    def test_refuse_unsafe_runtime_and_socket(self):
        unsafe = self.root / "unsafe"; unsafe.mkdir(mode=0o755); unsafe.chmod(0o755)
        self.assertEqual(self.cli("agent", "--runtime-dir", unsafe).returncode, 4)
        private = self.root / "private"; private.mkdir(mode=0o700)
        (private / "control.sock").write_text("keep me")
        self.assertEqual(self.cli("agent", "--runtime-dir", private).returncode, 4)
        self.assertEqual((private / "control.sock").read_text(), "keep me")

if __name__ == "__main__":
    unittest.main(verbosity=2)
