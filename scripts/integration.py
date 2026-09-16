#!/usr/bin/env python3
"""Unprivileged, real subprocess/socket tests. Usage: python3 scripts/integration.py /path/to/hbnvr"""
import json
import base64
import hashlib
import http.server
import fcntl
import os
import pty
import select
from pathlib import Path
import signal
import socket
import socketserver
import struct
import re
import subprocess
import sys
import tempfile
import termios
import time
import threading
import unittest
import xml.etree.ElementTree as ET

BINARY = os.path.abspath(sys.argv.pop(1))

class CameraFixture(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        data = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        root = ET.fromstring(data)
        values = {node.tag.split("}")[-1]: node.text or "" for node in root.iter()}
        body = next(node for node in root.iter() if node.tag.endswith("}Body"))
        operation = list(body)[0].tag.split("}")[-1]
        self.server.operations.append(operation)
        self.server.paths.append(self.path)
        digest = base64.b64encode(hashlib.sha1(base64.b64decode(values["Nonce"]) +
                    values["Created"].encode() + b"import-secret").digest()).decode()
        if values["Username"] != "viewer" or values["Password"] != digest or self.server.mode == "unauthorized":
            self.send_response(401); self.end_headers(); return
        if self.server.mode == "redirect":
            self.send_response(302); self.send_header("Location", "http://127.0.0.1:1/never-contact"); self.end_headers(); return
        if self.server.mode == "oversize":
            self.send_response(200); self.send_header("Content-Length", "1048577"); self.end_headers(); return
        if operation == "GetDeviceInformation":
            self.server.identifications += 1
            serial = "replaced" if self.server.mode == "changed" and self.server.identifications > 1 else "serial"
            content = "<Manufacturer>FixtureVendor</Manufacturer><SerialNumber>" + serial + "</SerialNumber>"
        elif operation == "GetCapabilities":
            content = ("<Capabilities><Media><XAddr>http://203.0.113.9:" + str(self.server.server_port) +
                       "/onvif/media</XAddr></Media></Capabilities>")
        elif operation == "GetProfiles":
            def profile(token, width, height, bitrate):
                return ('<Profiles token="' + token + '"><VideoEncoderConfiguration><Encoding>H264</Encoding>' +
                        '<Resolution><Width>' + str(width) + '</Width><Height>' + str(height) + '</Height></Resolution>' +
                        '<RateControl><FrameRateLimit>15</FrameRateLimit><BitrateLimit>' + str(bitrate) +
                        '</BitrateLimit></RateControl></VideoEncoderConfiguration></Profiles>')
            content = profile("main", 1920, 1080, 2048) + profile("sub", 1280, 720, 768)
        elif operation == "GetStreamUri":
            content = ("<MediaUri><Uri>rtsp://embedded:do-not-store@0.0.0.0:9999/stream/" +
                       values["ProfileToken"] + "?channel=1</Uri></MediaUri>")
        else:
            self.send_response(400); self.end_headers(); return
        data = ('<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body><' + operation +
                'Response>' + content + '</' + operation + 'Response></s:Body></s:Envelope>').encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/soap+xml")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

class RTSPFixture(socketserver.StreamRequestHandler):
    """Synthetic encoded NALs: tests assembly/transport, not pixel decoding."""
    def handle(self):
        self.server.connections += 1
        self.lock = threading.Lock()
        done = threading.Event()
        writer = None

        def send(data):
            with self.lock:
                self.connection.sendall(data)

        def video():
            frames = 0
            try:
                while not done.wait(0.05):
                    if self.server.stall:
                        continue
                    frames += 1
                    nal = b"\x26\x01\x07" if self.server.codec == "H265" else b"\x65\x07\x08"
                    rtp = struct.pack("!BBHII", 0x80, 0xe0, frames % 65536, frames * 4500, 42) + nal
                    send(b"$\x00" + struct.pack("!H", len(rtp)) + rtp)
                    if self.server.drop_once and frames == 10:
                        self.server.drop_once = False
                        self.connection.shutdown(socket.SHUT_RDWR)
                        return
            except OSError:
                return

        try:
            while True:
                line = self.rfile.readline(65537)
                if not line:
                    break
                method, url, _ = line.decode().strip().split(" ")
                headers = {}
                while True:
                    line = self.rfile.readline(65537)
                    if line == b"\r\n" or not line:
                        break
                    key, value = line.decode().split(":", 1)
                    headers[key.lower()] = value.strip()
                self.server.methods.append(method)
                authorization = headers.get("authorization", "")
                authenticated = False
                if self.server.auth == "basic":
                    authenticated = authorization == "Basic " + base64.b64encode(b"viewer:stream-secret").decode()
                    challenge = 'Basic realm="fixture"'
                else:
                    fields = dict((key, quoted or plain) for key, quoted, plain in
                                  re.findall(r'(\w+)=(?:"([^"]*)"|([^, ]+))', authorization))
                    md5 = lambda value: hashlib.md5(value.encode()).hexdigest()
                    expected = md5(":".join([md5("viewer:fixture:stream-secret"), "fixture-nonce",
                                            fields.get("nc", ""), fields.get("cnonce", ""), "auth", md5(method + ":" + url)]))
                    authenticated = fields.get("response") == expected and fields.get("username") == "viewer" and fields.get("uri") == url
                    challenge = 'Digest realm="fixture", nonce="fixture-nonce", algorithm=MD5, qop="auth"'
                code = 200 if authenticated else 401
                body = b""
                extra = {}
                if not authenticated:
                    extra["WWW-Authenticate"] = challenge
                elif method == "DESCRIBE":
                    body = ("v=0\r\na=control:*\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 " + self.server.codec +
                            "/90000\r\na=control:track1\r\n").encode()
                    extra["Content-Base"] = url + "/"
                    extra["Content-Type"] = "application/sdp"
                elif method == "SETUP":
                    extra["Transport"] = "RTP/AVP/TCP;unicast;interleaved=0-1"
                    extra["Session"] = "fixture;timeout=2"
                response = f"RTSP/1.0 {code} Result\r\nCSeq: {headers['cseq']}\r\nContent-Length: {len(body)}\r\n"
                response += "".join(f"{key}: {value}\r\n" for key, value in extra.items()) + "\r\n"
                send(response.encode() + body)
                if authenticated and method == "PLAY" and writer is None:
                    writer = threading.Thread(target=video, daemon=True)
                    writer.start()
                if authenticated and method == "TEARDOWN":
                    break
        except (OSError, ValueError):
            pass
        finally:
            done.set()
            if writer:
                writer.join(timeout=1)

class Integration(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="hn-", dir="/tmp")
        self.root = Path(self.temp.name)
        self.children = []
        self.servers = []

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
        for server, thread in self.servers:
            server.shutdown(); server.server_close(); thread.join(timeout=2)

    def cli(self, *args, input=None):
        return subprocess.run([BINARY, *map(str, args)], input=input, capture_output=True, text=True, timeout=8)

    def camera_request(self, directory, operation, **fields):
        return self.request(directory, json.dumps(dict(protocolVersion=1, operation=operation, **fields)).encode() + b"\n")

    def test_local_store_cli_permissions_lifecycle_and_persistence(self):
        directory, process = self.agent()
        output = self.root / "recordings"
        args = ("store", "add", "--runtime-dir", directory)
        cancelled = self.cli(*args, input=f"\n{output}\n\n\n\nno\n")
        self.assertEqual(cancelled.returncode, 0, cancelled.stderr)
        self.assertFalse(output.exists())
        self.assertIn("[~/NVR]", cancelled.stderr)
        self.assertIn("[1m]", cancelled.stderr)
        self.assertIn("[1w]", cancelled.stderr)
        added = self.cli(*args, input=f"Local test\n{output}\n1s\n1M\nyes\nyes\n")
        self.assertEqual(added.returncode, 0, added.stderr)
        self.assertEqual(output.stat().st_mode & 0o777, 0o700)
        stores = json.loads(self.cli("store", "list", "--runtime-dir", directory, "--json").stdout)
        self.assertEqual(len(stores), 1)
        store = stores[0]
        self.assertEqual(store["Directory"], str(output.resolve()))
        self.assertEqual(store["ShardDuration"], "1s")
        self.assertEqual(store["RetentionPeriod"], "1M")
        self.assertTrue(store["Enabled"])
        store_id = store["ID"]
        for action in ["disable", "disable", "enable", "enable"]:
            result = self.cli("store", action, store_id, "--runtime-dir", directory)
            self.assertEqual(result.returncode, 0, result.stderr)
        changed = self.cli("store", "change", store_id, "--runtime-dir", directory, input="Renamed\n\n2s\n1w\nno\nyes\n")
        self.assertEqual(changed.returncode, 0, changed.stderr)
        process.terminate(); process.wait(timeout=4)
        self.agent()
        result = self.cli("status", "--runtime-dir", directory, "--json")
        status = json.loads(result.stdout)["status"]["stores"][0]
        self.assertEqual(status["name"], "Renamed")
        self.assertEqual(status["state"], "disabled")
        self.assertFalse(status["enabled"])
        result = self.cli("store", "remove", store_id, "--runtime-dir", directory, input="yes\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(output.exists())
        self.assertEqual(json.loads(self.cli("store", "list", "--runtime-dir", directory, "--json").stdout), [])

    def test_local_store_rejects_unsafe_directory_and_invalid_duration(self):
        directory, _ = self.agent()
        existing = self.root / "existing"
        existing.mkdir(mode=0o755)
        result = self.cli("store", "add", "--runtime-dir", directory, input=f"Test\n{existing}\n1m\n1w\nyes\nyes\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(existing.stat().st_mode & 0o777, 0o755)
        invalid = self.root / "invalid"
        result = self.cli("store", "add", "--runtime-dir", directory, input=f"Test\n{invalid}\n0m\n1w\nyes\nyes\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(invalid.exists())
        self.assertEqual(json.loads(self.cli("store", "list", "--runtime-dir", directory, "--json").stdout), [])

    def rtsp_fixture(self, codec="H264", auth="digest"):
        server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), RTSPFixture)
        server.daemon_threads = True
        server.codec = codec; server.auth = auth; server.connections = 0
        server.methods = []; server.drop_once = False; server.stall = False
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start(); self.servers.append((server, thread))
        return server

    def add_stream(self, directory, server, name="Fixture", password="stream-secret"):
        port = server.server_address[1]
        camera = dict(SchemaVersion=1, Name=name, Provider="RTSP", IPAddress="127.0.0.1", RTSPPort=port,
                      RTSPURL=f"rtsp://127.0.0.1:{port}/stream", Credentials=dict(SchemaVersion=1, Username="viewer", Password=password))
        reply = self.camera_request(directory, "cameras.add", camera=camera)
        self.assertNotIn("error", reply, reply)
        return reply["camera"]["id"]

    def await_streams(self, directory, predicate, timeout=8):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            result = self.cli("status", "--runtime-dir", directory, "--json")
            self.assertEqual(result.returncode, 0, result.stderr)
            streams = json.loads(result.stdout)["status"]["streams"]
            self.assertNotIn("stream-secret", result.stdout)
            self.assertNotIn("rtsp://", result.stdout)
            if predicate(streams):
                return streams
            time.sleep(0.1)
        self.fail(f"Timed out waiting for streams: {streams}")

    def test_streams_receive_discard_keepalive_remove_and_restart(self):
        directory, process = self.agent()
        first, second = self.rtsp_fixture(), self.rtsp_fixture(codec="H265", auth="basic")
        camera_id = self.add_stream(directory, first, "First")
        self.add_stream(directory, second, "Second")
        streams = self.await_streams(directory, lambda s: len(s) == 2 and all(x["frames"] >= 25 and x["receiveKbps"] > 0 for x in s))
        self.assertEqual({x["codec"] for x in streams}, {"H264", "H265"})
        self.assertTrue(all(x["state"] == "streaming" and x["mode"] == "discard" and x["droppedFrames"] == 0 for x in streams))
        self.assertGreaterEqual(first.methods.count("OPTIONS"), 3)  # auth retry plus keepalive
        files = {p.relative_to(directory): (p.stat().st_size, p.stat().st_mtime_ns) for p in directory.rglob("*") if p.is_file()}
        time.sleep(1)
        after = {p.relative_to(directory): (p.stat().st_size, p.stat().st_mtime_ns) for p in directory.rglob("*") if p.is_file()}
        self.assertEqual(files, after)
        self.assertEqual(len(files), 3)  # lock plus two camera configs; no media/statistics files
        self.assertIn("First: streaming", self.cli("status", "--runtime-dir", directory).stdout)
        self.camera_request(directory, "cameras.remove", cameraID=camera_id)
        self.await_streams(directory, lambda s: len(s) == 1 and s[0]["name"] == "Second")
        process.terminate(); process.wait(timeout=3)
        self.assertEqual(process.returncode, 0)
        self.assertIn("TEARDOWN", first.methods)
        self.assertIn("TEARDOWN", second.methods)
        self.agent()
        self.await_streams(directory, lambda s: len(s) == 1 and s[0]["frames"] >= 5)

    def test_stream_disconnect_reconnect_and_auth_failure_are_isolated(self):
        directory, process = self.agent()
        good, bad = self.rtsp_fixture(), self.rtsp_fixture()
        good.drop_once = True
        self.add_stream(directory, good, "Good")
        self.add_stream(directory, bad, "Bad", password="wrong")
        streams = self.await_streams(directory, lambda s: len(s) == 2 and any(x["name"] == "Good" and x["reconnects"] >= 1 and x["frames"] >= 20 for x in s))
        self.assertGreaterEqual(good.connections, 2)
        bad_status = next(x for x in streams if x["name"] == "Bad")
        self.assertEqual(bad_status["frames"], 0)
        self.assertIn("credentials", bad_status["lastError"])
        started = time.monotonic(); process.terminate(); process.wait(timeout=3)
        self.assertLess(time.monotonic() - started, 2.5)

    def test_stream_watchdog_reconnects_when_video_stalls(self):
        directory, _ = self.agent()
        server = self.rtsp_fixture(); server.stall = True
        self.add_stream(directory, server)
        self.await_streams(directory, lambda s: s and s[0]["state"] == "retrying" and "15 seconds" in s[0].get("lastError", ""), timeout=19)
        server.stall = False
        self.await_streams(directory, lambda s: s and s[0]["reconnects"] >= 1 and s[0]["frames"] > 0)

    def homebase_fixture(self):
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), CameraFixture)
        server.mode = "normal"; server.operations = []; server.paths = []; server.identifications = 0
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.servers.append((server, thread))
        root = self.root / "homebase"
        (root / "modules").mkdir(parents=True)
        (root / "credentials").mkdir()
        module = {"Cameras": [{"Provider": "ONVIF", "IPAddress": "127.0.0.1", "ONVIFPort": server.server_port,
                              "RTSPPort": 8554, "CredentialsPath": "credentials/front.json"}]}
        (root / "modules/cameras.json").write_text(json.dumps(module))
        (root / "aliases.json").write_text(json.dumps({"FrontCamera": "camera-fixturevendor-serial"}))
        credential = root / "credentials/front.json"
        credential.write_text(json.dumps({"SchemaVersion": 1, "Username": "viewer", "Password": "import-secret",
                                         "TapoUsername": "management", "TapoPassword": "never-import-this"}))
        credential.chmod(0o600)
        return root

    def test_camera_import_cancel_remove_and_persistence(self):
        directory, process = self.agent()
        homebase = self.homebase_fixture()
        original = (homebase / "credentials/front.json").read_bytes()
        args = ("add", "--runtime-dir", directory, "--homebase-dir", homebase)
        result = self.cli(*args, input="1\n1\nFront\n\nno\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.camera_request(directory, "cameras.list")["cameras"], [])
        result = self.cli(*args, input="1\n1\nFront\n\nyes\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Front Camera", result.stdout + result.stderr)
        self.assertIn("Video quality", result.stdout)
        self.assertNotIn("RTSP path or full URL", result.stderr)
        self.assertNotIn("front.json", result.stdout + result.stderr)
        self.assertNotIn("Camera name [front]", result.stdout + result.stderr)
        self.assertNotIn("import-secret", result.stdout + result.stderr)
        entries = self.camera_request(directory, "cameras.list")
        self.assertEqual(len(entries["cameras"]), 1)
        self.assertNotIn("import-secret", json.dumps(entries))
        saved = entries["cameras"][0]
        self.assertEqual(saved["onvifPort"], self.servers[0][0].server_port)
        path = directory / "cameras" / (saved["id"] + ".json")
        config = json.loads(path.read_text())
        self.assertEqual(config["Credentials"]["Password"], "import-secret")
        self.assertNotIn("TapoPassword", config["Credentials"])
        self.assertEqual(config["RTSPURL"], "rtsp://127.0.0.1:8554/stream/sub?channel=1")
        self.assertEqual(config["HomebaseDeviceID"], "camera-fixturevendor-serial")
        self.assertEqual(config["VideoProfile"]["Token"], "sub")
        self.assertEqual(config["VideoProfile"]["Height"], 720)
        self.assertNotIn("do-not-store", path.read_text())
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
        self.assertNotEqual(self.cli(*args, input="1\n1\nFront\n\nyes\n").returncode, 0)
        process.terminate(); process.wait(timeout=3)
        self.agent()
        self.assertEqual(self.camera_request(directory, "cameras.list")["cameras"][0]["id"], saved["id"])
        # Human edits are read on the next operation, with no generated cache.
        config["Name"] = "Renamed by hand"
        path.write_text(json.dumps(config))
        self.assertEqual(self.camera_request(directory, "cameras.list")["cameras"][0]["name"], "Renamed by hand")
        cancelled = self.cli("remove", "--runtime-dir", directory, input="1\nno\n")
        self.assertEqual(cancelled.returncode, 0, cancelled.stderr)
        self.assertTrue(path.exists())
        removed = self.cli("remove", "--runtime-dir", directory, input="1\nyes\n")
        self.assertEqual(removed.returncode, 0, removed.stderr)
        self.assertFalse(path.exists())
        self.assertEqual((homebase / "credentials/front.json").read_bytes(), original)
        self.assertEqual(set(self.servers[0][0].operations), {"GetDeviceInformation", "GetCapabilities", "GetProfiles", "GetStreamUri"})
        self.assertIn("/onvif/media", self.servers[0][0].paths)

    def test_onvif_failures_do_not_save_or_expose_credentials(self):
        directory, _ = self.agent()
        homebase = self.homebase_fixture()
        server = self.servers[0][0]
        for mode in ["unauthorized", "redirect", "oversize", "changed"]:
            server.mode = mode; server.identifications = 0
            result = self.cli("add", "--runtime-dir", directory, "--homebase-dir", homebase, input="1\n1\n")
            self.assertNotEqual(result.returncode, 0, mode)
            self.assertNotIn("import-secret", result.stdout + result.stderr)
            self.assertEqual(self.camera_request(directory, "cameras.list")["cameras"], [])
            if mode == "changed":
                self.assertIn("hardware changed", result.stderr)

    def test_import_default_name_explicit_quality_and_cancel(self):
        directory, _ = self.agent()
        homebase = self.homebase_fixture()
        args = ("add", "--runtime-dir", directory, "--homebase-dir", homebase)
        cancelled = self.cli(*args, input="1\n1\n\nq\n")
        self.assertNotEqual(cancelled.returncode, 0)
        self.assertEqual(self.camera_request(directory, "cameras.list")["cameras"], [])
        result = self.cli(*args, input="1\n1\n\n1\nyes\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        config = json.loads(next((directory / "cameras").glob("*.json")).read_text())
        self.assertEqual(config["Name"], "Front Camera")
        self.assertEqual(config["VideoProfile"]["Height"], 1080)
        self.assertIn("/stream/main?", config["RTSPURL"])

    def test_manual_rtsp_anonymous_and_eof(self):
        directory, _ = self.agent()
        homebase = self.homebase_fixture()
        args = ("add", "--runtime-dir", directory, "--homebase-dir", homebase)
        self.assertNotEqual(self.cli(*args, input="2\n").returncode, 0)
        self.assertEqual(self.camera_request(directory, "cameras.list")["cameras"], [])
        result = self.cli(*args, input="2\nGuest\ncamera.local\n554\n\n/stream1\nyes\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        config = json.loads(next((directory / "cameras").glob("*.json")).read_text())
        self.assertEqual(config["Provider"], "RTSP")
        self.assertNotIn("ONVIFPort", config)
        self.assertNotIn("Credentials", config)
        self.assertEqual(config["RTSPURL"], "rtsp://camera.local:554/stream1")

    def test_manual_password_is_not_echoed(self):
        directory, _ = self.agent()
        homebase = self.homebase_fixture()
        master, slave = pty.openpty()
        def controlling_terminal():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)
        process = subprocess.Popen([BINARY, "add", "--runtime-dir", str(directory), "--homebase-dir", str(homebase)],
                                   stdin=slave, stdout=slave, stderr=slave, preexec_fn=controlling_terminal)
        os.close(slave)
        transcript = b""
        try:
            prompts = [
                (b"Choose 1...2", b"2\n"), (b"Camera name:", b"Study\n"),
                (b"IP address or hostname", b"192.0.2.20\n"), (b"RTSP port [554]:", b"\n"),
                (b"Camera username", b"viewer\n"), (b"Camera password:", b"pty-secret-123\n"),
                (b"RTSP path or full URL", b"/stream1\n"), (b"Save this camera", b"yes\n")]
            for prompt, answer in prompts:
                deadline = time.monotonic() + 5
                while prompt not in transcript:
                    self.assertLess(time.monotonic(), deadline, repr(transcript))
                    if select.select([master], [], [], .1)[0]:
                        transcript += os.read(master, 4096)
                # Password prompt is printed after echo is disabled by readpassphrase.
                os.write(master, answer)
            deadline = time.monotonic() + 5
            # macOS may wait for terminal output to drain during process exit.
            while time.monotonic() < deadline:
                if not select.select([master], [], [], .1)[0]:
                    if process.poll() is not None:
                        break
                    continue
                try:
                    part = os.read(master, 4096)
                except OSError:
                    break
                if not part:
                    break
                transcript += part
            self.assertEqual(process.wait(timeout=2), 0, repr(transcript))
            self.assertNotIn(b"pty-secret-123", transcript)
            config = json.loads(next((directory / "cameras").glob("*.json")).read_text())
            self.assertEqual(config["Credentials"]["Password"], "pty-secret-123")
            self.assertNotIn("ONVIFPort", config)
        finally:
            os.close(master)
            if process.poll() is None:
                process.kill(); process.wait(timeout=3)

    def test_empty_or_missing_homebase_cameras_fall_back_to_manual(self):
        directory, _ = self.agent()
        homebase = self.homebase_fixture()
        module = homebase / "modules/cameras.json"
        for content in [None, '{"Cameras":[]}', 'not JSON']:
            if content is None:
                module.unlink()
            else:
                module.write_text(content)
            result = self.cli("add", "--runtime-dir", directory, "--homebase-dir", homebase,
                              input="1\nManual\ncamera.local\n554\n\n/live\nyes\n")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Import from Homebase", result.stdout)
            self.assertIn("Continuing with manual", result.stdout)
            camera = self.camera_request(directory, "cameras.list")["cameras"][0]
            self.camera_request(directory, "cameras.remove", cameraID=camera["id"])

    def test_invalid_camera_requests_and_import_fail_closed(self):
        directory, _ = self.agent()
        for fields in [{}, {"cameraID": "../outside"}]:
            result = self.camera_request(directory, "cameras.remove", **fields)
            self.assertEqual(result["code"], 7)
        self.assertEqual(self.camera_request(directory, "cameras.add")["code"], 7)
        homebase = self.homebase_fixture()
        (homebase / "credentials/front.json").chmod(0o644)
        result = self.cli("add", "--runtime-dir", directory, "--homebase-dir", homebase, input="1\n1\nFront\n")
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertNotIn("import-secret", result.stderr)
        self.assertEqual(self.camera_request(directory, "cameras.list")["cameras"], [])
        self.assertEqual(self.cli("status", "--runtime-dir", directory).returncode, 0)

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
