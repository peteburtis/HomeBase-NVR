# Homebase camera integration (0.8.0)

NVR 0.13.0 also provides a separate playback catalog via
`playback.snapshot` / `playback.watch`, with persisted camera identity from local
manifests, store reachability, and recording-independent history discovery.
See [playback discovery](MEDIA-PROTOCOL.md#playback-discovery). This does not change
the existing recording-control subscription below or implement its Homebase consumer.

Homebase's camera module automatically connects to the installed NVR at
`/Library/Application Support/HomeBase-NVR/run/control.sock`. No configuration,
pairing, XPC service, shared credential files, or background CLI subprocess is needed.
The NVR authenticates Homebase's process using the same kernel peer UID and recorded
account UUID as CLI access. Run Homebase as the installing/authorized user. Homebase
also checks that the socket peer is the `_hbnvr` account before sending requests.
Root remains authorized by the existing NVR administration policy.

## Control semantics

Match a registered NVR camera's `HomebaseDeviceID` to Homebase's hardware-derived
device ID. Names, aliases, addresses, and credential filenames are not identity.
An imported camera already has this ID. A manual RTSP-only camera without it is
not guessed or linked. Multiple NVR entries matching one device are ambiguous;
Homebase will not choose one arbitrarily.

On the first unique match, Homebase publishes the writable switch `NVR.recording`:

- `true`: persistent recording intent is started (`hbnvr camera start`).
- `false`: persistent recording intent is stopped (`hbnvr camera stop`). Streaming
  is unchanged by either setting. Enabled stores determine where footage is recorded.
- Invalid: Homebase cannot currently observe/control that registration. Keep the
  control and its last value; do not turn it off or unpublish it. Disconnection,
  camera disable/removal, and ambiguous identity invalidate it. Recovery revalidates
  the same control. A first match that is disabled publishes an invalid control.

This is **intent**, not proof that frames are reaching storage. Stream/store faults
do not rewrite it; `hbnvr status` retains separate health and actual-recording reporting.
Writing does not enable a disabled camera, add a store, or change a video profile.
Acknowledgement means intent has been saved/applied; finishing an old shard continues
asynchronously. Repeated identical sets are harmless and do not rewrite configuration.

Discovery seeds the observed value before publishing readiness; it does not send
a default-off command. Reconnects do not replay writes. Homebase's ordinary automation,
provider command-completion, and fresh-readback mechanisms handle explicit changes.
Homebase shutdown never stops NVR recording. A restarted Homebase process discovers
capabilities anew; retention of the published control applies within that Homebase run.

## Wire contract

Since 0.19.0, camera snapshots also advertise optional `liveVideo` profile
capabilities, and `live.open` taps the existing receiver on a dedicated connection.
See [shared live video](LIVE-VIDEO.md). Recording controls and playback discovery
remain separate; neither viewing nor closing a viewer changes recording intent.

Protocol version remains `1`; these are additive operations using the existing
newline-delimited JSON transport and 64-KiB frame limit. Snapshots contain no camera
credentials, endpoint URLs, AWS credentials, or store details.

`cameras.snapshot` returns one ordinary reply. `cameras.watch` returns the initial
snapshot, then complete replacement snapshots on changes, plus an unchanged snapshot
heartbeat every 30 seconds. A fresh daemon-instance UUID and monotonically increasing
revision disambiguate reconnects and stale replies; no event journal or delta replay
is needed. A slow subscriber may skip intermediate revisions, but receives the latest
complete state. Clients must retain any unconsumed bytes across newline boundaries.

```json
{"protocolVersion":1,"operation":"cameras.watch"}
```

```json
{"protocolVersion":1,"cameraSnapshot":{"instanceID":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","revision":1,"cameras":[{"id":"BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB","homebaseDeviceID":"camera-vendor-serial","enabled":true,"recordingStarted":true}]}}
```

To set recording, send a separate ordinary request with the observed identities:

```json
{"protocolVersion":1,"operation":"cameras.recording.set","nvrInstanceID":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","cameraID":"BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB","homebaseDeviceID":"camera-vendor-serial","recordingStarted":false}
```

The daemon checks the epoch, registration, hardware ID, and enabled state before
saving. Neither an old Homebase binding nor an old daemon session can accidentally
address a replacement camera. A successful reply includes the resulting snapshot;
the same change reaches watchers. Existing CLI camera commands also publish updates.
Older daemons reject the new operation; Homebase remains functional without NVR controls.

At most eight subscribers are allowed. Each has one replaceable pending snapshot,
five-second write deadlines, and its own socket writer. Shutdown closes subscriptions
before recording finalization. Ordinary commands retain their five-second deadline.
Homebase's watch has a five-second initial response deadline and a 75-second heartbeat
deadline, then reconnects with bounded 1/2/5/15/30-second backoff. Absent/restarting NVRs
are quiet; permission/protocol failures have deduplicated diagnostics.

## Verification and deployment

Both updated binaries are needed: hbnvr 0.8.0 and a Homebase build with this bridge.
Installation/restarting production services is a separate operator action.

Automated tests use temporary runtimes and synthetic camera state: NVR subscriptions,
nonblocking CLI access, persistent/idempotent writes, restart epochs, subscriber limits,
retained invalid controls, identity ambiguity, stale acknowledgements, fresh readback,
socket framing, peer rejection, malformed replies, and deadlines. No AWS upload or live
camera access is required. Existing authorization tests cover allowed/disallowed UIDs.

For the cross-project end-to-end test, first build hbnvr, then run from the Homebase
source directory (the `TEST_RUNNER_` prefix forwards the variable through Xcode):

```sh
TEST_RUNNER_HBNVR_TEST_BINARY=/tmp/hbnvr-build/Build/Products/Release/hbnvr \
xcodebuild -project HomeBase.xcodeproj -scheme HomeBaseEngine \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:HomeBaseEngineTests/CameraModuleTests test
```

This opt-in test launches an unprivileged agent in a unique temporary directory,
registers a synthetic camera with no stream URL or stores, exercises Homebase writes,
checks the persisted JSON, and restarts that agent to verify invalidation/recovery.
It never connects to or restarts the installed NVR.

After installing both builds, inspect an imported camera's `NVR.recording` switch.
Use `hbnvr camera stop NAME` / `start NAME` and observe it change; use Homebase's switch
and confirm the persisted intent with `hbnvr camera list`. With the camera disabled or
the NVR service stopped, the same control should become invalid, then valid again
after re-enabling/restarting. **These smoke actions affect real recording.** Do them
only when a recording interruption is acceptable. Do not expect a Homebase logout or
restart to stop the independent NVR daemon.
