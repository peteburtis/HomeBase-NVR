# HBNVR media IPC — version 1 (hbnvr 0.22.0)

This is the local, authenticated media-request API. Homebase is one potential
client; no Homebase-specific binding is required. This release does not modify
Homebase's endpoint configuration or expose an NVR network listener. Homebase's
separate thin relay can forward these records over its existing media WebSocket.

The provider reads **indexed local recordings**, including finalized files in
disabled stores, completed on-disk fragments of currently recording shards, and
the local writer's newest accepted encoded frames still resident in RAM.
It does not maintain a rolling history, retrieve/decrypt S3 objects or spool
files, reconstruct lost indexes, salvage interrupted files, or forward continuous
live video. Those intervals are unavailable through this API.
No new disk storage is created by playback. Camera recording/streaming settings
are never changed by a request.

## Playback discovery

Before querying times, use the ordinary authenticated command protocol on
`control.sock` (newline-delimited JSON, **not** the binary media framing):

```json
{"protocolVersion":1,"operation":"playback.snapshot"}
```

Or dedicate a connection to `playback.watch` to receive the initial snapshot,
replacement snapshots on changes, and unchanged heartbeats every 30 seconds.
Both operations return the same `playbackSnapshot` shape:

```json
{
  "protocolVersion": 1,
  "playbackSnapshot": {
    "instanceID": "daemon-instance-uuid",
    "revision": 7,
    "ready": true,
    "stores": [{
      "id": "store-uuid", "name": "Local recordings", "type": "Local",
      "enabled": false, "frameReading": true, "state": "available"
    }],
    "cameras": [{
      "id": "camera-uuid", "name": "Living Room Camera",
      "homebaseDeviceID": "camera-vendor-serial", "identityAmbiguous": false,
      "configured": false, "enabled": false, "recordingStarted": false,
      "stores": [{"storeID": "store-uuid", "recordingEnabled": false, "indexedHistory": true}]
    }]
  }
}
```

The example describes a removed camera with retained history in a disabled store.
Disabling recording does **not** disable playback. Fields mean:

- `instanceID` is shared with `cameras.snapshot/watch`; revisions are independent.
  A changed instance invalidates the previous discovery session. Each snapshot is
  a full replacement, not a delta or journal; reconnect to obtain current state.
- `ready: false` means the current configuration is awaiting a background scan,
  not that the catalog is empty. Poll or watch until ready. `ready: true` means
  inspection completed, **not** that every store is accessible.
- `frameReading` describes NVR's capability, independently of current reachability:
  true for local stores, false for S3. S3 stores additionally include optional
  `s3` destination metadata: `bucket`, `region`, `prefix`, optional `expectedOwner`,
  and optional `clientEncryptionFormat` (`hbnvr-pbe-v1` when enabled). Credentials,
  passwords, private paths, and spool settings are never included. No AWS calls
  or playback of S3/spool data are introduced; a destination is not proof of footage.
- Store `state` is `checking`, `available`, `partial` (some indexes could not be
  inspected), `unavailable` (root inaccessible), or `unsupported` (S3). Available
  means the root/indexes could be inspected, not that every video file is intact.
- Camera `configured`, `enabled`, and `recordingStarted` describe current camera
  configuration. Retired cameras have all three false. `recordingEnabled` is
  per-store routing intent, not stream health or a guarantee new frames arrived.
  Today every configured camera is associated with every configured store.
- `indexedHistory` means that store has manifest rows for this camera. It is not
  an assertion of exact time coverage or playability; `availability` remains the
  authority. Interrupted/stale rows may have no readable coverage.
- The current configured name/hardware binding takes precedence; otherwise use
  last-recorded manifest metadata. Never match Homebase by alias, directory name,
  filename, or network address. Multiple conflicting persisted hardware bindings
  set `identityAmbiguous: true` and omit `homebaseDeviceID`; do not guess a match.
  Legacy metadata can lack both name and hardware binding; camera UUID still works.
  As with recording controls, if multiple NVR camera IDs match one Homebase device,
  clients must not arbitrarily choose one as that device's recording-control target.
  Playback may keep those distinct recording identities visible.

Catalog inspection runs on one coalescing background worker, with five-second
polling for new/expired history and mounted-volume changes. Configuration changes
schedule inspection immediately. Scans read index identity and row existence,
not video samples or exact time coverage; they do not write manifests. Filesystem
stalls cannot block the control loop or recording queues. Known historical camera
membership is retained in memory during failed/partial inspections and remains
marked uncertain by store state. After daemon restart an inaccessible store's
historical cameras cannot be rediscovered until its manifests can be read.
Successful inspection removes memberships whose manifests contain no rows.
Removing a store removes it from discovery even though its files are preserved.

