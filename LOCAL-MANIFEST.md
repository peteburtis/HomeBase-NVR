# Local recording manifests and shard timing (0.13.1)

Each camera directory receives `.hbnvr-manifest.sqlite` when this version starts
writing new footage there. This is a **prospectively maintained recording index**.
New 0.10.0 MP4s embed their own authoritative timing and identity, making a future
explicit rebuild possible; no rebuild operation exists yet. Existing MP4s and
`.mp4.recording` files are never scanned,
adopted, backfilled, or assigned capture times from filenames/filesystem dates.
The pre-existing retention policy still ages those files normally.

The [media IPC](MEDIA-PROTOCOL.md) reads this index, finalized MP4s,
completed disk fragments, and the local writer's resident encoded samples for availability/frame
requests. It adds no playback CLI, Homebase media relay, GUI,
S3 manifest, or rolling playback history. No keyframe/byte-offset tables are maintained;
the media reader opens the selected MP4 and finds keyframes from its samples.

## Location, permissions, and ownership

```text
<chosen local root>/Living Room Camera/
    .hbnvr-camera.json
    .hbnvr-manifest.sqlite
    2026-09-17_12-00-00.mp4
    2026-09-17_12-01-00.mp4.recording
```

The database is daemon-owned, mode `0600`, with the same inherited requester/daemon
ACLs as recordings. The existing camera marker and an identity row in the database
bind it to a particular camera and store. The store worker is its single writer.
Homebase queries NVR's playback discovery/range APIs, not this database directly.

SQLite uses DELETE rollback-journal mode, FULL synchronous commits, and macOS
fullfsync. A temporary `.hbnvr-manifest.sqlite-journal` can appear during writes or
remain after a crash; do not delete it independently. No WAL/shared-memory file is
normally created. Existing database/journal links, extra hard links, wrong owners,
or broad POSIX modes are refused. The camera directory's private ACL policy remains
in force. This is not protection against the authorized directory owner editing
their own recordings or index.

## Stored information and time semantics

Schema version 2 contains `identity`, `camera_metadata`, and `recordings` tables.
`camera_metadata` is a singleton containing the last recorded display name,
optional Homebase hardware-device ID, and metadata-update UTC time. This time is
only for choosing the newest descriptive metadata across renamed directories;
it never determines a frame's capture time. Metadata is committed in the same
transaction as shard creation, before accepting the first sample. Unchanged
metadata does not receive a new update time. Camera removal does not erase it.
While a camera is configured, discovery prefers its current name/binding; after
removal/restart, retained manifest metadata makes its history discoverable.

Opening a version-1 database for writing adds the metadata table transactionally,
preserving all recording rows. Read-only playback can still read version 1 but
returns no historical display name/hardware binding until new recording supplies
them. No metadata is inferred from directories, file timestamps, or aliases.
Discovery is read-only and never marks active shards interrupted.

Each recording stores:

- A UUID, current relative filename, and intended finalized filename.
- `start_utc`: canonical time at media zero, as Unix seconds in UTC.
- Required `received_utc`, `canonical_source` (`camera` or `received`), and
  `timing_json` containing the exact versioned MP4 metadata. `camera_utc` is NULL
  only when no usable camera-clock mapping is available.
- The camera media clock's `timescale`, first 32-bit RTP `source_timestamp`, and
  `end_ticks` relative to the MP4's zero-based media origin.
- Accepted frame count and `recording`, `complete`, or `interrupted` state.
- Finalized file device/inode/byte size, used to reject missing/replaced/truncated
  files when answering availability queries. File dates are not timeline inputs.

Reception stamps each complete encoded frame before store queues and maps RTP to
camera UTC using RTCP sender reports for the matching SSRC. Unknown/zero/relative,
malformed and stale (over 120 seconds) mappings are not used. RTP wraps
are handled with signed modular deltas; NTP era selection handles the 2036 rollover.
The receiver retains a bounded set of at most eight source mappings. No ONVIF clock
settings, camera clock changes, or camera reconfiguration are performed.

