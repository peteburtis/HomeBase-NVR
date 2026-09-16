# HBNVR CLI roadmap

Recorded September 16, 2026. The baseline below is implemented; subsequent camera
controls and S3 sections are a roadmap. No plugin loader is planned.

## Current baseline (0.5.3)

- System lifecycle: `install`, `uninstall`, `start`, and `stop` require sudo.
- `agent` supports both the system daemon and an unprivileged local instance.
- `status` / `status --json` report agent readiness and per-camera stream health.
- `add` and `remove` interactively manage cameras over authenticated IPC.
- Camera import reads Homebase configuration and credentials, then queries cameras
  directly. Manual RTSP-only configuration is also supported.
- Every configured camera with a stream URL is continuously received. Enabled
  stores record all cameras automatically; with no enabled stores, frames are discarded.
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
- Camera namespace/enablement/recording controls are explicitly deferred. The local
  store increment does not add or change the camera API.
- Camera add already has a shared options editor intended for future change:
  display name and video profile today, more camera options later.

## Planned command families

The `store` family below is available for local stores. The `camera` family is future
work; top-level camera add/remove continue to work today.

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
```

Retain `hbnvr add` and `hbnvr remove` as camera shortcuts. Top-level `hbnvr start`
and `hbnvr stop` retain their existing system-service meanings; they are not
recording controls.

An omitted selector opens an interactive picker. Stable IDs identify configurations;
names are editable human labels, not filenames or identity. Ambiguous names require
disambiguation, never an arbitrary match. Noninteractive callers must receive a
clear error instead of a prompt when a selection is missing or ambiguous.

Camera/store control uses the authorized user's IPC access without sudo. Default
to the installed service and support `--runtime-dir` for isolated development.
System lifecycle remains exclusively system-level. Storage destinations must be
accessible to the agent's account, not merely to the invoking CLI user.

## Camera controls: streaming versus recording

| Command | Intended effect |
| --- | --- |
| `camera enable` | Persist enabled state and open/maintain the stream. Do not implicitly start recording. |
| `camera disable` | Finish any active recording, close the stream, and persist disabled state. |
| `camera start` | Start recording an enabled camera to enabled recording stores. Reject a disabled camera clearly. |
| `camera stop` | Finish the current recording; keep receiving and discarding the stream. |

Enabled state is configuration. Recording state is operational, eventually driven
by manual commands and triggers. Report configured enablement, actual stream health,
and recording state separately: an enabled camera can be offline, and a streaming
camera can be idle or recording. Repeated enable/disable/start/stop should be harmless.

When introducing enablement, preserve today's behavior for existing camera files:
missing enablement means enabled. Define recording restart/reconnect behavior before
implementing recording commands; do not confuse persistent enablement with an
instruction to resume recording automatically.

## Recording stores

Use **recording store**, not archive. Each configured store is an independently named
instance with its own stable ID, type, enabled state, options, retention period,
and shard duration. Retention and shard duration are shared configuration concepts
across all store types, with independent values for every instance.
Support multiple local stores and multiple S3 stores, not one singleton per type.

`store add` should ask for:

1. Type: local directory or S3 (future; currently local only, so no type prompt).
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
It cannot by itself implement arbitrary short retention such as `1h`. Decide whether
S3 performs its own cleanup or validates a supported retention range; never silently
round a requested retention period. Also distinguish recording age from upload age
when recovering a backlog.

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
- An S3 store chooses its object representation and need not create a local media
  file before upload. It owns uploads, retries, retention, and its own optional RAM
  buffer and private disk spool. On recovery it uploads cached work and cleans up safely.
- A future streaming store may emit framed media/messages without a traditional file
  abstraction. It must define what shard duration and retention mean for its destination,
  and validate capabilities rather than silently ignoring common settings.
- An S3 disk spool is **not** a local recording store. S3-only configurations can
  permit disk fallback without enabling local recording.
- Enabling both local and S3 means independent copies, not a fallback relationship.
- Track volatile RAM acceptance, durable disk-spooled acceptance, and completed
  upload distinctly. RAM-only pending segments can be lost on process failure;
  disk-spooled work must be recoverable after restart.

A store manager owns configured instances, enablement, media/event routing, and
aggregate status, not containers or files. A small built-in Swift protocol supplies
each store's implementation. Individual stores own buffering, containerization,
persistence/delivery, recovery, cleanup, and health. Acceptance/durability reporting
must not assume that a local file exists.

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
2. Future: introduce the `camera` namespace and compatibility shortcuts; implement
   list/change using existing stable IDs and the camera options editor. Extract
   further genuinely shared configuration/selection helpers when both need them.
3. Future: persistent camera enable/disable, operational camera start/stop, and
   explicit migration/restart behavior from today's automatic-recording policy.
4. Implement the self-contained S3 store with bounded buffering, optional private
   disk spooling, retry/restart recovery, and independent retention.
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

## Decisions to settle before recording/storage implementation

- Manual recording behavior across daemon restart, camera disconnect, and trigger
  overlap; behavior when no enabled/usable store exists.
- Exact encoded-media/event types, codec initialization and changes, timing, bounded
  fan-out, and acceptance/durability acknowledgements.
- Shard-duration defaults and bounds, store-specific keyframe boundaries, and how
  start/stop finalizes partial output.
- How a newly enabled store joins an active recording (including initialization and
  keyframe requirements), and how disabling finalizes its current output.
- Retention age origin/enforcement timing, local ownership boundaries, and S3 lifecycle
  scope versus store-managed cleanup for durations native lifecycle cannot express.
- S3 credential sources, spool location/limits, overflow policy, retry limits, and
  safe credential/destination changes with pending work.

These are intentionally open, not implied by the command names above.