Starting with 0.15.1, media requests read only the first discovered Local store
(current ID ordering). All four operations use that same root and do not search
other Local stores on gaps or errors. Discovery still lists the complete catalog;
Homebase advertises only the first Local and first S3 destination. S3 credentials
belong to the reading client, not Homebase or the recorder's write-only principal.

There are at most eight playback subscriptions, independent of camera watchers and
media sessions. Each buffers only the newest snapshot, has a five-second write
deadline, and rechecks controller authorization before writes/heartbeats. On EOF
or missed heartbeats, invalidate discovery and reconnect (a 75-second heartbeat
deadline matches the existing Homebase integration). A reply containing `error`
invalidates the cached catalog until a successful replacement arrives. The 64-KiB
command limit applies; oversized catalogs fail explicitly, never silently truncate
or masquerade as empty. Snapshot/watch never return paths, endpoints, or secrets.

The complete sequence is **catalog → availability → frames**. Use camera UUIDs
from this catalog for media requests. NVR combines local stores and storage tiers;
clients do not select filenames, RAM versus disk, or a store ID when requesting frames.
Homebase's consumer of this catalog is separate work; this release adds only NVR IPC.

## Admission and connection lifetime

Connect to the existing `control.sock` in the system or local runtime directory.
Use a dedicated connection, not a camera-watch or ordinary command connection.
Both sides should verify the OS-provided Unix-socket peer identity. The server
applies its existing UID/account-UUID policy: the installing controller and root
in system mode, or the agent's UID in local mode. Media access deliberately grants
that principal the ability to receive recorded video, not merely control recording.
There is no application-name check, client-supplied identity, bearer token, file
descriptor transfer, shared memory, or access to camera/AWS credentials.

Send this one newline-terminated command-protocol JSON message:

```json
{"protocolVersion":1,"operation":"media.open","mediaProtocolVersion":1}
```

Wait for the ordinary JSON reply **before sending any media records**. Pipelining
across the upgrade is not supported. A successful reply includes:

```json
{"protocolVersion":1,"mediaSession":{"version":1,"discovery":"playback.snapshot","discoveryWatch":"playback.watch","framing":"type-u8,length-u32be,payload","maxMessageBytes":65536,"maxRangeSeconds":86400,"idleTimeoutSeconds":60,"requestTimeoutSeconds":300,"source":"localRecordings","includesActiveDiskFragments":true,"includesResidentLocalFrames":true,"supportsKeepalive":true,"supportsNeighbors":true}}
```

An error is an ordinary command error and closes the connection. Otherwise the
descriptor is transferred to an independent media worker and is permanently
media-only. Commands and subscriptions remain responsive on other connections.

If `supportsKeepalive` is true, a client can send the normal JSON-framed record
`{"requestID":"warm-1","operation":"keepalive"}` between requests. The response
is `{"type":"alive","requestID":"warm-1"}`. It revalidates peer authorization
and restarts the idle wait without scanning stores or reading frames. Send it at
20–30 second intervals when idle, never while awaiting another response. It has
no camera, path, time range or recording side effects. Older daemons omit this
capability; clients must not send keepalives without negotiation.

There is one active request per connection. After an `end` record the client may
send another request, including for a different camera, or close. Closing cancels
the current request; a different seek can open another connection. Parallel work
uses separate connections. **EOF is not End and never proves successful delivery.**
Clients should not pipeline requests; each request's relative anchor is resolved
when the server starts processing it, not when its bytes were sent.

Authorization is revalidated before each request. There are at most eight media
sessions, independent of the existing eight camera-watch subscriptions. Shutdown
cancels sessions before recording finalization. No session survives daemon restart.

## Binary record framing

After the successful handshake, every record in either direction consists of:

| Field | Encoding |
|---|---|
| Type | 1 unsigned byte: `1` = UTF-8 JSON, `2` = encoded-video bytes |
| Payload length | 4 unsigned bytes, big-endian; excludes this 5-byte header |
| Payload | Exactly that many bytes; no trailing newline |

Each record must have 1–65,536 payload bytes. Clients send only type 1. A frame's
payload may be larger than one record: its JSON `frame.byteCount` is followed by
as many type-2 chunks as needed to deliver exactly that many bytes. No JSON record
may interrupt those bytes. A client must accumulate or stream the chunks according
to that count, not assume one `recv()` is a record or one record is a video frame.
Binary video is not base64, Annex B start-code data, an MP4 container, or RTP packets.

Framing violations close the session. A well-framed but malformed/unsupported
request receives `end` with `outcome: error`; the session may then be reused.