The tested TP-Link cameras send consistent video RTP/NTP pairs but advertise a
different SSRC in RTCP. For the single video track on explicitly negotiated TCP
channels 0/1, HBNVR can associate by channel after two advancing reports received
since the current RTP source began. There must be only one fresh report source;
its RTP/NTP progression must agree within 100 ms, and both report age and the
frame/report RTP offset must be within five seconds. Ambiguity fails closed to
receipt time. The embedded `time.cameraClock` records method `ssrc` or
`interleavedChannel` and the report SSRC; the outer `ssrc` records the video SSRC.
This exception never associates across connections or negotiated tracks.
These cameras also encode the fractional NTP word as nanoseconds. When standard
NTP fractions fail the cadence check, three successive reports (two intervals)
must agree with video-clock progression within 100 ms under the nanosecond
interpretation, with every fractional value below one billion. Only then is that
interpretation used. `time.cameraClock.fractionEncoding` records `ntp` or
`nanoseconds`; ambiguous/inconsistent evidence remains unavailable.
Once inferred, the fractional format is retained for that report source. An
isolated inconsistent report does not replace the last validated channel mapping;
that mapping still expires five seconds after its original report, not five
seconds after each reuse. A changed RTP source or ambiguous report sources clear it.

At a new timing epoch, use camera time as canonical if its absolute difference
from actual complete-frame reception is **at most 2.5 seconds**, otherwise reception
time. Keep camera evidence even when outside that tolerance. An unavailable camera
clock is absent, not a fake zero timestamp. All stores share this decision before
fan-out. This is a plausibility policy, not a claim about exposure-time accuracy.

Within an epoch, all three timelines advance by unwrapped RTP media offsets, not
per-frame network jitter or nominal FPS. Received time is therefore a **smooth
receipt-anchored timeline**. `firstFrameReceivedUTC` separately preserves the actual
arrival of each shard's first complete frame. The canonical source is frozen for
an epoch. A source change, camera mapping appearing/disappearing, or a camera-clock
correction exceeding 250 ms starts a new epoch at the next keyframe; no existing
shard is retimed. These transitions may create real timeline overlaps or gaps;
the index does not pretend the files are contiguous. Smaller clock corrections
are tolerated until they accumulate past that boundary threshold.

Explicit recording stops, connection ends, and known dropped-frame events finalize
the current shard. Recording restarts on an existing live connection retain its
shared timing epoch; a new connection establishes a new mapping. A source-time jump greater
than `max(2 seconds, 8 × the preceding frame interval)` or a wall-clock step over
one second relative to monotonic receipt time splits the shard and reanchors; new
media waits for a keyframe. SSRC/clock-rate changes also start an epoch. Non-increasing RTP
timestamps retain the existing no-B-frame rejection. These are observed recording
boundaries, not continuity inferred from adjacent filenames. Small source cadence
variations follow the encoded sample timing, not an assumed fixed frame rate.

### Embedded MP4 metadata

Both local MP4 and segment-output RAM/S3 writers set a UTF-8 description metadata
item before writing samples. AVFoundation maps this to MP4's ISO user-data `dscp`
field (it silently drops arbitrary QuickTime metadata keys for this output).
The JSON identifies itself with `format: com.graygoolabs.hbnvr.timing`; readers
recognize the payload rather than relying on AVFoundation's metadata-key alias.
Its JSON schema 1 is:

```json
{
  "format": "com.graygoolabs.hbnvr.timing",
  "schemaVersion": 1,
  "storeID": "<UUID>", "cameraID": "<UUID>", "shardID": "<UUID>",
  "time": {
    "cameraUTC": 1789680000.0,
    "receivedUTC": 1789680000.2,
    "canonicalUTC": 1789680000.0,
    "canonicalSource": "camera", "epochID": "<UUID>",
    "cameraClock": {
      "method": "interleavedChannel", "reportSSRC": 12345,
      "fractionEncoding": "nanoseconds"
    }
  },
  "firstFrameReceivedUTC": 1789680000.2,
  "timescale": 90000, "rtpTimestamp": 123456789, "ssrc": 42
}
```

All dates are Unix seconds, independent of display timezone. For each timeline,
add the MP4 presentation offset to its anchor to place a frame. A missing camera
clock omits `cameraUTC`. No credentials are present. Encoded video samples are
passed through unchanged. The S3 key/shard ID agrees with the embedded ID; client
encryption covers the embedded metadata along with the MP4. Pending older shards
remain untouched, including their destination, bytes and retry keys.

