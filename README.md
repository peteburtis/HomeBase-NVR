# HomeBase-NVR / hbnvr

The foundation of an independent macOS NVR: a headless system LaunchDaemon,
authenticated Unix-socket control, and an unprivileged foreground development mode.
Interactive camera setup, direct ONVIF discovery, and one-time Homebase imports
are supported. Recording, buffering, S3, and ongoing Homebase synchronization
are not implemented yet.
Requires macOS 26.1 and Xcode 26.1 or newer.

## Build and test

Open `HomeBase-NVR.xcodeproj` and select the shared `HomeBase-NVR` scheme.
Run launches a local foreground agent; Stop in Xcode may leave a stale socket,
which the next agent recovers after obtaining its exclusive lock.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project HomeBase-NVR.xcodeproj -scheme HomeBase-NVR \
  -configuration Debug -derivedDataPath /tmp/hbnvr-build build
xcodebuild -project HomeBase-NVR.xcodeproj -scheme HomeBase-NVR \
  -destination 'platform=macOS' -derivedDataPath /tmp/hbnvr-build test
python3 scripts/integration.py /tmp/hbnvr-build/Build/Products/Debug/hbnvr
```

Swift ArgumentParser is pinned to 1.8.2. All other dependencies are system frameworks.
The test target compiles the shared implementation directly, avoiding a runtime
framework dependency in the deployed executable.

## Foreground development

```sh
# First terminal; creates a private runtime directory if needed.
/tmp/hbnvr-build/Build/Products/Debug/hbnvr agent --runtime-dir /tmp/hbnvr-dev