## Range requests

There are three operations: `availability`, `frames`, and the optional
`neighbors` capability, using the same fields.
`cameraID` is HBNVR's camera UUID (from playback discovery), not an alias, hardware ID,
filename, or arbitrary path. An unknown/unindexed camera has no available footage.
`requestID` is a nonempty printable string of at most 64 bytes, echoed in all JSON
response records. It is correlation only, not a durable identifier or replay key.

Absolute example:

```json
{"requestID":"seek-1","operation":"frames","cameraID":"11111111-1111-1111-1111-111111111111","timeline":"canonical","range":{"start":1800000000,"end":1800000030}}
```

Absolute timestamps are **Unix seconds in UTC**, with fractional seconds allowed.
The caller converts local calendar/timezone input before sending. Ranges are
half-open `[start,end)`, positive-duration and at most 24 hours; split longer queries.
`timeline` defaults to `canonical`; alternatives are `camera` and `received`.
Received means the **smooth receipt-anchored media timeline**, not each packet's
arrival time. A shard without camera-clock evidence cannot satisfy a camera-time
request; the server does not silently substitute canonical or received time.

Relative example (the same range model applies to `availability`):

```json
{"requestID":"seek-2","operation":"frames","cameraID":"11111111-1111-1111-1111-111111111111","relativeTo":"live","range":{"start":-45,"end":-15}}
```

- `relativeTo: live`: resolve once against the latest received frame's anchor in
  the selected timeline. Streaming must currently be healthy (last frame within
  the existing 15-second watchdog window). Recording may be stopped. The chosen
  timeline must be available; otherwise return an unavailable error.
- `relativeTo: now`: resolve once against the daemon's current UTC wall clock,
  then query the selected timeline. This works without an active camera stream.
- Omit `relativeTo` for an absolute request. Relative offsets must end at or before
  zero. A live anchor is not a promise that the corresponding footage is retained.

## Timestamp thumbnails (0.15.0)

When `media.open` advertises `supportsThumbnails: true`, the same dedicated media
session also accepts a point request:

```json
{"requestID":"thumb-1","operation":"thumbnail","cameraID":"11111111-1111-1111-1111-111111111111","timeline":"canonical","relativeTo":"live","timestamp":-30,"size":{"width":320,"height":180}}
```

`timestamp` replaces `range` for this operation. All other time selectors have
the same meanings as range requests: `canonical` (default), `camera`, `received`;
absolute UTC Unix seconds, or nonpositive offsets from `now` or a healthy `live`
anchor. Resolve the anchor once at request start. Missing camera-clock evidence
never falls back silently to another timeline. Camera identity and authentication
are unchanged. No filesystem paths or store selector are accepted.

`size` is required and expressed in **pixels**, not device-independent points.
Each dimension must be an integer from 1 through `maxThumbnailDimension` (2048).
Output fits inside this bounding box, preserving aspect ratio without cropping or
upscaling. Actual integer dimensions are returned. The advertised format is
`thumbnailFormats: ["image/jpeg"]`, with `maxThumbnailBytes: 8388608`.

The result is `begin` (camera, timeline, resolved `timestamp`, optional relative
`anchor`), then one `thumbnail` record, its JPEG bytes, and `end`:

```json
{"type":"thumbnail","requestID":"thumb-1","thumbnail":{"mimeType":"image/jpeg","width":320,"height":180,"byteCount":12345,"timestamp":1800000000,"time":{"canonicalUTC":1800000000,"receivedUTC":1800000000.4,"cameraUTC":1800000000,"canonicalSource":"camera","epochID":"example"},"presentationTicks":0,"timescale":90000,"keyFrame":true}}
```

`time` is the ordinary full `RecordingTime` value, including camera-clock evidence
when present. `timestamp` is the **actual selected keyframe time** on the selected
timeline, not an assertion of an exact-frame match. The anchors plus
`presentationTicks / timescale` also locate the image on the other available
timelines. `begin.timestamp` retains the requested resolved point.

The point must fall within readable indexed coverage. Within that recording, use
the frame reader's nearest preceding keyframe (including its ordinary keyframe
preroll), rather than replaying intervening P/B frames. No arbitrary older image
is substituted for a gap. Use `neighbors` separately to find retained history.
Overlapping copies/epochs use the existing stable source ordering, preferring RAM
where available. Only one image is returned. RAM eviction or shard rotation during
the read can produce a retryable unavailable error, just as frame retrieval can.