Metadata is not cryptographic authenticity for an editable local file, and does
not guarantee an unfinished container survived a power cut. Automatic manifest
reconstruction and incomplete-video salvage remain separate future work.

## Lifecycle and failure policy

1. Before the first sample, attempt to commit a `recording` row with its actual time anchor.
2. At most once per five seconds of active frame processing, commit accepted-frame
   progress. No per-frame SQLite commits or idle heartbeat writes occur.
3. Finalize/synchronize the MP4, rename the same file, and synchronize its directory.
4. Commit the final filename, media end, frame count, file identity, and `complete`
   state in one SQLite transaction.

`recording` progress is provisional: AVAssetWriter can still buffer those samples.
It is **not** advertised as readable/durable coverage. The manifest-only coverage
helper returns only `complete` rows with a matching existing regular file. Media
IPC also considers `recording` rows, but only to locate a current writer's pinned
file: it independently parses a fixed completed-fragment prefix and obtains its
readable duration. This does not require more frequent manifest checkpoints or
claim that AVFoundation-buffered samples are on disk. A bounded RAM bridge separately
publishes shared references to the writer's actual accepted sample buffers and
retires them as disk fragments become readable. It requires no per-frame manifest
writes. Interrupted/unowned files are never adopted through this path.

An interrupted process leaves `recording` rows that are marked `interrupted` when
the writer next opens that manifest. Failed finalization also marks the row
interrupted when possible. These entries are not playable availability, even if
a final-named file exists: a crash between file publication and database commit
may leave valid but unindexed footage. There is no automatic media salvage or
reconstruction. SQLite's normal transaction-journal recovery still applies; that
is database consistency recovery, not footage backfill.

Retention unlinks a recording first, then removes its known row. If interrupted
between those operations, a query excludes the missing file. User-deleted,
replaced, or truncated indexed files are also excluded without inferring alternate
paths or capture times. The byte-size/inode check is not a content-integrity hash.

A manifest failure is an **indexing warning, never a reason to stop video writes**.
The writer closes the failed connection and retries opening/validating the index
at later shard starts with 1–30 second capped backoff. It also retains the current
shard's original timing/identity metadata: after confirmed MP4 finalization it can
commit the complete entry even if the initial row or a progress checkpoint failed.
This uses known in-process recording facts, not a directory scan or media backfill.

If that final index write fails, a RAM-only queue holds at most **16 finalized
metadata entries per store**, with no video bytes or open file descriptors. Each
entry expires **60 seconds after its initial final-write failure**. Retry delays
are 1, 2, 4, 8, 16, then capped at 30 seconds (attempts normally at +1, +3, +7,
+15, and +31 seconds, with discard at +60). At most one queued attempt runs per
one-second maintenance tick. Delayed ticks do not extend expiry. A full queue
rejects the new metadata entry rather than evicting accepted work. Shutdown clears
remaining entries without waiting for the retry window; process crashes lose them.

Each retry opens a fresh validated SQLite connection without marking another live
shard interrupted. It verifies the finalized file's frozen device/inode/size and
commits idempotently: an already-committed identical row is success, while conflicting
rows, replaced footage, and unsafe databases are preserved. Older retries cannot
replace newer camera names/bindings. Initial failures, each retry failure, successful
recovery, queue-limit rejection, expiry, and shutdown discard go to both error logs.
Discard affects **only pending index metadata**, never video (normal retention still
applies). Such a shard can remain absent from playback. This mitigation does not fix
the underlying file-access/descriptor failure or repair pre-existing index gaps.

Pending retries keep the manifest warning visible even when a newer shard indexes
successfully. Recovery clears the current warning when no other camera update needs
attention; discarded gaps remain in the error log rather than being auto-rebuilt.
Failed media writes/finalization instead abandon that shard for fresh keyframe
attempts with bounded backoff; they never permanently latch recording off.

