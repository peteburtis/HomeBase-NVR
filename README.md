# HomeBase-NVR / hbnvr

The foundation of an independent macOS NVR: a headless system LaunchDaemon,
authenticated Unix-socket status, and an unprivileged foreground development mode.
Camera setup, recording, buffering, S3, and Homebase integration are not implemented yet.
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

## IPC and diagnostics

The stream socket is `control.sock` within the runtime directory. One JSON request
and one JSON reply are exchanged per connection, terminated with a newline:

```json
{"protocolVersion":1,"operation":"status"}
```

A successful response has `protocolVersion: 1` and a `status` object containing
`ready`, `version`, `pid`, and `uptimeSeconds`. An error response has `error` and
`code`. Messages are limited to 64 KiB (excluding the newline). Clients use a
five-second total deadline; the serial server bounds each accepted connection to
five seconds. It handles one active client at a time with a bounded listen backlog.

System clients can reach the socket (0666), but the daemon checks kernel-provided
peer credentials **before reading requests**. Only root or the configured controller
with its matching local account UUID is authorized. A reused numeric UID is not enough.
The surrounding directory prevents clients from replacing the socket. Local agents
authorize only their own UID and use a private 0600 socket. No identity in request
JSON is trusted.

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