JPEG bytes use the existing type-2 chunks, each at most 65,536 bytes; accumulate
exactly `thumbnail.byteCount`. They are not encoded-video NAL units. There is no
`segment` or `frame` record for a thumbnail. Success ends with `outcome: complete`,
`frames: 1`; uncovered points end with `unavailable`, `frames: 0`, no image. Errors
use the usual `end: error`; EOF never means success. After End, the session can
serve another thumbnail, range request, or negotiated keepalive.

Rendering decodes one H.264/H.265 keyframe using VideoToolbox and produces an
in-memory [Core Image JPEG](https://developer.apple.com/documentation/coreimage/cicontext/jpegrepresentation%28of%3Acolorspace%3Aoptions%3A%29).
It uses the same validated RAM, active-file-prefix, and completed-file readers.
No temporary image/media files, caches, manifest writes, recording changes or S3
reads occur. Two thumbnail requests may run concurrently, within the existing
eight-media-session cap; excess requests get a retryable unavailable error. Decode
waits are bounded to ten seconds within the ordinary request deadline. Source
dimensions are limited to 8192 per edge / 33,554,432 total pixels to bound decode
memory. Cancel by closing the media connection. These are preview images, not an
exact-frame export or a live-follow stream.

Older daemons omit this capability. Clients must check negotiation rather than
inferring support from camera playback metadata or the Homebase version.

## Response records

### Nearest retained recordings

When `media.open` advertises `supportsNeighbors: true`, send `operation: neighbors`.
The range is the excluded interval: search **all retained history in the selected local store** for the
nearest readable interval before `range.start` and after `range.end`. This does not
limit the search to 24 hours; only the excluded range has the ordinary range limit.
For a point in a gap, send a tiny positive-duration range starting at the cursor.

The response is `begin`, one `neighbors` record, and `end` with `outcome: complete`
and `frames: 0`. No video bytes or `gap` records are returned. For example:

```json
{"type":"neighbors","requestID":"next-1","neighbors":{"previous":{"start":1800000000,"end":1800000060},"next":{"start":1800100000,"end":1800100060}}}
```

Absent `previous`/`next` inside the required `neighbors` object means that no
interval exists in that direction **at query time**. An empty object means neither.
Errors, incomplete replies, inaccessible stores, and bounded-scan limits never
mean archive end. Older servers do not advertise the capability.

The lookup uses the first-discovered local store (including when disabled), using only
identity-bound indexes and the same validated disk/RAM frontiers as availability.
Deleted/replaced files are skipped; camera/received/canonical time rules still apply.
Intervals crossing the excluded range are clipped. Returned intervals describe
indexed readable sources, not a promise against later deletion or a damaged codec.
Clients fetch `frames` normally at the returned interval's start; preceding-keyframe
preroll remains the frame reader's job. No filenames or filesystem dates are used.

### Tag-filtered neighbors

The optional media-open capability is **`supportsTagFilteredNeighbors: true`**.
It extends `neighbors` with **`excludeTagKeys`**, an array of arbitrary tag-key
strings; media protocol version remains 1. Negotiate it on each new connection.
Omitting the field or sending null selects an empty array, preserving ordinary
recording navigation. A nonempty filter is valid only on `neighbors`; `includeTags: true` remains
frames-only. At most 32 distinct nonempty keys of at most 256 UTF-8 bytes each
are accepted. Duplicate keys and invalid types are rejected.

Exact request shape (optional `timeline`, `relativeTo`, and `excludeTagKeys`):

```json
{"requestID":"filtered-1","operation":"neighbors","cameraID":"11111111-1111-1111-1111-111111111111","timeline":"canonical","range":{"start":1800000005,"end":1800000005.001},"excludeTagKeys":["review.skip","workflow.private"]}
```

A sample is excluded if **any** requested key is present in its effective tags.
Values are opaque strings: `"false"` and `""` both count as present. No key has a
reserved meaning, and unrequested keys never affect navigation. HBNVR does not
define a hidden state, a veil, or application-specific tag policy. Clients own
that policy and choose the keys to send; the filter is not access control.

`timeline` is `canonical` (default), `camera`, or `received`; `relativeTo` may be
`now` or `live` with nonpositive offsets. Omit it for absolute Unix seconds. The
existing request-ID, camera UUID, finite increasing range and 24-hour excluded
range limits apply. The search itself may cross arbitrarily many days, within the
existing bounded scan/deadline limits.

Successful response shape (one JSON record per message, no binary payload):

```json
{"type":"begin","requestID":"filtered-1","cameraID":"11111111-1111-1111-1111-111111111111","timeline":"canonical","range":{"start":1800000005,"end":1800000005.001}}
{"type":"neighbors","requestID":"filtered-1","neighbors":{"previous":{"start":1800000000,"end":1800000002},"next":{"start":1800000010,"end":1800000012}}}
{"type":"end","requestID":"filtered-1","outcome":"complete","frames":0}
```

For relative requests, `begin` also includes numeric `anchor`, and its `range` is
resolved absolute time. Each neighbor is `{ "start": number, "end": number }` in
the selected timeline. `previous` and `next` are independently optional and omitted
when absent; an empty result is `"neighbors": {}`. Neither uses JSON `null`.

The query range may be a tiny interval within excluded footage or a gap. Each
side searches for the nearest matching recording interval, so matching A →
excluded → missing → excluded → matching B returns A and B from anywhere in the
unavailable middle. Gaps and any number of fully excluded recordings are skipped
in either direction. Overlapping recordings are compared by filtered bounds,
not just their whole-recording order, using the same source precedence as playback.

Returned intervals are half-open `[start,end)`, with `previous.end <= range.start`
and `next.start >= range.end`. Within a recording, runs split at actual sample
presentation times where effective presence of a selected key changes. Historical
edits between samples take effect at the first sample at or after the edit's
boundary. Prospective changes use exact sample ordinals, preserving MP4 clock
rounding semantics. A final run ends at the captured readable frontier. Intervals
are clipped to the excluded range and readable source coverage; adjacent RAM/disk
pieces of one recording are merged. They need not extend across recording-file
boundaries. Seek to an interval's `start` (or another point strictly before its
exclusive `end`); boundaries are not necessarily keyframes. Frame playback still
decodes preceding-keyframe preroll and clips its presentation normally.

