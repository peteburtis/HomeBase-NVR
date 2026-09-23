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
import uuid
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
                    if getattr(self.server, "tag_live_fixture", False):
                        body += b"a=fmtp:96 packetization-mode=1;sprop-parameter-sets=Z0IAH5WoFAFuQA==,aM4G4g==\r\n"
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

    def terminal_cli(self, arguments, prompts):
        master, slave = pty.openpty()
        def controlling_terminal():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)
        process = subprocess.Popen([BINARY, *map(str, arguments)], stdin=slave, stdout=slave,
                                   stderr=slave, preexec_fn=controlling_terminal)
        os.close(slave)
        transcript, cursor = b"", 0
        try:
            for prompt, answer in prompts:
                deadline = time.monotonic() + 8
                while prompt not in transcript[cursor:]:
                    self.assertLess(time.monotonic(), deadline, repr(transcript))
                    if select.select([master], [], [], .1)[0]:
                        transcript += os.read(master, 4096)
                cursor = transcript.index(prompt, cursor) + len(prompt)
                os.write(master, answer)
            deadline = time.monotonic() + 8
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
            return process.wait(timeout=2), transcript
        finally:
            os.close(master)
            if process.poll() is None:
                process.kill(); process.wait(timeout=3)

    def test_s3_optional_encryption_prompt_hidden_confirmed_and_cancellable(self):
        directory, _ = self.agent()
        for password, confirmation in [(b"", b""), (b"only-test-encryption", b"only-test-encryption"), (b"only-test-encryption", b"different-password")]:
            prompts = [(b"Choose 1...2", b"2\n"), (b"Store name [S3 recordings]:", b"\n"),
                       (b"Existing S3 bucket:", b"hbnvr-no-network-test\n"), (b"AWS region", b"\n"),
                       (b"Object prefix", b"\n"), (b"Expected bucket owner", b"\n"),
                       (b"Shard duration", b"\n"), (b"Retention period", b"\n"),
                       (b"Choose 1...2", b"2\n"), (b"Enable recording", b"no\n"),
                       (b"Access key ID:", b"AKIAUNITTEST000000000\n"),
                       (b"Secret access key:", b"only-test-aws-secret\n"),
                       (b"Encryption password (optional; blank for none):", password + b"\n")]
            if password:
                prompts += [(b"Confirm encryption password:", confirmation + b"\n")]
            if password == confirmation:
                prompts += [(b"Validate access and save this S3 store?", b"no\n")]
            code, transcript = self.terminal_cli(["store", "add", "--runtime-dir", directory], prompts)
            self.assertEqual(code, 0 if password == confirmation else 1, repr(transcript))
            for secret in [b"only-test-encryption", b"only-test-aws-secret", b"different-password"]:
                self.assertNotIn(secret, transcript)
            self.assertFalse(list((directory / "stores").glob("*.json")))
            # Cancelling before validation must never contact AWS.
            self.assertNotIn(b"Validating S3 access", transcript)

    def test_offline_decrypt_cli_hidden_password_and_no_overwrite(self):
        encrypted = self.root / "download.mp4.hbnvr"
        encrypted.write_bytes(base64.b64decode("SEJOVlJFMDEACSfAAAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKisoturA7Czgie/kJ6LijBNu0L0hoXq28bZ3U0WDyuMJptqSwL4BlKlsNw9494LK8g=="))
        output = self.root / "recovered.mp4"
        for password, expected in [(b"incorrect-secret", 1), (b"independent test password", 0), (b"independent test password", 1)]:
            code, transcript = self.terminal_cli(["decrypt", encrypted, output], [(b"Recording encryption password:", password + b"\n")])
            self.assertEqual(code, expected, repr(transcript))
            self.assertNotIn(password, transcript)
            if password == b"incorrect-secret":
                self.assertFalse(output.exists())
            else:
                self.assertEqual(output.read_bytes(), b"independent synthetic recording")
                self.assertEqual(output.stat().st_mode & 0o777, 0o600)

    def test_encryption_aware_setup_refuses_legacy_agent(self):
        directory = self.root / "legacy"
        directory.mkdir(mode=0o700)
        operations = []
        config = dict(SchemaVersion=1, ID="AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", Name="Encrypted",
                      Type="S3", Enabled=False, Directory="", ShardDuration="1m", RetentionPeriod="1w",
                      OwnerUID=os.getuid(), OwnerUUID="BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                      S3=dict(Bucket="hbnvr-unit-test", Region="us-west-2", Prefix="test/", Lifecycle="External",
                              ClientEncryption=dict(Enabled=True)))
        class LegacyHandler(socketserver.StreamRequestHandler):
            def handle(self):
                request = json.loads(self.rfile.readline())
                operations.append(request["operation"])
                reply = dict(protocolVersion=1)
                if request["operation"] == "stores.list":
                    reply["stores"] = [config]
                else:
                    reply.update(error="Unknown operation. Reinstall if the agent is older.", code=7)
                self.wfile.write(json.dumps(reply).encode() + b"\n")
        server = socketserver.UnixStreamServer(str(directory / "control.sock"), LegacyHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        self.servers.append((server, thread))
        result = self.cli("store", "enable", "Encrypted", "--runtime-dir", directory, input="yes\n")
        self.assertEqual(result.returncode, 5, result.stderr)
        self.assertIn("does not support this S3 setup protocol", result.stderr)
        self.assertEqual(operations, ["stores.list", "stores.setup.start.v3"])

    def seed_s3_controls(self):
        directory = self.root / "run"
        directory.mkdir(mode=0o700)
        stores = directory / "stores"; stores.mkdir(mode=0o700)
        identity = subprocess.check_output(["/usr/bin/dsmemberutil", "getuuid", "-u", str(os.getuid())], text=True)
        owner_uuid = re.search(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}", identity).group(0)
        store_id = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        # No cameras, no backlog, External lifecycle; these tests never contact AWS.
        config = dict(SchemaVersion=1, ID=store_id, Name="Cloud fixture", Type="S3", Enabled=False,
                      Directory="", ShardDuration="1m", RetentionPeriod="1w", OwnerUID=os.getuid(), OwnerUUID=owner_uuid,
                      S3=dict(Bucket="hbnvr-no-network-test", Region="us-west-2", Prefix="test/", Lifecycle="External",
                              Credentials=dict(AccessKeyID="AKIAUNITTEST000000000", SecretAccessKey="private-fixture-secret-000000000000000000")))
        path = stores / (store_id + ".json"); path.write_text(json.dumps(config)); path.chmod(0o600)
        return directory, store_id, path

    def await_store(self, directory, predicate):
        deadline = time.monotonic() + 4
        while True:
            status = json.loads(self.cli("status", "--runtime-dir", directory, "--json").stdout)["status"]["stores"][0]
            if predicate(status):
                return status
            self.assertLess(time.monotonic(), deadline, status); time.sleep(.02)

    def test_spool_cli_picker_persistence_and_manual_release(self):
        directory, store_id, path = self.seed_s3_controls()
        _, process = self.agent()
        code, transcript = self.terminal_cli(["store", "spool", "--on", "--runtime-dir", directory],
                                             [(b"Choose a store", b""), (b"Choose 1...1", b"1\n")])
        self.assertEqual(code, 0, transcript)
        self.assertIn(b"Cloud fixture", transcript)
        status = self.await_store(directory, lambda s: "manual" in s.get("s3", {}).get("reasons", []))
        self.assertTrue(status["s3"]["spooling"]); self.assertNotIn("nextProbeSeconds", status["s3"])
        config = json.loads(path.read_text()); self.assertTrue(config["S3"]["Advanced"]["ForceSpooling"])
        self.assertEqual(config["SchemaVersion"], 4)
        # A legacy client must not erase the hold while editing unrelated options.
        legacy = json.loads(json.dumps(config)); legacy["SchemaVersion"] = 1
        del legacy["S3"]["Advanced"]["ForceSpooling"]
        rejected = self.camera_request(directory, "stores.setup.start.v2", store=legacy)
        self.assertEqual(rejected["code"], 5)
        self.assertTrue(json.loads(path.read_text())["S3"]["Advanced"]["ForceSpooling"])
        process.terminate(); process.wait(timeout=5); self.agent()
        self.await_store(directory, lambda s: "manual" in s.get("s3", {}).get("reasons", []))
        code, transcript = self.terminal_cli(["store", "spool", "--off", "--runtime-dir", directory], [(b"Choose 1...1", b"1\n")])
        self.assertEqual(code, 0, transcript)
        self.await_store(directory, lambda s: "s3" in s and not s["s3"]["spooling"])
        result = self.cli("store", "spool", store_id, "--off", "--runtime-dir", directory)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(json.loads(path.read_text())["S3"]["Advanced"]["ForceSpooling"])
        self.assertNotEqual(self.cli("store", "spool", store_id, "--runtime-dir", directory).returncode, 0)
        self.assertNotEqual(self.cli("store", "spool", store_id, "--on", "--off", "--runtime-dir", directory).returncode, 0)

    def test_advanced_store_editor_offline_validation_cancel_and_relocation(self):
        directory, store_id, path = self.seed_s3_controls(); self.agent()
        initial = json.loads(self.cli("store", "list", "--runtime-dir", directory, "--json").stdout)[0]
        target = self.root / "advanced-spool"; target.mkdir(mode=0o700)
        advanced = ["3", "1", "3", "30", "30", "2m", "600", "10", "2", "120", "10737418240", "2147483648", str(target), "yes"]
        def edit(values, confirm="yes"):
            return self.cli("store", "change", store_id, "--advanced", "--runtime-dir", directory,
                            input="\n".join([""] * 5 + values + ["no", confirm]) + "\n")
        before = path.read_bytes()
        cancelled = edit(advanced, "no"); self.assertEqual(cancelled.returncode, 0, cancelled.stderr)
        self.assertEqual(path.read_bytes(), before)
        invalid = advanced.copy(); invalid[1] = "3"
        self.assertNotEqual(edit(invalid).returncode, 0); self.assertEqual(path.read_bytes(), before)
        saved = edit(advanced); self.assertEqual(saved.returncode, 0, saved.stderr)
        self.assertNotIn("Validating S3", saved.stdout)
        self.assertNotIn("private-fixture-secret", saved.stdout + saved.stderr)
        config = json.loads(path.read_text())
        self.assertEqual(config["S3"]["Advanced"]["ProbeIntervalSeconds"], 120)
        # Configuration keeps the selected spelling; status reports its resolved path.
        self.assertEqual(config["S3"]["Advanced"]["SpoolDirectory"], str(target))
        self.assertTrue(config["S3"]["Advanced"]["ForceSpooling"])
        self.assertIn("SecretAccessKey", config["S3"]["Credentials"])
        self.assertFalse(config["Enabled"])
        self.await_store(directory, lambda s: s.get("s3", {}).get("spoolDirectory") == str(target.resolve()))
        current = json.loads(self.cli("store", "list", "--runtime-dir", directory, "--json").stdout)[0]
        self.assertNotIn("Credentials", current["S3"])
        # Stale edits and common-option changes cannot bypass setup validation.
        stale = self.camera_request(directory, "stores.advanced.change", store=current, storeOriginal=initial)
        self.assertIn("error", stale)
        edited = json.loads(json.dumps(current)); edited["Enabled"] = True
        self.assertIn("error", self.camera_request(directory, "stores.advanced.change", store=edited, storeOriginal=current))
        self.assertFalse(json.loads(path.read_text())["Enabled"])
        self.assertEqual(self.cli("status", "--runtime-dir", directory).returncode, 0)

    def test_unreadable_spool_rechecks_repair_without_restart_or_upload(self):
        directory, store_id, path = self.seed_s3_controls()
        config = json.loads(path.read_text())
        config["SchemaVersion"] = 4
        # ForceSpooling prevents network dispatch throughout this synthetic test.
        config["S3"]["Advanced"] = dict(ForceSpooling=True, ProbeIntervalSeconds=1)
        path.write_text(json.dumps(config))
        shard_id = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        spool = directory / "spool"; spool.mkdir(mode=0o700)
        store_spool = spool / store_id; store_spool.mkdir(mode=0o700)
        entry = store_spool / shard_id; entry.mkdir(mode=0o700)
        data = b"synthetic payload, never sent to AWS"
        payload = entry / "video.mp4"; payload.write_bytes(data); payload.chmod(0o600)
        marker = entry / "quarantined"
        marker.write_text("Shard rejected; manual inspection required.\n"); marker.chmod(0o600)
        manifest = entry / "metadata.json"; manifest.write_text("{"); manifest.chmod(0o600)
        self.agent()
        status = self.await_store(directory, lambda s: s.get("s3", {}).get("unreadableSpoolCount") == 1)
        self.assertEqual(status["s3"]["quarantinedCount"], 0)  # Retired protocol-v1 compatibility field.
        self.assertEqual(status["s3"]["active"], 0)
        self.assertIn("nextReadRetrySeconds", status["s3"])
        human = self.cli("status", "--runtime-dir", directory)
        self.assertIn("unreadable: 1", human.stdout)
        time.sleep(1.2)
        self.assertEqual(payload.read_bytes(), data); self.assertTrue(marker.exists())
        metadata = dict(schemaVersion=1, id=shard_id, storeID=store_id,
                        cameraID="CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC", bucket=config["S3"]["Bucket"],
                        region="us-west-2", prefix="test/", key="test/fixture.mp4", capturedAt=0,
                        size=len(data), sha256=hashlib.sha256(data).hexdigest())
        manifest.write_text(json.dumps(metadata))
        status = self.await_store(directory, lambda s: s.get("s3", {}).get("unreadableSpoolCount") == 0
                                  and s["s3"]["spoolCount"] == 1)
        self.assertEqual(status["s3"]["active"], 0); self.assertEqual(status["s3"]["confirmedUploads"], 0)
        self.assertTrue(marker.exists()); self.assertEqual(payload.read_bytes(), data)
        current = json.loads(self.cli("store", "list", "--runtime-dir", directory, "--json").stdout)[0]
        target = self.root / "new-spool"; target.mkdir(mode=0o700)
        edited = json.loads(json.dumps(current)); edited["S3"]["Advanced"]["SpoolDirectory"] = str(target)
        rejected = self.camera_request(directory, "stores.advanced.change", store=edited, storeOriginal=current)
        self.assertIn("Store is disabled", rejected["error"])
        self.assertIn("1 spooled entries", rejected["error"])
        self.assertTrue(payload.exists())

    def test_custom_spool_permission_diagnostic_reaches_status(self):
        directory, store_id, path = self.seed_s3_controls()
        target = self.root / "insecure-spool"; target.mkdir(mode=0o755); target.chmod(0o755)
        config = json.loads(path.read_text()); config["SchemaVersion"] = 3
        config["S3"]["Advanced"] = dict(SpoolDirectory=str(target))
        path.write_text(json.dumps(config))
        self.agent()
        status = self.await_store(directory, lambda s: s.get("lastError") is not None)
        message = status["lastError"]
        self.assertIn("Required: a directory (not a symbolic link)", message)
        self.assertIn("UID " + str(os.getuid()), message)
        self.assertIn("permissions 0700", message)
        self.assertIn("Found: directory", message)
        self.assertIn("permissions 0755", message)
        self.assertEqual(target.stat().st_mode & 0o777, 0o755)

    def test_custom_spool_status_and_missing_drive_startup_never_falls_back(self):
        directory, custom = self.root / "run", self.root / "custom-spool"
        directory.mkdir(mode=0o700); custom.mkdir(mode=0o700)
        stores = directory / "stores"; stores.mkdir(mode=0o700)
        identity = subprocess.check_output(["/usr/bin/dsmemberutil", "getuuid", "-u", str(os.getuid())], text=True)
        owner_uuid = re.search(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}", identity).group(0)
        store_id = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        # Disabled, empty, External lifecycle: opening this fixture cannot contact AWS.
        config = dict(SchemaVersion=3, ID=store_id, Name="Custom spool", Type="S3", Enabled=False,
                      Directory="", ShardDuration="1m", RetentionPeriod="1w", OwnerUID=os.getuid(), OwnerUUID=owner_uuid,
                      S3=dict(Bucket="hbnvr-no-network-test", Region="us-west-2", Prefix="test/", Lifecycle="External",
                              Advanced=dict(SpoolDirectory=str(custom))))
        config_path = stores / (store_id + ".json")
        config_path.write_text(json.dumps(config)); config_path.chmod(0o600)
        _, process = self.agent()
        deadline = time.monotonic() + 3
        while True:
            status = json.loads(self.cli("status", "--runtime-dir", directory, "--json").stdout)["status"]["stores"][0]
            if "s3" in status:
                break
            self.assertLess(time.monotonic(), deadline, status); time.sleep(.02)
        detail = status["s3"]
        self.assertEqual(detail["spoolDirectory"], str(custom.resolve()))
        self.assertGreater(detail["spoolVolumeCapacityBytes"], 0)
        self.assertGreater(detail["spoolVolumeAvailableBytes"], 0)
        self.assertEqual(detail["spoolLimitBytes"], 10 * 1024**3)
        self.assertEqual(detail["spoolMinimumFreeBytes"], 2 * 1024**3)
        self.assertFalse((directory / "spool" / store_id).exists())
        self.assertTrue((custom / ".hbnvr-store.json").exists())
        process.terminate(); process.wait(timeout=5)
        detached = self.root / "detached"; custom.rename(detached)
        _, process = self.agent()
        status = json.loads(self.cli("status", "--runtime-dir", directory, "--json").stdout)["status"]["stores"][0]
        self.assertEqual(status["state"], "error")
        self.assertFalse(custom.exists()); self.assertFalse((directory / "spool" / store_id).exists())
        self.assertTrue((detached / ".hbnvr-store.json").exists())
        process.terminate(); process.wait(timeout=5)
        detached.rename(custom)
        _, process = self.agent()
        status = json.loads(self.cli("status", "--runtime-dir", directory, "--json").stdout)["status"]["stores"][0]
        self.assertNotEqual(status["state"], "error", status)

    def test_local_store_cli_permissions_lifecycle_and_persistence(self):
        directory, process = self.agent()
        output = self.root / "recordings"
        args = ("store", "add", "--runtime-dir", directory)
        cancelled = self.cli(*args, input=f"1\n\n{output}\n\n\n\nno\n")
        self.assertEqual(cancelled.returncode, 0, cancelled.stderr)
        self.assertFalse(output.exists())
        self.assertIn("[~/NVR]", cancelled.stderr)
        self.assertIn("[1m]", cancelled.stderr)
        self.assertIn("[1w]", cancelled.stderr)
        added = self.cli(*args, input=f"1\nLocal test\n{output}\n1s\n1M\nyes\nyes\n")
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
        # Local agent is both requester and daemon: private POSIX ownership is
        # sufficient after removing setup ACLs, including across edit/restart.
        subprocess.run(["/bin/chmod", "-N", str(output)], check=True)
        self.assertNotEqual(self.cli("store", "spool", store_id, "--on", "--runtime-dir", directory).returncode, 0)
        for acl in [None, "group:everyone allow readattr,readsecurity"]:
            if acl:
                subprocess.run(["/bin/chmod", "+a", acl, str(output)], check=True)
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
        result = self.cli("store", "add", "--runtime-dir", directory, input=f"1\nTest\n{existing}\n1m\n1w\nyes\nyes\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(existing.stat().st_mode & 0o777, 0o755)
        invalid = self.root / "invalid"
        result = self.cli("store", "add", "--runtime-dir", directory, input=f"1\nTest\n{invalid}\n0m\n1w\nyes\nyes\n")
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

    def test_camera_controls_are_persistent_and_stop_keeps_receiver_alive(self):
        directory, process = self.agent()
        first, second = self.rtsp_fixture(), self.rtsp_fixture()
        camera_id = self.add_stream(directory, first, "First")
        self.add_stream(directory, second, "Second")
        self.await_streams(directory, lambda s: len(s) == 2 and all(x['frames'] >= 5 for x in s))
        def control(action, name=camera_id):
            result = self.cli('camera', action, name, '--runtime-dir', directory)
            self.assertEqual(result.returncode, 0, result.stderr)
            return result
        config_path = directory / 'cameras' / (camera_id + '.json')
        initial = json.loads(config_path.read_text())
        self.assertTrue(initial['Enabled']); self.assertTrue(initial['RecordingStarted'])
        connections = first.connections
        control('stop', 'First')
        stopped = self.await_streams(directory, lambda s: any(x['id'] == camera_id and x['recordingState'] == 'stopped' for x in s))
        count = next(x['frames'] for x in stopped if x['id'] == camera_id)
        self.await_streams(directory, lambda s: any(x['id'] == camera_id and x['frames'] > count + 5 for x in s))
        self.assertEqual(first.connections, connections)
        stamp = config_path.stat().st_mtime_ns
        control('stop')
        self.assertEqual(config_path.stat().st_mtime_ns, stamp)
        process.terminate(); process.wait(timeout=3)
        directory, process = self.agent()
        self.await_streams(directory, lambda s: len(s) == 2 and all(x['frames'] >= 5 for x in s)
                           and next(x for x in s if x['id'] == camera_id)['recordingState'] == 'stopped')
        control('disable')
        self.await_streams(directory, lambda s: next(x for x in s if x['id'] == camera_id)['state'] == 'disabled')
        self.assertNotEqual(self.cli('camera', 'start', camera_id, '--runtime-dir', directory).returncode, 0)
        control('stop')  # Allowed while disabled; intent remains independently configurable.
        control('enable')
        self.await_streams(directory, lambda s: any(x['id'] == camera_id and x['state'] == 'streaming' and not x['recordingStarted'] for x in s))
        connections = first.connections
        control('start')
        self.await_streams(directory, lambda s: any(x['id'] == camera_id and x['recordingState'] == 'waitingForStore' for x in s))
        self.assertEqual(first.connections, connections)
        # A failed persistence step must not change the running receiver's intent.
        (directory / 'cameras').chmod(0o500)
        try:
            self.assertNotEqual(self.cli('camera', 'stop', camera_id, '--runtime-dir', directory).returncode, 0)
            self.await_streams(directory, lambda s: any(x['id'] == camera_id and x['recordingStarted'] for x in s))
        finally:
            (directory / 'cameras').chmod(0o700)
        control('disable')
        process.terminate(); process.wait(timeout=3)
        connections = first.connections
        self.agent()
        self.await_streams(directory, lambda s: any(x['id'] == camera_id and x['state'] == 'disabled' and x['recordingStarted'] for x in s))
        self.assertEqual(first.connections, connections)
        control('enable')
        self.await_streams(directory, lambda s: any(x['id'] == camera_id and x['state'] == 'streaming' and x['recordingStarted'] for x in s))
        listing = self.cli('camera', 'list', '--runtime-dir', directory, '--json')
        self.assertEqual(len(json.loads(listing.stdout)), 2)
        self.assertNotIn('stream-secret', listing.stdout)
        self.assertNotIn('rtsp://', listing.stdout)

    def test_camera_selection_manual_change_and_edit_conflicts(self):
        directory, _ = self.agent()
        camera_id = self.add_stream(directory, self.rtsp_fixture(), 'Same')
        self.add_stream(directory, self.rtsp_fixture(), 'Same')
        for arguments in [('camera', 'stop'), ('camera', 'stop', 'Same'), ('camera', 'remove')]:
            result = self.cli(*arguments, '--runtime-dir', directory, input='')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('unambiguous', result.stderr)
        path = directory / 'cameras' / (camera_id + '.json')
        before = path.read_bytes()
        cancelled = self.cli('camera', 'change', camera_id, '--runtime-dir', directory, input='Unsaved\nno\n')
        self.assertEqual(cancelled.returncode, 0, cancelled.stderr)
        self.assertEqual(path.read_bytes(), before)
        options = self.camera_request(directory, 'cameras.options', cameraID=camera_id)['cameraOptions']
        self.assertNotIn('stream-secret', json.dumps(options))
        self.assertNotIn('rtsp://', json.dumps(options))
        self.camera_request(directory, 'cameras.stop', cameraID=camera_id)
        stale = dict(name='Stale', profileToken=None, revision=options['revision'])
        self.assertIn('error', self.camera_request(directory, 'cameras.change', cameraID=camera_id, cameraEdit=stale))
        self.camera_request(directory, 'cameras.disable', cameraID=camera_id)
        changed = self.cli('camera', 'change', camera_id, '--runtime-dir', directory, input='Renamed\nyes\n')
        self.assertEqual(changed.returncode, 0, changed.stderr)
        saved = json.loads(path.read_text())
        self.assertEqual(saved['Name'], 'Renamed')
        self.assertFalse(saved['Enabled']); self.assertFalse(saved['RecordingStarted'])
        self.assertEqual(saved['Credentials'], json.loads(before)['Credentials'])
        self.assertEqual(saved['RTSPURL'], json.loads(before)['RTSPURL'])
        before = path.read_bytes()
        options = self.camera_request(directory, 'cameras.options', cameraID=camera_id)['cameraOptions']
        for name, token in [('', None), ('Bad profile', 'invented')]:
            bad = dict(name=name, profileToken=token, revision=options['revision'])
            self.assertIn('error', self.camera_request(directory, 'cameras.change', cameraID=camera_id, cameraEdit=bad))
            self.assertEqual(path.read_bytes(), before)
        removed = self.cli('camera', 'remove', 'Renamed', '--runtime-dir', directory, input='yes\n')
        self.assertEqual(removed.returncode, 0, removed.stderr)
        self.assertFalse(path.exists())

    def test_camera_change_uses_daemon_credentials_and_preserves_controls(self):
        directory, _ = self.agent()
        homebase = self.homebase_fixture()
        result = self.cli('camera', 'add', '--runtime-dir', directory, '--homebase-dir', homebase, input='1\n1\nFront\n\nyes\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        camera_id = self.camera_request(directory, 'cameras.list')['cameras'][0]['id']
        self.camera_request(directory, 'cameras.disable', cameraID=camera_id)
        path = directory / 'cameras' / (camera_id + '.json')
        before = json.loads(path.read_text())
        result = self.cli('camera', 'change', camera_id, '--runtime-dir', directory, input='Front Door\n1\nyes\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('import-secret', result.stdout + result.stderr)
        saved = json.loads(path.read_text())
        self.assertEqual(saved['Name'], 'Front Door')
        self.assertEqual(saved['VideoProfile']['Token'], 'main')
        self.assertEqual(saved['RTSPURL'], 'rtsp://127.0.0.1:8554/stream/main?channel=1')
        self.assertEqual(saved['Credentials'], before['Credentials'])
        self.assertFalse(saved['Enabled']); self.assertTrue(saved['RecordingStarted'])
        preserved = path.read_bytes()
        self.servers[0][0].mode = 'unauthorized'
        result = self.cli('camera', 'change', camera_id, '--runtime-dir', directory, input='Nope\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(path.read_bytes(), preserved)
        self.assertNotIn('import-secret', result.stderr)
        self.assertEqual(set(self.servers[0][0].operations), {'GetDeviceInformation', 'GetCapabilities', 'GetProfiles', 'GetStreamUri'})

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
        cancelled = self.cli("remove", saved['id'], "--runtime-dir", directory, input="no\n")
        self.assertEqual(cancelled.returncode, 0, cancelled.stderr)
        self.assertTrue(path.exists())
        removed = self.cli("remove", saved['id'], "--runtime-dir", directory, input="yes\n")
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

    def media_open(self, directory):
        client = self.connect(directory)
        client.sendall(b'{"protocolVersion":1,"operation":"media.open","mediaProtocolVersion":1}\n')
        reply = b""
        while not reply.endswith(b"\n"):
            part = client.recv(1)
            self.assertTrue(part)
            reply += part
        info = json.loads(reply)["mediaSession"]
        self.assertEqual(info["version"], 1)
        self.assertTrue(info["supportsThumbnails"])
        self.assertEqual(info["thumbnailFormats"], ["image/jpeg"])
        self.assertEqual(info["maxThumbnailDimension"], 2048)
        self.assertEqual(info["segmentTagsVersion"], 1)
        return client

    def media_send(self, client, request):
        payload = json.dumps(request).encode()
        client.sendall(struct.pack("!BI", 1, len(payload)) + payload)

    def media_response(self, client):
        def exact(length):
            result = b""
            while len(result) < length:
                part = client.recv(length - len(result))
                self.assertTrue(part, "EOF is not a successful media response")
                result += part
            return result
        records = []
        while True:
            kind, length = struct.unpack("!BI", exact(5))
            self.assertGreater(length, 0); self.assertLessEqual(length, 65536)
            payload = exact(length)
            self.assertEqual(kind, 1)  # These smoke cases have no recorded media.
            record = json.loads(payload); records.append(record)
            if record["type"] == "end":
                return records

    def test_media_session_reuse_errors_and_command_isolation(self):
        directory, process = self.agent()
        request = dict(requestID="range-1", operation="availability", cameraID="11111111-1111-1111-1111-111111111111",
                       range=dict(start=100, end=110))
        with self.media_open(directory) as client:
            self.media_send(client, request)
            records = self.media_response(client)
            self.assertEqual([r["type"] for r in records], ["begin", "gap", "end"])
            self.assertEqual(records[-1]["outcome"], "unavailable")
            self.assertEqual(records[0]["timeline"], "canonical")
            self.assertEqual(self.cli("status", "--runtime-dir", directory).returncode, 0)
            self.media_send(client, dict(request, operation="neighbors"))
            neighbors = self.media_response(client)
            self.assertEqual([r["type"] for r in neighbors], ["begin", "neighbors", "end"])
            self.assertEqual(neighbors[1]["neighbors"], {})
            self.assertEqual(neighbors[-1]["outcome"], "complete")
            self.assertEqual(neighbors[-1]["frames"], 0)
            self.media_send(client, dict(request, operation="status"))
            self.assertEqual(self.media_response(client)[-1]["code"], 7)
            # Properly framed malformed JSON is a request error, not corruption
            # of the reusable connection. Arbitrary filenames cannot be requested.
            client.sendall(struct.pack("!BI", 1, 1) + b"{")
            self.assertEqual(self.media_response(client)[-1]["code"], 7)
            self.media_send(client, dict(request, cameraID="/etc/passwd"))
            self.assertEqual(self.media_response(client)[-1]["code"], 7)
            self.media_send(client, dict(request, operation="frames", relativeTo="now", range=dict(start=-45, end=-15)))
            records = self.media_response(client)
            self.assertLess(abs(records[0]["anchor"] - time.time()), 3)
            self.assertEqual(records[0]["range"]["start"], records[0]["anchor"] - 45)
            self.assertEqual(records[-1]["frames"], 0)
            process.terminate(); self.assertEqual(process.wait(timeout=3), 0)
            self.assertEqual(client.recv(1), b"")

    def test_thumbnail_point_validation_gaps_and_session_reuse(self):
        directory, _ = self.agent()
        request = dict(requestID="thumb", operation="thumbnail", cameraID="11111111-1111-1111-1111-111111111111",
                       timestamp=-30, relativeTo="now", size=dict(width=320, height=180))
        with self.media_open(directory) as client:
            for invalid in [dict(request, size=dict(width=0, height=180)), dict(request, timestamp=1),
                            dict(request, timeline="unknown"), dict(request, cameraID="/etc/passwd")]:
                self.media_send(client, invalid)
                self.assertEqual(self.media_response(client)[-1]["code"], 7)
            for timeline in ["canonical", "camera", "received"]:
                self.media_send(client, dict(request, timeline=timeline))
                records = self.media_response(client)
                self.assertEqual([r["type"] for r in records], ["begin", "end"])
                self.assertEqual(records[0]["timeline"], timeline)
                self.assertLess(abs(records[0]["anchor"] - time.time()), 3)
                self.assertEqual(records[0]["timestamp"], records[0]["anchor"] - 30)
                self.assertEqual(records[-1]["outcome"], "unavailable")
                self.assertEqual(records[-1]["frames"], 0)
            self.assertEqual(self.cli("status", "--runtime-dir", directory).returncode, 0)

    def test_media_limits_version_and_invalid_framing(self):
        directory, _ = self.agent()
        self.assertEqual(self.camera_request(directory, "media.open", mediaProtocolVersion=99)["code"], 5)
        clients = [self.media_open(directory) for _ in range(8)]
        try:
            self.assertEqual(self.camera_request(directory, "media.open", mediaProtocolVersion=1)["code"], 3)
            self.assertEqual(self.cli("status", "--runtime-dir", directory).returncode, 0)
        finally:
            for client in clients:
                client.close()
        time.sleep(.2)
        for kind, length in [(1, 0), (1, 65537), (2, 1)]:
            with self.media_open(directory) as client:
                client.sendall(struct.pack("!BI", kind, length))
                try:
                    self.assertEqual(client.recv(1), b"")
                except ConnectionResetError:
                    pass
        self.assertEqual(self.cli("status", "--runtime-dir", directory).returncode, 0)

    def test_media_live_anchor_survives_recording_stop_but_not_camera_disable(self):
        directory, _ = self.agent()
        camera = self.add_stream(directory, self.rtsp_fixture())
        self.await_streams(directory, lambda streams: streams and streams[0]["frames"] >= 5)
        request = dict(requestID="live", operation="availability", cameraID=camera,
                       relativeTo="live", range=dict(start=-45, end=-15))
        with self.media_open(directory) as client:
            self.media_send(client, request)
            records = self.media_response(client)
            self.assertLess(abs(records[0]["anchor"] - time.time()), 3)
            self.assertEqual(records[-1]["outcome"], "unavailable")  # live timing != retained footage
            self.camera_request(directory, "cameras.stop", cameraID=camera)
            self.media_send(client, request)
            self.assertEqual(self.media_response(client)[0]["type"], "begin")
            self.media_send(client, dict(request, timeline="camera"))
            self.assertEqual(self.media_response(client)[-1]["code"], 3)  # fixture has no RTCP mapping
            self.camera_request(directory, "cameras.disable", cameraID=camera)
            self.media_send(client, request)
            self.assertEqual(self.media_response(client)[-1]["code"], 3)

    def test_playback_catalog_subscription_and_recording_distinction(self):
        directory, process = self.agent()
        with self.connect(directory) as watch:
            watch.sendall(b'{"protocolVersion":1,"operation":"playback.watch"}\n')
            with watch.makefile("rb") as frames:
                def snapshot(predicate):
                    end = time.monotonic() + 10
                    while time.monotonic() < end:
                        reply = json.loads(frames.readline())
                        self.assertNotIn("error", reply)
                        value = reply["playbackSnapshot"]
                        if predicate(value):
                            return value
                    self.fail("No matching playback snapshot")
                initial = snapshot(lambda x: x["ready"])
                self.assertEqual(initial["stores"], [])
                self.assertEqual(initial["cameras"], [])
                self.assertEqual(initial["instanceID"], self.camera_request(directory, "cameras.snapshot")["cameraSnapshot"]["instanceID"])
                output = self.root / "playback"
                added = self.cli("store", "add", "--runtime-dir", directory,
                                 input=f"1\nPlayback test\n{output}\n1m\n1w\nyes\nyes\n")
                self.assertEqual(added.returncode, 0, added.stderr)
                current = snapshot(lambda x: x["ready"] and len(x["stores"]) == 1)
                store_id = current["stores"][0]["id"]
                self.assertEqual(current["stores"][0]["state"], "available")
                self.assertTrue(current["stores"][0]["frameReading"])
                camera = dict(SchemaVersion=1, Name="Discovery fixture", Provider="RTSP", IPAddress="192.0.2.1",
                              RTSPPort=554, HomebaseDeviceID="camera-fixture-serial",
                              Credentials=dict(SchemaVersion=1, Username="private-user", Password="private-password"))
                result = self.camera_request(directory, "cameras.add", camera=camera)
                self.assertNotIn("error", result, result)
                camera_id = result["camera"]["id"]
                current = snapshot(lambda x: x["ready"] and len(x["cameras"]) == 1)
                self.assertEqual(current["cameras"][0]["homebaseDeviceID"], "camera-fixture-serial")
                self.assertEqual(current["cameras"][0]["stores"],
                                 [dict(storeID=store_id, recordingEnabled=True, indexedHistory=False)])
                for secret in ["private-user", "private-password", "192.0.2.1", str(output)]:
                    self.assertNotIn(secret, json.dumps(current))
                self.camera_request(directory, "stores.disable", storeID=store_id)
                stopped = snapshot(lambda x: x["ready"] and not x["stores"][0]["enabled"])
                self.assertEqual(stopped["stores"][0]["state"], "available")
                self.assertFalse(stopped["cameras"][0]["stores"][0]["recordingEnabled"])
                self.assertGreater(stopped["revision"], current["revision"])
                self.camera_request(directory, "cameras.remove", cameraID=camera_id)
                snapshot(lambda x: x["ready"] and not x["cameras"])
                self.camera_request(directory, "stores.remove", storeID=store_id)
                empty = snapshot(lambda x: x["ready"] and not x["stores"])
                self.assertEqual(self.camera_request(directory, "playback.snapshot")["playbackSnapshot"], empty)
                self.assertEqual(self.cli("status", "--runtime-dir", directory).returncode, 0)
                process.terminate(); self.assertEqual(process.wait(timeout=3), 0)
                self.assertEqual(frames.readline(), b"")

    def test_playback_offline_volume_refresh_and_watch_limit(self):
        directory, process = self.agent()
        output = self.root / "playback-volume"
        result = self.cli("store", "add", "--runtime-dir", directory,
                          input=f"1\nPlayback volume\n{output}\n1m\n1w\nno\nyes\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        def await_state(state):
            end = time.monotonic() + 8
            while time.monotonic() < end:
                value = self.camera_request(directory, "playback.snapshot")["playbackSnapshot"]
                if value["ready"] and value["stores"][0]["state"] == state:
                    return value
                time.sleep(.05)
            self.fail(f"No {state} discovery: {value}")
        initial = await_state("available")
        watches = []
        try:
            for _ in range(8):
                watch = self.connect(directory); watches.append(watch)
                watch.sendall(b'{"protocolVersion":1,"operation":"playback.watch"}\n')
                self.assertIn("playbackSnapshot", json.loads(watch.recv(65536)))
            self.assertEqual(self.camera_request(directory, "playback.watch")["code"], 3)
            self.assertEqual(self.cli("status", "--runtime-dir", directory).returncode, 0)
            offline = self.root / "offline"
            output.rename(offline)
            missing = await_state("unavailable")
            self.assertEqual(missing["stores"][0]["id"], initial["stores"][0]["id"])
            offline.rename(output)
            await_state("available")
        finally:
            for watch in watches:
                watch.close()
        process.terminate(); self.assertEqual(process.wait(timeout=3), 0)
        self.agent()
        self.assertNotEqual(self.camera_request(directory, "playback.snapshot")["playbackSnapshot"]["instanceID"], initial["instanceID"])

    def test_camera_subscription_and_persistent_recording_commands(self):
        directory, process = self.agent()
        with self.connect(directory) as watch:
            watch.sendall(b'{"protocolVersion":1,"operation":"cameras.watch"}\n')
            with watch.makefile("rb") as frames:
                def snapshot():
                    reply = json.loads(frames.readline())
                    self.assertNotIn("error", reply)
                    return reply["cameraSnapshot"]
                initial = snapshot()
                self.assertEqual(initial["cameras"], [])
                # A long-lived observer must never hold up the ordinary IPC loop.
                self.assertEqual(self.cli("status", "--runtime-dir", directory).returncode, 0)
                camera = dict(SchemaVersion=1, Name="Arbitrary alias", Provider="RTSP", IPAddress="127.0.0.1",
                              RTSPPort=554, HomebaseDeviceID="camera-fixture-serial",
                              Credentials=dict(SchemaVersion=1, Username="viewer", Password="never-publish"))
                added = self.camera_request(directory, "cameras.add", camera=camera)
                self.assertNotIn("error", added, added)
                camera_id = added["camera"]["id"]
                current = snapshot()
                self.assertGreater(current["revision"], initial["revision"])
                self.assertEqual(current["cameras"], [dict(id=camera_id, homebaseDeviceID="camera-fixture-serial",
                                                         enabled=True, recordingStarted=True)])
                for secret in ["never-publish", "viewer", "127.0.0.1", "Arbitrary alias"]:
                    self.assertNotIn(secret, json.dumps(current))
                fields = dict(cameraID=camera_id, homebaseDeviceID="camera-fixture-serial",
                              nvrInstanceID=current["instanceID"], recordingStarted=False)
                result = self.camera_request(directory, "cameras.recording.set", **fields)
                self.assertNotIn("error", result, result)
                stopped = snapshot()
                self.assertFalse(stopped["cameras"][0]["recordingStarted"])
                self.assertEqual(result["cameraSnapshot"], stopped)
                path = directory / "cameras" / (camera_id + ".json")
                before = path.stat().st_ino
                result = self.camera_request(directory, "cameras.recording.set", **fields)
                self.assertEqual(result["cameraSnapshot"], stopped)
                self.assertEqual(path.stat().st_ino, before)  # No extra write for an idempotent set.
                self.assertFalse(json.loads(path.read_text())["RecordingStarted"])
                for bad in [dict(nvrInstanceID="old-instance"), dict(homebaseDeviceID="camera-other-serial"),
                            dict(recordingStarted=None)]:
                    result = self.camera_request(directory, "cameras.recording.set", **(fields | bad))
                    self.assertIn("error", result)
                self.camera_request(directory, "cameras.disable", cameraID=camera_id)
                disabled = snapshot()
                self.assertFalse(disabled["cameras"][0]["enabled"])
                self.assertIn("error", self.camera_request(directory, "cameras.recording.set", **fields))
                self.camera_request(directory, "cameras.enable", cameraID=camera_id)
                self.assertTrue(snapshot()["cameras"][0]["enabled"])
                self.camera_request(directory, "cameras.start", cameraID=camera_id)
                self.assertTrue(snapshot()["cameras"][0]["recordingStarted"])
                self.camera_request(directory, "cameras.remove", cameraID=camera_id)
                removed = snapshot()
                self.assertEqual(removed["cameras"], [])
                self.assertEqual(self.camera_request(directory, "cameras.snapshot")["cameraSnapshot"], removed)
                process.terminate()
                self.assertEqual(process.wait(timeout=3), 0)
                self.assertEqual(frames.readline(), b"")

    def test_historical_tag_cli_ipc_batch_and_restart_leave_live_tags_alone(self):
        directory, process = self.agent()
        output = self.root / "tagged-history"
        added = self.cli("store", "add", "--runtime-dir", directory,
                         input=f"1\nHistory tags\n{output}\n1m\n1w\nyes\nyes\n")
        self.assertEqual(added.returncode, 0, added.stderr)
        store_id = self.camera_request(directory, "stores.list")["stores"][0]["ID"]
        server = self.rtsp_fixture(); server.tag_live_fixture = True
        camera_id = self.add_stream(directory, server, "History Camera")
        self.await_streams(directory, lambda s: s and s[0]["frames"] >= 15)
        self.assertEqual(self.cli("camera", "stop", camera_id, "--runtime-dir", directory).returncode, 0)
        files = list(output.rglob("*.mp4"))
        self.assertEqual(len(files), 1)
        path = files[0].resolve()
        args = ("--runtime-dir", directory, "--store", store_id, "--file", path, "--all-frames")
        inspected = self.cli("media", "tag", "inspect", *args)
        self.assertEqual(inspected.returncode, 0, inspected.stderr)
        original = json.loads(inspected.stdout)[0]
        def playback_tags(expected):
            start = original["timing"]["time"]["canonicalUTC"]
            end = start + original["endTicks"] / original["timing"]["timescale"]
            with self.media_open(directory) as client:
                self.media_send(client, dict(requestID="tagged-history", operation="frames", cameraID=camera_id,
                                            range=dict(start=start, end=end), includeTags=True))
                def exact(count):
                    data = b""
                    while len(data) < count:
                        part = client.recv(count - len(data))
                        self.assertTrue(part, "unexpected EOF")
                        data += part
                    return data
                pending = 0
                tag_data = None
                frames = 0
                frame_count = None
                while True:
                    kind, count = struct.unpack("!BI", exact(5))
                    self.assertGreater(count, 0); self.assertLessEqual(count, 65536)
                    data = exact(count)
                    if kind == 2:
                        self.assertLessEqual(count, pending)
                        pending -= count
                        if tag_data is not None:
                            tag_data += data
                            if pending == 0:
                                self.assertEqual(json.loads(tag_data), {} if expected is None else {
                                    "person.alice": [dict(startFrame=0, endFrame=frame_count, value=expected)]})
                                tag_data = None
                        continue
                    self.assertEqual(kind, 1); self.assertEqual(pending, 0)
                    message = json.loads(data)
                    if message["type"] == "segment":
                        segment = message["segment"]
                        self.assertEqual(segment["tagRangesVersion"], 1)
                        pending = segment["tagByteCount"]; frame_count = segment["tagFrameCount"]
                        tag_data = b""
                    elif message["type"] == "frame":
                        self.assertNotIn("tags", message["frame"])
                        pending = message["frame"]["byteCount"]; frames += 1
                    elif message["type"] == "end":
                        self.assertEqual(message["outcome"], "complete", message)
                        self.assertGreater(frames, 0); self.assertEqual(frames, frame_count)
                        return
        snapshot = path.read_bytes()
        preview = self.cli("media", "tag", "set", *args, "--key", "person.alice", "--value", "present", "--dry-run")
        self.assertEqual(preview.returncode, 0, preview.stderr)
        self.assertEqual(path.read_bytes(), snapshot)
        result = self.cli("media", "tag", "set", *args, "--key", "person.alice", "--value", "present",
                          "--expected-revision", original["revision"])
        self.assertEqual(result.returncode, 0, result.stderr)
        status = json.loads(result.stdout)
        self.assertEqual(status["results"][0]["publication"], "local-complete")
        playback_tags("present")
        self.assertEqual(self.camera_request(directory, "cameras.tags.get", cameraID=camera_id)["tags"], {})
        stale = self.cli("media", "tag", "remove", *args, "--key", "person.alice", "--expected-revision", original["revision"])
        self.assertNotEqual(stale.returncode, 0)
        inspected = json.loads(self.cli("media", "tag", "inspect", *args).stdout)[0]
        self.assertEqual(inspected["tags"]["overrides"][0]["value"], "present")
        batch = dict(jobID=str(uuid.uuid4()).upper(), storeIDs=[store_id], edits=[dict(
            selection=dict(shardID=original["shardID"], sourceStoreID=store_id, allFrames=True), key="person.alice")])
        removed = self.cli("media", "tag", "apply", "-", "--runtime-dir", directory, input=json.dumps(batch))
        self.assertEqual(removed.returncode, 0, removed.stderr)
        retry = self.cli("media", "tag", "apply", "-", "--runtime-dir", directory, input=json.dumps(batch))
        self.assertEqual(retry.stdout, removed.stdout)
        poll = self.cli("media", "tag", "status", batch["jobID"], "--runtime-dir", directory)
        self.assertEqual(poll.returncode, 0, poll.stderr)
        process.terminate(); self.assertEqual(process.wait(timeout=8), 0)
        self.agent()
        restored = self.cli("media", "tag", "inspect", *args)
        self.assertEqual(restored.returncode, 0, restored.stderr)
        self.assertNotIn("value", json.loads(restored.stdout)[0]["tags"]["overrides"][0])
        playback_tags(None)
        self.assertEqual(self.camera_request(directory, "cameras.tags.get", cameraID=camera_id)["tags"], {})

    def test_live_tags_are_prospective_persistent_and_do_not_reconnect(self):
        directory, process = self.agent()
        server = self.rtsp_fixture(); server.tag_live_fixture = True
        port = server.server_address[1]
        camera = dict(SchemaVersion=1, Name="Tagged", Provider="RTSP", IPAddress="127.0.0.1", RTSPPort=port,
                      RTSPURL=f"rtsp://127.0.0.1:{port}/stream", HomebaseDeviceID="camera-tag-fixture",
                      VideoProfile=dict(Token="main", Encoding="H264", Width=1280, Height=720),
                      Credentials=dict(SchemaVersion=1, Username="viewer", Password="stream-secret"))
        added = self.camera_request(directory, "cameras.add", camera=camera)
        self.assertNotIn("error", added, added)
        camera_id = added["camera"]["id"]
        self.await_streams(directory, lambda s: s and s[0]["frames"] >= 5)
        snapshot = self.camera_request(directory, "cameras.snapshot")["cameraSnapshot"]
        self.assertEqual(snapshot["cameras"][0]["liveVideo"]["frameTagsVersion"], 1)
        connections = server.connections
        fields = dict(cameraID=camera_id, nvrInstanceID=snapshot["instanceID"], homebaseDeviceID="camera-tag-fixture")
        with self.connect(directory) as client:
            client.sendall(json.dumps(dict(protocolVersion=1, operation="live.open", liveProtocolVersion=1, **fields)).encode() + b"\n")
            with client.makefile("rb") as media:
                opened = json.loads(media.readline())
                self.assertNotIn("error", opened, opened)
                self.assertEqual(opened["liveSession"]["frameTagsVersion"], 1)
                def frame():
                    kind, length = struct.unpack("!BI", media.read(5))
                    self.assertEqual(kind, 1)
                    value = json.loads(media.read(length))
                    remaining = value["byteCount"]
                    while remaining:
                        kind, length = struct.unpack("!BI", media.read(5))
                        self.assertEqual(kind, 2)
                        self.assertEqual(len(media.read(length)), length)
                        remaining -= length
                    return value
                def await_tags(expected):
                    for _ in range(40):
                        value = frame()
                        if value["tags"] == expected:
                            return value
                    self.fail("Tag change did not reach the live stream")
                self.assertEqual(frame()["tags"], {})
                result = self.cli("camera", "tag", "set", camera_id, "--key", "opaque", "--value", "", "--runtime-dir", directory)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout), {"opaque": ""})
                first = await_tags({"opaque": ""})
                for _ in range(3):
                    self.assertEqual(frame()["tags"], {"opaque": ""})
                result = self.camera_request(directory, "cameras.tags.set", **fields, tagKey="opaque", tagValue="changed")
                self.assertEqual(result["tags"], {"opaque": "changed"})
                self.assertGreater(await_tags({"opaque": "changed"})["timestamp"], first["timestamp"])
                path = directory / "cameras" / (camera_id + ".json")
                inode = path.stat().st_ino
                self.camera_request(directory, "cameras.tags.set", **fields, tagKey="opaque", tagValue="changed")
                self.assertEqual(path.stat().st_ino, inode)
                self.camera_request(directory, "cameras.stop", cameraID=camera_id)
                self.camera_request(directory, "cameras.tags.set", **fields, tagKey="while-stopped", tagValue="yes")
                await_tags({"opaque": "changed", "while-stopped": "yes"})
                self.camera_request(directory, "cameras.tags.remove", **fields, tagKey="while-stopped")
                await_tags({"opaque": "changed"})
                self.assertFalse(self.camera_request(directory, "cameras.list")["cameras"][0]["recordingStarted"])
                # Mutation changes neither recording intent nor the RTSP source.
                self.assertEqual(server.connections, connections)
                stale = fields | dict(nvrInstanceID="stale")
                self.assertIn("error", self.camera_request(directory, "cameras.tags.remove", **stale, tagKey="opaque"))
                self.assertIn("error", self.camera_request(directory, "cameras.tags.set", **fields, tagKey="opaque", tagValue="x" * 2049))
                self.assertEqual(self.camera_request(directory, "cameras.tags.get", cameraID=camera_id)["tags"], {"opaque": "changed"})
        process.terminate(); self.assertEqual(process.wait(timeout=5), 0)
        directory, _ = self.agent()
        self.assertEqual(self.camera_request(directory, "cameras.tags.get", cameraID=camera_id)["tags"], {"opaque": "changed"})
        result = self.cli("camera", "tag", "remove", camera_id, "--key", "opaque", "--runtime-dir", directory)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {})
        self.assertEqual(self.camera_request(directory, "cameras.tags.remove", cameraID=camera_id, tagKey="opaque")["tags"], {})

    def test_camera_watch_limit_and_restart_epoch(self):
        directory, process = self.agent()
        watches = []
        try:
            for _ in range(8):
                watch = self.connect(directory); watches.append(watch)
                watch.sendall(b'{"protocolVersion":1,"operation":"cameras.watch"}\n')
                reply = json.loads(watch.recv(65536))
                self.assertIn("cameraSnapshot", reply)
            epoch = reply["cameraSnapshot"]["instanceID"]
            self.assertIn("error", self.camera_request(directory, "cameras.watch"))
            self.assertEqual(self.cli("status", "--runtime-dir", directory).returncode, 0)
            process.terminate(); self.assertEqual(process.wait(timeout=3), 0)
            directory, _ = self.agent()
            self.assertNotEqual(self.camera_request(directory, "cameras.snapshot")["cameraSnapshot"]["instanceID"], epoch)
        finally:
            for watch in watches:
                watch.close()

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