# Second terminal
/tmp/hbnvr-build/Build/Products/Debug/hbnvr status --runtime-dir /tmp/hbnvr-dev --json
```

Use Ctrl-C or SIGTERM to stop. No installation or sudo is needed. Without an override,
`agent` uses `~/Library/Caches/HomeBase-NVR/run`. Each runtime directory supports one
agent, and different directories support concurrent instances. Use a short absolute
path: macOS limits Unix socket paths to 103 UTF-8 bytes plus the terminating null.
Local directories must belong to the current user and have mode 0700.

Plain `status` targets the **system service**, so supply `--runtime-dir` to query a
development instance. A sandbox may still prohibit Unix socket operations; these
tests require a process environment that permits local IPC, but not root privileges.

## System installation

```sh
sudo /tmp/hbnvr-build/Build/Products/Debug/hbnvr install
sudo /usr/local/bin/hbnvr start
/usr/local/bin/hbnvr status
/usr/local/bin/hbnvr status --json
sudo /usr/local/bin/hbnvr stop
sudo /usr/local/bin/hbnvr uninstall
```

First installation identifies the controller through `SUDO_UID`. A direct-root shell
must use `install --owner USER`. Reinstallation preserves the original controller;
`--owner` cannot change it. Additional-controller management is deferred.

`install` creates a hidden `_hbnvr` user/group, root-owned executable and configuration,
and the following layout:

| Path | Purpose |
| --- | --- |
| `/usr/local/bin/hbnvr` | Single deployed executable |
| `/Library/LaunchDaemons/com.graygoolabs.hbnvr.plist` | System launchd job |
| `/Library/Application Support/HomeBase-NVR/authorization.json` | Root-owned controller UID and account UUID |
| `/Library/Application Support/HomeBase-NVR/private` | Service-owned private data (0700) |
| `/Library/Application Support/HomeBase-NVR/run` | Service-owned socket and process lock (0755) |

The installer extracts the plist from `__TEXT,__launchd_plist` in the executable.
No adjacent resource files are required. Installation requires secure root-owned
parent directories; it does not silently change permissions on existing directories.

New installations remain disabled. `start` enables boot startup and starts the service;
`stop` disables boot startup and stops it. Upgrades restart an enabled service and
preserve disabled state. Lifecycle commands require sudo and are serialized by a lock.
`start` and an installation that restarts the service wait for a successful authenticated
IPC status reply before reporting success. They allow up to 35 seconds, including
connection attempts, to accommodate launchd's restart throttle. An already-ready
service returns immediately. Permission and protocol failures are reported immediately;
a readiness timeout exits with code 6 and leaves launchd's configured state in place.
Failures are reported with launchctl diagnostics; rerunning install completes an
interrupted file deployment. Service-account provisioning preserves macOS-generated
UUIDs and reconciles the reserved `_hbnvr` user and group on every install. It repairs
the display name, shell, home directory, hidden flag, and primary-group membership,
including partial records and older settings. Existing UIDs, GIDs, and UUIDs are
preserved; identity collisions and invalid identities remain explicit errors.

Uninstall removes the executable and plist, but **preserves the service account,
authorization, private data, and runtime directory**. There is no purge command.

## Camera configuration

With the updated agent running, use these as the controller, **without sudo**:

    hbnvr add
    hbnvr remove

Add offers import when it detects Homebase's executable, user LaunchAgent, or the
selected configuration directory, even if Homebase has no cameras yet. With no
Homebase detected, it goes straight to manual entry. Missing, malformed, or empty
camera configuration explains the problem and falls back to manual setup.

### Homebase import: name and video quality

Import reads modules/cameras.json and the referenced camera credential files from
~/Library/Application Support/HomeBase (or --homebase-dir). HBNVR then contacts
the configured cameras **directly**, using authenticated, read-only ONVIF requests.
Homebase does not need to be installed or running if its configuration is available.
There is no Homebase CLI, IPC, remote-target preference, or new Homebase API involved.

The flow is:

1. Discover hardware identities and show a numbered list using Homebase names.
2. Select a camera.
3. Accept or change its name, defaulting to the Homebase display name.
4. Choose an actual advertised video profile (resolution, codec, frame rate, and
   bitrate when supplied). Enter defaults to the profile nearest 1280 x 720.
5. Confirm saving the independent HBNVR configuration and credential copy.

There is no stream-URL prompt on successful import. HBNVR obtains the chosen
profile's RTSP URL from the camera. It saves that URL and VideoProfile metadata.
The running agent immediately opens the saved stream in discard mode; no recording
is created and camera settings are not modified.

Hardware identity uses the same manufacturer/serial-number normalization and
escaping as Homebase. Names come from aliases.json and the optional DisplayName in
devices/<hardware-ID>.json or devices/<alias>.json; the hardware-named document
takes precedence, matching Homebase. Otherwise aliases are humanized using the
same word-boundary rules. Credential filenames are never camera names. Identity
is learned directly from the camera, not inferred by matching IP addresses against
another daemon's metadata. The old live-daemon adapter and proposed Homebase
inventory API are no longer needed for this import workflow.

Discovery uses ONVIF Media1 GetDeviceInformation, GetCapabilities, GetProfiles,
and GetStreamUri with WS-Security UsernameToken digests. It tries /onvif/service,
with /onvif/device_service as a 404 fallback. H.264 and H.265 profiles are supported.
Other discovery/authentication protocols remain future work. Initial identity
discovery uses up to four concurrent requests and a 12-second overall budget;
individual HTTP requests are capped at five seconds, responses at 1 MiB, and XML
depth/node counts are bounded. Redirects and external XML entities are refused.
Media service hosts and RTSP hosts are pinned to the configured camera address;
embedded RTSP username/password values are removed and the configured RTSP port
is retained. TLS verification is not disabled. HTTP ONVIF traffic is not encrypted,
so use this on a trusted camera network.

Unreachable cameras remain listed by address with an unavailable marker. Selecting
one reports the discovery error and saves nothing; it does not pretend an incomplete
import succeeded. A hardware identity change during setup also aborts. Neither
Homebase files nor the camera's settings are modified.

Only the camera Username/Password is copied, not Tapo management credentials.
Relative credential paths resolve from the selected Homebase configuration root;
absolute paths are supported. Credential files must be regular files owned by the
invoking user or root with no group/other access. Malformed or insecure credentials
fail closed. Import is a snapshot, not ongoing synchronization. Cameras with expiring
stream URLs may need runtime refresh using the saved profile token; this slice
does not implement that runtime behavior.

### Shared camera-options workflow: add and future change

Name and video profile are **camera options** in HBNVR. Import/discovery obtains
connection details and capabilities; it is separate from editing those options.
The imported add path now uses CameraOptionsUI and CameraOptionsEditor rather
than owning its own name/quality form.

A future change command should select an existing camera, load its saved
configuration, refresh capabilities directly from that camera, and invoke the
same editor. Add seeds the editor with Homebase's name and the nearest-720p
default; change seeds it with the saved name and profile. Existing profiles are
matched by token, not menu position. If a saved profile disappeared, the user
must explicitly choose its replacement. RTSP-only cameras without discoverable
profiles retain their supplied stream URL.

New options belong in this shared editor and its validation, so add and change
offer the same UX. The editor returns a validated draft: confirmation and saving
are separate. Cancellation or discovery/validation failure must leave saved
configuration untouched. Change must preserve the camera's stable HBNVR ID,
credentials, and unrelated options and must not reimport from Homebase.

These currently configure HBNVR's name and stream selection, not camera firmware
settings. Future options that write settings to physical cameras need explicit
semantics and must not take effect while merely editing a draft. The change
command and its authenticated update/persistence operation are **not implemented
in this increment**.

### Manual RTSP-only setup

Manual entry asks for name, IP/hostname, RTSP port (default 554), username, hidden
password, and a stream path or full URL. Leave username blank for an unauthenticated
camera. Password entry requires a terminal; passwords are not command-line arguments.
ONVIF is not required or contacted in manual mode. The supplied URL selects the
stream/quality; HBNVR does not discover or validate it in this path.

Supply /stream1 or a full rtsp:// or rtsps:// URL matching the entered host and port,
without username/password. A blank URL is allowed for manual configuration staging,
but it must be supplied before the agent can receive that camera's video.

Both add and remove confirm before changing saved configuration. Remove deletes
the selected HBNVR configuration **including its copied credentials**, not Homebase's.

For an isolated agent or a different Homebase configuration directory:

    hbnvr add --runtime-dir /tmp/hbnvr-dev --homebase-dir /path/to/HomeBase
    hbnvr remove --runtime-dir /tmp/hbnvr-dev

Reinstall after building 0.3.0 so the system agent also understands VideoProfile.
Local development needs no installation or sudo.

### Editable JSON

Each camera is a pretty-printed UUID.json file, with no database:

- Installed: /Library/Application Support/HomeBase-NVR/private/cameras/
- Local: the cameras/ subdirectory of the runtime directory.

Directories are 0700 and files 0600, owned by _hbnvr for the installed service or the
foreground agent's user locally. These are **plaintext secrets protected by filesystem
permissions**, not encrypted credential storage. One file makes configuration and
credentials an atomic unit. Camera lists and IPC replies omit usernames, passwords,
and stream URLs. Install/uninstall preserve these files.

Example imported camera (all credentials are placeholders):

~~~json
{
  "SchemaVersion": 1,
  "Name": "Hall Camera",
  "Provider": "ONVIF",
  "IPAddress": "192.0.2.10",
  "ONVIFPort": 2020,
  "RTSPPort": 554,
  "RTSPURL": "rtsp://192.0.2.10:554/stream2",
  "HomebaseDeviceID": "camera-acme-123",
  "VideoProfile": {
    "Token": "substream",
    "Encoding": "H264",
    "Width": 1280,
    "Height": 720,
    "FrameRate": 15,
    "BitrateKbps": 512
  },
  "Credentials": {
    "SchemaVersion": 1,
    "Username": "viewer",
    "Password": "replace-me"
  }
}
~~~

RTSPURL, Credentials, ONVIFPort, HomebaseDeviceID, and VideoProfile are optional
for backward compatibility and manual configurations. VideoProfile, when supplied,
requires RTSPURL; FrameRate and BitrateKbps are optional. Use Provider: "RTSP" for a
manual RTSP-only camera. All other example fields are required. Unknown fields in
other camera files are not rewritten by add/remove. UUID filenames are stable
identifiers; use uuidgen when adding files manually. This increment permits up to
64 cameras and 64 KiB per file, with one camera per case-insensitive host/RTSP-port pair.

Stop the agent before manual edits to avoid racing CLI operations. Preserve ownership
and permissions; system edits require admin access (editing as _hbnvr via sudo -u
_hbnvr avoids root-owned replacements). JSON is re-read for each camera operation;
invalid files are reported without overwriting them.

Tests use synthetic configuration, credentials, and a local ONVIF HTTP simulator.
They exercise hidden password entry, authentication, profile selection, address
pinning, cancellation, hardware changes, and persistence without touching real
Homebase files. Hardware smoke checks should use read-only discovery and cancel
before saving unless an actual import is intended.

## Continuous receive / discard mode (0.4.0)

Every running agent—system or local—opens **all configured camera streams**. Adding
a camera starts its receiver immediately; removing it closes the connection. Startup
loads the private JSON configurations independently of Homebase. Stop/restart after
manual edits. A missing RTSPURL is reported as `unconfigured` and makes no connection.

This increment consumes encoded H.264/H.265 video over RTSP interleaved TCP. It
assembles complete RTP access units in bounded memory and then discards them; it
does **not** decode pixels, save recordings, buffer a recording history, upload to
S3, or perform motion detection. Continuous receiving still consumes camera/LAN
bandwidth even though nothing is recorded. Audio tracks and UDP transport are not
requested. There is no ffmpeg or Homebase-process dependency.

RTSP supports Basic and MD5/MD5-sess Digest authentication (no qop or qop=auth).
`rtsps://` uses verified TLS; certificate validation is never bypassed. Ordinary
`rtsp://` is unencrypted, including Basic credentials: use a trusted camera network.
Advertised control URLs are pinned to the configured camera's host/port/scheme.

