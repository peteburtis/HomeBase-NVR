# HomeBase-NVR / hbnvr

Version **0.22.0** adds opt-in historical IPC tag maps, once per returned segment.
Maps cover exact returned frame ranges (including preroll), resolve retroactive
edits, and treat missing/unknown values as absent. RAM and growing-file requests
snapshot the writer's tags without waiting for SQLite checkpoints or copying video.
See [segment tags](MEDIA-PROTOCOL.md#segment-tag-maps-0220). Existing clients are unchanged.

Version 0.21.0 adds historical `media tag set/remove/inspect/apply/status` over
authenticated IPC. Address finalized footage by managed file/shard and frames,
or canonical/camera/received timestamps with optional actual-frame offsets.
Local edits safely replace MP4 metadata and the index; S3 edits update only
manifests, never video/JPEG objects. Batches, dry runs, revision checks, bounded
background work, and recovery are described in [historical tags](HISTORICAL-TAGS.md).
Live tags and Homebase/GUI behavior are unchanged by historical edits.

Version 0.20.0 adds opaque, prospective per-camera string tags. Set/remove
them with `camera tag`; every shared live frame includes its tag dictionary.
Tags persist with newly recorded MP4s, local/S3 manifests, and S3 thumbnails.
No historical files are rewritten by these prospective commands. Homebase tag
interpretation remains deferred. See [video tags](VIDEO-TAGS.md).

Version 0.19.0 adds authenticated, bounded live H.264 forwarding from the
existing NVR receiver to Homebase. Viewing never starts a camera connection or
changes recording intent; slow viewers cannot hold up recording. See
[shared live video](LIVE-VIDEO.md). Homebase's temporary quality override allows
existing GUI clients to use the shared feed without an app update.

Version 0.18.3 adds bounded retries for local recording manifest failures:
known finalized-shard metadata retries for up to one minute, with a 16-entry
per-store cap and explicit failure/recovery/discard logging. No historical scan
or video deletion is introduced; see [the retry policy](LOCAL-MANIFEST.md#lifecycle-and-failure-policy).

The foundation of an independent macOS NVR: a headless system LaunchDaemon,
authenticated Unix-socket control, and an unprivileged foreground development mode.
Interactive camera setup, direct ONVIF discovery, and one-time Homebase imports
are supported. Version 0.5.0 adds independent local recording stores, playable MP4
shards, and per-store retention. Version 0.5.1 makes incremental recording and crash
recovery explicit, with visible `.mp4.recording` files and periodic checkpoints.
Version 0.5.2 tolerates transient AVFoundation backpressure and slow finalization,
including first-use initialization under the service account, and preserves the
original failure in status instead of replacing it with a cleanup error.
Version 0.5.3 writes directly into display-name camera folders under the chosen
recording root, with readable local start-time filenames.
Version 0.6.0 adds `camera add/list/change/remove/enable/disable/start/stop`, with
persistent streaming enablement and recording intent, shared name/profile editing,
and separate stream-health and recording-state reporting.
Version 0.7.0 adds independent RAM-first S3 stores, durable outage/shutdown spooling,
write-only IAM setup, optional client-side password encryption with offline recovery,
and managed or external bucket lifecycle expiration.
Version 0.7.1 adds a configurable private S3 spool directory, including external-drive
volume identity checks and capacity reporting. See [spool placement](S3-STORE.md#custom-spool-directory-and-external-drives).
Version 0.7.2 adds persistent `store spool [NAME] --on/--off` controls and
`store change [NAME] --advanced` for all operational tuning, including offline edits
and disabled/drained spool relocation. Omit NAME for the usual picker.
Version 0.7.3 removes permanent S3 quarantine: all failed uploads remain retryable,
unreadable spool entries are retained and periodically rechecked, and repaired files
resume automatically. Existing quarantine markers no longer exclude valid entries.
Version 0.7.4 fixes S3 disk-replay HTTP framing (`MissingContentLength` / 411).
File uploads use the SDK's incremental SHA-256 checksum trailer and matching chunked
headers; RAM uploads are unchanged. Existing spool entries retry without migration.
Version 0.7.5 makes directory validation errors show the required and observed owner,
permissions, and directory type, identifies disabled volume ownership explicitly, and
explains macOS privacy checks when spool directory reads fail with EPERM.
Version 0.7.6 allows encrypted S3 spools on APFS/HFS+ volumes that ignore ownership,
without requiring daemon ownership or exact private modes there. Plaintext spooling
still requires private ownership-enforced storage. Metadata is not encrypted, and
encryption does not prevent another local user from deleting or modifying spool files.
Version 0.8.0 adds authenticated Homebase discovery and recording-intent control.
Homebase publishes `NVR.recording` on matching cameras, retaining it as invalid when
the NVR or camera becomes unavailable. See [the integration contract](HOMEBASE-INTEGRATION.md).
Version 0.10.0 introduces a prospective `.hbnvr-manifest.sqlite` in each local camera
directory, with recording-time anchors, finalized coverage/gap queries, and explicit
interrupted state. Existing footage is not scanned or backfilled; losing the manifest
loses its timeline metadata, not the media files. See [local manifests](LOCAL-MANIFEST.md).
It also reads camera RTCP sender reports and embeds versioned timing metadata
in both local and RAM/S3 MP4 shards without transcoding. Camera time is canonical
when within 2.5 seconds of reception; otherwise the receipt-anchored timeline wins.
The initial manifest schema requires timing metadata and the chosen canonical source;
camera time is absent only when no usable mapping is available. Files are self-describing;
automatic index rebuilding remains unimplemented. See [timing semantics](LOCAL-MANIFEST.md#stored-information-and-time-semantics).
Pre-event buffering and automatic camera-configuration synchronization remain future work.
Version 0.12.0 provides authenticated, reusable media IPC sessions for availability and
encoded-frame requests across the local writer's shared resident samples, growing
MP4 fragments, and finalized recordings. A bounded RAM bridge reaches the latest
accepted frame and releases history as disk becomes readable, without a second
payload copy or changing recording durability. Absolute canonical/camera/
received ranges and live-/now-relative ranges are supported, with explicit gaps
and keyframe preroll. Continuous live forwarding is now separate from history
requests; frame-reference requests remain future work. See the
[media wire contract](MEDIA-PROTOCOL.md).
Version 0.13.0 adds `playback.snapshot` / `playback.watch` over the authenticated
control IPC: discover stores, frame-reading capability, camera membership, and
source reachability before asking for time ranges. Local manifests retain each
camera's last-recorded name and Homebase hardware identity after camera removal.
Disabled stores remain discoverable/readable; recording intent is separate from
history. Scans run off the command/recording queues and never read video samples.
See [playback discovery](MEDIA-PROTOCOL.md#playback-discovery). Homebase consumption
is not part of this release.
Version 0.13.1 removes fail-stop behavior from local recording. Manifest errors
warn without stopping video writes; failed media shards are preserved and fresh
ones retry automatically at keyframes with capped backoff. Retention errors and
queue overload no longer permanently disable recording. A private, rotating
`.hbnvr-errors.log` in each local recording root records write/index failures.
Version 0.13.2 adds negotiated, authenticated media-session keepalives for an
already-open playback screen. They do not read recordings. The media reader also
tolerates one source-clock tick of MP4 end-time rounding while clipping returned
coverage to the exact indexed boundary; this prevents a valid shard's last frame
from failing an otherwise valid history request.
Requires macOS 26.1 and Xcode 26.1 or newer.

See [the CLI roadmap](CLI-ROADMAP.md) for planned camera/store command families,
streaming versus recording controls, and independent recording-store behavior.

### S3 security model

The S3 default manages expiration through
Amazon S3 Lifecycle in an existing bucket, without object-read or direct object-delete
permissions. **Lifecycle-management permission can nevertheless cause object deletion
by changing expiration rules**, and applies to the whole bucket. Setup discloses
this risk alongside the generated IAM policy; a dedicated bucket is recommended.
An externally managed mode omits lifecycle permissions and API calls,
leaving the user responsible for bucket expiration. Denied lifecycle access in
managed mode warns without stopping working uploads or claiming retention was
applied. See [S3 setup, configuration, and durability](S3-STORE.md) and the
[opt-in AWS smoke procedure](S3-SMOKE.md).

S3 setup always offers an optional encryption password (blank means none). Encryption
uses macOS PBKDF2-HMAC-SHA256 and AES-256-GCM before upload or spooling; SSE-S3 remains
enabled too. The unattended daemon retains the password in its private JSON. Back it
up separately: losing it makes encrypted recordings unrecoverable. To recover a file
downloaded using separate read credentials, run `hbnvr decrypt downloaded.mp4.hbnvr recovered.mp4`.
The command prompts without echo, requires no daemon/AWS access, and never overwrites.

Local playback also offers a `neighbors` query (0.14.0) for previous/next retained
video across recording gaps, including active disk/RAM data. It is read-only and
does not require an actively configured camera or change recording behavior.
See [MEDIA-PROTOCOL.md](MEDIA-PROTOCOL.md) for capability negotiation and bounds.

## S3 playback indexes (0.16.0)

Newly confirmed S3 recordings now publish encrypted (when configured), predictable
per-camera daily and monthly playback manifests plus a small day catalog. Homebase
advertises the optional `playbackManifestVersion: 1` capability; older NVRs and local
playback remain compatible. Reader credentials still need only prefix-scoped
`s3:GetObject`, not bucket listing. The private metadata journal survives restart,
external spool moves, and uninstall. Existing uploaded footage is not automatically backfilled.
See [the S3 playback contract and durability limits](S3-STORE.md#playback-manifests-0160).

## S3 thumbnails and metadata repair (0.18.0)

S3 recording now publishes a JPEG at each 20-minute tile midpoint (UTC :10, :30,
and :50), as soon as the selected keyframe is available. Images fit within 1280×720
without upscaling, use 80% JPEG quality, and follow the store's encryption setting.
Video and thumbnails share the same upload slots, retries, manual-spooling switch,
chosen spool volume/quota, and durable shutdown/replay path. Thumbnail object keys
are predictable and require no extra IAM permissions. This is the NVR publication
side; the GUI's S3 thumbnail reader is separate from its existing video fallback.

`hbnvr store repair-metadata [NAME] [--dry-run]` explicitly repairs missing S3
playback manifests and missing thumbnails for currently configured cameras. Omit NAME for a picker.
The command lists candidates, previews download bytes, and asks before fetching
recordings. It tries saved keys first and prints a narrowly scoped read/list IAM
policy if temporary reader credentials are needed; those keys are never saved.
Valid embedded shard timing is required. Unknown objects, legacy recordings without
timing, and damaged files are skipped, never changed or deleted. A dry run only
lists; it does not prove candidates are recoverable. The installed agent and CLI
must both support 0.18.0 for thumbnail repair. Indexed videos are read again only
when a midpoint thumbnail is missing; existing images are not overwritten.
See [repair details and limits](S3-STORE.md#explicit-metadata-repair-0180).

Version **0.18.1** adds bounded repair-download diagnostics to CLI progress and daemon
logs: HTTP 404/412, byte-count mismatches, and missing/different ETags are reported
separately. Examples show sizes and ETag fingerprints, never raw headers, object
paths, credentials, or video data. A scan with no recovered metadata or thumbnails
now says so explicitly. Install the matching CLI and agent for these diagnostics.

Version **0.18.2** fixes repair of object keys containing spaces: S3's URL-encoded
listing can represent a space as `+`. Repair now decodes that representation once,
without changing literal plus signs or percent escapes in the original key. Install
the updated agent and rerun `hbnvr store repair-metadata`; no object renaming or
GUI/Homebase update is needed for this fix.

## Build and test

Version **0.15.1** adds secret-free S3 destination metadata to playback discovery.
Homebase can use it to offer client-owned reader credential setup. No S3 reads or
AWS credential disclosure are introduced. Local frame, availability, neighbor,
and thumbnail requests now use only the first discovered local store (existing
ID ordering), matching Homebase's one-local-store advertisement; they no longer
fill missing ranges from additional local stores.

Version **0.15.0** adds timestamp JPEG thumbnails over media IPC. Requests support
the same canonical/camera/received timelines and live/now anchors as frame reads,
plus a required pixel bounding box. Images use a preceding keyframe and report its
actual time. RAM tails, open shards, and finalized recordings are supported without
thumbnail files or recording changes. See [the thumbnail wire API](MEDIA-PROTOCOL.md#timestamp-thumbnails-0150).
Homebase may be upgraded first: it negotiates this optional capability and keeps
ordinary frame playback working with older NVR builds. Install HBNVR separately.

Open `HomeBase-NVR.xcodeproj` and select the shared `HomeBase-NVR` scheme.
Run launches a local foreground agent; Stop in Xcode may leave a stale socket,
which the next agent recovers after obtaining its exclusive lock.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project HomeBase-NVR.xcodeproj -scheme HomeBase-NVR \
  -configuration Debug -derivedDataPath /tmp/hbnvr-build -skipPackagePluginValidation build
xcodebuild -project HomeBase-NVR.xcodeproj -scheme HomeBase-NVR \
  -destination 'platform=macOS' -derivedDataPath /tmp/hbnvr-build -skipPackagePluginValidation test
python3 scripts/integration.py /tmp/hbnvr-build/Build/Products/Debug/hbnvr
```

Swift ArgumentParser is pinned to 1.8.2; AWS SDK for Swift is pinned to 1.7.78.
`Package.resolved` pins its transitive dependencies. Xcode needs approval to run the
SDK's Smithy code-generation plug-in; the command above trusts that pinned plug-in.
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
The running agent immediately opens the saved stream. Enabled stores record it
automatically; without an enabled store, video is discarded. Camera settings are
not modified.

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

### Camera commands and persistent controls (0.6.0)

```sh
hbnvr camera list --json
hbnvr camera add
hbnvr camera change "Bedroom Camera"
hbnvr camera stop "Bedroom Camera"
hbnvr camera start "Bedroom Camera"
hbnvr camera disable "Bedroom Camera"
hbnvr camera enable "Bedroom Camera"
hbnvr camera remove "Bedroom Camera"
```

Camera controls use authenticated IPC without sudo. Commands accept a name or stable
UUID, or open a picker when omitted in a terminal. Missing or ambiguous selectors
are errors in noninteractive use. `hbnvr add/remove` remain shortcuts. Top-level
`hbnvr start/stop` still manage the system daemon and require sudo.

Two independent settings are saved in each camera's JSON:

- `Enabled`: maintain the stream connection. Disable finalizes recording and
  disconnects, but does not erase recording intent. Enable reconnects and resumes
  recording only if its saved intent is started.
- `RecordingStarted`: record incoming video to enabled, usable stores. Stop saves
  false and finalizes the current shard, while an enabled camera keeps receiving
  and discarding frames. Start saves true without reconnecting an existing stream;
  it rejects a disabled camera. Stop is allowed while disabled.

New cameras default to **enabled and started**. Existing camera files missing either
field default that field to true, preserving pre-0.6.0 behavior. Both settings survive
daemon restart, logout, reboot, and camera reconnect. No usable store or no stream
does not clear recording intent: status reports `waitingForStore` or `waitingForStream`,
and recording begins at the next usable keyframe when both become available. Other
states are `disabled`, `stopped`, and `recording`. No historical backfill is performed.
Repeated controls are harmless; unchanged configuration is not rewritten.

Disable/stop/change/remove drain queued recording work with a bounded wait. If the
writer needs longer, the command reports that settings were already saved/applied
and finalization is pending; it does not undo the requested state or discard the
unfinished file. Check status and retry after it drains. Other cameras continue.
Changing a name or profile restarts that receiver and finalizes its current shard;
start/stop alone preserve the receiver and its counters.

### Shared camera-options workflow: add and change

Name and video profile are **camera options** in HBNVR. Import/discovery obtains
connection details and capabilities; it is separate from editing those options.
The imported add path now uses CameraOptionsUI and CameraOptionsEditor rather
than owning its own name/quality form.

`camera change` selects an existing camera and asks the daemon to refresh profiles
using its private credential copy. Only editable options, profile descriptions, and
an opaque edit-conflict token return to the CLI—not credentials or stream URLs.
It invokes the same editor. Add seeds it with Homebase's name and the nearest-720p
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
semantics and must not take effect while merely editing a draft. Discovery is bounded
within the IPC deadline; an offline ONVIF camera fails without saving. Confirmation
revalidates changed profile selections on the camera. Concurrent configuration changes
reject a stale editor rather than overwriting a newer control or edit.

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

Reinstall after building an update so the system agent understands the new commands.
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
  "Enabled": true,
  "RecordingStarted": true,
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
manual RTSP-only camera. Enabled and RecordingStarted are optional for legacy files
and default to true; when present, they must be booleans. All other example fields
are required. Control/change commands preserve unrecognized JSON fields and the
credential object; other camera files are not rewritten. UUID filenames are stable
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

## Local recording stores (0.5.0)

After reinstalling the updated binary, run these as the controller **without sudo**:

```sh
hbnvr store add
hbnvr store list
hbnvr status
hbnvr store change "Local recordings"
hbnvr store disable "Local recordings"
hbnvr store enable "Local recordings"
hbnvr store remove "Local recordings"
```

Add/change share an interactive options editor. Defaults are `~/NVR` (the requesting
user's home), `1m` shards, `1w` retention, and enabled. Add first selects Local or S3;
multiple independent instances of either type are supported. Each command accepts
`--runtime-dir PATH` for an isolated foreground agent. List/status support `--json`.
Change/enable/disable/remove accept an exact name or UUID; omit it for a terminal
picker. Ambiguous or missing selections are errors outside a terminal.
S3 `store spool --on` / `--off` follows the same picker convention; see
[manual spooling and advanced editing](S3-STORE.md#manual-spooling-and-advanced-editing).

Every enabled store records **enabled cameras whose recording intent is started**,
beginning at their next usable keyframe. Disabling one store finalizes its current shards without affecting other
stores or the camera connections. Retention continues for disabled stores. Removing
a store removes only configuration: recordings, directories, and permissions are
preserved, and retention stops. Moving a destination requires remove/add; existing
recordings are not migrated or adopted by the new store.

### Private destination setup

After confirmation, setup creates a dedicated directory with mode 0700 and explicit
inheritable macOS ACLs granting read/write access to the requesting user and agent
account (`_hbnvr` for the installed service). Locally those are the same identity.
Recording files use mode 0600 plus inherited ACLs. Other ordinary users have no
access; root retains administrative access. The directory remains owned by its
creator; daemon-created subdirectories/files belong to the daemon. This is
filesystem access protection, not video encryption.

Setup does not broaden ancestor permissions or silently adopt an existing directory
with unrelated permissions. Existing destinations must already match the private
ownership/ACL policy; otherwise choose a new directory. The parent must exist and
be accessible to both accounts. `~/NVR` avoids Documents/Desktop privacy controls,
but customized home permissions and macOS privacy rules can still deny daemon
access. Such failures are reported, not bypassed. No sudo is needed for store setup;
running add as root is rejected. A failed save may leave the new private directory
in place, with an explicit message so it can be inspected or reused.

The chosen directory is the recording root; there is no additional store directory.
Each camera gets a folder named for its display name:

```text
~/NVR/
  Bedroom Camera/
    2026-09-16_14-30-00.mp4
    2026-09-16_14-31-00.mp4.recording
  Living Room Camera/
    2026-09-16_14-30-01.mp4
```

Filenames use `yyyy-MM-dd_HH-mm-ss`: local recording-start time, Gregorian calendar,
24-hour clock, and filename-safe hyphens instead of time colons. A `-2`, `-3`, etc.
suffix distinguishes starts within the same second or a repeated wall-clock time
(including daylight-saving changes). Finalization only removes `.recording`.
Unsafe camera-name characters become hyphens, leading/trailing dots and whitespace
are trimmed, and long names are truncated safely. Duplicate names get ` (2)`, etc.,
without combining cameras. Renaming a camera creates a newly named folder for new
shards; old folders remain covered by retention.

A hidden `.hbnvr.lock` serializes use of the root. Each camera folder has a small
private `.hbnvr-camera.json` identity file, so duplicate names and retention remain
scoped to the correct store and camera. Do not delete these files or add unrelated
timestamp-named videos to managed camera folders. Unmarked directories are not adopted.
Old `hbnvr-<store-UUID>` layouts are not moved or renamed; their existing retention
policy continues to apply. New recordings use only the layout above.
Two stores cannot use duplicate or nested destination paths. Do not point a local
development store at a production destination. Permissions are deliberately
preserved on store removal and system uninstall; recordings remain accessible to
the original requester and daemon account.

### Duration options and JSON

Use positive whole-number duration components: `s` seconds, `m` minutes, `h` hours,
`d` days, `w` weeks, `M` months, `y` years. Compounds such as `1h30m` or `1w2d` work,
with optional spaces. A month is exactly 31 days and a year exactly 365 days;
`12M` is deliberately not `1y`. Fractions, unitless numbers, and overflow are errors.
The prompt shows the exact seconds. Local shard duration supports `1s` through `1d`;
retention must be at least that duration and at most `100y`.

Store configurations are plain, pretty-printed `<UUID>.json` files in:

- Installed: `/Library/Application Support/HomeBase-NVR/private/stores/`
- Local: `<runtime-dir>/stores/`

Fields are `SchemaVersion`, `ID`, `Name`, `Type` (`Local`), `Enabled`, `Directory`
(expanded absolute path), `ShardDuration`, `RetentionPeriod`, `OwnerUID`, and
`OwnerUUID`. Configuration files are mode 0600 in a 0700 directory, owned by the
agent. The owner identity is recorded from authenticated IPC, never trusted from
a client's submitted JSON. Preserve it when hand-editing. Stop/edit/restart is the
manual workflow; external file edits are not hot-reloaded. Install/uninstall preserve
configuration. A shorter retention setting can immediately expire older shards;
change warns before confirmation.

### Media, retention, and limits

The camera receiver distributes encoded access units and codec/timing metadata.
Each store owns its container and shard writer. The local implementation uses system
AVFoundation to pass H.264/H.265 into MP4 without decoding/re-encoding. S3
delivery/buffering remains independent of local stores. No ffmpeg is required.

Shard duration is a **target**: files begin at a keyframe and rotate at the next
keyframe at or after the target. Disconnect, damaged frames, codec changes, disable,
and graceful shutdown finalize the current shard; new recording waits for a keyframe.
Audio is not recorded. Profiles with reordered presentation timestamps (B-frames)
are not supported in this increment and fail explicitly; use a no-B-frame profile.

**Local-store durability goal:** put incoming media on disk incrementally, keeping
as little solely in memory as practical without excessive disk activity. A shard is
not an all-or-nothing transaction or a whole-file RAM buffer. Its visible
`.mp4.recording` file grows while frames arrive, with the same private access as a
completed file. Successful finalization flushes it and removes the `.recording`
suffix, keeping the original start timestamp; committing does not copy the video
into a second file.

The writer requests an initial recovery fragment at one second and subsequent
fragments at five-second intervals, independently of shard duration. This writes
container metadata during capture using AVFoundation's
[movie fragments](https://developer.apple.com/videos/play/wwdc2020/10011/), rather
than depending solely on the final file index. File syncs are batched about every
five seconds while frames arrive, plus finalization; directory entries are synced
when the file appears and when it is renamed. These are best-effort checkpoints,
not a strict maximum-loss guarantee: framework buffering, media timing, the OS,
and storage hardware can delay persistence. No per-frame fsync or full-drive
hardware-cache flush is requested.

An interruption leaves a clearly named recording for recovery. The writer does
not cancel/delete it on a finalization timeout; it may continue finishing in the
background, but is not reported or renamed as a successful shard. Restart never
silently truncates or resumes an abandoned file. Some completed fragments can be
playable after a process crash; the trailing fragment or a very short recording
may be incomplete. Power loss can lose cached bytes and metadata, so recovery is
not guaranteed. Copy an abandoned recording outside the managed camera folders, with
an `.mp4` suffix, before trying playback or repair tools. Automatic repair is not
implemented.

Retention runs on startup and approximately every 30 seconds. New completed files
age from their filesystem modification time, set at finalization; abandoned
`.mp4.recording` files age from filesystem creation time. This is independent of
the filename's local start time and avoids timezone ambiguity. Touching a completed
file extends its retention. Legacy filenames retain their original embedded
completion/creation timestamps, including `.mp4.partial` files. Cleanup only removes
recognized, agent-owned regular files with a single link within folders identified
for this store (or its exact legacy directory). Unknown files, unmarked folders,
symlinks, hardlinks, and other store directories are not deleted. Cleanup
requires a running agent and accessible destination; it is not an exact deletion
deadline. The current open shard is never expired.

Each store has its own serial writer and bounded queue (32 MiB of encoded payloads,
at most 2,048 events). Temporary writer backpressure is allowed up to 30 seconds
on that store's worker; reception, other stores, and status remain independent.
Finalization has a separate 30-second deadline. These waits do not extend the IPC
deadline: an operation that cannot drain within its existing three-second budget
returns a pending-work error and can be retried after the work finishes. The queue
limits still apply during a stall. An actual writer failure is reported immediately,
with framework/underlying error codes but no error-userInfo secrets. Status preserves
the current recording failure; secondary cleanup errors remain in the logs.
Video-write errors end only the affected camera's shard, preserve the existing file
(subject to normal retention), and retry fresh shards on keyframes after 1, 2, 4,
8, 16, then at most 30 seconds. Successful full shards reset the backoff. A full or
unavailable disk is not a permanent stop: attempts continue until the cause clears.
There is no alternate-disk fallback or unbounded RAM buffering; frames during an
outage can be lost. Startup-unavailable destinations are also reopened automatically,
with permissions and exclusive locks revalidated. Explicit disable/stop still wins.
Queue overload drains/finalizes the accepted prefix and automatically resumes at
new keyframes instead of appending across known dropped frames. Other stores and
camera reception remain independent.

Manifest errors do **not** stop MP4 writing. The writer retains the current shard's
known metadata and tries its complete index entry after successful finalization.
Failed final updates enter a metadata-only RAM queue capped at **16 entries per
store**, retried on fresh SQLite connections with exponential backoff for **60
seconds**, at most one queued attempt per second. Updates are idempotent, and retry
does not interrupt newer active shards. Failures, recovery, and discarded updates
are logged. Queue overflow, expiry, shutdown, or a crash can leave footage unindexed;
discarding an update never deletes its video. No automatic historical backfill
or replacement of a corrupt/foreign database is performed. Retention warnings are
separate and retried every 30 seconds, without stopping recording or cleanup of
other accessible files. Pending RAM is not durable; checkpoints reduce the open
shard's recovery risk but do not eliminate it.

Write, finalization, index, queue-overload, and retention errors also go to
`<local root>/.hbnvr-errors.log`: UTC timestamps, camera IDs when applicable, and
SQLite operation/primary/extended codes and OS errno when available. It inherits
the root's private controller/daemon ACLs, with daemon ownership and mode `0600`.
At approximately 1 MiB it rotates to `.hbnvr-errors.log.1`, replacing the prior
rotated log. Both files are excluded from video retention. Logging is best-effort,
not fsynced for every entry; failure to write it is reported via the normal agent
log and status and never stops recording retries. Neither log contains SQL values,
camera credentials, or raw framework error user-info.

`status` reports each store's configured enablement, state, active recordings,
completed shards, pending bytes, and last error. JSON also has `recordedFrames`
(samples submitted to the writer, not individually durable commits). Counters reset
on agent restart or store reconfiguration, including disable/enable. Camera mode
`record` means media is routed to at least one healthy enabled store; check store
activity/completed shards to confirm actual recording. Agent readiness alone is
not a guarantee of camera or storage health.
Local `retrying` means no active writer is currently available; `degraded` permits
ongoing recording while another camera or index/retention/logging needs attention.
The JSON `local` object reports destination/camera retries, dropped queue events,
and separate manifest, retention, and diagnostic-log warnings. A subsequent
successful indexed shard/retry clears that camera's current manifest warning when
no other updates remain pending; the log retains failures and discarded gaps.
Earlier unindexed footage is not implicitly repaired.

Tests generate both H.264 and H.265 video, shard it, and decode every output frame.
They also cover permissions/ACL validation, duration parsing, retention scoping,
independent failures, bounded queues, locking, CLI cancellation, and persistence.
Injected-clock tests cover temporary backpressure/slow finalization longer than
the old deadlines, genuine timeouts, immediate framework failures, and preserving
the initial error during cleanup.
Recovery tests check file growth and playback before commit, inode-preserving
rename, retention of unfinished/legacy files, and playable fragments after SIGKILL
of an isolated synthetic-video test subprocess. These are not physical power-cut tests.
Live camera recording is an opt-in smoke check, not part of the default test suite.
After reinstalling, verify an installed store can write as `_hbnvr` and the requesting
user can play/delete a completed MP4; local tests do not prove cross-account access.

## Continuous receiving

Known protocol/lifecycle follow-ups are tracked in the
[camera protocol hardening backlog](RTSP-HARDENING.md), with audit evidence and
regression criteria. They are not established causes of the September 2026 camera
outage, and the documented fixes are not yet implemented.

Every running agent—system or local—opens **all enabled camera streams**. Adding
a camera starts its receiver immediately; removing it closes the connection. Startup
loads the private JSON configurations independently of Homebase. Stop/restart after
manual edits. A missing RTSPURL is reported as `unconfigured` and makes no connection.

This increment consumes encoded H.264/H.265 video over RTSP interleaved TCP. It
assembles complete RTP access units in bounded memory and routes them to enabled
stores only when that camera's recording intent is started. With recording stopped
or no enabled stores it discards them, with no media writes. The receiver
does not decode pixels, buffer a pre-event history, upload to S3, or perform motion
detection. Continuous receiving still consumes camera/LAN bandwidth even when
nothing is recorded. Audio tracks and UDP transport are not
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
within a bounded interval. Normal shutdown attempts TEARDOWN, but some error/race
paths currently close without acknowledged cleanup; see the hardening backlog above.

```sh
hbnvr status
hbnvr status --json
```

Status shows each camera's state, cumulative complete frames, recent fps and kb/s.
JSON's `status.streams` also includes enabled, recordingStarted, recordingState,
codec, receivedBytes, rtpPackets, droppedFrames,
reconnects, lastFrameAgeSeconds, and a sanitized lastError when applicable. Counters
reset with the agent or receiver replacement (enable/disable, name/profile change,
removal/re-add), but not camera start/stop; rates are sampled about once per
second. Received bytes include RTSP/RTP/RTCP application traffic but not IP/TCP/TLS
overhead, so this is not a network-interface or billing meter. `droppedFrames`
counts incomplete/invalid access units, not the intentional disposal of good
frames. `streaming` means complete encoded access units are arriving, not that a
pixel decoder has validated the image. Agent `ready` and exit 0 mean IPC is healthy;
inspect individual stream states for camera health.

The receiver has an 8 MiB assembly limit per camera, 64 KiB RTSP header limit, and
1 MiB response-body limit. Counters remain in memory; media writes belong to stores.
Lifecycle/errors still use normal stderr/unified logging.
Tests include H.264/H.265 packet assembly, a local authenticated RTSP simulator,
keepalives, disconnect/stall recovery, add/remove/restart, and unchanged runtime
files during reception. Actual installed `_hbnvr` network access should also be
smoke-tested after reinstalling; unprivileged tests cannot prove service-account
network permissions on the deployment machine.

## IPC and diagnostics

The stream socket is `control.sock` within the runtime directory. Normally one JSON
request and one JSON reply are exchanged per connection, terminated with a newline:

```json
{"protocolVersion":1,"operation":"status"}
```

A successful response has `protocolVersion: 1` and a `status` object containing
`ready`, `version`, `pid`, `uptimeSeconds`, `streams`, and `stores`. An error response has `error` and
`code`. Messages are limited to 64 KiB (excluding the newline). Clients use a
five-second total deadline; the serial server bounds each accepted connection to
five seconds. It handles one active ordinary request at a time with a bounded listen
backlog. `cameras.watch` transfers an authenticated connection to a separate bounded
subscription writer; it never occupies the ordinary request loop while watching.
See [the subscription and write protocol](HOMEBASE-INTEGRATION.md#wire-contract).
`media.open` similarly transfers a dedicated authenticated connection to a bounded
media worker, switching to length-prefixed JSON/binary records for reusable range
requests. Its deadlines and video framing are separate from ordinary command IPC;
see [media protocol v1](MEDIA-PROTOCOL.md).

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

Store operations use the same transport: `stores.list`, `stores.add`, `stores.change`,
`stores.enable`, `stores.disable`, and `stores.remove`. Add/change take a `store`
configuration; the other mutations take `storeID`. Store setup requires the
requesting non-root controller; root can list, enable, disable, and remove. The
daemon validates destination access independently and rolls back a configuration
change if opening the destination fails. On a client timeout, inspect list/status
before retrying: a mutation may have completed even if its reply was lost.

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