The filter reuses the exact `includeTags` projection: prospective state changes,
historical overrides and explicit removals all apply; removal does not restore
an older embedded value. Legacy/missing metadata and unknown portions have no
public tag values, matching tagged playback.

The search reads identity-matched SQLite tag metadata and MP4 sample-table timing
through sample cursors, or captured RAM timing/tag metadata. It never enumerates
encoded frame payloads, decodes video, downloads recordings, or changes recordings,
tags, configuration or authorization. Supported sources are finalized local MP4s,
readable fragments in growing `.mp4.recording` files, and resident local RAM tails
in the selected first local store, including retained history when recording is
disabled. S3 and spool data are not searched.

Only `end` with `outcome: complete` confirms absence. An error is a terminal
`{"type":"end","requestID":"filtered-1","outcome":"error","code":3,"error":"..."}`
(the code varies: unavailable 3, permission 4, incompatible 5, timeout 6, invalid
request/scan limit 7). EOF, cancellation, malformed metadata, unavailable sample
indexes, revision changes and exhausted bounds must not be shown as archive ends.
No neighbor record is emitted until both directions finish. The per-recording
sample bound is 1,000,000; existing 10,000-row scan, 4096-root-entry and 300-second
request limits apply. A result describes a captured snapshot, not a guarantee
against later deletion, active-tail eviction or codec damage.

Application bridges may translate their own higher-level requests and capabilities
to this generic operation. They must negotiate `supportsTagFilteredNeighbors`
before sending nonempty `excludeTagKeys`; an older server may ignore unknown fields.
Reconnect after an NVR upgrade to renegotiate.

Direct S3 readers must implement their desired filtering themselves. S3 manifests'
`tagMetadata` is authoritative (including removals and encrypted metadata); never
fall back to stale embedded MP4 tags. Current manifests lack a per-sample PTS map,
so exact frame-ordinal/PTS parity needs bounded container sample-table reads or
additional sample-timing metadata. Reading entire video objects to search hours
of history is not required or supported by this local API.

Every JSON response has `type` and `requestID`. Unused fields are omitted.

| Type | Additional fields and meaning |
|---|---|
| `begin` | `cameraID`, `timeline`, resolved absolute `range`, and `anchor` for relative requests |
| `available` | `range`; emitted by availability queries, sorted/merged indexed coverage |
| `neighbors` | required `neighbors` object with optional `previous` and `next` ranges |
| `segment` | `segment` object described below; starts an independently decodable sequence |
| `frame` | `frame` object described below, immediately followed by its binary bytes |
| `gap` | `range`, `reason: notAvailableInLocalRecordings` |
| `end` | `outcome`, `frames` on normal completion; or `code` and sanitized `error` on failure |

Normal outcomes are `complete` (full requested coverage), `partial` (some gaps),
and `unavailable` (no coverage). `error` terminates a failed request, possibly after
some frames; it must not be treated as a completed range. Numeric error codes match
ordinary IPC: 3 unavailable, 4 permission, 5 incompatible, 6 timeout, 7 invalid
message. Transport failure may prevent delivery of End. If a frame/record or
segment tag payload is only partly written the server closes rather than inserting
an error into its payload.