Each camera has an independent connection/retry loop. Connection and RTSP request
deadlines are ten seconds; no complete video for fifteen seconds triggers a
reconnect. Retry delays increase from 1 to 30 seconds and reset after 30 seconds of
healthy video. Session keepalives honor the advertised timeout. A broken camera
does not prevent other streams or IPC from working. Shutdown closes connections
within a bounded interval, attempting TEARDOWN first.

```sh
hbnvr status
hbnvr status --json
```

Status shows each camera's state, cumulative complete frames, recent fps and kb/s.
JSON's `status.streams` also includes codec, receivedBytes, rtpPackets, droppedFrames,
reconnects, lastFrameAgeSeconds, and a sanitized lastError when applicable. Counters
reset with the agent (or camera removal/re-add); rates are sampled about once per
second. Received bytes include RTSP/RTP/RTCP application traffic but not IP/TCP/TLS
overhead, so this is not a network-interface or billing meter. `droppedFrames`
counts incomplete/invalid access units, not the intentional disposal of all good
frames. `streaming` means complete encoded access units are arriving, not that a
pixel decoder has validated the image. Agent `ready` and exit 0 mean IPC is healthy;
inspect individual stream states for camera health.

All video and counters remain in memory, with an 8 MiB assembly limit per camera,
64 KiB RTSP header limit, and 1 MiB response-body limit. There are no periodic media
or statistics writes. Lifecycle/errors still use normal stderr/unified logging.
Tests include H.264/H.265 packet assembly, a local authenticated RTSP simulator,
keepalives, disconnect/stall recovery, add/remove/restart, and unchanged runtime
files during reception. Actual installed `_hbnvr` network access should also be
smoke-tested after reinstalling; unprivileged tests cannot prove service-account
network permissions on the deployment machine.

