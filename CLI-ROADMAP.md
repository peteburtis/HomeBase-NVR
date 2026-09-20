# HBNVR CLI roadmap

Recorded September 16, 2026. Local stores, camera controls, and S3 stores are implemented.
Triggers remain future work. No plugin loader is planned. The original S3 discussion
notes below are retained; the implemented decisions immediately below supersede their earlier
examples and open questions.

## Current baseline (0.10.0)

- RTCP sender-report mapping supplies optional camera wall-clock time. New local
  and S3 MP4s embed camera, receipt-anchored, and canonical time, source choice,
  actual first-frame receipt, stream epoch and recording identities (no transcoding).
- Canonical policy: camera within ±2.5 seconds of actual reception, otherwise
  received. Mapping changes are explicit shard/epoch boundaries. The initial local
  SQLite schema requires the same timing metadata; camera time may be unavailable.
- Self-describing new files make a future explicit index rebuild possible; no
  automatic scan, backfill, or recovery command is added in this increment.

- System lifecycle: `install`, `uninstall`, `start`, and `stop` require sudo.
- `agent` supports both the system daemon and an unprivileged local instance.
- `status` / `status --json` report agent readiness and per-camera stream health.
- `add` and `remove` interactively manage cameras over authenticated IPC.
- Camera import reads Homebase configuration and credentials, then queries cameras
  directly. Manual RTSP-only configuration is also supported.
- Every enabled camera with a stream URL is continuously received. Enabled stores
  record cameras whose persistent recording intent is started; otherwise frames are discarded.
- `store add/list/change/remove/enable/disable` manage independent local stores.
  Defaults: `~/NVR`, `1m` shards, `1w` retention, enabled. The shared duration parser,
  private requester/daemon directory setup, MP4 sharding, and retention are implemented.
- Local recordings grow visibly as `.mp4.recording` files, with periodic recovery
  metadata and batched disk syncs. Finalization renames the existing file; unfinished
  recordings remain available for recovery until their retention expires.
- The selected root directly contains display-name camera directories and
  `yyyy-MM-dd_HH-mm-ss.mp4` shards (local start time, 24-hour clock). Hidden identity
  files scope ownership/retention; numeric suffixes resolve name/time collisions.
  Legacy layouts are preserved in place and continue to receive retention cleanup.
- Local camera directories maintain a prospective `.hbnvr-manifest.sqlite` (0.10.0).
  New shards record NVR receipt/media-time anchors, provisional/finalized state,
  and file identity. Internal range queries return available intervals and gaps.
  No filename/date reconstruction, backfill, keyframe/offset index, or playback
  endpoint is included. Lost metadata cannot be reconstructed automatically.
  See [local manifest design and failure semantics](LOCAL-MANIFEST.md).
- `camera add/list/change/remove/enable/disable/start/stop` are implemented. Both
  streaming enablement and recording intent persist; new/legacy cameras default
  enabled and started. Stop leaves streaming intact; disable preserves recording intent.
- Camera add/change use the same options editor:
  display name and video profile today, more camera options later.
- Homebase's camera module discovers the installed NVR over authenticated Unix IPC.
  Matching uses `HomebaseDeviceID`, never an alias, credential filename, or IP address.
  `NVR.recording` reads/writes persistent start/stop intent. Once published, the control
  stays present but invalid while disconnected, disabled, removed, or ambiguously matched.
  Full snapshot subscriptions announce camera additions/removals/enablement/intent;
  reconnecting observes current state without sending a write. No camera/store lifecycle,
  credentials, or automatic configuration synchronization are exposed by this bridge.
  See [Homebase integration](HOMEBASE-INTEGRATION.md).
- S3 stores are implemented in 0.7.0 with generated IAM setup, asynchronous validation,
  RAM MP4s, controlled uploads, durable private spooling, and independent lifecycle
  warnings. See the settled 0.7.0 decisions and operational documentation below.
- S3 `Advanced.SpoolDirectory` can select an exact dedicated directory on an external
  drive. It is JSON or `store change --advanced`, not another ordinary setup prompt.
  Changes require disabled/drained; offline JSON edits additionally require restart.
  Volume UUIDs prevent silent replacement/fallback. Free-space reserves
  and capacity reporting use the actual spool volume. Custom paths use store schema 3+.
- `store spool [NAME_OR_ID] --on/--off` persistently holds/releases uploads and probes,
  without disabling recording or clearing automatic safety reasons. Omitted names
  show the normal picker. ForceSpooling upgrades to schema 4 to reject older readers.
- `store change --advanced` shows all Advanced fields. Operational-only edits work
  offline, preserve secrets/current shards, and reject stale edits. A disabled/drained
  store can switch to a pre-created dedicated empty spool without an agent restart.
- No permanent S3 quarantine: every upload error remains retryable with normal pacing.
  Unreadable or invalid spool entries are preserved, reported, and rechecked periodically;
  repair automatically restores eligibility. Legacy quarantine markers no longer block
  valid entries. Failed probes rotate so one file cannot starve the rest of the backlog.
  Relocation/removal reports remaining work rather than merely asking to disable again.
- Disk replay uses paired SDK streaming checksum/framing (0.7.4), correcting HTTP 411
  failures without changing queued keys, payloads, encryption, or credentials.
- Directory diagnostics (0.7.5) state expected/observed ownership, mode, and type;
  external-volume ownership errors explain the volume-wide setting without changing it.