Gap records follow available/frame data and describe the union of uncovered
intervals. They mean unavailable **through this provider**, not proof that footage
never existed or is absent from S3. Availability checks the index and file identity,
not every encoded sample; a subsequent frame read can fail or see retention removal.
Malformed/inaccessible manifests produce a request error, not invented coverage.

### Segment and frame objects

`segment` contains:

- `number`: a request-local integer; **not a stable frame/stream reference**.
- `range`: the decoding start (possibly earlier than requested) through the
  intended clipping end. Actual sample timing is provided on every frame.
- `time`: the shard's `RecordingTime` anchors at sample tick zero: optional
  `cameraUTC`, required `receivedUTC`, `canonicalUTC`, `canonicalSource`, `epochID`,
  and optional `cameraClock` evidence. See [timing semantics](LOCAL-MANIFEST.md).
- `timescale`: integer ticks per second for all sample timing in this segment.
- `codec`: `H264` or `H265`; `parameterSets`: small base64 JSON data values
  (SPS/PPS for H.264, VPS/SPS/PPS for H.265).
- `nalUnitLengthBytes`: 1, 2, or 4; each encoded sample contains big-endian
  length-prefixed NAL units in the original MP4 sample format.

`frame` contains `segment`, `presentationTicks`, optional `decodeTicks`,
`durationTicks`, `keyFrame`, `preroll`, and `byteCount`. Absolute time on any
available timeline is its segment anchor plus `presentationTicks / timescale`.
Do not derive frame rate from frame count, packet numbering, or filenames.

The reader selects the nearest preceding keyframe within the available recording.
If none exists, it begins at the next available keyframe before the requested end
and reports the missing interval. Preroll frames must be decoded but not presented
as requested content. Samples with presentation time at/after the clipping end are
not sent; a final sample's duration may extend past it, so clients clip presentation.
Each new segment carries fresh codec/anchor information and starts on a keyframe;
clients must not assume decoder continuity across segments.