## IPC and diagnostics

The stream socket is `control.sock` within the runtime directory. One JSON request
and one JSON reply are exchanged per connection, terminated with a newline:

```json
{"protocolVersion":1,"operation":"status"}
```

A successful response has `protocolVersion: 1` and a `status` object containing
`ready`, `version`, `pid`, `uptimeSeconds`, and `streams`. An error response has `error` and
`code`. Messages are limited to 64 KiB (excluding the newline). Clients use a
five-second total deadline; the serial server bounds each accepted connection to
five seconds. It handles one active client at a time with a bounded listen backlog.

System clients can reach the socket (0666), but the daemon checks kernel-provided
peer credentials **before reading requests**. Only root or the configured controller
with its matching local account UUID is authorized. A reused numeric UID is not enough.
The surrounding directory prevents clients from replacing the socket. Local agents
authorize only their own UID and use a private 0600 socket. No identity in request
JSON is trusted.

Camera operations use the same authorization and deadlines: cameras.list returns
nonsecret summaries; cameras.add accepts a camera configuration object;
cameras.remove accepts a cameraID. Add/remove return a nonsecret camera summary.
The client verifies the agent's OS peer UID before sending credentials. Requests
are processed serially, including atomic configuration writes.

Exit codes: 0 success; 1 operational failure; 2 CLI usage; 3 unavailable;
4 permission/authorization denied; 5 incompatible protocol; 6 timeout; 7 invalid message.
`status --json` emits JSON on success; failures go to stderr with the relevant exit code.

Foreground lifecycle messages go to stderr. Installed lifecycle and error messages
use unified logging:

```sh
log stream --predicate 'subsystem == "com.graygoolabs.hbnvr"'
```

## Elevated acceptance checks

Run these separately on the deployment machine; unit and live local tests require
no sudo. Do not reboot or log out automatically as part of the test suite.

1. Install and confirm the job remains disabled. Start it, then run `status` as the
   installing user. Confirm its PID runs as `_hbnvr`.
2. Run `status` as a different ordinary account: expect exit 4. Root status should succeed.
3. Send SIGKILL to the **NVR PID returned by status** as root. After the 30-second
   restart throttle, verify a new PID and successful status.
4. Install an upgrade while running; verify a new PID and unchanged controller identity.
   Stop, install again, and confirm it remains disabled.
5. Start, log out, and confirm from another session that the process continues.
   Reboot when convenient and verify enabled startup; repeat after `stop` to verify
   disabled persistence. FileVault may require preboot disk unlocking.
6. Uninstall and verify the job and binary are gone while the service account and
   state remain. Reinstall and confirm authorization is preserved.

All operations target `com.graygoolabs.hbnvr`; they do not manage Homebase's service.