- Encrypted S3 spools (0.7.6) may use ignore-ownership APFS/HFS+ volumes without
  exact UID/mode requirements. Plaintext spools stay private; credentials/passwords
  stay in private daemon state. Metadata visibility and local deletion/tampering are
  accepted tradeoffs, not solved by encryption. Filesystem durability checks remain.

## Deferred camera protocol hardening

The September 19, 2026 audit identified session-cleanup, teardown authentication,
SETUP/shutdown races, unnecessary reconnection on rename, cleanup-deadline, SDP
control-URL, RTCP-feedback, and diagnostic follow-ups. These remain unimplemented;
see [the camera protocol hardening backlog](RTSP-HARDENING.md) for evidence,
reproduction scenarios, and acceptance criteria.

Treat this as robustness work, not an established explanation for the camera outage:
the NVR was largely static around those failures, whereas most confirmed defects
require a transition. Recovery after stopping a stream would not prove it caused
the original failure. Reproduce safely with isolated fake-camera instances.

## Command families

The `store` family below is available for Local and S3 stores. The `camera` family and
top-level camera add/remove shortcuts are implemented.

Keep daemon lifecycle at the top level. Put resource operations under singular
`camera` and `store` namespaces:

```text
hbnvr camera add
hbnvr camera list
hbnvr camera change  [NAME_OR_ID]
hbnvr camera remove  [NAME_OR_ID]
hbnvr camera enable  [NAME_OR_ID]
hbnvr camera disable [NAME_OR_ID]
hbnvr camera start   [NAME_OR_ID]
hbnvr camera stop    [NAME_OR_ID]

hbnvr store add
hbnvr store list
hbnvr store change   [NAME_OR_ID]
hbnvr store remove   [NAME_OR_ID]
hbnvr store enable   [NAME_OR_ID]
hbnvr store disable  [NAME_OR_ID]
hbnvr store spool    [NAME_OR_ID] --on|--off
hbnvr store change   [NAME_OR_ID] --advanced
```

Retain `hbnvr add` and `hbnvr remove` as camera shortcuts. Top-level `hbnvr start`
and `hbnvr stop` retain their existing system-service meanings; they are not
recording controls.

An omitted selector opens an interactive picker. Stable IDs identify configurations;
names are editable human labels, not identity (local recording folders derive from
display names). Ambiguous names require
disambiguation, never an arbitrary match. Noninteractive callers must receive a
clear error instead of a prompt when a selection is missing or ambiguous.

Camera/store control uses the authorized user's IPC access without sudo. Default
to the installed service and support `--runtime-dir` for isolated development.
System lifecycle remains exclusively system-level. Storage destinations must be
accessible to the agent's account, not merely to the invoking CLI user.

## Camera controls: streaming versus recording

| Command | Intended effect |
| --- | --- |
| `camera enable` | Persist enabled state and maintain the stream. Resume recording if saved recording intent is started. |
| `camera disable` | Finish recording, close the stream, persist disabled state, and preserve recording intent. |
| `camera start` | Persist recording intent and record to enabled stores. Reject a disabled camera clearly. |
| `camera stop` | Persist stopped recording intent and finish the shard; leave streaming enablement unchanged. |

Enabled state and recording intent are both configuration. Actual recording activity
depends on stream/store availability. Report configured enablement, actual stream health,
and recording state separately: an enabled camera can be offline, and a streaming
camera can be idle or recording. Repeated enable/disable/start/stop should be harmless.

JSON uses `Enabled` and `RecordingStarted`, both true on add and when absent from
legacy files. Both survive restart/reboot/reconnect. Start with no usable store saves
intent and reports waiting; it resumes at a usable keyframe when a store becomes
available. Stop is allowed while disabled. Start/stop do not reconnect the receiver.
Disable/re-enable preserves recording intent. Configuration save failures leave
runtime unchanged. If finalization exceeds the bounded drain wait, settings remain
saved/applied and the command reports pending work, rather than undoing the request.

## Recording stores

Use **recording store**, not archive. Each configured store is an independently named
instance with its own stable ID, type, enabled state, options, retention period,
and shard duration. Retention and shard duration are shared configuration concepts
across all store types, with independent values for every instance.
Support multiple local stores and multiple S3 stores, not one singleton per type.

`store add` should ask for:

1. Type: Local or S3.
2. Display name.
3. Type-specific destination settings: directory, or bucket/prefix/region and
   authentication configuration.
4. This store's retention period.
5. This store's shard duration (time, not bytes).
6. Enable immediately? Default: yes.
7. Final confirmation before saving/applying anything.

`store change` reuses the add options editor, prefilled from the saved configuration.
Preserve credentials unless explicitly replaced; never echo existing secrets.
Reject duplicate destinations and unsafe overlapping local recording directories.
Validate directory access and destination scope without silently changing unrelated
permissions or configuration.

### Shared duration options

- **Retention period:** how long this store keeps recorded video.
- **Shard duration:** the target media duration of a store-defined recording/delivery
  unit. It may govern file or object rotation, or a streaming batch/window; it does
  not require a filesystem file. Use this term instead of "shard size" in prompts
  and JSON to avoid implying bytes. Each store documents its interpretation.

JSON fields shared by every store type (current local defaults):

```json
{
  "RetentionPeriod": "1w",
  "ShardDuration": "1m"
}
```

Use one duration parser and validator for interactive input and hand-edited JSON,
reusable for future camera options where a duration is needed. Implemented input grammar:

- Unsigned whole-number components with explicit, case-sensitive units: `s` seconds,
  `m` minutes, `h` hours, `d` days, `w` weeks, `M` months, and `y` years. Accept compounds
  such as `1h30m`, `1w2d`, and `1y2M`, optionally separated by spaces.