The reader uses [AVAssetReader passthrough output](https://developer.apple.com/documentation/avfoundation/avassetreadertrackoutput/outputsettings)
and skips empty-media markers, without decoding or transcoding. It keeps the
existing no-B-frame limitation. The frame bytes round-trip unchanged in tests.

Overlapping RAM/disk sources sharing one recording epoch fill coverage holes rather
than duplicating presentation; selection prefers the resident keyframe-aligned tail
and uses on-disk ranges for the remaining history. Separate epochs with
overlapping wall times remain separate segments, not silently merged footage.
Keyframe preroll can repeat bytes even where requested presentation is deduplicated.
The current API does not provide exact frame references or a live-follow operation.

### Segment tag maps (0.22.0)

The opening `mediaSession` advertises `segmentTagsVersion: 1`,
`maxSegmentTagBytes: 4194304`, and `maxTaggedSegmentFrames: 1000000`.
Only `frames` requests accept `includeTags: true`; it defaults to false.
Existing requests receive the original segment/frame framing without any tag
payload or extra sample scan. Homebase/GUI consumers are not changed in this slice;
their request validation/decoding must adopt this capability before requesting it.

```json
{"requestID":"tagged-1","operation":"frames","cameraID":"11111111-1111-1111-1111-111111111111","timeline":"canonical","range":{"start":1800000000,"end":1800000030},"includeTags":true}
```

For each returned segment, its JSON header additionally contains:

- `tagRangesVersion: 1`.
- `tagFrameCount`: the number of video frames selected for this segment, including
  keyframe preroll. Count frames from zero separately for each segment.
- `tagByteCount`: byte length of the immediately following UTF-8 JSON dictionary.

Read exactly `tagByteCount` bytes from type-2 binary records (each at most the
ordinary 65,536-byte record bound), concatenate them, and decode the dictionary
**before** processing this segment's first video-frame header. No JSON record or
video payload is interleaved inside that dictionary. This is one logical map per
segment, not metadata on every frame. Even an empty map sends the two bytes `{}`.

Example map for a 45-frame segment:

```json
{
  "person.alice": [
    {"startFrame": 0, "endFrame": 10, "value": "present"},
    {"startFrame": 20, "endFrame": 45, "value": "present"}
  ],
  "example.note": [{"startFrame": 5, "endFrame": 8, "value": ""}]
}
```

Spans are sorted, non-overlapping, half-open `[startFrame,endFrame)` **per key**.
Adjacent equal values coalesce even if unrelated keys changed between them.
An empty string is a value. A key missing from the map, or a frame outside that
key's spans, has no value. Unknown legacy metadata and known absence deliberately
have the same public representation; no complete vocabulary, unknown marker,
removal tombstone, file path, or edit history is sent. Internal explicit removals
still suppress original embedded values. Applications assign any meaning to
absence; the NVR does not interpret tags as authorization.

Frame ordinals describe the actual returned samples, not nominal FPS. Prospective
changes use the writer's recorded sample ordinals, so MP4 clock rounding cannot
move a tag change one frame late. Historical overrides resolve against sample
presentation times. Shard/RAM/disk boundaries may split transport segments and
reset their local frame numbering; identical values across adjacent footage are
not a semantic off/on transition. Coalescing here is within each returned segment,
not a new archive-wide tag-range query API.

Completed recordings use the manifest's effective timeline, matched in one SQLite
read to the exact file identity pinned by that reader. Concurrent edits either
produce a retryable changed-source error or leave an already-captured old revision
consistent for the whole segment. The next request sees the new revision. Video
bytes are never modified to serve tags and live camera tag state is never consulted.

For active recordings, the writer publishes the bounded tag timeline and accepted
frame frontier together with each RAM append. Snapshots retain immutable/COW
metadata but only weak video handles. RAM eviction does not discard the active
tag timeline. Growing-file requests capture it before inspecting disk and cap
their frame/time frontier to that snapshot, so SQLite's periodic checkpoint cannot
leave the newest accepted frames mislabeled. RAM snapshots capture their frames
and tags under the same short lock. Finalization/eviction still interrupts reads
as documented below; tag delivery never pins an entire GOP or delays recording.

Tagged disk reads extend the existing keyframe scan through the selected end,
retaining only bounded sample coordinates, then stream the same pinned source.
Limits per segment: 1,000,000 sample coordinates, 65,536 value-bearing spans, and
4 MiB encoded tag JSON. Oversized maps fail explicitly rather than dropping tags;
narrow the range. The five-minute request deadline remains in force. A failed or
interrupted segment may deliver fewer than `tagFrameCount` frames; only a successful
End completes the request. Clients must not treat undispatched frame ranges as video.
Thumbnail tag reporting and S3/client interpretation remain separate features.

## Reading a shard that is still recording

There is no need to wait for the one-minute shard to close. For disk reads, each request captures
the completed fragment prefix of its active `.mp4.recording` file and reads that
fixed prefix directly from disk. The next request can see newer fragments. Both
`availability` and `frames` use the parsed on-disk media duration, **not** the
manifest's provisional accepted-frame count or a guessed file timestamp.

The existing writer targets a one-second first fragment and five-second subsequent
[movie fragments](https://developer.apple.com/documentation/avfoundation/avassetwriter/moviefragmentinterval).
Disk fragments alone can lag several seconds behind live. The RAM bridge below
fills that tail up to the latest frame accepted by the local writer, including
before its first disk fragment exists. Neither source promises a latency deadline.
A request reaching
beyond the readable edge returns the available frames plus a gap, not a promise
that those last seconds were never recorded. Retry that interval as recording
progresses. Frames merely waiting in a store's input queue have not yet been accepted
by the writer and are not exposed as recorded footage.

Finalization can rewrite the MP4 layout. Before allowing that rewrite, the writer
invalidates active read snapshots. It does not wait for playback clients, force an
early shard rotation, or hold a camera/store queue behind socket backpressure. A
request caught by closure may end with `unavailable` / `outcome: error`; if a frame
was only partly sent, the session closes instead. In either case, retry the desired
absolute interval on the finalized file (reconnect after EOF). Frames received
before closure remain valid, but EOF alone never completes the range.

Only a currently registered writer with matching embedded/index identity and a
pinned private regular-file descriptor can supply an active prefix. Old interrupted
files are not automatically exposed. There are no temporary media copies, additional
per-frame SQLite writes, forced early finalizations, or recording durability changes.

## Minimal RAM bridge

The local writer publishes references to the **same encoded CMBlockBuffers** it
appends to AVAssetWriter; playback never creates a second encoded payload copy or
decodes pictures to retain them. These shared references can extend a buffer's
lifetime until its disk fragment is readable. They are not free memory, but they
avoid duplicating the payload and are retired independently of playback demand.
All buffers remain immutable after append, as required by
[AVAssetWriterInput](https://developer.apple.com/documentation/avfoundation/avassetwriterinput/append(_:)).

A utility worker checks growing files once per second and inspects media metadata
only when the complete fragment prefix changes. It releases earlier samples once
disk can serve them, keeping a keyframe-aligned overlap to decode the remaining
tail. Queries can also advance this frontier. No file reads or AVFoundation waits
run under the cache lock or on the camera/store recording queue. Final publication,
recording stop, or writer destruction removes the registration and releases the tail.

Playback-only safeguards are **16 MiB / 4,096 frames / 30 seconds per active local
shard**, and **64 MiB total per daemon**, whichever limit is reached first. These
are maximum retained tails, not a target history or a recording/shard-size limit.
Oldest GOPs are discarded to stay within bounds. OS memory-pressure warnings clear
the bridge; caching resumes on a keyframe after pressure returns to normal. The
recording writer continues unchanged, even if playback temporarily falls back to
the disk fragment edge. S3 recording memory and its independent pressure policy
are not changed; S3-only RAM shards are not a source in this release.

Request snapshots hold timing metadata and weak sample handles, not an entire GOP
or shard's payloads. Sending holds at most one resident sample per session, plus
bounded wire chunks. Thus a slow/disconnected client cannot preserve an old bridge
or delay its retirement. The bounds above exclude buffers still independently owned
by AVFoundation and the at-most-one in-flight sample per admitted media session.
If a snapshot's sample is retired mid-request, the server returns a retryable
unavailable error. Retry the absolute range; the same protocol searches disk when
RAM has been released. Receiving some frames is not a successful End.

The newest sample's duration is provisional until the next PTS arrives. Completed
durations follow the same next-PTS rule as the no-B-frame MP4 writer. Every source
uses the shard's identical camera/received/canonical anchors and keyframe contract.
`status` reports each local store's `playbackRAMBytes` (human output: `Playback RAM`),
counting shared payload references, not an estimate of additional process RSS.

## Resource and filesystem bounds

The opening handshake retains the five-second command deadline. Media workers have
a 60-second idle deadline, five seconds to receive a started request record or write
an output record, a 15-second asset-opening deadline, and a five-minute whole-request
deadline. A slow client never blocks the reception/store queues. Historical output
is sent as fast as the reader and client permit, not paced at playback speed.

Queries reject more than 10,000 candidate shards/coverage intervals or 4,096 root directory entries;
they do not silently truncate. Range planning retains bounded metadata, not video.
Each reader retains one encoded sample at a time plus bounded wire/disk chunks;
it never loads a whole file/backlog into an application-owned cache. The shared
recent-frame bridge has the independent bounds above. AVFoundation manages its
own internal buffers.

Only identity-marked camera directories within configured local store roots are
considered. Manifests are opened read-only with existing permission checks. Before
reading a finalized recording, an `openat(O_NOFOLLOW)` descriptor is verified against
its manifest device/inode/size, ownership, private mode and link count. Active files
instead use the writer's pinned descriptor, verify its identity against the directory
entry, and bound every read to the captured complete prefix under a finalization guard. AVFoundation's
resource loader reads that pinned descriptor, not a pathname reopened after the
check. Retention may unlink an already-open recording without invalidating its
current read; later requests will no longer find it. Embedded timing must exactly
match the index. An authorized owner can still edit their own local media; this is
not cryptographic authenticity or protection against that owner.

## Verification

`MediaTests` exercises synthetic playable H.264/H.265 recordings, exact byte
passthrough, nearest-keyframe preroll, re-decoding responses, all three timelines,
gaps, missing camera time, duplicate store coverage, overlapping epochs, replaced
files, missing manifests, cancellation/deadlines, framing, authorization/revocation,
and real socket sessions that read finalized/active frames then accept a second request.
Active-file tests cover both codecs, prefix growth, unchanged encoded payloads,
provisional-index lag, all timelines, live-relative requests, cross-shard ranges,
replacement/orphan rejection, incomplete box tails, and concurrent finalization.
RAM tests additionally cover first-frame access before any readable disk fragment,
a single request spanning all three tiers, unchanged payloads and variable-rate
sample timing, re-decoding both codecs, shared block identity, weak snapshots,
automatic disk retirement, global/per-shard limits, pressure shedding without
recording loss, and binary IPC from resident frames.

`scripts/integration.py` launches isolated unprivileged agents and mock loopback
cameras to exercise the public `media.open` handshake, limits, reuse, malformed
requests, command isolation, shutdown, and live anchors with recording stopped or
the camera disabled. No installed daemon, real camera footage, or AWS access is
needed. Build and run the existing test suite and subprocess smoke suite normally.

### Thumbnail tags (0.23.0)

`thumbnail.tags` is the actual selected keyframe's effective string dictionary,
resolved with the same exact-frame projection as `includeTags` frame requests.
It incorporates historical edits across finalized, active-disk, and RAM sources.
Unknown/legacy metadata projects to no values. Tags remain opaque to HBNVR;
clients choose their presentation. JPEG bytes and framing are unchanged.