Completed or unfinished video is preserved subject to normal retention. Corrupt,
foreign, unsafe, or unsupported databases are never silently reset. Deleting or
replacing an open index is detected; before indexing a subsequent new shard, the
writer must reopen and validate it. A deliberately removed manifest starts empty
on that next attempt; prior footage remains unindexed except for still-retained,
in-process finalized metadata within the bounded retry window. Back up using SQLite's
backup facilities or copy while the store is stopped; this is not disposable cache.
Retention retries independently, and index errors do not prevent normal expiration
of owned media files.

Errors are timestamped in `<local root>/.hbnvr-errors.log` as well as the ordinary
agent log. SQLite diagnostics include operation, primary and extended result codes,
and OS errno when available, captured before rollback can replace them. The private
log rotates at approximately 1 MiB with one previous `.1` file. No raw SQL values
or credentials are logged. Failed diagnostic writes never gate video or retries.

## Query contract

`LocalRecordingManifest.coverage(from:to:)` accepts finite, half-open UTC intervals
`[start,end)` inside the daemon. It returns matching finalized recording records,
merged available intervals clipped to the request, and their complement as gaps.
Overlapping valid recordings are not double-counted. No adjacent files are assumed
contiguous, and filesystem timestamps are never consulted for this calculation.

"Gap" means **not available through this manifest**, not proof that recording
never happened. Existing unindexed footage and footage whose manifest was lost are
intentionally invisible to these queries.

The eventual external API can express "now minus" ranges and reusable server time
anchors; that conversion belongs in NVR above this internal UTC-based index. Frame
streaming, keyframe preroll, and file demuxing remain outside the manifest.

## Verification and inspection

`LocalManifestTests` covers prospective creation, no backfill after deletion,
gaps/overlaps, provisional and interrupted rows, safe paths/permissions,
corruption/unsupported schema, blocked writes, idempotent retained completions,
preservation of live rows/newer camera identity during retry, timestamp wrap and clock changes,
missing/replaced/truncated media, retention, and real synthetic-video shard timing.
The existing H.264/H.265 local recording and power-interruption tests remain in use.
`RecordingTimeTests` checks RTCP parsing, source matching, rollover/expiry, the
2.5-second policy, jitter/clock transitions, and metadata round-tripping through
both MP4 writers with byte-identical encoded samples and successful decoding.

An explicitly opt-in live test reads Homebase camera configuration/credentials,
discovers a stream, discards video, and prints only timing summaries. It makes no
AWS calls and changes no installed configuration. After building tests:

```sh
HBNVR_LIVE_CLOCK_TEST=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun xctest -XCTest CameraClockLiveTests/testHomebaseCameraClockMapping \
  /private/tmp/hbnvr-build/Build/Products/Debug/HBNVRTests.xctest
```

Also setting `HBNVR_LIVE_CLOCK_RECORD=1` writes short local test shards in a private
temporary directory, compares each MP4's embedded timing to SQLite, checks playback,
and removes that temporary footage at the end. It never configures an S3 store.

Live verification on 2026-09-17 confirmed the two configured TP-Link cameras'
channel-associated, nanosecond-fraction reports. Once validated, Living Room's
camera time trailed complete-frame receipt by 0.34–0.43 seconds and Bedroom's by
0.40–0.52 seconds in that sample (not a guaranteed latency bound). Both selected
camera time as canonical after initial receipt-time fallback. Five playable test
shards per camera had embedded metadata exactly matching their SQLite rows;
temporary footage was removed and no AWS upload was performed.

After separately installing the build and recording a new shard, inspect a camera
directory with your normal account (substitute its actual path):

```sh
sqlite3 -readonly "$HOME/NVR/Living Room Camera/.hbnvr-manifest.sqlite" \
  "SELECT filename, datetime(start_utc, 'unixepoch'), canonical_source, camera_utc, received_utc, end_ticks * 1.0 / timescale AS seconds, frames, state FROM recordings ORDER BY start_utc DESC LIMIT 10;"
```

This reads metadata only; no camera video or AWS access is needed. A short query is
preferable to a long SQLite transaction that blocks the recording writer. Files
predating installation are expected not to appear. New rows are provisional until
the shard finalizes. Active-shard media availability comes from the actual completed
disk fragments, not these provisional progress columns; see [the media protocol](MEDIA-PROTOCOL.md#reading-a-shard-that-is-still-recording).