- Fixed elapsed-time conversions: a minute is 60 seconds, an hour is 60 minutes,
  a day is 24 hours, a week is seven days, a month is 31 days, and a year is 365 days.
  `m` and `M` are distinct; do not lowercase input before parsing.
  Thus `1w2d` is nine days, `1M` is 31 days, and `1y` is 365 days. These are not calendar
  intervals and are independent of time zones, daylight saving, and leap years.
  In particular, `12M` is 372 days and intentionally differs from `1y`; normalization
  must preserve total duration rather than carrying twelve months into one year.
- Require a positive total. Reject negative values, unitless numbers, unknown units,
  trailing junk, and overflow. Do not initially support fractions or natural-language
  date expressions.
- Preserve readable duration strings in JSON; normalize to an exact duration/checked
  whole seconds internally. Confirm the interpreted duration in the interactive UX.
  Additional safe bounds and the relationship between retention and shard duration
  should be validated before a store is enabled, not silently clamped.

The macOS 26.1 SDK's `NSDateComponentsFormatter.h` explicitly documents that parsing
is not implemented (`getObjectValue` always returns NO). Foundation's
[Duration.UnitsFormatStyle](https://developer.apple.com/documentation/swift/duration/unitsformatstyle)
provides localized formatting, not a compact-duration parse strategy. Plan a small,
deterministic shared parser for the grammar above (implemented as `IntervalText`); use system duration types and
formatting where useful. Do not substitute a locale-dependent date parser.

Shard duration is a target, not a promise of frame-exact cuts. For independently
playable shards, the store must respect keyframes; stop/disconnect can produce a
shorter final shard. A streaming store owns its own framing/boundary requirements.
Different stores can choose different durations. A long shard does not imply an
unbounded in-memory buffer; resource limits still apply.

All stores expose the same duration syntax, but enforcement capabilities must be
honest. Native [S3 Lifecycle expiration](https://docs.aws.amazon.com/AmazonS3/latest/userguide/intro-lifecycle-rules.html)
uses whole-day object ages rounded to midnight UTC, and deletion is
[asynchronous](https://docs.aws.amazon.com/AmazonS3/latest/userguide/troubleshoot-lifecycle.html).
S3 Lifecycle is the sole authority for S3 object expiration: HBNVR will not list and
delete objects to enforce retention. Validate that S3 retention resolves to a positive
whole number of days; reject unsupported values such as `1h` rather than silently
rounding. Distinguish recording age from upload age when recovering a backlog:
uploading old footage does not backdate its S3 lifecycle age. Retention is not a
promise of deletion at an exact elapsed-time deadline.

### S3 setup and lifecycle authority

Use existing, user-created buckets only. Do not request bucket-creation or
bucket-deletion permission. Setup will collect bucket, region, and recording prefix,
then produce a scoped IAM permissions policy before asking for upload credentials.
An optional expected-owner account ID can guard against using the wrong bucket.
API credentials are not an IAM user's console username/password; never echo secrets.
The precise credential-provider and upload implementation remain future work.

Support two explicit lifecycle-management modes:

- **Managed (default):** the store's configured retention is the desired source of
  truth. Request `s3:GetLifecycleConfiguration` and `s3:PutLifecycleConfiguration`
  on the exact bucket, in addition to scoped upload permissions. Read, merge, apply,
  and verify HBNVR's stable-ID rules for this store's prefix, preserving unrelated
  rules and settings. Never blindly replace lifecycle configuration if reading it
  failed. Report desired retention separately from successfully applied or
  unverified retention.
- **External (advanced):** the user configures expiration using separate AWS
  administrative credentials. Generate an upload policy without lifecycle read/write
  permissions, and do not attempt lifecycle API calls. Uploads work normally;
  configuration/status identifies retention as externally managed and unverified,
  not as a service failure. Any locally displayed retention target is advisory,
  not a claim that HBNVR has applied or enforced it. Explain that a missing or
  ineffective external rule can leave recordings accumulating indefinitely.

**Security warning in setup and documentation:** managed-mode credentials can
potentially cause object deletion even without `s3:DeleteObject` or object-read
permission, by changing expiration rules. Lifecycle permissions are bucket-wide;
our prefix/rule convention does not restrict what a stolen credential can change.
Recommend a dedicated recording bucket. AWS explicitly includes
`s3:PutLifecycleConfiguration` among the permissions that must be denied to
[prevent lifecycle-driven deletion](https://docs.aws.amazon.com/AmazonS3/latest/API/API_PutBucketLifecycleConfiguration.html).
External mode removes this lifecycle-management authority from the recorder's
credentials; it is useful for security-sensitive unattended machines, but does not
make upload credentials harmless or objects immutable.

If managed-mode lifecycle access is denied, warn without stopping otherwise
successful uploads. Do not silently switch modes or claim retention was applied.
Keep a stable lifecycle-warning state separate from upload health; emit a warning
once per unresolved incident, not on every shard, with bounded retries and another
attempt after relevant configuration/credential changes. Tell the user how to fix
the grant or explicitly choose external management. Actual upload authorization,
destination, and transport failures remain real errors, not lifecycle warnings.

The [lifecycle write API](https://docs.aws.amazon.com/AmazonS3/latest/API/API_PutBucketLifecycleConfiguration.html)
replaces the bucket's entire lifecycle configuration. Preserve existing settings
and avoid suggesting that read/merge/write is race-free against another administrator.
Tests must cover both modes, denied lifecycle access with successful uploads,
preservation of unrelated rules, warning deduplication, and honest applied/unverified
status. Native expiration and outage-buffer replay are separate concerns. The
RAM-first delivery and disk-recovery decisions are recorded below; exact retry and
backpressure thresholds remain open.

### Lifecycle and safety defaults

- **Enable:** persist participation in new recordings. No automatic historical backfill.
- **Disable:** stop accepting new media; finalize and deliver previously accepted
  work according to the store's format, including draining an S3 backlog. Continue
  retention housekeeping. This is not a full pause.
- **Remove:** remove configuration, not stored recordings. Refuse removal while
  accepted work would be stranded; do not silently discard a backlog.
- **Change:** warn before reducing retention because existing recordings may become
  eligible for deletion. Block unsafe destination changes while work is pending.

Local-store defaults have command help and tests. For S3, define a safe path for repairing
credentials with a pending backlog; do not make a failed login impossible to fix.
No pause, purge, or force-discard command is included in the initial CLI slice.

Retention is per store, not global. The local store checks approximately every 30
seconds and ages finalized files from their modification time, set at completion;
abandoned partial files age from creation, while open files are exempt. Readable
filenames retain local start time, independent of retention age. Legacy filenames
keep their embedded retention timestamps. It only deletes recognized, daemon-owned,
single-link regular files in camera folders marked for this store or its exact
legacy directory. Other backends must
specify their own age/enforcement mechanism without deleting unrelated contents.

## Store independence and delivery contract

**Containerization belongs to the store.** The shared recording pipeline must not
hand stores pre-wrapped media files or require a filesystem path as its delivery
contract. A store is a consumer of encoded media, not merely a copier of finished
files. This supersedes the earlier proposal to create shared playable segments
before distributing them to stores.

Receive and depacketize camera video once. Recording policy gates distribution of
immutable encoded access units to enabled stores. The shared media contract supplies
track/codec configuration (including initialization/parameter-set data), media timing
and time base, keyframe information, and recording lifecycle/discontinuity events.
Define presentation/decode timing where required rather than treating arrival time
as the media clock. Codec changes and reconnects must be explicit to consumers.

Each store owns container/muxing choice, framing, shard boundaries, naming/addressing,
destination, and retention. Shared muxing helpers can avoid duplicate implementation,
but using them is optional and does not move ownership into the store manager.
Different stores may produce different formats and durations from the same incoming
encoded media without decoding/re-encoding merely to wrap or divide it differently.
One destination must not block reception or another destination; queues/buffers and
retained references to shared media must have explicit bounds.

- A local store muxes media into its chosen files and owns its directory and retention.
  Its explicit durability goal is incremental on-disk recording, not whole-shard
  atomic publication: keep a visible `.mp4.recording` file, checkpoint metadata and
  flush in reasonable batches, then finalize and rename. Preserve interrupted output
  for recovery within retention. Avoid per-frame syncs, whole-file copies at commit,
  and any claim that process-crash tests guarantee physical power-loss safety.
- An S3 store chooses its object representation and creates completed shards in RAM
  before upload, without routine local media-file writes. It owns uploads, retries,
  lifecycle integration, and a private recovery spool for adverse conditions and
  graceful shutdown. On recovery it uploads spooled work and deletes each local copy
  only after confirmed upload. See the delivery decisions below.
- A future streaming store may emit framed media/messages without a traditional file
  abstraction. It must define what shard duration and retention mean for its destination,
  and validate capabilities rather than silently ignoring common settings.
- An S3 disk spool is **not** a local recording store. S3-only configurations can
  use disk fallback without enabling local recording.
- Enabling both local and S3 means independent copies, not a fallback relationship.
- Track volatile RAM acceptance, durable disk-spooled acceptance, and completed
  upload distinctly. RAM-only pending segments can be lost on process failure;
  disk-spooled work must be recoverable after restart.

A store manager owns configured instances, enablement, media/event routing, and
aggregate status, not containers or files. A small built-in Swift protocol supplies
each store's implementation. Individual stores own buffering, containerization,
persistence/delivery, recovery, cleanup, and health. Acceptance/durability reporting
must not assume that a local file exists.

## S3 shard delivery and recovery

### Implemented S3 decisions (updated through 0.7.6)

The complete current contract, JSON defaults, and limits are in [S3-STORE.md](S3-STORE.md),
with an explicit-destination [AWS smoke procedure](S3-SMOKE.md). These settle the
historical discussion's formerly open values:

- Existing never-versioned, SSE-S3 general-purpose AWS buckets;
  S3 Standard; dedicated explicit access key/secret in private JSON. No object reads.
- Optional client-side encryption password prompted during setup, blank to omit;
  shared change editor keeps/replaces/disables it explicitly. Apple's PBKDF2-HMAC-SHA256
  (600,000 rounds, fresh 32-byte salt per shard) and CryptoKit AES-256-GCM encrypt
  finalized MP4s before upload/spooling. The versioned `.mp4.hbnvr` envelope is frozen
  with the shard; pending work retains its original encryption across settings changes.
  `hbnvr decrypt INPUT OUTPUT` provides offline, authenticated recovery with a hidden
  password prompt and no AWS permissions. No custom KDF or encryption algorithm.
  The daemon retains the password privately; keep old passwords for old footage.
- Add/change shared editor with visible `hbnvr/<store UUID>/` default prefix,
  fixed destination, no prefix overlaps, generated IAM policy, hidden secret, and
  authenticated 15-minute asynchronous validation jobs. Failure can save disabled.
- Managed read/merge/write/verify lifecycle, serialized by bucket, startup/change/hourly;
  nonfatal separate warnings. External makes no lifecycle calls. Rules survive removal.
- AVAssetWriter segment-output RAM MP4s; H.264/H.265 passthrough, keyframe boundaries,
  complete short shards. AWS SDK 1.7.78, one attempt, checksums, PUT below 64 MiB,
  sequential multipart above it with adaptive 16 MiB minimum parts and 600s HTTP deadlines.
- Five slots, one reserved live, one serial error retry with shared full-jitter backoff
  capped at 30s. Three transient failures in 30s without success spool; redlines immediate.
- 60s non-overlapping oldest-shard probe; one confirmed success clears upload-error only.
  Replay uses background capacity; a failed replay joins the serial retry lane.
- Pressure: finalized residents > max(10, 2 × recording cameras), ready RAM age
  > max(120s, 2 × shard duration), or OS warning. Clear below half count with age/OS normal.
- Private 0700/0600 per-store spool, 10 GiB including staging/unreadable files, 2 GiB free reserve.
  Durable staged/hash-verified publication; bounded replay; never evict unuploaded video.
  Full/unwritable spool suspends only this store while preserving volatile accepted work.
  A controlled RAM probe is allowed when disk handoff failed with no eligible disk shard.
- Disable finishes media but drains; change preserves pending keys/bytes and permits
  credential repair; remove requires disabled/drained/no unreadable work. Shutdown has 45s
  app / 60s launchd / 75s installer budgets and explicitly reports unsafe RAM-only work.
- Crash/power failure can lose RAM-only footage. Local stores retain responsibility for
  incremental durability and incomplete-container recovery. No local-to-S3 backfill.

The detailed discussion below records the reasoning; where it says a threshold,
credential source, container, quota, removal rule, or deadline is undecided, the
implemented decisions above are authoritative.

These decisions supersede suggestions of streaming unfinished shards into S3 or
recovering truncated S3-spool video files. They do not change the local store's
incremental recording/recovery behavior.

### Completed-shard atomicity

- Finalize each shard into a complete video file in RAM, then upload it as one S3
  object. A completed shard is the unit of upload and S3 atomicity; the S3 store
  does not promise remote protection of individual frames within an unfinished shard.
- Ordinary [S3 PutObject](https://docs.aws.amazon.com/AmazonS3/latest/API/API_PutObject.html)
  does not publish partial requests. [Multipart uploads](https://docs.aws.amazon.com/AmazonS3/latest/userguide/mpuoverview.html)
  retain completed parts but require an explicit completion request; disconnecting
  does not automatically publish an interrupted shard. We are not building that
  unfinished-upload recovery scheme or depending on S3 Express append semantics.
  This does not prohibit multipart transport for an already-finalized large shard.
- Checksums are not the obstacle to incremental delivery, and disabling them is not
  part of the design. Preserve upload integrity checking.

### RAM-first lifetime and backpressure

- In healthy operation, a shard lives in memory from its first received frame
  through finalization, waiting for upload, upload itself, and confirmed completion.
  Only an adverse condition or graceful shutdown moves it into the recovery spool.
  Do not routinely write a temporary video file before every upload.
- Continue recording the next shard while earlier shards upload. Two resident shards
  per camera per S3 store will be normal; three, four, or more are also legitimate
  during temporary backpressure. A shard count above two is not itself an error,
  failure, or automatic reason to spool. Total memory includes all active, queued,
  and uploading shards across cameras and store instances.
- Trust the user's chosen shard duration rather than imposing an arbitrary small
  per-shard memory cap or silently shortening the configured duration. Explain its
  memory implications, including bitrate and overlapping resident shards.
- Backlog growth is a separate concern. Upload failures/timeouts, sustained
  backpressure, or memory pressure can trigger spooling mode; do not allow an
  unavailable or persistently slower destination to build an unlimited RAM queue.
  Exact pressure thresholds and concurrency limits remain policy decisions, not
  implicit one- or two-shard limits. Recovery uses the periodic probe described below.
- Never release a shard's only copy until its upload is confirmed or a successful
  durable handoff to the disk spool has preserved it. Failed spooling must not be
  treated as successful delivery or permission to discard the RAM copy silently.

### Shard responsibilities and the upload-management layer

Use one logical upload manager per S3 store as the entry point for ready shards
from all of that store's cameras. A shard is assembled/finalized and reports
"ready for upload"; it does not independently inspect global pressure, choose a
network request time, or launch its own retries. The upload manager decides whether
to dispatch immediately, wait for capacity, or persist it under spooling mode.
"Immediate first attempt" means prompt dispatch through this manager, not bypassing
its accounting or scheduling. Upload outcomes return to the same management layer.

"Arbiter" and "arbitrator" in this roadmap describe higher-level policy responsibility,
not a requirement for one monolithic object. The upload manager may delegate to
separate error-policy, scheduling, transport, and spool components. The distinction
is shard/media-lifecycle work versus store-wide upload decisions; concrete Swift
types and concurrency primitives are not prescribed here. This is separate from
the existing store manager, which routes shared camera media to independent stores.

Keep admission, queue membership, capacity reservations, and completion accounting
coherent across those components. The management layer can observe ready-but-waiting
shards, active uploads, retries, queued age, resident bytes, and upload completions
to detect backpressure. A growing ready queue is meaningful even without HTTP errors;
a full set of upload slots alone need not imply sustained trouble. Also report
currently assembling shards' memory usage, which ready-queue accounting alone misses.
Disk backlog is tracked separately rather than counted as if all of it were in RAM.
All dispatch paths, including probes and replay, share the same capacity accounting.

### Binary spooling mode and policy arbitration

For each S3 store, the upload-management layer owns one binary spooling-mode flag.
Its shard-routing decision consults the current value at every decision point;
individual shards need not observe or own that flag:

- **Off:** attempt an upload.
- **On:** persist the completed shard to the private disk spool. If it is already
  spooled, retain that copy rather than rewriting or duplicating it.

Decision points include initial shard finalization, a scheduled retry after an
eligible error, and dispatch of recovered backlog. Retries must consult the current
mode rather than remember the mode from the initial attempt. Changing the mode
governs subsequent decisions; it does not by itself cancel an upload already in
progress. Confirmed uploads still release their RAM/spool copies normally.

A higher-level arbitrator owns error classification, in-flight shard accounting,
and transitions into and out of spooling mode. It can turn spooling on in response
to a qualifying error or an excessive number of in-flight shards. The exact count
definition and threshold remain to be chosen; accounting must represent resident
active/queued/uploading work, not mistake the number of HTTP requests for total
buffered work. Having several shards resident is not itself an error.

Shard/media-lifecycle components report readiness and state; transport components
report outcomes. They do not embed their own error-to-spooling rules or independently
decide that a backlog is too large. After an error, arbitration occurs before routing
the affected shard through its next decision point. The same separation applies to
shutdown: shutdown policy selects spooling, and finalized pending shards follow the
ordinary spool path.

Recovery probes and retry scheduling belong above this binary routing decision.
While normal upload decisions are diverted to disk, the arbitrator explicitly
authorizes one periodic probe upload of existing spooled work, as described below.
This avoids waiting for an ordinary successful upload that spooling mode prevents.
Each store's mode is independent of other S3 stores and of local stores.

### Immediate first attempts, centrally sequenced retries

- In normal operation, a newly finalized shard immediately reaches its first upload
  decision point by reporting ready to its store's upload manager. If spooling is
  off, make it immediately eligible for a live upload slot without waiting behind a
  retry queue or adding a routine retry delay. First
  attempts may overlap, subject to the shared upload limit below. This does not
  change the allowance for multiple resident shards.
- On failure, report the outcome to the higher-level arbitrator. It classifies the
  error, updates failure/pressure state, and either routes the shard to disk under
  spooling mode or enqueues an eligible retry. A shard never starts its own retry
  loop or independently schedules a retry timer.
- Use one shared retry scheduler per S3 store across all of its cameras/shards.
  Dispatch at most one retry upload at a time, with shared pacing/backoff and jitter;
  simultaneous failures must not result in simultaneous retries or a tight sequence
  of requests merely because each failed shard has its own retry budget.
- At dispatch, consult the current spooling flag again. If it is now on, persist the
  shard (or retain its existing spool copy) instead of issuing a normal retry upload.
  A retry failing again returns to the arbitrator, never directly to another upload.
- Deduplicate queued work by shard identity and do not upload the same shard
  concurrently. Preserve fairness across cameras; one permanently failing shard
  must not prevent other eligible work from progressing. Exact queue ordering and
  delay values remain open. Disk-backlog replay and controlled recovery probes share
  this scheduling authority and its capacity limits. Recovery replay can use bounded
  parallelism as described below; error-triggered retries still run one at a time.
- Configure the upload transport/SDK so autonomous per-request retries cannot bypass
  arbitration and reintroduce concurrent retry loops. Initially prefer one transport
  attempt per arbiter-observed attempt; any necessary lower-level retries must be
  explicitly coordinated and accounted for by the same scheduler.

This sequences retries, not all healthy uploads. Normal first attempts may coexist
with the single retry in progress while spooling is off. The arbitrator can turn
spooling on when errors or overall resident work warrant it. It retains a separate
controlled recovery path while ordinary upload decisions are diverted to disk.

### Recovery probes and live-priority backlog draining

Shard routing still has only spooling on/off. Recovery scheduling belongs to the
upload-management layer, not a third mode exposed to individual shards.

- **While spooling:** once a minute, attempt to upload the oldest eligible completed
  shard in this store's disk spool. Allow only one probe at a time; a slow probe must
  not overlap another at the next tick or cause missed ticks to accumulate requests.
  If there is no eligible spooled shard, do not manufacture a test object. A failed
  probe leaves the file in place and normal shards continue to spool.
- **On confirmed probe success:** delete that confirmed spool copy and turn spooling
  off for the recovered upload-error condition. One confirmed shard upload is enough;
  do not require several consecutive successful probes or a drained disk backlog.
  An independently active shutdown or memory-pressure reason can still require
  spooling; a successful network probe must not override those protections.
- **Once spooling is off:** live shards take the immediate upload path. Separately,
  the arbitrator drains disk backlog oldest-eligible-first using bounded parallelism
  until it is empty. Recovered backlog can include shards whose uploads failed before
  the outage; this is deliberately not restricted to the single-error-retry lane.
  Keep each spool file until that shard's upload is confirmed.
- Use one total upload limit per store, with capacity reserved for live shards. For
  example, with five total slots and one reserved live slot, background uploads can
  occupy at most four. Five/one are illustrative tuning values, not fixed defaults.
  Live uploads can use any available slot, including slots not used by background
  work. Background work may not borrow the reserved capacity while waiting for live
  shards, and new live work takes priority over queued background dispatches.
- All network upload work counts against the total, including retries and probes.
  Background replay/retry work also shares the background cap; it must not obtain
  an extra slot outside that budget. There is at most one error-triggered retry in
  progress. A failed backlog upload enters that paced retry path and cannot be
  immediately redispatched as fresh replay to bypass backoff.
- "Immediate" means eligible without a retry delay, not unlimited concurrency. If
  simultaneous live shards exceed available slots, queue them in RAM with priority
  over background work; do not cancel already-running uploads to make room. Account
  for all cameras when tuning live capacity. Slot reservation protects admission,
  not a guaranteed share of network bandwidth; assess throughput during testing.
- If new errors or pressure turn spooling on again, stop launching ordinary uploads
  and backlog replay; normal decision points spool/retain work and periodic probing
  resumes. Already-running uploads may finish and confirmed successes are honored.
  During graceful shutdown, stop recovery dispatch as well and preserve pending work.

Use bounded reads/streaming from spool files during replay instead of loading the
entire disk backlog into RAM. Restart recovery uses the same scheduler and limits.
Unreadable work is preserved/rechecked until repaired; no AWS error makes a shard
permanently non-retryable. Rotate failed probes and paced retries so one failing file
does not permanently block other eligible backlog behind it.

### Error classification and escalation

Agreed shape: the arbitrator distinguishes immediate-spooling ("redline") errors
from tolerable transient errors. A redline switches this store to spooling at once.
Other qualifying upload errors accumulate over a short interval without successful
uploads; enough such failures also switch it to spooling. In-flight pressure remains
an independent trigger. The manager's shard-routing decision still uses only the
binary mode; individual shards do not implement this policy.

Recommended initial policy (details and numerical thresholds are proposals):

- Classify by operation, transport error, structured S3 error code, and scope, not
  HTTP status alone. Confirmed network unavailability/no route is an immediate-spool
  candidate; an isolated timeout, connection reset, or transient DNS failure need
  not prove the network is unavailable. Store-wide upload authorization or invalid
  destination errors should preserve footage on disk and clearly report that user
  intervention is needed, rather than retry rapidly as if they were transient.
- Retry transient upload failures such as S3 InternalError/HTTP 500 and 502/503/504
  through the shared scheduler with bounded exponential backoff and jitter.
  Recognize throttling/SlowDown as
  requiring reduced request pressure. AWS's [retry guidance](https://docs.aws.amazon.com/sdkref/latest/guide/feature-retry-behavior.html)
  likewise distinguishes transient, throttling, and non-retryable errors; our
  spool policy is separate from the transport/SDK retry policy.
- Start with an explainable failure streak in a rolling window rather than a
  weighted statistical model. For example, three failed logical upload attempts
  within 30 seconds with no intervening confirmed shard upload could trigger
  spooling. These numbers are illustrative, not selected defaults. Expire old
  observations using monotonic time; a confirmed shard upload resets the soft-error
  streak for this store, not another store's streak.
- Count one outcome per arbiter-observed upload attempt; do not hide uncontrolled
  SDK retries inside it or double-count the same failure at multiple layers.
  Redline signals should reach arbitration immediately rather than wait for a
  per-shard retry budget. A success means confirmed object upload, not successful
  DNS resolution, lifecycle configuration, connection setup, or a multipart part.
- Keep pressure/progress safeguards independent: intermittent successes must not
  conceal a growing RAM backlog, and slow failures must not evade protection simply
  by falling outside the error window. Backlog age, pending-work/no-progress deadlines,
  and in-flight limits need tuning for configured shard sizes and upload throughput.
  Idle time with no pending work is not an upload failure.
- Do not infer a store-wide outage from a shard-specific malformed request or media
  defect. Preserve and report affected work separately. A denied lifecycle-management
  request remains the nonfatal lifecycle warning described above and must not trigger
  upload spooling when uploads work.
- Once spooling is active, an unrelated or already-in-flight success must not
  automatically override an outstanding redline or pressure reason. For upload-error
  recovery, use the agreed once-a-minute probe and one confirmed success. Pressure
  entry/exit thresholds and repair-triggered retry details remain to be chosen;
  the arbitrator must not require an empty disk backlog before permitting its upload.

Report the reason for a mode transition, with useful evidence such as recent failed
attempt count/window or resident-shard pressure. Test isolated failures, error bursts,
success resets, expiration of old errors, intermittent successes with growing backlog,
SDK retry accounting, redlines, operation-specific exclusions, and recovery transitions.

### Private disk recovery spool

- The spool belongs exclusively to this S3 store, not to a configured local store.
  It holds completed, finalized, upload-ready shards. It is temporary recovery
  storage, not a second recording archive, and requires no local store to be enabled.
- When adverse conditions clear, drain the spool to S3 while recording continues.
  Delete each spooled shard only after confirmed upload; retain failed/unconfirmed
  work for retry. Resume this recovery after daemon or machine restarts.
- Keep volatile RAM backlog, disk-spooled backlog, and confirmed S3 delivery distinct
  in status. Recovery must not block another store or the camera receiver.
- Durable spool handoff, interrupted spool writes, and ambiguous upload acknowledgments
  still need safe bookkeeping and tests. This is not permission to add video-container
  salvage machinery; report damaged spool entries rather than silently discarding them.

### Graceful shutdown: short duration, complete video

- Stop accepting new frames, then finalize the active shard at its actual duration.
  It may be shorter than `ShardDuration`, but must be a complete, valid video file.
  "Partial shard" here means partial duration, never an unfinalized/truncated container.
- Persist that shortened shard and all other completed shards whose uploads remain
  unconfirmed to the private spool before a successful graceful exit. Shutdown must
  not depend on the network being available or an S3 upload completing.
- On the next startup, upload this backlog and delete local copies only after
  confirmation, using the same recovery path as other spooled shards. Finalization
  or persistence failures must be reported, not described as a successful safe shutdown.

### Explicit durability boundary and verification

S3-store data that remains only in RAM can be lost on a crash, forced termination,
or power failure. HBNVR cannot retroactively spool RAM after power disappears.
Users requiring incremental on-disk recording and partial-file recovery should also
enable a local store. The S3 store does not salvage truncated/unfinalized video,
read local-store recordings, or automatically backfill from a local store.

Tests must cover RAM residency until confirmed delivery, overlapping shards without
premature spooling, sustained backpressure triggering the selected policy, failed
disk handoff, restart replay, confirmed-upload-only spool deletion, shutdown with
network unavailable, and short but valid shutdown shards. Test binary routing at
initial/retry/replay decision points, arbitration before retry, mode changes during
an upload, independent store modes, and recovery while spooling is active. Verify
all ready/retry/probe/replay paths use coherent manager capacity accounting, and
queue growth can be detected even when uploads eventually succeed. Exercise
simultaneous shard failures to verify retries are serialized and paced, first attempts
remain immediate in healthy operation, queued retries observe later mode changes,
and SDK retry behavior cannot bypass scheduling. Test minute-paced/non-overlapping
oldest-shard probes, single-success reopening, live-slot reservation and priority,
bounded parallel replay, retries sharing capacity, no duplicate shard dispatch,
relapse into spooling, and bounded-memory restart replay. Exercise fault boundaries and
ambiguous acknowledgments without assuming process-crash tests prove physical
power-loss safety. No default threshold or specific container/muxer is selected here.

## Shared configuration workflow

Extract the reusable parts of camera/store configuration, not a universal resource
with identical runtime behavior:

- Stable ID, display name, schema version, and persistent enabled state.
- Selection by ID/name or interactive picker.
- Shared add/change editing flow: defaults, validation, cancellation, and confirmation.
- Type-specific options, secret handling, and validation.
- Common store retention/shard-duration options and a shared duration parser.
- Plain, obvious, hand-editable JSON; atomic validated persistence through the agent.

Preserve existing camera IDs and configuration compatibility during the refactor.
Keep stop/edit/restart as the documented manual-edit workflow until hot reload is
explicitly designed. Cancelling an editor must leave saved configuration and runtime
state unchanged. Editing options must not change physical camera settings implicitly.

`camera list`, `store list`, and aggregate `status` should have human-readable and
JSON output. Report store enablement separately from operational health, pending work,
and durable/volatile backlog. Do not expose credentials in listings, errors, or logs.

## Implementation sequence

1. **Implemented in 0.5.0:** shared durations, store manager/protocol, JSON models,
   shared store add/change editor, and add/list/change/remove/enable/disable commands.
   Receive once and deliver encoded media to independent local MP4 writers, with
   private directory setup, keyframe-aligned sharding, retention, and playable-video
   verification. Cameras record automatically to every enabled store. No S3 stub
   is exposed as if it could record.
2. **Implemented in 0.6.0:** `camera` namespace and shortcuts, list/change with
   stable IDs, shared name/profile editor and camera/store selection helper.
   Daemon-side profile discovery keeps credentials private; stale edits are rejected.
3. **Implemented in 0.6.0:** persistent camera enable/disable and start/stop,
   default-true migration, per-camera routing, bounded shard draining, and distinct
   configured intent/stream health/recording status.
4. **Implemented in 0.7.0:** the self-contained S3 store with RAM-first completed-shard uploads,
   policy-driven backpressure handling, a private disk recovery spool, short finalized
   shards on graceful shutdown, and retry/restart recovery. Use per-store S3 Lifecycle
   retention with managed and external lifecycle authority as described above.
5. Add trigger-driven recording and any additional camera/store options through the
   same configuration paths.

Keep the complete local build/test path usable without sudo. Test CLI parsing,
selection, cancellation, configuration migration, authorization, and lifecycle
transitions before adding real storage side effects. Duration tests must cover
compounds, whitespace, case-sensitive `m`/`M`, fixed 31-day months and 365-day years,
the intentional `12M`/`1y` difference, normalization preserving total duration,
positive bounds, overflow, and identical CLI/JSON interpretation. Storage tests must
cover independent shard durations/formats and
failures, backlog recovery, retention boundaries, and safe removal. Exercise a
file-free test consumer to verify the shared delivery contract has no file dependency.

## Remaining decisions for future recording/storage work

- How trigger-driven recording combines with persistent manual recording intent,
  including overlapping triggers and any temporary overrides.
- Acceptance/durability acknowledgements for future backends. Local media routing,
  keyframe starts, shard finalization, restart behavior, and retention are implemented.
- Optional future S3 versioning, KMS, Express, renewable credential providers, or
  additional AWS partitions; these are outside the supported V1 contract.
- Any stronger coordination with outside bucket administrators; within-daemon
  lifecycle serialization cannot eliminate external read/modify/write races.
- Optional bandwidth controls beyond the implemented five-slot/one-live-slot
  concurrency reservation. Slot priority is not a bandwidth guarantee.

S3 credential replacement with backlog, fixed destinations, container/transport,
retry/probe/pressure defaults, quota/full-disk behavior, durable publication,
shutdown budgets, and lifecycle-rule preservation on removal are **settled and
implemented**, not remaining design questions. The implementation separates
`S3RecordingStore`, `MemoryMP4Shard`, `S3UploadManager`/`S3UploadPolicy`, `S3Spool`,
`S3Transport`, `S3LifecycleCoordinator`, and `S3SetupJobs`.

These are intentionally open, not implied by the command names above.
